import 'dart:io';

import 'package:ai_camera/models/capture_mode.dart';
import 'package:ai_camera/screens/preview_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/ai_call.dart';
import 'package:ai_camera/services/ai_gate.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class _Fake extends EnhanceService {
  final jobs = <EnhanceJob>[];
  @override
  Future<EnhanceResult> enhance(EnhanceJob job, {AiCancelToken? cancel}) async {
    jobs.add(job);
    return const EnhanceResult();
  }
}

void main() {
  late Directory dir;
  late File photo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
    AiGate.enabled = true;
    AiGate.duration = const Duration(seconds: kAiGateSeconds);
    dir = Directory.systemTemp.createTempSync('gate_test');
    photo = File('${dir.path}/shot.png')..writeAsBytesSync(_png);
  });
  tearDown(() {
    AiGate.enabled = false;
    dir.deleteSync(recursive: true);
  });

  test('version + labels', () {
    expect(File('pubspec.yaml').readAsStringSync(), matches(RegExp(r'version: 1\.11\.(5|6)\d')));
    expect(kAiGateSeconds, 3);
    expect(aiGateLabel(zoom: 40, night: false), 'Zoom 40x · AI enhance');
    expect(
      aiGateLabel(zoom: 2, night: false, aiMode: 'macro', macroLabel: 'Macro'),
      'Macro · AI',
    );
    expect(
      aiGateLabel(
        zoom: 20,
        night: false,
        aiMode: 'macro',
        macroLabel: 'Microscope',
      ),
      'Microscope · AI',
    );
    expect(aiGateLabel(zoom: 1, night: true), 'Night · AI');
    expect(aiGateLabel(zoom: 1, night: false), 'Photo · AI enhance');
  });

  test('Ask before enhancing defaults OFF and persists', () async {
    expect(await AiGate.askBeforeEnhancing(), isFalse);
    await AiGate.setAskBeforeEnhancing(true);
    expect(await AiGate.askBeforeEnhancing(), isTrue);
  });

  Widget app(_Fake f) => MaterialApp(
    home: PreviewScreen(
      imageFile: photo,
      captureZoom: 40,
      mode: CaptureMode.pro,
      enhanceService: f,
    ),
  );

  testWidgets('countdown: no AI during 3 s, starts after', (t) async {
    final f = _Fake();
    await t.pumpWidget(app(f));
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('ai_gate')), findsOneWidget);
    expect(find.text('Zoom 40x · AI enhance'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai_gate_cancel')), findsOneWidget);
    await t.pump(const Duration(milliseconds: 2900));
    expect(f.jobs, isEmpty);
    await t.pump(const Duration(milliseconds: 200));
    await t.pump();
    expect(f.jobs, hasLength(1));
    expect(find.byKey(const ValueKey('ai_gate')), findsNothing);
  });

  testWidgets('Cancel in the window: no AI call, original kept', (t) async {
    final f = _Fake();
    await t.pumpWidget(app(f));
    await t.pump();
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await t.tap(find.byKey(const ValueKey('ai_gate_cancel')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(f.jobs, isEmpty);
    expect(find.byKey(const ValueKey('ai_gate')), findsNothing);
    expect(find.textContaining('Cancelled, saved original'), findsOneWidget);
  });

  testWidgets('Ask ON: no countdown; Tick starts, Cross cancels', (t) async {
    SharedPreferences.setMockInitialValues({kAskBeforeEnhanceKey: true});
    final f = _Fake();
    await t.pumpWidget(app(f));
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('ai_gate_tick')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai_gate_ring')), findsNothing);
    await t.pump(const Duration(seconds: 10));
    expect(f.jobs, isEmpty); // waits for the user
    await t.tap(find.byKey(const ValueKey('ai_gate_tick')));
    await t.pump();
    await t.pump();
    expect(f.jobs, hasLength(1));
  });

  testWidgets('Ask ON: Cross keeps original, no AI', (t) async {
    SharedPreferences.setMockInitialValues({kAskBeforeEnhanceKey: true});
    final f = _Fake();
    await t.pumpWidget(app(f));
    await t.pump();
    await t.pump();
    await t.tap(find.byKey(const ValueKey('ai_gate_cross')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(f.jobs, isEmpty);
    expect(find.textContaining('Cancelled, saved original'), findsOneWidget);
  });

  testWidgets('Normal (non-AI) capture shows no window', (t) async {
    final f = _Fake();
    await t.pumpWidget(
      MaterialApp(
        home: PreviewScreen(imageFile: photo, enhanceService: f),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('ai_gate')), findsNothing);
    expect(f.jobs, isEmpty);
  });
}
