// v11.67 (1.11.67+80) tests: one group per agreed change.
import 'dart:convert';
import 'dart:io';


import 'package:camera/camera.dart' show ExposureMode, FocusMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as im;

import 'package:ai_camera/services/gate_detect.dart';
import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/services/capture_crop.dart' show computeCaptureCrop;
import 'package:ai_camera/services/clear_ref.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/subject_detector.dart';
import 'package:ai_camera/services/tap_focus.dart';
import 'package:ai_camera/services/macro_gates.dart';
import 'package:ai_camera/services/zoom_range.dart';

class _Ops implements FocusOps {
  final calls = <String>[];
  @override
  Future<void> setFocusPoint(Offset? p) async => calls.add('AF:$p');
  @override
  Future<void> setExposurePoint(Offset? p) async => calls.add('AE:$p');
  @override
  Future<void> setFocusMode(FocusMode m) async => calls.add('AFmode:${m.name}');
  @override
  Future<void> setExposureMode(ExposureMode m) async => calls.add('AEmode:${m.name}');
}

http.Response _reply(String text) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'content': text},
        'finish_reason': 'stop',
      },
    ],
  }),
  200,
);

void main() {
  final home = File('lib/screens/home_camera_screen.dart').readAsStringSync();

  group('1: Microscope / Extreme / Ultra 15x via digital crop', () {
    const micro = [MacroLevel.microscope, MacroLevel.extreme, MacroLevel.ultra];
    // S24 Ultra: camera reports 10x, display range 100x.
    final s24 = computeZoomRange(
      controllerMin: 0.6,
      controllerMax: 10,
      nativeReportedMax: 10,
      teleMultiplier: 5,
    );

    test('limit: micro levels past the camera max, Macro / Close not', () {
      for (final l in micro) {
        final lim = macroZoomLimit(
          l,
          hardwareMax: s24.hardwareMax,
          displayMax: s24.displayMax,
        );
        expect(macroLevelZoomMax(l, lim), 15);
        expect(macroGateZooms(l, lim), [5.0, 10.0]); // v11.67 item 2
        expect(macroGateCap(l, lim, {5.0, 10.0}), 15);
        expect(macroLevelZoomChips(l, lim), [1, 2, 3, 5, 10, 15]);
      }
      for (final l in [MacroLevel.macro, MacroLevel.close, null]) {
        final lim = macroZoomLimit(
          l,
          hardwareMax: s24.hardwareMax,
          displayMax: s24.displayMax,
        );
        expect(lim, 10);
        expect(macroLevelZoomMax(l, lim), 10);
        expect(macroLevelZoomChips(l, lim), [1, 2, 3, 5, 10]);
      }
    });

    test('front-like range (display = camera max) stays capped', () {
      final lim = macroZoomLimit(
        MacroLevel.microscope,
        hardwareMax: 8,
        displayMax: 8,
      );
      expect(macroLevelZoomMax(MacroLevel.microscope, lim), 8);
    });

    test('15x = camera 10x × centre crop 1.5x (preview + still)', () {
      final p = planZoom(requested: 15, range: s24);
      expect(p.selected, 15);
      expect(p.cameraZoom, 10);
      expect(p.digitalZoom, closeTo(1.5, 1e-9));
      final cap = macroCaptureZoom(
        chip: 15,
        previewCamera: p.cameraZoom,
        opticalCap: macroCameraCap(hardwareMax: 10, opticalLimit: 10),
      );
      expect(cap.camera, 10);
      expect(cap.crop, closeTo(1.5, 1e-9));
    });

    test('home screen feeds the crop-aware limit everywhere', () {
      expect(home, contains('macroLevelZoomMax(_macroLevel, _macroLimit)'));
      expect(home, contains('macroGateCap(_macroLevel, _macroLimit, _gatesDone)'));
      expect(home, contains('macroGateDue(level, _macroLimitFor(level), _gatesDone, _zoom)'));
      expect(home, contains('macroLevelZoomChips(level, _macroLimit)'));
      expect(home, isNot(contains('macroLevelZoomMax(_macroLevel, _range.hardwareMax)')));
      expect(home, contains("crop \${_digitalZoom.toStringAsFixed(2)}x"));
    });
  });

  group('2: 5x / 10x gates + connected detection on every level', () {
    final img = File('${Directory.systemTemp.path}/v1167_gate.jpg')
      ..writeAsBytesSync(base64Decode(
        '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
      ));

    test('gates 5x and 10x on every level; 1.5x / 2x gone', () {
      expect(kGateZooms, [5.0, 10.0]);
      for (final l in MacroLevel.values) {
        expect(macroGateZooms(l, 10), [5.0, 10.0], reason: l.name);
        expect(macroGateZooms(l, 30).contains(1.5), isFalse);
        expect(macroGateZooms(l, 30).contains(2.0), isFalse);
      }
      // cheap phone (camera 4x): Macro / Close have no gate (final only)
      expect(macroGateZooms(MacroLevel.macro, 4), isEmpty);
      expect(
        kMicroZoomFirst,
        'Zoom in to 5x first so the AI can see the object. No credits used.',
      );
      expect(kDetectGateMaxTokens, 300);
    });

    test('prompts: general, connected, ≤40 words visible', () {
      for (final p in [kGateDetect5Prompt, kGateDetect10Prompt]) {
        for (final w in ['coin', 'leaf', 'fabric', 'napkin', 'paper']) {
          expect(p.toLowerCase(), isNot(contains(w)));
        }
        expect(p, contains('Keep visible under 40 words.'));
      }
      expect(gateDetectPrompt(null), kGateDetect5Prompt);
      const five = GateDetect(
        object: 'coin',
        context: 'wooden table',
        visible: 'silver disc, raised symbol',
      );
      final p10 = gateDetectPrompt(five);
      expect(
        p10,
        startsWith(
          'Earlier (5x) this was seen: {"object":"coin","context":"wooden table","visible":"silver disc, raised symbol"}. Now zoomed in:',
        ),
      );
      expect(p10, contains('If it is a different object now, say so.'));
    });

    test('parse + merge: same object keeps the 5x name, new object moves the lock', () {
      final five = parseGateReply(
        '```json\n{"object": "Coin", "context": "table", "visible": "silver disc"}\n```',
      )!;
      expect(five.object, 'coin');
      final same = parseGateReply(
        '{"object": "metal coin", "part": "rim", "visible": "worn edge", "same_object": true}',
      )!;
      final m = mergeGate(five, same);
      expect((m.object, m.part, m.visible, m.newSubject), ('coin', 'rim', 'worn edge', false));
      final other = parseGateReply(
        '{"object": "red ceramic mug", "part": "handle", "visible": "glossy glaze", "same_object": false}',
      )!;
      final n = mergeGate(five, other);
      expect((n.object, n.newSubject), ('red ceramic mug', true));
      expect(parseGateReply('no json'), isNull);
      expect(parseGateReply('{"object": "shiny textured"}'), isNull); // vague
      expect(
        gateLock({5.0: five, 10.0: m})!.part,
        'rim',
      );
      expect(gateDebugLine(5, five), '5x: coin · around: table · visible: silver disc');
      expect(gateDebugLine(10, null), '10x: detect failed');
      expect(sanitizeVisible(List.filled(80, 'w').join(' ')).split(' ').length, 45);
    });

    test('direct (test key): one image, 300 tokens, 10x gets the 5x answer', () async {
      final bodies = <Map<String, dynamic>>[];
      final replies = [
        '{"object": "coin", "context": "table", "visible": "silver disc, raised symbol"}',
        '{"object": "coin", "part": "raised symbol", "visible": "scratches", "same_object": true}',
      ];
      final c = OpenRouterClient(
        apiKey: 'test',
        httpClient: MockClient((r) async {
          bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
          return _reply(replies[bodies.length - 1]);
        }),
      );
      final d = SubjectDetector(
        openRouter: c,
        serverUrl: () async => '',
        deviceId: () async => 'x',
      );
      final five = await d.detectGateTimed(img, gate: 5);
      expect(five!.object, 'coin');
      expect(bodies[0]['max_tokens'], 300);
      expect(bodies[0]['model'], 'google/gemini-2.5-flash-lite');
      final c0 = (bodies[0]['messages'] as List).first['content'] as List;
      expect(c0.first['text'], kGateDetect5Prompt);
      expect(c0.where((x) => x['type'] == 'image_url').length, 1);
      final ten = await d.detectGateTimed(img, earlier: five, gate: 10);
      expect(ten!.part, 'raised symbol');
      final c1 = (bodies[1]['messages'] as List).first['content'] as List;
      expect(c1.first['text'], contains('"visible":"silver disc, raised symbol"'));
    });

    test('server: gate-detect endpoint; older server → micro-name name', () async {
      final seen = <String>[];
      final fields = <String>[];
      final mock = MockClient((r) async {
        seen.add(r.url.path);
        fields.add(utf8.decode(r.bodyBytes, allowMalformed: true));
        if (r.url.path.endsWith('/gate-detect')) {
          return http.Response(
            jsonEncode({
              'object': 'coin',
              'context': '',
              'part': 'rim',
              'visible': 'worn edge',
              'same_object': true,
            }),
            200,
          );
        }
        return http.Response('{"detail": "nope"}', 404);
      });
      final d = SubjectDetector(
        server: ServerApiClient(httpClient: mock),
        serverUrl: () async => 'https://srv.example',
        deviceId: () async => 'dev',
      );
      const five = GateDetect(object: 'coin', visible: 'silver disc');
      final r = await d.detectGateTimed(img, earlier: five, gate: 10);
      expect(r!.part, 'rim');
      expect(seen.single, '/v1/macro/gate-detect');
      expect(fields.single, contains('name="earlier"'));
      expect(fields.single, contains('"object":"coin"'));

      final old = MockClient((r) async {
        seen.add(r.url.path);
        if (r.url.path.endsWith('/micro-name')) {
          return http.Response(jsonEncode({'name': 'coin', 'part': 'face'}), 200);
        }
        return http.Response('{"detail": "Not Found"}', 404);
      });
      final d2 = SubjectDetector(
        server: ServerApiClient(httpClient: old),
        serverUrl: () async => 'https://srv.example',
        deviceId: () async => 'dev',
      );
      final o = await d2.detectGateTimed(img, gate: 5);
      expect((o!.object, o.part), ('coin', ''));
    });

    test('home wiring: detection at every gate, shutter rules, debug', () {
      expect(home, contains('      await _detectAtGate(g, shot.path, dig, gen);'));
      expect(home, contains('final boxed = await tmp(writeZoomBoxed(view, 1 / kMacroBoxFraction));'));
      expect(home, contains('_gateInfo[g] = r == null ? null : mergeGate(earlier, r);'));
      // Microscope levels below 5x fail closed; Macro / Close go on.
      expect(home, contains('if (micro && gates.isNotEmpty && !_gatesDone.contains(gates.first)) {'));
      expect(home, contains('if (micro) {\n      final sharp = await photoRegionSharpness(path, crop);'));
      expect(home, contains('final gm = await _fromGates(path, crop, level);'));
      expect(home, contains('subject = lockName;'));
      // gate photos sent with the shot (10x gate at an 11x shot too)
      expect(home, contains('(gated ? kGateStepMinWider : kMacroCtxMinWider)'));
      expect(kGateStepMinWider, lessThan(1.1));
      // zooming back below a gate forgets it, debug too
      expect(home, contains('if (had) _boxDbg = _gateInfo.isEmpty ? null : _gateDebug();'));
      expect(home, isNot(contains('detectMicroNameTimed(')));
    });
  });

  group('3: simple Macro / Close / Microscope prompts', () {
    // same table as enhance-server/tests/test_v1167.py SIMPLE_CASES
    const cases = [
      ('macro', 'coin', '', '', 'This is a coin. Show it as a sharp macro-lens close-up.'),
      ('macro', '', '', '', 'Show this object as a sharp macro-lens close-up.'),
      ('macro', 'apple', '', '', 'This is an apple. Show it as a sharp macro-lens close-up.'),
      ('close', 'coin', 'rim', '', 'This is a coin, rim. Show it as an extreme macro close-up with fine surface detail.'),
      ('close', 'coin', '', '', 'This is a coin. Show it as an extreme macro close-up with fine surface detail.'),
      ('close', '', '', '', 'Show this object as an extreme macro close-up with fine surface detail.'),
      (
        'microscope',
        'coin',
        'raised symbol',
        'worn silver metal, fine scratches.',
        'This is a coin, zoomed on raised symbol, showing worn silver metal, fine scratches. Show how it would look under a light microscope at 100x magnification.',
      ),
      ('microscope', 'coin', '', 'silver disc', 'This is a coin, showing silver disc. Show how it would look under a light microscope at 100x magnification.'),
      ('microscope', 'close-up', '', '', 'Show how this object would look under a light microscope at 100x magnification.'),
      ('microscope', '', 'rim', '', 'This is this object, zoomed on rim. Show how it would look under a light microscope at 100x magnification.'),
    ];

    test('templates + graceful fallback (server parity table)', () {
      for (final (l, o, p, v, want) in cases) {
        expect(simpleMacroPrompt(l, object: o, part: p, visible: v), want);
      }
      expect(simpleMacroPrompt('extreme', object: 'coin'), isNull);
      expect(simpleMacroPrompt('ultra', object: 'coin'), isNull);
      expect(kSimpleMacroPrompt, 'This is a {object}. Show it as a sharp macro-lens close-up.');
      expect(kSimpleClosePrompt, 'This is a {object}, {part}. Show it as an extreme macro close-up with fine surface detail.');
      expect(kSimpleMicroscopePrompt, 'This is a {object}, zoomed on {part}, showing {visible}. Show how it would look under a light microscope at 100x magnification.');
    });

    test('job: simple prompt for Macro / Close / Microscope only, photo sent', () {
      final f = File('a.jpg');
      const g = GateDetect(object: 'coin', part: 'rim', visible: 'worn edge');
      EnhanceJob job(String level, {GateDetect? gate, List<File> steps = const []}) => EnhanceJob(
        image: f,
        mode: 'macro',
        macroLevel: level,
        subject: 'coin',
        part: 'rim of a coin',
        steps: steps,
        gate: gate,
      );
      for (final l in ['macro', 'close', 'microscope']) {
        expect(job(l, gate: g).simpleMacro, isTrue);
        expect(job(l, gate: g).deepTextOnly, isFalse);
        expect(job(l).simpleMacro, isFalse); // old flow
      }
      for (final l in ['extreme', 'ultra']) {
        expect(job(l, gate: g).simpleMacro, isFalse);
      }
      if (AiConfig.kHasEmbeddedKey) {
        expect(
          job('microscope', gate: g, steps: [File('s5.jpg')]).prompt(hasContext: true),
          '$kMicroStepsLine This is a coin, zoomed on rim, showing worn edge. Show how it would look under a light microscope at 100x magnification.',
        );
        expect(job('macro', gate: g).prompt(hasContext: false), 'This is a coin. Show it as a sharp macro-lens close-up.');
        // Extreme untouched: its own prompt
        expect(job('extreme', gate: g).prompt(hasContext: false), deepPrompt(kMacroExtremePrompt, 'coin', 'rim of a coin'));
      }
    });

    test('wiring: home → preview → job → server fields', () {
      expect(home, contains('gateDetect = gm.detect ?? const GateDetect();'));
      final pv = File('lib/screens/preview_screen.dart').readAsStringSync();
      expect(pv, contains("gate: widget.aiMode == 'macro' ? widget.gateDetect : null,"));
      final es = File('lib/services/enhance_service.dart').readAsStringSync();
      expect(es, contains('gate: job.simpleMacro ? job.gate : null,'));
      final sc = File('lib/services/server_api_client.dart').readAsStringSync();
      expect(sc, contains("if (gate != null) 'simple_macro': 'true',"));
      expect(sc, contains("'gate_visible': gate.visible,"));
    });
  });

  group('4: one frame everywhere except Night; no AF pass when focused', () {
    test('no burst / merge / HDR bracket at the shutter', () {
      expect(home, isNot(contains('_zoomBurst(')));
      expect(home, isNot(contains('_burstSharpest(')));
      expect(home, isNot(contains('nativeZoomMerge')));
      expect(home, isNot(contains('mergeHdrFiles(')));
      expect(home, isNot(contains('mergeZoomRegion(')));
      expect(home, contains("onNote('Single frame');\n    return _takeSingle(c);"));
      expect(home, contains('// v11.67: ONE frame (no sharpest-of burst, no low-end merge).'));
      // Night keeps its burst + merge
      expect(home, contains('NightBridge.capture('));
      expect(home, contains('NightBridge.mergeJpegs('));
      // the camera zoom moved for the macro still → always one AF pass
      expect(home, contains('await _preCapture(force: moved);'));
      expect(home, contains('_focus.afStateReader = () async {'));
    });

    test('preCapture: converged preview AF → no fresh pass', () async {
      final ops = _Ops();
      final f = TapFocusController();
      await f.attach(ops);
      ops.calls.clear();
      var st = kAfPassiveFocused;
      f.afStateReader = () async => st;
      expect(await f.preCapture(), isFalse);
      expect(ops.calls, isEmpty);
      expect(f.lastPreCapture, 'af ok (no pass)');
      st = kAfFocusedLocked;
      expect(await f.preCapture(), isFalse);
      expect(ops.calls, isEmpty);
      // still hunting / unfocused → one centre pass as before
      for (final s in [1, 3, 5, 6, 0]) {
        st = s;
        ops.calls.clear();
        expect(await f.preCapture(), isTrue);
        expect(ops.calls.single, startsWith('AF:Offset(0.5, 0.5)'));
      }
      // forced (camera zoom moved) → pass even when focused
      st = kAfPassiveFocused;
      ops.calls.clear();
      expect(await f.preCapture(force: true), isTrue);
      expect(ops.calls, hasLength(1));
      // unknown state (no reader) → pass as before
      f.afStateReader = null;
      ops.calls.clear();
      expect(await f.preCapture(), isTrue);
      expect(afConverged(null), isFalse);
      f.dispose();
    });
  });

  group('5: clear reference (behind kClearRefEnabled)', () {
    test('switch on; limit S24 Ultra 10x, cheap phones ~2-3x', () {
      expect(kClearRefEnabled, isTrue);
      // S24 Ultra: optical 5x tele, camera max 10x → 10x
      expect(
        clearRefLimit(lowEnd: false, opticalLimit: 5, hardwareMax: 10, pixelClear: 6),
        10,
      );
      // cheap phone: observed clear limit wins, else the real-pixel one
      expect(
        clearRefLimit(lowEnd: true, opticalLimit: 1, hardwareMax: 8, observedClear: 2.5, pixelClear: 3),
        2.5,
      );
      expect(
        clearRefLimit(lowEnd: true, opticalLimit: 1, hardwareMax: 8, pixelClear: 2.7),
        2.7,
      );
      expect(clearRefNeeded(22, 10), isTrue);
      expect(clearRefNeeded(10.3, 10), isFalse);
      // hold the camera at the limit until the reference is taken
      expect(clearRefHold(active: true, selected: 6, cameraZoom: 6, limit: 2.5), 2.5);
      expect(clearRefHold(active: false, selected: 6, cameraZoom: 6, limit: 2.5), isNull);
      expect(clearRefHold(active: true, selected: 22, cameraZoom: 10, limit: 10), isNull);
      expect(kClearRefLine, 'Use the first image for real detail; keep the framing of the second image.');
    });

    test('stale reasons', () {
      final now = DateTime(2026, 1, 1, 12);
      expect(clearRefStaleReason(null, now, 22), 'none');
      final f = File('${Directory.systemTemp.path}/v1167_ref_exists.jpg')..writeAsBytesSync([1]);
      final ref = ClearRef(path: f.path, cameraZoom: 10, at: now);
      expect(clearRefStaleReason(ref, now, 22), '');
      expect(clearRefStaleReason(ref, now.add(const Duration(minutes: 2)), 22), 'old');
      expect(clearRefStaleReason(ref, now, 10.2), 'not past');
      expect(clearRefDebug(refZoom: 10, match: 0.8), 'clear ref 10x · match 0.80');
      expect(clearRefDebug(reason: 'none'), 'clear ref none (final only)');
    });

    test('crop = the final area of the reference; other scene → final only', () async {
      final dir = Directory.systemTemp.createTempSync('v1167cr');
      // reference at 10x: a pattern
      final ref = im.Image(width: 800, height: 600);
      for (final p in ref) {
        final v = ((p.x ~/ 20 + p.y ~/ 30) % 2) * 200 + (p.x * 50 ~/ 800);
        p..r = v..g = (p.y * 255 ~/ 600)..b = 255 - v;
      }
      final refPath = '${dir.path}/ref.jpg';
      File(refPath).writeAsBytesSync(im.encodeJpg(ref, quality: 95));
      // final at 20x = the centre half of the reference (portrait 3:4 crop
      // of a landscape frame here), blurred
      final r = computeCaptureCrop(iw: 800, ih: 600, portraitRatio: 3 / 4, digitalZoom: 2);
      final fin = im.gaussianBlur(
        im.copyCrop(ref, x: r.x, y: r.y, width: r.width, height: r.height),
        radius: 3,
      );
      final finPath = '${dir.path}/fin.jpg';
      File(finPath).writeAsBytesSync(im.encodeJpg(fin));
      final (path, score) = await writeClearRefCrop(
        refPath: refPath,
        refCameraZoom: 10,
        finalZoom: 20,
        portraitRatio: 3 / 4,
        finalCropPath: finPath,
        outPath: '${dir.path}/out.jpg',
      );
      expect(path, isNotNull);
      expect(score, greaterThan(0.8));
      final out = im.decodeImage(File(path!).readAsBytesSync())!;
      expect((out.width, out.height), (r.width, r.height));
      // a different scene → no reference
      final other = im.Image(width: r.width, height: r.height);
      for (final p in other) {
        p..r = (p.y * 255 ~/ r.height)..g = 255 - (p.x * 255 ~/ r.width)..b = 0;
      }
      final otherPath = '${dir.path}/other.jpg';
      File(otherPath).writeAsBytesSync(im.encodeJpg(other));
      final (p2, s2) = await writeClearRefCrop(
        refPath: refPath,
        refCameraZoom: 10,
        finalZoom: 20,
        portraitRatio: 3 / 4,
        finalCropPath: otherPath,
        outPath: '${dir.path}/out2.jpg',
      );
      expect(p2, isNull);
      expect(s2, lessThan(kClearRefMinMatch));
      dir.deleteSync(recursive: true);
    });

    test('wiring: capture at the limit, crop at the shutter, prompt line', () {
      expect(home, contains('_onClearRefZoom();'));
      expect(home, contains('final hold = clearRefHold('));
      expect(home, contains('await _awaitClearRef();'));
      expect(home, contains('final (src, dbg) = await _clearRefSource(snap, crop.path);'));
      expect(home, contains('clearRef: clearRef,'));
      // Pro AI photo only (Normal has no AI call; Macro has its own path)
      expect(home, contains('      kClearRefEnabled &&\n      _snapshotMode &&\n      !_macroActive &&'));
      final es = File('lib/services/enhance_service.dart').readAsStringSync();
      expect(es, contains('if (clearRef) kClearRefLine, // v11.67'));
      final sc = File('lib/services/server_api_client.dart').readAsStringSync();
      expect(sc, contains("if (clearRef && zoomSource) 'clear_ref': 'true',"));
      final job = EnhanceJob(
        image: File('f.jpg'),
        zoomSource: File('src.jpg'),
        clearRef: true,
      );
      expect(job.isZoomSource, isTrue);
      expect(job.sentSteps.single.path, 'f.jpg'); // final second (framing)
      if (AiConfig.kHasEmbeddedKey) {
        expect(job.prompt(hasContext: true), contains(kClearRefLine));
      }
    });
  });
}
