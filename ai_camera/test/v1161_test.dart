// v11.61 tests: low-zoom ROOT reference (optical vs digital labels), the
// real-pixel gate ("Beyond clear range, AI-enhanced" / fail closed on an
// absurdly tiny region), no "final sharp enough" exemption, fair noise-
// corrected sharpness at equal scale, tracking past blur (coarse match +
// gyro coasting), robust burst ghost test with per-pixel sharpening.
// Synthetic data only; no network, no paid calls.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_camera/screens/preview_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/burst_merge.dart';
import 'package:ai_camera/services/capture_crop.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/image_register.dart';
import 'package:ai_camera/services/zoom_ladder.dart';
import 'package:ai_camera/services/zoom_preview_policy.dart';
import 'package:ai_camera/services/zoom_root.dart';
import 'package:ai_camera/services/zoom_source.dart';
import 'package:ai_camera/services/zoom_tracker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/synth_scene.dart';

img.Image texture(int w, int h, int seed) {
  final r = math.Random(seed);
  final im = img.Image(width: w, height: h);
  const b = 6;
  final cols = List.generate(
    (w ~/ b + 1) * (h ~/ b + 1),
    (_) => r.nextInt(200) + 20,
  );
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = cols[(y ~/ b) * (w ~/ b + 1) + x ~/ b];
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return im;
}

img.Image addNoise(img.Image im, double sigma, int seed) {
  final r = math.Random(seed);
  final out = img.Image.from(im);
  for (final p in out) {
    // Box–Muller
    final u = math.max(1e-9, r.nextDouble()), v = r.nextDouble();
    final n = sigma * math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
    final g = (p.r + n).round().clamp(0, 255);
    p
      ..r = g
      ..g = g
      ..b = g;
  }
  return out;
}

class FakeEnhance extends EnhanceService {
  final jobs = <EnhanceJob>[];
  @override
  Future<EnhanceResult> enhance(EnhanceJob job, {AiCancelToken? cancel}) async {
    jobs.add(job);
    return const EnhanceResult();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version 1.11.61+74', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 1.11.61+74'),
    );
  });

  group('ROOT reference + real zoom labels', () {
    test('root only at 1x–2x, or the true optical zoom', () {
      expect(rootMaxZoom(1), 2);
      expect(rootMaxZoom(3), 3); // real 3x telephoto
      expect(rootMaxZoom(double.nan), 2);
      expect(isRootZoom(1, 1), isTrue);
      expect(isRootZoom(2, 1), isTrue);
      expect(isRootZoom(2.5, 1), isFalse);
      expect(isRootZoom(3, 3), isTrue);
      expect(isRootZoom(10, 1), isFalse, reason: 'hardware max ≠ optical');
    });

    test('digital crops up to the hardware max are NOT optical', () {
      final a = refZoomLabel(4); // single-lens phone, ISP crop 4x
      expect(a.optical, 1);
      expect(a.digital, 4);
      expect(a.isOptical, isFalse);
      expect(a.realScale, closeTo(0.25, 1e-9));
      expect(a.text, 'opt 1x + dig 4.0x');
      final b = refZoomLabel(5, lensFactors: const [1, 3]);
      expect(b.optical, 3);
      expect(b.digital, closeTo(5 / 3, 1e-9));
      final c = refZoomLabel(2, sensorCrop: 2); // 50 MP in-sensor 2x
      expect(c.isOptical, isTrue);
      expect(c.text, 'opt 2x');
      expect(refZoomLabel(1).text, 'opt 1x');
      expect(refZoomLabel(1.5, sensorCrop: 2).optical, 1.5);
    });

    test('first reference must be the root; later ones step up', () {
      final now = DateTime(2026, 11, 12);
      bool ref(double cam, List<double> refs, {double opt = 1}) =>
          shouldCaptureReference(
            cameraZoom: cam,
            hardwareMax: 10,
            refZooms: refs,
            now: now,
            zoomChangedAt: now.subtract(const Duration(seconds: 1)),
            gyroSteady: true,
            tracked: true,
            motion: 0,
            busy: false,
            flashOff: true,
            opticalLimit: opt,
          );
      expect(ref(8, const []), isFalse, reason: 'no root deep in the zoom');
      expect(ref(1, const []), isTrue);
      expect(ref(3, const [], opt: 3), isTrue);
      expect(ref(4, const [1]), isTrue);
      expect(ref(6, const [1, 4]), isTrue);
      expect(ref(8, const [1, 2, 4, 6]), isFalse, reason: 'max 4');
    });

    test('ladder: root kept, always among the source candidates', () {
      LadderShot s(double cp, double sh, {bool root = false}) => LadderShot(
        checkpoint: cp,
        path: '/x$cp',
        cameraZoom: cp,
        sharpness: sh,
        root: root,
      );
      final l = ZoomLadder(hardwareMax: 10)
        ..add(s(1, 100, root: true))
        ..add(s(2, 90))
        ..add(s(3, 80))
        ..add(s(4.5, 70))
        ..add(s(7, 60));
      expect(l.root!.checkpoint, 1);
      final c = l.sourceCandidates(20);
      expect(c.length, kLadderMaxRefs);
      expect(c.first.checkpoint, 7);
      expect(c.last.root, isTrue);
      expect(l.refsLabelText(), startsWith('root 1x opt 1x ✓'));
      expect(l.refsLabelText(), contains('7x opt 1x + dig 7.0x ✓'));
      // zoomed back below the root → the whole chain restarts
      l.zoomedTo(0.9);
      expect(l.root, isNull);
    });
  });

  group('real-pixel gate', () {
    test('real ROI pixels count only real sensor pixels', () {
      final root = refZoomLabel(1);
      expect(realRoiPx(stillLong: 4000, label: root, finalZoom: 50), 80);
      // a 4x digital reference has the SAME real pixels as the 1x root
      expect(
        realRoiPx(stillLong: 4000, label: refZoomLabel(4), finalZoom: 50),
        closeTo(80, 1e-9),
      );
      // a 50 MP in-sensor 2x root has twice as many
      expect(
        realRoiPx(
          stillLong: 4000,
          label: refZoomLabel(2, sensorCrop: 2),
          finalZoom: 50,
        ),
        closeTo(160, 1e-9),
      );
    });

    test('per-device clear limit; beyond → label, tiny → fail closed', () {
      final lim = pixelClearLimit(stillLong: 4000, rootOptical: 1);
      expect(lim, closeTo(4000 / kClearRoiPx, 1e-9)); // ≈ 10.4x
      expect(
        pixelClearLimit(stillLong: 4000, rootOptical: 2),
        closeTo(lim * 2, 1e-9),
      );
      expect(
        pixelClearLimit(stillLong: 0, rootOptical: 1),
        closeTo(kDefaultStillLong / kClearRoiPx, 1e-9),
      );
      expect(
        pixelClearLimit(stillLong: 1000, rootOptical: 1, opticalLimit: 5),
        5,
      );
      expect(beyondClearRange(8, lim), isFalse);
      expect(beyondClearRange(20, lim), isTrue);
      expect(
        roiTooTiny(80),
        isFalse,
        reason: '50x on a 4000 px root: label only',
      );
      expect(roiTooTiny(31), isTrue);
      expect(roiTooTiny(double.nan), isTrue);
    });

    test('live note: missing base photo first, then the clear-range label', () {
      String? n({bool root = true, double zoom = 20, bool ladder = true}) =>
          liveZoomNote(
            ladderMode: ladder,
            zoom: zoom,
            opticalLimit: 1,
            hasRoot: root,
            clearLimit: 10,
          );
      expect(n(), kBeyondClearLabel);
      expect(n(zoom: 6), isNull);
      expect(n(root: false), kRootMissingHint);
      expect(n(root: false, zoom: 1.5), isNull);
      expect(n(ladder: false), isNull);
      expect(kBeyondClearLabel, 'Beyond clear range, AI-enhanced');
    });

    test('fail closed: no exemption for a "sharp enough" final', () {
      expect(zoomFailClosed(ok: false, need: true, tiny: false), isTrue);
      expect(zoomFailClosed(ok: true, need: true, tiny: false), isFalse);
      expect(zoomFailClosed(ok: false, need: false, tiny: false), isFalse);
      expect(zoomFailClosed(ok: true, need: true, tiny: true), isTrue);
      expect(zoomFailMessage(tiny: false, hasRoot: false), kHoldLowerZoomFirst);
      expect(
        zoomFailMessage(tiny: false, hasRoot: true),
        kNoSharpSourceMessage,
      );
      expect(zoomFailMessage(tiny: true, hasRoot: true), kRoiTooTinyMessage);
      for (final m in [kHoldLowerZoomFirst, kRoiTooTinyMessage]) {
        expect(m, contains('No credits used'));
      }
      expect(
        ZoomSourceReason.values.map((e) => e.name),
        isNot(contains('finalSharp')),
      );
    });
  });

  group('fair sharpness (equal scale, noise-corrected)', () {
    test('noise does not pose as detail', () {
      final flat = img.Image(width: 120, height: 120)
        ..clear(img.ColorRgb8(128, 128, 128));
      final noisy = addNoise(flat, 6, 1);
      final raw = sharpnessOf(noisy);
      final fair = fairSharpnessOf(noisy);
      expect(fair, lessThan(raw * 0.35), reason: 'raw $raw fair $fair');
      // a really detailed image keeps most of its measure
      final tex = texture(120, 120, 3);
      expect(fairSharpnessOf(tex), greaterThan(sharpnessOf(tex) * 0.5));
    });

    test('root crop vs heavily downscaled blurry final: compared fairly', () {
      final area = texture(60, 45, 5); // the root's real pixels of the area
      // the final: same area, digitally upscaled 10x and blurred (deep zoom)
      final fin = img.gaussianBlur(
        img.copyResize(area, width: 600, height: 450),
        radius: 6,
      );
      final r = fairSharpRatio(area, fin);
      expect(r, greaterThanOrEqualTo(kZoomSourceMinRatio), reason: '$r');
      // a blurred source is clearly blurrier than a sharp final
      final sharpFin = img.copyResize(area, width: 60, height: 45);
      final r2 = fairSharpRatio(
        img.gaussianBlur(img.Image.from(area), radius: 3),
        sharpFin,
      );
      expect(r2, lessThan(kZoomSourceMinRatio), reason: '$r2');
      // a noisy source does not win just by its noise
      final r3 = fairSharpRatio(
        addNoise(img.gaussianBlur(img.Image.from(area), radius: 3), 8, 2),
        sharpFin,
      );
      expect(r3, lessThan(1.0), reason: '$r3');
    });

    test('a digital reference is compared at its REAL resolution', () {
      final area = texture(60, 45, 9);
      final dig = img.copyResize(area, width: 240, height: 180); // 4x upscaled
      final r = fairSharpRatio(dig, area, aRealScale: 0.25);
      expect(r, closeTo(1, 0.35), reason: '$r');
    });
  });

  group('tracking past blur', () {
    final s = SynthScene(21);
    const aspect = kTrackH / kTrackW;
    GreyImage view(double fov, {double blur = 0, int seed = 1}) =>
        s.view(kTrackW, kTrackH, fov: fov, blur: blur, noise: 2, seed: seed);

    test('gyro steady: unmatched frames coast on the zoom prediction', () {
      final t0 = DateTime(2026, 11, 12);
      ZoomTracker run({required bool steady}) {
        final tr = ZoomTracker();
        tr.update(TrackFrame(view(1), 1, t0));
        tr.update(TrackFrame(view(1 / 1.3, seed: 2), 1.3, t0));
        // featureless frames (lens hunting / extreme blur): no match
        final flat = GreyImage(
          kTrackW,
          kTrackH,
          Float32List(kTrackW * kTrackH)..fillRange(0, kTrackW * kTrackH, 90),
        );
        for (var i = 0; i < 12; i++) {
          tr.update(
            TrackFrame(
              flat,
              1.3 * math.pow(1.05, i + 1).toDouble(),
              t0.add(Duration(milliseconds: 100 * i)),
              steady: steady,
            ),
          );
        }
        return tr;
      }

      final moving = run(steady: false);
      expect(moving.state, TrackState.lost);
      final still = run(steady: true);
      expect(still.state, TrackState.tracking, reason: still.debugText);
      expect(still.debugText, contains('coast'));
      // the coasted view follows the zoom ratio (scale ≈ camera zoom)
      final z = 1.3 * math.pow(1.05, 12);
      expect(still.rootToCur!.scale, closeTo(z, z * 0.12));
      expect(
        ZoomTracker.viewInside(
          still.rootToCur!.inverse(),
          aspect,
          rootAspect: aspect,
        ),
        isTrue,
      );
    });

    test('coasting is bounded (kTrackCoastMax) — then lost', () {
      final t0 = DateTime(2026, 11, 12);
      final tr = ZoomTracker();
      tr.update(TrackFrame(view(1), 1, t0));
      final flat = GreyImage(
        kTrackW,
        kTrackH,
        Float32List(kTrackW * kTrackH)..fillRange(0, kTrackW * kTrackH, 90),
      );
      for (var i = 0; i < kTrackCoastMax + kTrackLostAfter + 1; i++) {
        tr.update(TrackFrame(flat, 1, t0, steady: true));
      }
      expect(tr.state, TrackState.lost);
    });

    test('blurry deep-zoom frames still register (coarse match)', () {
      final t0 = DateTime(2026, 11, 12);
      final tr = ZoomTracker();
      var z = 1.0;
      tr.update(TrackFrame(view(1), z, t0));
      for (var i = 0; i < 14; i++) {
        z *= 1.12;
        tr.update(
          TrackFrame(
            view(1 / z, blur: i > 6 ? 5 : 0, seed: i + 3),
            z,
            t0.add(Duration(milliseconds: 100 * i)),
          ),
        );
      }
      expect(tr.state, TrackState.tracking, reason: tr.debugText);
      expect(tr.rootToCur!.scale, closeTo(z, z * 0.15));
    });
  });

  group('burst merge robustness', () {
    final s = SynthScene(31);
    const w = 160, h = 200;
    const inner = (12, 16, 136, 168);
    const v = (0.0, 0.0, 0.5, 0.0);

    test('a brightness offset (exposure flicker) is not a ghost', () {
      final a = rgbOf(s, w, h, v, noise: 3, seed: 1);
      final b = rgbOf(s, w, h, v, noise: 3, seed: 2, offset: 6);
      final c = rgbOf(s, w, h, v, noise: 3, seed: 3, offset: -5);
      final r = mergeBurst([a, b, c], inner: inner);
      expect(r.used, 3, reason: r.debugText);
      expect(r.ghostTiles, lessThan(0.2), reason: r.debugText);
    });

    test('nothing merged → anchor returned unsharpened (exact)', () {
      final a = rgbOf(s, w, h, v, noise: 2, seed: 1);
      final other = rgbOf(SynthScene(77), w, h, v, noise: 2, seed: 4);
      final r = mergeBurst([a, other], inner: inner);
      expect(r.used, 1);
      final anc = [a, other][r.anchor];
      final (ix, iy, iw, ih) = inner;
      final out = r.image!;
      for (var y = 0; y < ih; y += 7) {
        for (var x = 0; x < iw; x += 5) {
          final o = (y * iw + x) * 3;
          final src = ((iy + y) * w + ix + x) * 3;
          expect(out.rgb[o], anc.rgb[src]);
        }
      }
    });

    test('a moving patch stays anchor-only and is not sharpened there', () {
      final a = rgbOf(s, w, h, v, noise: 2, seed: 1);
      final b = rgbOf(s, w, h, v, noise: 2, seed: 2);
      // paint a bright moving block into b only
      for (var y = 60; y < 100; y++) {
        for (var x = 60; x < 100; x++) {
          final i = (y * w + x) * 3;
          b.rgb[i] = b.rgb[i + 1] = b.rgb[i + 2] = 250;
        }
      }
      final r = mergeBurst([a, b], inner: inner);
      final anc = [a, b][r.anchor];
      final (ix, iy, iw, _) = inner;
      // inside the block (tile fully covered) the output is the anchor
      for (var y = 66; y < 94; y += 3) {
        for (var x = 66; x < 94; x += 3) {
          final o = ((y - iy) * iw + x - ix) * 3;
          expect(r.image!.rgb[o], anc.rgb[(y * w + x) * 3]);
        }
      }
    });
  });

  group('wiring', () {
    final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
    test('home: root rule, real-pixel gate, labels, fail closed', () {
      expect(h, contains('isRoot && !isRootZoom(cam, _optical.opticalLimit)'));
      expect(h, contains('opticalLimit: _optical.opticalLimit,'));
      expect(h, contains('refZoomLabel('));
      expect(h, contains('root: isRoot,'));
      expect(h, contains('zoomFailClosed(ok: d.ok, need: need, tiny: tiny)'));
      expect(h, contains('if (beyond) zoomLabel = kBeyondClearLabel;'));
      expect(h, contains('zoomLabel: zoomLabel,'));
      expect(h, contains("'beyond_clear_label'"));
      expect(h, contains("'root_missing_hint'"));
      expect(
        h,
        contains('TrackFrame(g, _cameraZoom, now, steady: _gyroStill)'),
      );
      expect(h, isNot(contains('ZoomSourceReason.finalSharp')));
      // the AI model / prompts are untouched by this version
      expect(h, isNot(contains('gpt-image')));
    });

    testWidgets('result shows "Beyond clear range, AI-enhanced"', (t) async {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      final dir = Directory.systemTemp.createTempSync('v1161');
      final f = File('${dir.path}/p.png')
        ..writeAsBytesSync(img.encodePng(texture(8, 8, 1)));
      await t.pumpWidget(
        MaterialApp(
          home: PreviewScreen(
            imageFile: f,
            captureZoom: 30,
            zoomLabel: kBeyondClearLabel,
            enhanceService: FakeEnhance(),
          ),
        ),
      );
      await t.pump();
      expect(find.byKey(const ValueKey('zoom_clear_label')), findsOneWidget);
      expect(find.text(kBeyondClearLabel), findsOneWidget);
      dir.deleteSync(recursive: true);
    });
  });
}

RgbFrame rgbOf(
  SynthScene s,
  int w,
  int h,
  (double, double, double, double) v, {
  double noise = 0,
  int seed = 1,
  int offset = 0,
}) {
  final g = s.view(
    w,
    h,
    cx: v.$1,
    cy: v.$2,
    fov: v.$3,
    angle: v.$4,
    noise: noise,
    seed: seed,
    ss: 1,
  );
  final out = Uint8List(w * h * 3);
  for (var i = 0; i < w * h; i++) {
    final q = (g.data[i] + offset).round().clamp(0, 255);
    out[i * 3] = out[i * 3 + 1] = out[i * 3 + 2] = q;
  }
  return RgbFrame(w, h, out);
}
