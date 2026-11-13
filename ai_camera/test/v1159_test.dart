// v11.59 regression tests: sharp-source zoom, fail-closed microscope,
// offline handling (fake network only) and the anchored Styles hint.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/image_guard.dart';
import 'package:ai_camera/services/local_ledger.dart';
import 'package:ai_camera/services/look_service.dart';
import 'package:ai_camera/services/micro_lock.dart';
import 'package:ai_camera/services/network_check.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/prompt_builder.dart';
import 'package:ai_camera/services/zoom_ladder.dart';
import 'package:ai_camera/services/zoom_source.dart';
import 'package:ai_camera/widgets/styles_quick_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic textured scene (blocks + a diagonal stripe pattern).
img.Image scene(int w, int h, int seed) {
  final r = math.Random(seed);
  final im = img.Image(width: w, height: h);
  const b = 16;
  final cols = List.generate(
    (w ~/ b + 1) * (h ~/ b + 1),
    (_) => [r.nextInt(256), r.nextInt(256), r.nextInt(256)],
  );
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = cols[(y ~/ b) * (w ~/ b + 1) + x ~/ b];
      final s = ((x + y) ~/ 3).isEven ? 30 : -30;
      im.setPixelRgb(
        x,
        y,
        (c[0] + s).clamp(0, 255),
        (c[1] + s).clamp(0, 255),
        (c[2] + s).clamp(0, 255),
      );
    }
  }
  return im;
}

/// The final zoom area (centre 1/1.6 of [wide]), blurred like a cheap
/// phone's digital zoom and upscaled.
img.Image blurryFinal(img.Image wide, {int up = 2, int blur = 6}) {
  final cw = (wide.width / 1.6).round(), ch = (wide.height / 1.6).round();
  final c = img.copyCrop(
    wide,
    x: (wide.width - cw) ~/ 2,
    y: (wide.height - ch) ~/ 2,
    width: cw,
    height: ch,
  );
  final big = img.copyResize(c, width: cw * up, height: ch * up);
  return img.gaussianBlur(big, radius: blur);
}

String png64(img.Image im) => base64Encode(img.encodePng(im));

img.Image decodeDataUrl(String u) =>
    img.decodeImage(base64Decode(u.substring(u.indexOf(',') + 1)))!;

NetworkCheck fakeNet(bool online) =>
    NetworkCheck(probes: [(_) async => online]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version (v11.64: 1.11.64+77)', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 1.11.64+77'),
    );
  });

  group('sharp-source zoom (D1–D3, D5, F1–F3)', () {
    final wide = scene(480, 360, 7);
    final fin = blurryFinal(wide);
    String? written;
    String write(img.Image im) {
      written = '${im.width}x${im.height}';
      return '/tmp/src.jpg';
    }

    test('strictNcc fails closed without evidence / on flat images', () {
      expect(strictNcc(List.filled(10, 1.0), List.filled(10, 1.0)), -1);
      final flat = List<double>.filled(400, 50);
      final tex = [for (var i = 0; i < 400; i++) (i * 37 % 255).toDouble()];
      expect(strictNcc(flat, tex), -1);
      expect(strictNcc(tex, tex), closeTo(1, 1e-9));
    });

    test('alignInWide finds the final area in the centre of the wider ref', () {
      final (pw, ph) = proxySize(fin.width, fin.height);
      final ww = (pw * 1.6).round(), wh = (ph * 1.6).round();
      final (s, ox, oy) = alignInWide(
        greyOf(wide, ww, wh),
        ww,
        wh,
        greyOf(fin, pw, ph),
        pw,
        ph,
      );
      expect(s, greaterThan(kZoomSourceMatchMin));
      expect((ox - (ww - pw) / 2).abs(), lessThanOrEqualTo(2));
      expect((oy - (wh - ph) / 2).abs(), lessThanOrEqualTo(2));
    });

    test('matching sharper ref → it is the source, cropped to the area', () {
      written = null;
      final d = pickZoomSourceImages(
        finalArea: fin,
        refs: [(wide, 8, 1.6)],
        writeSource: write,
      );
      expect(d.reason, ZoomSourceReason.ok, reason: d.debugText);
      expect(d.ok, isTrue);
      expect(d.checkpoint, 8);
      expect(d.sharpRatio!, greaterThanOrEqualTo(kZoomSourceMinRatio));
      // cropped to the final area (1/1.6 of the ref), not the whole ref
      final wh = written!.split('x').map(int.parse).toList();
      expect((wh[0] - 300).abs(), lessThanOrEqualTo(3));
      expect((wh[1] - 225).abs(), lessThanOrEqualTo(3));
    });

    test('different subject → rejected (noMatch), never sent', () {
      final d = pickZoomSourceImages(
        finalArea: fin,
        refs: [(scene(480, 360, 99), 8, 1.6)],
        writeSource: write,
      );
      expect(d.reason, ZoomSourceReason.noMatch);
      expect(d.ok, isFalse);
    });

    // v11.61: no "final is sharp enough → send it alone" exemption any
    // more: a matching source that is clearly blurrier than the final (fair,
    // same-scale, noise-corrected) is no usable source → caller fails closed.
    test('ref clearly blurrier than the final → sourceBlurrier', () {
      final sharpFinal = img.copyCrop(
        wide,
        x: 90,
        y: 67,
        width: 300,
        height: 225,
      );
      final d = pickZoomSourceImages(
        finalArea: sharpFinal,
        refs: [(img.gaussianBlur(img.Image.from(wide), radius: 6), 8, 1.6)],
        writeSource: write,
      );
      expect(d.reason, ZoomSourceReason.sourceBlurrier, reason: d.debugText);
      expect(d.ok, isFalse);
    });

    test('tiny matching ref (< 32 real px) → tooSmall', () {
      // v11.61: the gate counts REAL pixels (kRoiMinRealPx = 32).
      final d = pickZoomSourceImages(
        finalArea: fin,
        refs: [(img.copyResize(wide, width: 40, height: 30), 8, 1.6)],
        writeSource: write,
      );
      expect(d.reason, ZoomSourceReason.tooSmall, reason: d.debugText);
      // A digital-crop ref: its upscaled pixels do not count.
      final dig = pickZoomSourceImages(
        finalArea: fin,
        refs: [(wide, 8, 1.6)],
        realScales: const [0.1],
        writeSource: write,
      );
      expect(dig.reason, ZoomSourceReason.tooSmall, reason: dig.debugText);
    });

    test('no clear refs → noClearRef (caller fails closed)', () {
      final d = pickZoomSourceImages(
        finalArea: fin,
        refs: const [],
        writeSource: write,
      );
      expect(d.reason, ZoomSourceReason.noClearRef);
    });

    test('best-first: the first good candidate wins over a mismatch', () {
      final d = pickZoomSourceImages(
        finalArea: fin,
        refs: [(scene(480, 360, 5), 12, 1.6), (wide, 8, 1.6)],
        writeSource: write,
      );
      expect(d.ok, isTrue);
      expect(d.checkpoint, 8);
      expect(d.tries.single.checkpoint, 12);
    });

    test(
      'pickZoomSource (files, isolate) writes the source next to the final',
      () async {
        final dir = Directory.systemTemp.createTempSync('zs');
        final fp = '${dir.path}/final.jpg';
        File(fp).writeAsBytesSync(img.encodeJpg(fin, quality: 95));
        final rp = '${dir.path}/ref.jpg';
        File(rp).writeAsBytesSync(img.encodeJpg(wide, quality: 95));
        final d = await pickZoomSource(
          finalAreaPath: fp,
          candidates: [ZoomSourceCandidate(rp, 8)],
        );
        expect(d.ok, isTrue, reason: d.debugText);
        expect(File(d.path!).existsSync(), isTrue);
        dir.deleteSync(recursive: true);
      },
    );

    test('effectiveSourceMargin follows the real region zoom', () {
      expect(effectiveSourceMargin(5), kZoomSourceMargin);
      expect(effectiveSourceMargin(1.2), 1.2);
      expect(effectiveSourceMargin(0.5), 1.0);
    });

    test('zoomNeedsSource: device clear limit, no universal 2x rule', () {
      bool n(double z, {double opt = 2, double? clear, bool fc = false}) =>
          zoomNeedsSource(
            ladderFlow: true,
            zoom: z,
            opticalLimit: opt,
            clearLimit: clear,
            finalClear: fc,
          );
      expect(n(2), isFalse);
      expect(n(3), isTrue);
      expect(n(6, clear: 8), isFalse); // this phone is clear up to 8x
      expect(n(10, clear: 8), isTrue);
      expect(n(30, fc: true), isFalse); // the final itself is clear
      expect(
        zoomNeedsSource(
          ladderFlow: false,
          zoom: 30,
          opticalLimit: 2,
          finalClear: false,
        ),
        isFalse,
      );
    });
  });

  group('ladder chain (D4)', () {
    LadderShot s(double cp, double sh) => LadderShot(
      checkpoint: cp,
      path: '/x$cp',
      cameraZoom: cp,
      sharpness: sh,
    );

    test(
      'lastClearBelow skips a blurry checkpoint; sourceCandidates clear only',
      () {
        final l = ZoomLadder(hardwareMax: 30)
          ..add(s(2, 100))
          ..add(s(3, 90))
          ..add(s(4, 5)) // blurry
          ..add(s(6, 60));
        expect(l.refSharpness, 100);
        expect(l.lastClearBelow(6)!.checkpoint, 3);
        expect(l.lastClearBelow(8)!.checkpoint, 6);
        final c = l.sourceCandidates(10);
        expect(c.map((e) => e.checkpoint), [6, 3, 2]);
        expect(c.any((e) => e.checkpoint == 4), isFalse);
        // not clearly wider than the final → not a candidate
        expect(l.sourceCandidates(6.1).map((e) => e.checkpoint), [3, 2]);
      },
    );

    test('home: blurry checkpoints keep the chain; diagnostics reset', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      // v11.60: blurry references never break the TRACKING chain (they are
      // never sources); references come from the tracker, not from
      // per-checkpoint subject comparisons.
      expect(h, contains("\${clear ? 'clear' : 'blurry'} · \${_track.debugText}"));
      expect(h, contains('rootToRef: before'));
      expect(h, contains('_zoomSendDbg = null'));
      expect(
        h,
        contains(
          "'chain \${_ladderDbg ?? '–'} · last zoom \${_zoomSendDbg ?? '–'}'",
        ),
      );
      // no silent final-only fallback past the clear limit; v11.61: no
      // "final sharp enough" exemption at all
      expect(h, contains('zoomFailClosed(ok: d.ok, need: need, tiny: tiny)'));
      expect(h, isNot(contains('_snack(zoomFailMessage('))); // v11.63: never blocks
      expect(h, isNot(contains('ZoomSourceReason.finalSharp')));
    });
  });

  group('payload + output check (D6, F4, F5, D7)', () {
    late Directory dir;
    late File fin;
    late File src;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest(
        ledger: LocalLedger(clock: () => DateTime.utc(2026, 11, 11, 6)),
      );
      dir = Directory.systemTemp.createTempSync('v1159');
      final wide = scene(480, 360, 3);
      fin = File('${dir.path}/final.jpg')
        ..writeAsBytesSync(img.encodeJpg(blurryFinal(wide)));
      src = File('${dir.path}/source.jpg')
        ..writeAsBytesSync(
          img.encodeJpg(
            img.copyCrop(wide, x: 90, y: 67, width: 300, height: 225),
            quality: 100,
          ),
        );
    });
    tearDown(() => dir.deleteSync(recursive: true));

    EnhanceService svc(http.Client c, {bool online = true}) => EnhanceService(
      openRouter: OpenRouterClient(httpClient: c, apiKey: 'test-key'),
      tempDir: () async => dir,
      net: fakeNet(online),
    );

    test(
      'source first (main), final after it (framing), at their sizes',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final out = img.decodeImage(src.readAsBytesSync())!;
        final c = MockClient((req) async {
          bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'data': [
                {'b64_json': png64(out)},
              ],
            }),
            200,
          );
        });
        final job = EnhanceJob(
          image: fin,
          zoomSource: src,
          zoom: 20,
          opticalLimit: 2,
          zoomClean: true,
        );
        expect(job.isZoomSource, isTrue);
        expect(job.primaryImage.path, src.path);
        expect(job.sentSteps.single.path, fin.path);
        final r = await svc(c).enhance(job);
        expect(r.usedAi, isTrue, reason: '${r.aiError} ${r.guard}');
        final refs = bodies.single['input_references'] as List;
        expect(refs, hasLength(2));
        final first = decodeDataUrl(
          (refs[0] as Map)['image_url']['url'] as String,
        );
        final second = decodeDataUrl(
          (refs[1] as Map)['image_url']['url'] as String,
        );
        expect(first.width, 300); // the sharp source crop
        expect(second.width, greaterThan(300)); // the final (framing)
      },
    );

    test(
      'changed result is rejected against the source area, no charge',
      () async {
        final bad = scene(300, 225, 77);
        final c = MockClient(
          (req) async => http.Response(
            jsonEncode({
              'data': [
                {'b64_json': png64(bad)},
              ],
            }),
            200,
          ),
        );
        final before = await AccountService.instance.ledger.load();
        final r = await svc(c).enhance(
          EnhanceJob(
            image: fin,
            zoomSource: src,
            zoom: 20,
            opticalLimit: 2,
            zoomClean: true,
          ),
        );
        expect(r.usedAi, isFalse);
        expect(r.guard, AiFailureKind.structureChanged);
        expect(r.creditsCharged, 0);
        expect(
          (await AccountService.instance.ledger.load()).freeDaily,
          before.freeDaily,
        );
      },
    );

    test('zoomOutputCheck: same → ok, other scene → bad', () async {
      final a = img.encodeJpg(scene(200, 150, 1));
      final (ok1, _) = await zoomOutputCheck(a, a);
      expect(ok1, isTrue);
      final (ok2, _) = await zoomOutputCheck(
        a,
        img.encodeJpg(scene(200, 150, 2)),
      );
      expect(ok2, isFalse);
    });

    test(
      'prompts: no invented texture; source prompt explains both images',
      () {
        expect(kZoomCleanPrompt, kUniversalEnhancePrompt);
        expect(kZoomCleanPrompt, 'Clean up and sharpen this image, with a natural tone.');
        expect(
          kZoomSourcePrompt,
          startsWith('The first image is a sharp photo'),
        );
        expect(kZoomSourcePrompt, contains('only to match the framing'));
        expect(kZoomSourcePrompt, contains('do not invent new texture'));
      },
    );

    test('offline: exact message, no request, no charge', () async {
      var calls = 0;
      final c = MockClient((req) async {
        calls++;
        return http.Response('{}', 500);
      });
      final r = await svc(
        c,
        online: false,
      ).enhance(EnhanceJob(image: fin, zoom: 3, opticalLimit: 5));
      expect(calls, 0);
      expect(r.usedAi, isFalse);
      expect(r.guard, AiFailureKind.network);
      expect(r.aiError, 'Check your internet connection');
      expect(r.creditsCharged, 0);
    });

    test(
      'socket error mid-call → network (not a provider error), no charge',
      () async {
        final c = MockClient(
          (req) async =>
              throw const SocketException('Failed host lookup: openrouter.ai'),
        );
        final r = await svc(
          c,
        ).enhance(EnhanceJob(image: fin, zoom: 3, opticalLimit: 5));
        expect(r.guard, AiFailureKind.network);
        expect(r.aiError, kCheckInternetMessage);
        expect(r.creditsCharged, 0);
      },
    );
  });

  group('offline helpers', () {
    test('NetworkCheck: multi-endpoint, first success wins, bounded', () async {
      final net = NetworkCheck(
        probes: [
          (_) async => false,
          (_) => Completer<bool>().future, // hangs
          (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return true;
          },
        ],
      );
      expect(await net.online(), isTrue);
      expect(net.recentlyOnline, isTrue);
      net.markOffline();
      expect(net.recentlyOnline, isFalse);
      final dead = NetworkCheck(probes: [(_) => Completer<bool>().future]);
      final sw = Stopwatch()..start();
      expect(
        await dead.online(timeout: const Duration(milliseconds: 200)),
        isFalse,
      );
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });

    test(
      'a Wi-Fi-style "connected" probe that fails is still offline',
      () async {
        final net = NetworkCheck(
          probes: [(_) async => throw const SocketException('no route')],
        );
        expect(await net.online(), isFalse);
      },
    );

    test('isOfflineError tells socket/DNS apart from provider errors', () {
      expect(
        isOfflineError(const SocketException('Failed host lookup')),
        isTrue,
      );
      expect(
        isOfflineError(
          http.ClientException('Connection closed while receiving data'),
        ),
        isTrue,
      );
      expect(isOfflineError(const OfflineException()), isTrue);
      expect(isOfflineError(Exception('HTTP 500 provider error')), isFalse);
      expect(classifyAiError(const OfflineException()), AiFailureKind.network);
      expect(
        aiFailureMessage(AiFailureKind.network),
        'Check your internet connection',
      );
    });

    test(
      'watchNetwork cancels a hanging call when the network drops',
      () async {
        var up = true;
        final net = NetworkCheck(probes: [(_) async => up]);
        AiCancelToken? seen;
        final f = watchNetwork<int>(
          (tok) async {
            seen = tok;
            await Completer<void>().future.timeout(const Duration(seconds: 5));
            return 1;
          },
          net: net,
          every: const Duration(milliseconds: 30),
          lostAfter: 2,
        );
        up = false;
        final sw = Stopwatch()..start();
        await expectLater(f, throwsA(isA<OfflineException>()));
        expect(seen!.isCancelled, isTrue);
        expect(sw.elapsedMilliseconds, lessThan(1500)); // bounded
      },
    );

    test(
      'LookService (styles / custom) offline → exact message, no call',
      () async {
        SharedPreferences.setMockInitialValues({});
        AccountService.resetForTest(
          ledger: LocalLedger(clock: () => DateTime.utc(2026, 11, 11, 6)),
        );
        var calls = 0;
        final c = MockClient((req) async {
          calls++;
          return http.Response('{}', 500);
        });
        final dir = Directory.systemTemp.createTempSync('look');
        final f = File('${dir.path}/a.jpg')
          ..writeAsBytesSync(img.encodeJpg(scene(64, 64, 1)));
        final r = await LookService(
          openRouter: OpenRouterClient(httpClient: c, apiKey: 'test-key'),
          tempDir: () async => dir,
          net: fakeNet(false),
        ).apply(LookJob(image: f, customPrompt: 'make it a painting'));
        expect(calls, 0);
        expect(r.failure, AiFailureKind.network);
        expect(r.error, kCheckInternetMessage);
        expect(r.creditsCharged, 0);
        dir.deleteSync(recursive: true);
      },
    );

    test('wiring: shutter precheck (Pro AI only), video, preview snack', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(
        h,
        contains('if (_aiMode && !NetworkCheck.instance.recentlyOnline)'),
      );
      expect(h, contains('_snack(kCheckInternet)'));
      final v = File('lib/services/video_service.dart').readAsStringSync();
      expect(v, contains('throw VideoException(kCheckInternet)'));
      expect(v, contains('isOfflineError(e)'));
      final p = File('lib/screens/preview_screen.dart').readAsStringSync();
      expect(p, contains('Text(kCheckInternetMessage)'));
    });
  });

  group('microscope fails closed (F6)', () {
    test('no lock / match error / mismatch → no AI flow', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(h, contains('fail: kMicroNoLock'));
      expect(h, contains('fail: kMicroNoMatch'));
      expect(h, contains('matchError = true'));
      expect(h, isNot(contains('var score = 1.0;')));
      expect(h, isNot(contains('await _detectBoxArea(')));
      expect(
        h,
        contains('if (fail != null || lockName == null || lockPart == null)'),
      );
      expect(kMicroNoLock, contains('No credits used'));
      expect(kMicroNoMatch, contains('No credits used'));
    });
  });

  group('Styles hint anchored to the four-dot button', () {
    test('placement: above, clamped, tail at the button centre', () {
      const bubble = Size(160, 36);
      // phone, button near the right edge
      var p = placeStylesHint(
        viewport: const Size(400, 700),
        anchor: const Rect.fromLTWH(352, 640, 36, 36),
        bubble: bubble,
      );
      expect(p.below, isFalse);
      expect(p.left + bubble.width, lessThanOrEqualTo(400 - 8 + 0.01));
      expect(p.left + p.tailX, closeTo(370, 0.01));
      expect(p.top + bubble.height + kStylesHintTail, lessThanOrEqualTo(640));
      // tablet landscape, button in the middle of a wide bar
      p = placeStylesHint(
        viewport: const Size(1280, 760),
        anchor: const Rect.fromLTWH(800, 700, 36, 36),
        bubble: bubble,
      );
      expect(p.left + p.tailX, closeTo(818, 0.01));
      expect(p.left, closeTo(818 - 80, 0.01));
      // no room above → below, still inside
      p = placeStylesHint(
        viewport: const Size(400, 300),
        anchor: const Rect.fromLTWH(10, 10, 36, 36),
        bubble: bubble,
      );
      expect(p.below, isTrue);
      expect(p.left, 8);
      expect(p.top, greaterThanOrEqualTo(46));
    });

    Future<void> pumpHint(WidgetTester t, Size size, Alignment where) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Align(
                  alignment: where,
                  child: SizedBox(key: key, width: 36, height: 36),
                ),
                Positioned.fill(
                  child: AnchoredStylesHint(anchorKey: key, onTap: () {}),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      final a = t.getRect(find.byKey(key));
      final tip = t.getRect(find.byKey(const ValueKey('styles_here_tooltip')));
      final tail = t.getRect(find.byKey(const ValueKey('styles_here_tail')));
      expect(tip.left, greaterThanOrEqualTo(0), reason: '$size $where');
      expect(tip.right, lessThanOrEqualTo(size.width), reason: '$size $where');
      expect(tip.top, greaterThanOrEqualTo(0));
      expect(tip.bottom, lessThanOrEqualTo(size.height));
      expect(
        (tail.center.dx - a.center.dx).abs(),
        lessThan(1.5),
        reason: '$size $where',
      );
    }

    testWidgets(
      'phone portrait / tablet portrait + landscape / narrow window',
      (t) async {
        addTearDown(t.view.reset);
        await pumpHint(t, const Size(400, 800), const Alignment(0.9, 0.9));
        await pumpHint(t, const Size(800, 1280), const Alignment(0.95, 0.9));
        await pumpHint(t, const Size(1280, 800), const Alignment(0.2, 0.9));
        await pumpHint(t, const Size(1280, 800), const Alignment(1, 1));
        await pumpHint(t, const Size(320, 640), const Alignment(-1, 0.9));
      },
    );

    testWidgets('re-anchors after a rotation / width change', (t) async {
      addTearDown(t.view.reset);
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1;
      final key = GlobalKey();
      Widget app() => MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: const Alignment(0.9, 0.9),
                child: SizedBox(key: key, width: 36, height: 36),
              ),
              Positioned.fill(
                child: AnchoredStylesHint(anchorKey: key, onTap: () {}),
              ),
            ],
          ),
        ),
      );
      await t.pumpWidget(app());
      await t.pump();
      t.view.physicalSize = const Size(1280, 800);
      await t.pump();
      await t.pump();
      await t.pump();
      final a = t.getRect(find.byKey(key));
      final tail = t.getRect(find.byKey(const ValueKey('styles_here_tail')));
      expect((tail.center.dx - a.center.dx).abs(), lessThan(1.5));
    });

    testWidgets('no measurable button → nothing visible to tap', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: AnchoredStylesHint(
                    anchorKey: GlobalKey(),
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();
      expect(find.byType(IgnorePointer), findsWidgets);
      final op = t.widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('styles_here_tooltip')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(op.opacity, 0);
    });

    test('home passes the real four-dot key', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(h, contains('menuKey: _menuKey'));
      expect(h, contains('AnchoredStylesHint('));
      expect(
        h,
        isNot(contains('right: 10,\n                        bottom: 66,')),
      );
      final z = File('lib/widgets/zoom_pill.dart').readAsStringSync();
      expect(z, contains('FourDotButton(key: menuKey'));
    });
  });
}
