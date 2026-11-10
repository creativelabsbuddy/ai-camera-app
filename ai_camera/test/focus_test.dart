import 'dart:async';

import 'package:ai_camera/services/focus_mapping.dart';
import 'package:ai_camera/services/tap_focus.dart';
import 'package:ai_camera/widgets/focus_ring.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _near(Offset? a, Offset b) {
  expect(a, isNotNull);
  expect(a!.dx, closeTo(b.dx, 1e-9));
  expect(a.dy, closeTo(b.dy, 1e-9));
}

class FakeOps implements FocusOps {
  final calls = <String>[];
  bool throwAll = false;
  Completer<void>? afGate;

  String _p(Offset? p) => p == null
      ? 'null'
      : '${p.dx.toStringAsFixed(3)},${p.dy.toStringAsFixed(3)}';

  @override
  Future<void> setExposureMode(ExposureMode mode) async {
    calls.add('AEmode:${mode.name}');
    if (throwAll) throw CameraException('x', 'boom');
  }

  @override
  Future<void> setExposurePoint(Offset? point) async {
    calls.add('AE:${_p(point)}');
    if (throwAll) throw CameraException('x', 'boom');
  }

  @override
  Future<void> setFocusMode(FocusMode mode) async {
    calls.add('AFmode:${mode.name}');
    if (throwAll) throw CameraException('x', 'boom');
  }

  @override
  Future<void> setFocusPoint(Offset? point) async {
    calls.add('AF:${_p(point)}');
    if (throwAll) throw CameraException('x', 'boom');
    if (point != null && afGate != null) await afGate!.future;
  }
}

void main() {
  group('tap → preview point mapping', () {
    test('4:3 frame, exact fit (default)', () {
      final g = PreviewGeometry.cover(const Size(360, 480), 3 / 4);
      expect(g.previewSize, const Size(360, 480));
      _near(tapToPreviewPoint(const Offset(180, 240), g), const Offset(.5, .5));
      _near(
        tapToPreviewPoint(const Offset(90, 120), g),
        const Offset(.25, .25),
      );
      _near(tapToPreviewPoint(const Offset(360, 480), g), const Offset(1, 1));
    });

    test('9:16 frame: preview overflows left/right (cover crop)', () {
      final g = PreviewGeometry.cover(const Size(360, 640), 3 / 4);
      expect(g.previewSize, const Size(480, 640));
      // Frame left edge is 60 px inside the preview.
      _near(tapToPreviewPoint(const Offset(0, 320), g), const Offset(.125, .5));
      _near(tapToPreviewPoint(const Offset(360, 0), g), const Offset(.875, 0));
      _near(tapToPreviewPoint(const Offset(180, 320), g), const Offset(.5, .5));
    });

    test('1:1 frame: preview overflows top/bottom', () {
      final g = PreviewGeometry.cover(const Size(360, 360), 3 / 4);
      expect(g.previewSize, const Size(360, 480));
      _near(tapToPreviewPoint(const Offset(180, 0), g), const Offset(.5, .125));
      _near(tapToPreviewPoint(const Offset(0, 360), g), const Offset(0, .875));
    });

    test('digital crop zoom is undone about the centre', () {
      final g = PreviewGeometry.cover(
        const Size(360, 480),
        3 / 4,
        digitalZoom: 2,
      );
      // Corner of the zoomed view = quarter point of the sensor.
      _near(tapToPreviewPoint(Offset.zero, g), const Offset(.25, .25));
      _near(
        tapToPreviewPoint(const Offset(360, 480), g),
        const Offset(.75, .75),
      );
      _near(tapToPreviewPoint(const Offset(180, 240), g), const Offset(.5, .5));
    });

    test('9:16 + digital zoom combined', () {
      final g = PreviewGeometry.cover(
        const Size(360, 640),
        3 / 4,
        digitalZoom: 2,
      );
      // ux = 180 + 180/2 = 270 → (270+60)/480; uy = 320 + 320/2 = 480 → /640.
      _near(
        tapToPreviewPoint(const Offset(360, 640), g),
        const Offset(.6875, .75),
      );
    });

    test('16:9 sensor preview (9:16 portrait) in a 4:3 frame', () {
      final g = PreviewGeometry.cover(const Size(360, 480), 9 / 16);
      expect(g.previewSize.width, closeTo(360, 1e-9));
      expect(g.previewSize.height, closeTo(640, 1e-9));
      _near(tapToPreviewPoint(const Offset(180, 0), g), const Offset(.5, .125));
    });

    test('outside the frame → null; result always clamped to 0..1', () {
      final g = PreviewGeometry.cover(const Size(360, 480), 3 / 4);
      expect(tapToPreviewPoint(const Offset(-1, 10), g), isNull);
      expect(tapToPreviewPoint(const Offset(10, 481), g), isNull);
      const bad = PreviewGeometry(
        frameSize: Size(360, 480),
        previewSize: Size(100, 100),
      );
      final p = tapToPreviewPoint(const Offset(360, 480), bad)!;
      expect(p.dx, inInclusiveRange(0, 1));
      expect(p.dy, inInclusiveRange(0, 1));
    });

    test('mirror flag flips x; bad aspect falls back to 3:4', () {
      final g = PreviewGeometry.cover(const Size(360, 480), double.nan);
      expect(g.previewSize, const Size(360, 480));
      _near(
        tapToPreviewPoint(const Offset(90, 120), g, mirror: true),
        const Offset(.75, .25),
      );
    });

    test('inverse mapping round-trips (all ratios, zooms)', () {
      for (final frame in const [
        Size(360, 480),
        Size(360, 640),
        Size(360, 360),
      ]) {
        for (final dz in const [1.0, 1.7, 3.0]) {
          final g = PreviewGeometry.cover(frame, 3 / 4, digitalZoom: dz);
          for (final t in const [Offset(10, 20), Offset(200, 300)]) {
            if (t.dy > frame.height) continue;
            final p = tapToPreviewPoint(t, g)!;
            final back = previewPointToFrame(p, g);
            expect(back.dx, closeTo(t.dx, 1e-6));
            expect(back.dy, closeTo(t.dy, 1e-6));
          }
        }
      }
    });
  });

  group('TapFocusController', () {
    final g = PreviewGeometry.cover(const Size(360, 480), 3 / 4);

    testWidgets('tap → AE + AF at point, ring, back to continuous after 5s', (
      tester,
    ) async {
      final ops = FakeOps();
      final f = TapFocusController();
      await f.attach(ops);
      expect(ops.calls, ['AFmode:auto', 'AEmode:auto']);
      ops.calls.clear();

      await f.focusAt(const Offset(90, 120), g);
      expect(ops.calls, ['AE:0.250,0.250', 'AF:0.250,0.250']);
      expect(f.ringPosition, const Offset(90, 120));
      expect(f.focused, isTrue);
      expect(f.locked, isFalse);

      ops.calls.clear();
      await tester.pump(const Duration(seconds: 5, milliseconds: 10));
      expect(ops.calls, ['AE:null', 'AF:null']);
      expect(f.ringPosition, isNull);
      expect(f.point, isNull);
      f.dispose();
    });

    testWidgets('long-press locks AE/AF; stays locked; tap unlocks', (
      tester,
    ) async {
      final ops = FakeOps();
      final f = TapFocusController();
      await f.attach(ops);
      ops.calls.clear();

      await f.focusAt(const Offset(180, 240), g, lock: true);
      expect(ops.calls, [
        'AE:0.500,0.500',
        'AF:0.500,0.500',
        'AFmode:locked',
        'AEmode:locked',
      ]);
      expect(f.locked, isTrue);
      ops.calls.clear();
      await tester.pump(const Duration(seconds: 30));
      expect(ops.calls, isEmpty, reason: 'lock never auto-resets');
      expect(f.locked, isTrue);

      // Shutter while locked: no extra AF pass.
      expect(await f.preCapture(), isFalse);
      expect(ops.calls, isEmpty);

      await f.focusAt(const Offset(90, 120), g);
      expect(ops.calls.take(2), ['AFmode:auto', 'AEmode:auto']);
      expect(f.locked, isFalse);
      f.dispose();
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('zoom / lens / ratio change resets tap focus and lock', (
      tester,
    ) async {
      final ops = FakeOps();
      final f = TapFocusController();
      await f.attach(ops);
      await f.focusAt(const Offset(90, 120), g, lock: true);
      ops.calls.clear();
      f.onSceneChange();
      await tester.pump();
      expect(ops.calls, ['AFmode:auto', 'AEmode:auto', 'AE:null', 'AF:null']);
      expect(f.isActive, isFalse);
      ops.calls.clear();
      f.onSceneChange(); // nothing active → no camera calls
      await tester.pump();
      expect(ops.calls, isEmpty);
      f.dispose();
    });

    testWidgets('pre-capture AF at centre, waits ≤900ms, then continuous', (
      tester,
    ) async {
      final ops = FakeOps()..afGate = Completer<void>(); // never focuses
      final f = TapFocusController();
      await f.attach(ops);
      ops.calls.clear();
      var done = false;
      bool? ours;
      unawaited(
        f.preCapture().then((v) {
          ours = v;
          done = true;
        }),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(done, isFalse, reason: 'waits for AF');
      await tester.pump(const Duration(milliseconds: 450));
      expect(done, isTrue, reason: 'bounded by kPreCaptureFocusWait');
      expect(ours, isTrue);
      expect(ops.calls, ['AF:0.500,0.500']);
      await f.afterCapture(ours!);
      expect(ops.calls.last, 'AF:null');
      f.dispose();
    });

    testWidgets('pre-capture skips AF right after a converged tap', (
      tester,
    ) async {
      final ops = FakeOps();
      var now = DateTime(2026, 10, 8, 12);
      final f = TapFocusController(clock: () => now);
      await f.attach(ops);
      await f.focusAt(const Offset(90, 120), g);
      ops.calls.clear();
      now = now.add(const Duration(seconds: 1));
      expect(await f.preCapture(), isFalse);
      expect(ops.calls, isEmpty);
      // Older tap (still within hold): re-focus at the tapped point.
      now = now.add(const Duration(seconds: 3));
      expect(await f.preCapture(), isFalse);
      expect(ops.calls, ['AF:0.250,0.250']);
      f.dispose();
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('plugin errors never escape; taps outside ignored', (
      tester,
    ) async {
      final ops = FakeOps()..throwAll = true;
      final f = TapFocusController();
      await f.attach(ops);
      await f.focusAt(const Offset(90, 120), g, lock: true);
      expect(f.focused, isFalse);
      await f.reset();
      expect(await f.preCapture(), isTrue);
      ops.calls.clear();
      ops.throwAll = false;
      await f.focusAt(const Offset(500, 120), g);
      expect(ops.calls, isEmpty);
      f.dispose();
    });
  });

  group('FocusRing', () {
    Widget host(bool locked, bool focused) => MaterialApp(
      home: Stack(
        children: [
          FocusRing(
            center: const Offset(100, 100),
            diameter: 72,
            locked: locked,
            focused: focused,
          ),
        ],
      ),
    );

    testWidgets('tap ring fades; no lock label', (tester) async {
      await tester.pumpWidget(host(false, true));
      expect(find.byKey(const ValueKey('focus_ring')), findsOneWidget);
      expect(find.text('AE/AF lock'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump(const Duration(milliseconds: 400));
      final op = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(op.opacity, 0);
    });

    testWidgets('locked ring shows "AE/AF lock" and stays', (tester) async {
      await tester.pumpWidget(host(true, true));
      expect(find.text('AE/AF lock'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      final op = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(op.opacity, 1);
    });
  });

  group('preview gesture arena (same recognizers as the viewfinder)', () {
    Future<List<String>> run(
      WidgetTester tester,
      Future<void> Function() act,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 300,
              height: 400,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => log.add('tap'),
                onLongPressStart: (d) => log.add('lock'),
                onScaleUpdate: (d) {
                  if (d.pointerCount >= 2) log.add('pinch');
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      );
      await act();
      return log;
    }

    testWidgets('single tap → focus only', (tester) async {
      final log = await run(tester, () => tester.tap(find.byType(ColoredBox)));
      expect(log, ['tap']);
    });

    testWidgets('long press → AE/AF lock, not tap', (tester) async {
      final log = await run(
        tester,
        () => tester.longPress(find.byType(ColoredBox)),
      );
      expect(log, ['lock']);
    });

    testWidgets('two-finger pinch → zoom, never a tap', (tester) async {
      final log = await run(tester, () async {
        final c = tester.getCenter(find.byType(ColoredBox));
        final a = await tester.startGesture(c - const Offset(20, 0));
        final b = await tester.startGesture(c + const Offset(20, 0));
        for (var i = 1; i <= 5; i++) {
          await a.moveTo(c - Offset(20.0 + i * 12, 0));
          await b.moveTo(c + Offset(20.0 + i * 12, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await a.up();
        await b.up();
        await tester.pump();
      });
      expect(log, contains('pinch'));
      expect(log, isNot(contains('tap')));
      expect(log, isNot(contains('lock')));
    });
  });
}
