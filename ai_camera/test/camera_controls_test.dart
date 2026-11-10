import 'package:ai_camera/models/camera_options.dart';
import 'package:ai_camera/models/quality_tier.dart';
import 'package:ai_camera/services/optical_profile.dart';
import 'package:ai_camera/services/zoom_chips.dart';
import 'package:ai_camera/services/zoom_range.dart';
import 'package:ai_camera/services/zoom_ruler.dart';
import 'package:ai_camera/widgets/quick_menu_bar.dart';
import 'package:ai_camera/widgets/zoom_pill.dart';
import 'package:ai_camera/widgets/zoom_ruler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const s24 = OpticalProfile(
  usableFactors: [0.6, 1, 3, 5],
  allFactors: [0.6, 1, 3, 5],
  bestOptical: 5,
  sensorCropFactor: 2,
  opticalLimit: 5,
  appMaxZoom: 10,
  fromCamera2: true,
);

/// Minimal stand-in for the camera screen: zoom pill ⇄ ruler ⇄ quick menu,
/// with the same haptic rule (tick per lens chip crossed).
class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  double zoom = 1;
  bool menu = false;
  bool ruler = false;
  bool night = false;
  int haptics = 0;
  final range = computeZoomRange(controllerMin: 0.6, controllerMax: 10);
  late final chips = buildZoomChipSet(range, optical: s24);
  late final scale = ZoomRulerScale(min: range.minZoom, max: range.displayMax);

  void setZoom(double v) {
    haptics += crossedTicks(zoom, v, chips.lensValues).length;
    setState(() => zoom = v);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.grey,
        body: Center(
          child: menu
              ? QuickMenuBar(
                  flash: FlashChoice.off,
                  timer: TimerChoice.off,
                  ratio: FrameRatio.r4x3,
                  tier: QualityTier.ultraHd,
                  stylesOpen: false,
                  styleActive: false,
                  night: night,
                  onNight: () => setState(() => night = !night),
                  onSettings: () {},
                  onFlash: () {},
                  onTimer: () {},
                  onRatio: () {},
                  onQuality: () {},
                  onStyles: () {},
                  onClose: () => setState(() => menu = false),
                )
              : ruler
              ? ZoomRuler(
                  scale: scale,
                  zoom: zoom,
                  ticks: buildRulerTicks(
                    scale,
                    lensChips: chips.lensValues,
                    shortcuts: chips.shortcutValues,
                  ),
                  onChanged: setZoom,
                )
              : ZoomPill(
                  chips: chips,
                  zoom: zoom,
                  onSelected: setZoom,
                  onOpenMenu: () => setState(() => menu = true),
                  onRulerOpen: () => setState(() => ruler = true),
                ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('zoom pill: real-lens chips only, no 30/100 chips', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    expect(find.text('1×'), findsOneWidget); // selected chip shows "×"
    for (final l in ['.6', '2', '3', '5', '10']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    expect(find.text('30'), findsNothing);
    expect(find.text('100'), findsNothing);
    expect(find.byKey(const ValueKey('quick_menu_open')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('zoom_chip_10')));
    await tester.pumpAndSettle();
    expect(find.text('10×'), findsOneWidget);
    // v9: no expansion, menu button stays.
    expect(find.text('30'), findsNothing);
    expect(find.byKey(const ValueKey('quick_menu_open')), findsOneWidget);
    final st = tester.state<_HarnessState>(find.byType(_Harness));
    expect(st.haptics, 4); // crossed 2, 3, 5, 10

    await tester.tap(find.byKey(const ValueKey('zoom_chip_2')));
    await tester.pumpAndSettle();
    expect(find.text('2×'), findsOneWidget);
  });

  testWidgets('long-press pill opens the ruler; drag scrubs to 22.0x', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    await tester.longPress(find.byKey(const ValueKey('zoom_pill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zoom_ruler')), findsOneWidget);
    expect(find.text('1.0x'), findsOneWidget);
    final st = tester.state<_HarnessState>(find.byType(_Harness));
    // Drag left = zoom in. Work out the drag for 22x from the scale.
    final track = find.byKey(const ValueKey('zoom_ruler_track'));
    final width = tester.getSize(track).width;
    final extent = width * ZoomRuler.extentFactor;
    final dx = -(st.scale.positionOf(22) - st.scale.positionOf(1)) * extent;
    await tester.drag(track, Offset(dx, 0));
    await tester.pumpAndSettle();
    expect(st.zoom, closeTo(22, 1.01));
    expect(st.zoom, st.zoom.roundToDouble()); // 1x steps above 10x
    expect(find.text(formatRulerLabel(st.zoom)), findsOneWidget);
    expect(st.haptics, greaterThanOrEqualTo(4)); // 2, 3, 5, 10 crossed
  });

  testWidgets('quick menu night toggle', (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.tap(find.byKey(const ValueKey('quick_menu_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('qm_night')));
    await tester.pumpAndSettle();
    expect(tester.state<_HarnessState>(find.byType(_Harness)).night, isTrue);
  });

  testWidgets('four-dot opens the quick menu; ✕ returns to the zoom pill', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness());
    await tester.tap(find.byKey(const ValueKey('quick_menu_open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick_menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('zoom_pill')), findsNothing);
    for (final k in [
      'qm_settings',
      'qm_night',
      'qm_timer',
      'qm_ratio',
      'qm_quality',
      'qm_styles',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.text('4:3'), findsOneWidget);
    expect(find.text('UHD'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quick_menu_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick_menu')), findsNothing);
    expect(find.byKey(const ValueKey('zoom_pill')), findsOneWidget);
  });

  test('option cycles', () {
    expect(FrameRatio.r4x3.next, FrameRatio.r16x9);
    expect(FrameRatio.r16x9.label, '9:16');
    expect(FrameRatio.r1x1.next, FrameRatio.r4x3);
    expect(FlashChoice.off.next, FlashChoice.auto);
    expect(TimerChoice.off.next.seconds, 3);
    expect(TimerChoice.s3.next.seconds, 10);
    expect(TimerChoice.s10.next, TimerChoice.off);
    expect(QualityTier.values.map((t) => t.shortLabel).toList(), [
      'HD',
      'FHD',
      'UHD',
      '4K',
    ]);
  });
}
