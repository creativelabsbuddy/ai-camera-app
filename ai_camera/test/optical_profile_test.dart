import 'package:ai_camera/services/optical_profile.dart';
import 'package:ai_camera/services/zoom_info.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> lens(
  String id, {
  double? mult,
  bool main = false,
  bool logical = false,
  List<String> phys = const [],
  String source = 'physical',
  String facing = 'back',
  int w = 4000,
  int h = 3000,
  double? zoomMax,
}) => {
  'id': id,
  'source': source,
  'lensFacing': facing,
  'isLogical': logical,
  'physicalIds': phys,
  'opticalMultiplier': mult,
  'isMain': main,
  'pixelArrayWidth': w,
  'pixelArrayHeight': h,
  'zoomRatioMax': zoomMax,
  'eqFocalMm': mult == null ? null : 23 * mult,
};

NativeZoomInfo info(List<Map<String, Object?>> cams, {String primary = '0'}) =>
    NativeZoomInfo.fromMap({
      'cameras': cams,
      'cameraIdList': ['0', '1'],
      'primaryBackId': primary,
    });

void main() {
  test('S24 Ultra-like: usable 0.55/1/3/5, optical limit 5, warn > 35', () {
    final o = computeOpticalProfile(
      info([
        lens(
          '0',
          logical: true,
          phys: ['52', '53', '54', '55'],
          source: 'listed',
          zoomMax: 10,
        ),
        lens('52', mult: 1.0, main: true, w: 16320, h: 12240),
        lens('53', mult: 0.55),
        lens('54', mult: 2.9),
        lens('55', mult: 4.83, w: 8160, h: 6120),
        lens('1', facing: 'front', source: 'listed'),
      ]),
      controllerMax: 10,
    );
    expect(o.usableFactors, [0.55, 1.0, 3.0, 5.0]);
    expect(o.bestOptical, 5);
    expect(o.opticalLimit, 5);
    expect(o.aiRecoverableLimit, 35);
    expect(o.teleNotExposed, isFalse);
    expect(o.isAboveOptical(5), isFalse);
    expect(o.isAboveOptical(5.05), isFalse); // 2% tolerance
    expect(o.isAboveOptical(6), isTrue);
    expect(o.isBeyondRecoverable(30), isFalse);
    expect(o.isBeyondRecoverable(40), isTrue);
    expect(o.appMaxZoom, 10);
  });

  test('tele hidden from third-party apps → best usable = main', () {
    final o = computeOpticalProfile(
      info([
        lens(
          '0',
          logical: true,
          phys: ['52', '53'],
          source: 'listed',
          zoomMax: 10,
        ),
        lens('52', mult: 1.0, main: true, w: 4000, h: 3000),
        lens('53', mult: 0.6),
        lens('4', mult: 4.9, source: 'hidden'),
      ]),
    );
    expect(o.usableFactors, [0.6, 1.0]);
    expect(o.allFactors, [0.6, 1.0, 5.0]);
    expect(o.bestOptical, 1);
    expect(o.teleNotExposed, isTrue);
    expect(o.opticalLimit, 1);
  });

  test('lens beyond exposed zoom-ratio range is not usable', () {
    final o = computeOpticalProfile(
      info([
        lens(
          '0',
          logical: true,
          phys: ['2', '3'],
          source: 'listed',
          zoomMax: 8,
        ),
        lens('2', mult: 1.0, main: true),
        lens('3', mult: 10.0),
      ]),
    );
    expect(o.usableFactors, [1.0]);
    expect(o.teleNotExposed, isTrue);
  });

  test('cheap 50MP single camera → 2x in-sensor crop counts as optical', () {
    final o = computeOpticalProfile(
      info([
        lens('0', mult: 1.0, main: true, source: 'listed', w: 8160, h: 6144),
      ]),
    );
    expect(o.usableFactors, [1.0]);
    expect(o.sensorCropFactor, 2);
    expect(o.opticalLimit, 2);
    expect(o.aiRecoverableLimit, 14);
  });

  test('cheap 12MP single camera → 1x, warning above 7x', () {
    final o = computeOpticalProfile(
      info([lens('0', mult: 1.0, main: true, source: 'listed')]),
    );
    expect(o.opticalLimit, 1);
    expect(o.aiRecoverableLimit, 7);
    expect(o.isAboveOptical(1.5), isTrue);
  });

  test('no probe → conservative fallback', () {
    final o = computeOpticalProfile(null);
    expect(o.fromCamera2, isFalse);
    expect(o.opticalLimit, 1);
    expect(o.overOptical(10), 10);
    expect(o.overOptical(0.6), 1);
  });
}
