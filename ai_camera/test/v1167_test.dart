// v11.67 (1.11.67+80) tests: one group per agreed change.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ai_camera/services/gate_detect.dart';
import 'package:ai_camera/config/ai_config.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/subject_detector.dart';
import 'package:ai_camera/services/macro_gates.dart';
import 'package:ai_camera/services/zoom_range.dart';

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
}
