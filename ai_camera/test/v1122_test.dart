import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:ai_camera/services/openrouter_client.dart';
import 'package:ai_camera/services/server_api_client.dart';
import 'package:ai_camera/services/subject_detector.dart';
import 'package:ai_camera/widgets/macro_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// Same step logic as HomeCameraScreen._applyMacroChip / _takeStepPhoto /
/// _advanceStep, on the real MacroChips widget. [photoNeverDone] simulates
/// a step photo / check that never completes.
class _Flow extends StatefulWidget {
  const _Flow({this.photoNeverDone = false});
  final bool photoNeverDone;
  @override
  State<_Flow> createState() => _FlowState();
}

class _FlowState extends State<_Flow> {
  int stage = 1; // subject detected at 1.5x
  double chip = 1.5;
  Timer? timer;

  void advance(double c) {
    if (!mounted || (chip - c).abs() > 0.01) return;
    setState(() => stage = macroStageAfter(stage, c));
  }

  void tap(double c) {
    timer?.cancel();
    setState(() => chip = c);
    if (isMacroContextZoom(c) && !widget.photoNeverDone) {
      Future<void>.delayed(const Duration(milliseconds: 450), () => advance(c));
    }
    if (stepCompletesWithoutPhoto(c)) {
      Future<void>.delayed(const Duration(milliseconds: 450), () => advance(c));
    }
    if (isMacroStepZoom(c) && c != kMacroDetectZoom) {
      timer = Timer(kMacroStepTimeout, () => advance(c));
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: MacroChips(
        chips: visibleMacroChips(stage),
        selected: chip,
        onSelected: tap,
      ),
    ),
  );
}

Future<void> _tapChip(WidgetTester t, double z) async {
  final f = find.byKey(ValueKey(macroChipKey(z)));
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump();
}

void main() {
  // ---- 1. 5x unlock -------------------------------------------------------
  test('root cause: 5x is a step chip without a step photo', () {
    expect(isMacroStepZoom(5.0), isTrue);
    expect(isMacroContextZoom(5.0), isFalse); // no _takeStepPhoto at 5x
    for (final z in kMacroStepZooms) {
      // every step completes: its photo, or right after the zoom settles
      expect(isMacroContextZoom(z) || stepCompletesWithoutPhoto(z), isTrue);
    }
    expect(kMacroStepTimeout, const Duration(seconds: 6));
  });

  testWidgets('chip widget: 2x→3x→4x→5x reveals the level chips', (t) async {
    await t.pumpWidget(const _Flow());
    for (final z in [2.0, 3.0, 4.0, 5.0]) {
      await _tapChip(t, z);
      await t.pump(const Duration(milliseconds: 500));
    }
    for (final z in [6.0, 12.0, 21.0, 30.0]) {
      expect(find.byKey(ValueKey(macroChipKey(z))), findsOneWidget);
    }
    expect(find.text('30x Ultra'), findsOneWidget);
  });

  testWidgets('chip widget: step photo never completes → 6 s timeout', (
    t,
  ) async {
    await t.pumpWidget(const _Flow(photoNeverDone: true));
    for (final z in [2.0, 3.0, 4.0]) {
      await _tapChip(t, z);
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(ValueKey(macroChipKey(z + 1))), findsNothing);
      await t.pump(kMacroStepTimeout);
    }
    await _tapChip(t, 5.0);
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('6x Close'), findsOneWidget);
    expect(find.text('21x Extreme'), findsOneWidget);
  });

  test(
    'home screen wires the 5x completion + timeout',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(s, contains('stepCompletesWithoutPhoto(chip)'));
      expect(s, contains('Timer(kMacroStepTimeout'));
      expect(s, contains('_advanceStep(chip)'));
    },
    skip: 'v11.33: replaced by level chips + box check',
  );

  // ---- 2. drift + return --------------------------------------------------
  test('drift: back on the reference → returned; else expired after 3 s', () {
    final ref = List<int>.filled(64, 100), away = List<int>.filled(64, 220);
    final t0 = DateTime(2026);
    final d = DriftReturn()..start(ref, t0);
    expect(d.waiting, isTrue);
    expect(
      d.update(away, t0.add(const Duration(milliseconds: 300))),
      DriftState.waiting,
    );
    expect(
      d.update(ref, t0.add(const Duration(milliseconds: 1600))),
      DriftState.waiting,
    ); // 1 frame is not enough
    expect(
      d.update(ref, t0.add(const Duration(milliseconds: 1900))),
      DriftState.returned,
    );
    expect(d.waiting, isFalse);
    d.start(ref, t0);
    expect(
      d.update(away, t0.add(const Duration(seconds: 2))),
      DriftState.waiting,
    );
    expect(d.update(null, t0.add(kDriftReturnTimeout)), DriftState.expired);
    // size mismatch never counts as a match
    d.start(ref, t0);
    expect(
      d.update([1, 2], t0.add(const Duration(milliseconds: 10))),
      DriftState.waiting,
    );
    expect(kDriftReturnTimeout, const Duration(seconds: 5));
    expect(kDriftReturnDiff, lessThan(kDriftDiffThreshold));
  });

  test('drift reference: own step, else nearest step', () {
    final m = {
      1.5: [1],
      3.0: [3],
    };
    expect(driftReference(m, 3.0), [3]);
    expect(driftReference(m, 2.0), [1]); // equal distance → first sorted
    expect(driftReference(m, 12.0), [3]);
    expect(driftReference({}, 2.0), isNull);
  });

  test('drift guides + subject-only label while drifting', () {
    expect(guideDriftBack('Red mug'), 'Moved off subject — return to Red mug');
    expect(kGuideDriftReset, 'New subject? Tap 1.5x');
    expect(
      macroFlowGuide(
        chip: 3,
        stage: 3,
        detecting: false,
        label: 'Red mug',
        driftWaiting: true,
      ),
      'Moved off subject — return to Red mug',
    );
    expect(
      macroFlowGuide(chip: 1, stage: 0, detecting: false, drifted: true),
      'New subject? Tap 1.5x',
    );
    final l = SubjectLock();
    l.completeDetect(l.beginDetect(), 'red mug', others: ['blue pen']);
    l.setCloudPart('red handle');
    expect(l.display(3), 'red handle');
    l.drifting = true;
    expect(l.display(3), 'Red mug');
    l.drifting = false;
    expect(l.display(3), 'red handle'); // restored silently
  });

  test(
    'home screen: drift waits for return, no immediate reset',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(s, contains('_drift.begin('));
      expect(s, contains('case DriftEvent.reset:'));
      expect(s, contains('driftWaiting: _driftReturn.waiting'));
    },
    skip: 'v11.33: replaced by level chips + box check',
  );

  // ---- 3. multiple objects ------------------------------------------------
  test('device rule in all detection prompts', () {
    expect(
      kDetectDeviceRule,
      'If the object is a phone, tablet, laptop, monitor or TV, name the '
      'device itself (e.g. black mobile phone screen), never what is shown '
      'on its screen (people, clothes, images, text).',
    );
    for (final p in [
      kDetectSubjectPrompt,
      kDetectPartPrompt,
      kDetectSpotPrompt,
    ]) {
      expect(p, contains(kDetectDeviceRule));
    }
    expect(kDetectSubjectPrompt, contains('CENTER'));
    expect(
      kDetectSubjectPrompt,
      contains('{"main": "...", "others": ["..."], "fill"'),
    );
    expect(kDetectPartPrompt, contains('"in_scene": true}'));
    expect(kDetectSpotPrompt, contains('{objects}'));
  });

  test('tolerant parsing', () {
    (String, List<String>) sub(String t) => parseSubjectReply(t);
    var (m, o) = sub(
      '```json\n{"main": "Red mug", "others": ["Blue pen", "red mug", 3]}\n```',
    );
    expect(m, 'red mug');
    expect(o, ['blue pen']);
    (m, o) = sub('White styrofoam');
    expect(m, 'white styrofoam');
    expect(o, isEmpty);
    (m, o) = sub('{"main": "black mobile phone scr');
    expect(m, 'black mobile phone scr');
    expect(
      parseObjectPartReply(
        '{"object": "blue pen", "part": "metal tip", "in_scene": true}',
      ),
      ('blue pen', 'metal tip', true),
    );
    expect(parseObjectPartReply('{"same_subject": false, "part": "x"}'), (
      '',
      'x',
      false,
    ));
    expect(parseObjectPartReply('brown iris'), ('', 'brown iris', null));
    expect(
      matchKnownObject('the blue pen', ['red mug', 'blue pen']),
      'blue pen',
    );
    expect(matchKnownObject('green cup', ['red mug']), isNull);
    expect(spotText('blue pen', 'metal tip'), 'blue pen metal tip');
    expect(spotText('blue pen', 'blue pen tip'), 'blue pen tip');
    expect(objectsText('red mug', ['blue pen']), 'red mug; blue pen');
  });

  test('known other object → subject switches, no reset', () {
    final l = SubjectLock();
    l.completeDetect(l.beginDetect(), 'red mug', others: ['blue pen']);
    expect(l.others, ['blue pen']);
    expect(l.applyObjectPart('blue pen', 'silver metal tip'), isTrue);
    expect(l.parent, 'Blue pen');
    expect(l.display(3), 'silver metal tip');
    expect(l.others, ['red mug']);
    expect(l.partHint, 'silver metal tip');
    // same / unknown object → part only
    expect(l.applyObjectPart('green cup', 'rim'), isTrue);
    expect(l.parent, 'Blue pen');
    expect(l.display(3), 'rim');
  });

  group('mocked network', () {
    late Directory tmp;
    late File one;
    setUpAll(() {
      UploadPrep.nativeDecode = false;
      tmp = Directory.systemTemp.createTempSync('v1122');
      final im = img.Image(width: 40, height: 30);
      img.fill(im, color: img.ColorRgb8(90, 90, 90)); // synthetic
      one = File('${tmp.path}/one.jpg')..writeAsBytesSync(img.encodeJpg(im));
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    http.Response chat(String content) => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'content': content},
            'finish_reason': 'stop',
          },
        ],
      }),
      200,
    );

    test('subject JSON → main + others; part/spot send the objects', () async {
      final prompts = <String>[];
      final replies = [
        '{"main": "red mug", "others": ["blue pen", "white paper"]}',
        '{"object": "blue pen", "part": "silver metal tip", "in_scene": true}',
        '{"object": "blue pen", "part": "silver metal tip", "in_scene": true}',
      ];
      var i = 0;
      final d = SubjectDetector(
        openRouter: OpenRouterClient(
          apiKey: 'k',
          httpClient: MockClient((r) async {
            final j = jsonDecode(r.body) as Map;
            final c = ((j['messages'] as List).first as Map)['content'] as List;
            prompts.add((c.first as Map)['text'] as String);
            return chat(replies[i++]);
          }),
        ),
        server: ServerApiClient(),
        serverUrl: () async => '',
        deviceId: () async => 'dev',
      );
      expect(await d.detectSubject(one), 'red mug');
      expect(d.lastOthers, ['blue pen', 'white paper']);
      final r = await d.detectPart(one, one, 'red mug', others: d.lastOthers);
      expect(r!.object, 'blue pen');
      expect(r.part, 'silver metal tip');
      expect(r.inScene, isTrue);
      expect(
        prompts[1],
        contains('objects in it: red mug; blue pen; white paper.'),
      );
      expect(prompts[1], contains(kDetectDeviceRule));
      expect(
        await d.detectSpot(one, one, 'red mug', others: d.lastOthers),
        'blue pen silver metal tip',
      );
    });

    test('in_scene false is reported (drift)', () async {
      final d = SubjectDetector(
        openRouter: OpenRouterClient(
          apiKey: 'k',
          httpClient: MockClient(
            (r) async =>
                chat('{"object": "wall", "part": "white", "in_scene": false}'),
          ),
        ),
        server: ServerApiClient(),
        serverUrl: () async => '',
        deviceId: () async => 'dev',
      );
      final r = await d.detectPart(one, one, 'red mug');
      expect(r!.inScene, isFalse);
    });
  });
}
