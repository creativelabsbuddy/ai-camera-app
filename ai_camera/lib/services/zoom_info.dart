import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'optical_profile.dart';
import 'zoom_range.dart';

double? _d(Object? v) => v is num ? v.toDouble() : null;
int? _i(Object? v) => v is num ? v.toInt() : null;
List<String> _strings(Object? v) =>
    v is List ? v.map((e) => '$e').toList() : const <String>[];
List<double> _doubles(Object? v) => v is List
    ? v.whereType<num>().map((e) => e.toDouble()).toList()
    : const <double>[];

/// One Camera2 camera (logical, physical sub-camera, or hidden id).
class CameraLensInfo {
  CameraLensInfo.fromMap(Map<Object?, Object?> m)
    : id = '${m['id']}',
      source = '${m['source'] ?? ''}',
      lensFacing = '${m['lensFacing'] ?? 'unknown'}',
      isLogical = m['isLogical'] == true,
      physicalIds = _strings(m['physicalIds']),
      parentId = m['parentId'] == null ? null : '${m['parentId']}',
      focalLengths = _doubles(m['focalLengths']),
      sensorWidthMm = _d(m['sensorWidthMm']),
      sensorHeightMm = _d(m['sensorHeightMm']),
      activeArrayWidth = _i(m['activeArrayWidth']),
      activeArrayHeight = _i(m['activeArrayHeight']),
      maxDigitalZoom = _d(m['maxDigitalZoom']),
      zoomRatioMin = _d(m['zoomRatioMin']),
      zoomRatioMax = _d(m['zoomRatioMax']),
      reportedMaxZoom = _d(m['reportedMaxZoom']),
      pixelArrayWidth = _i(m['pixelArrayWidth']),
      pixelArrayHeight = _i(m['pixelArrayHeight']),
      pixelArrayMaxResWidth = _i(m['pixelArrayMaxResWidth']),
      pixelArrayMaxResHeight = _i(m['pixelArrayMaxResHeight']),
      eqFocalMm = _d(m['eqFocalMm']),
      opticalMultiplier = _d(m['opticalMultiplier']),
      isMain = m['isMain'] == true,
      minFocusDiopters = _d(m['minFocusDiopters']),
      manualSensor = m['manualSensor'] == true,
      maxExposureNs = _i(m['maxExposureNs']),
      maxIso = _i(m['maxIso']);

  final String id;

  /// listed | physical | hidden
  final String source;
  final String lensFacing;
  final bool isLogical;
  final List<String> physicalIds;
  final String? parentId;
  final List<double> focalLengths;
  final double? sensorWidthMm;
  final double? sensorHeightMm;
  final int? activeArrayWidth;
  final int? activeArrayHeight;
  final double? maxDigitalZoom;
  final double? zoomRatioMin;
  final double? zoomRatioMax;
  final double? reportedMaxZoom;
  final int? pixelArrayWidth;
  final int? pixelArrayHeight;
  final int? pixelArrayMaxResWidth;
  final int? pixelArrayMaxResHeight;
  final double? eqFocalMm;
  final double? opticalMultiplier;
  final bool isMain;

  /// v11: closest focus in diopters (1/m); 0 / null = fixed or unknown.
  final double? minFocusDiopters;

  /// v11: Camera2 MANUAL_SENSOR (manual exposure for Night).
  final bool manualSensor;
  final int? maxExposureNs;
  final int? maxIso;

  /// Closest focus distance in cm (null when fixed focus / unknown).
  double? get minFocusCm {
    final d = minFocusDiopters;
    if (d == null || d <= 0) return null;
    return 100 / d;
  }

  bool get isBack => lensFacing == 'back';

  /// Sensor megapixels (largest of max-resolution / pixel / active array).
  double? get megapixels {
    double? best;
    void consider(int? w, int? h) {
      if (w == null || h == null || w <= 0 || h <= 0) return;
      final mp = w * h / 1e6;
      if (best == null || mp > best!) best = mp;
    }

    consider(pixelArrayMaxResWidth, pixelArrayMaxResHeight);
    consider(pixelArrayWidth, pixelArrayHeight);
    consider(activeArrayWidth, activeArrayHeight);
    return best;
  }
}

/// Result of the native `ai_camera/zoom_info` → `getZoomInfo` probe.
class NativeZoomInfo {
  NativeZoomInfo.fromMap(Map<Object?, Object?> m)
    : cameras = (m['cameras'] is List)
          ? (m['cameras'] as List)
                .whereType<Map<Object?, Object?>>()
                .map(CameraLensInfo.fromMap)
                .toList()
          : const <CameraLensInfo>[],
      cameraIdList = _strings(m['cameraIdList']),
      primaryBackId = m['primaryBackId'] == null
          ? null
          : '${m['primaryBackId']}',
      mainCameraId = m['mainCameraId'] == null ? null : '${m['mainCameraId']}',
      mainEqFocalMm = _d(m['mainEqFocalMm']),
      reportedMaxZoom = _d(m['reportedMaxZoom']),
      opticalMultipliers = _doubles(m['opticalMultipliers']),
      rawTeleMultiplier = _d(m['teleMultiplier']),
      manufacturer = '${m['manufacturer'] ?? ''}',
      model = '${m['model'] ?? ''}',
      sdkInt = _i(m['sdkInt']),
      nightExtension = m['nightExtension'] is bool
          ? m['nightExtension'] as bool
          : null,
      error = m['error'] == null ? null : '${m['error']}',
      errors = _strings(m['errors']);

  final List<CameraLensInfo> cameras;
  final List<String> cameraIdList;
  final String? primaryBackId;
  final String? mainCameraId;
  final double? mainEqFocalMm;

  /// max(CONTROL_ZOOM_RATIO_RANGE.upper, SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
  /// of the primary back camera.
  final double? reportedMaxZoom;
  final List<double> opticalMultipliers;

  /// Largest measured back multiplier >= 1.5 (unsnapped).
  final double? rawTeleMultiplier;
  final String manufacturer;
  final String model;
  final int? sdkInt;

  /// Camera2 Night extension on the back camera (API 31+; null = unknown).
  /// Info only: the camera plugin can't bind extension sessions.
  final bool? nightExtension;
  final String? error;
  final List<String> errors;

  List<CameraLensInfo> get backCameras =>
      cameras.where((c) => c.isBack).toList();

  /// Snapped tele multiplier (e.g. 4.83 → 5) used for displayMax.
  double? get teleMultiplier => teleMultiplierFrom(opticalMultipliers);
}

/// Bridge + small in-memory cache shared by camera and settings screens.
class ZoomInfoService {
  ZoomInfoService._();

  static const _channel = MethodChannel('ai_camera/zoom_info');
  static Future<NativeZoomInfo?>? _cached;

  /// Last back-camera range computed by the camera screen (for Settings).
  static ZoomRange? lastBackRange;

  /// Last optical profile computed by the camera screen (for Settings).
  static OpticalProfile? lastOptical;

  /// Zoom calibration line for the last capture (requested camera ×
  /// digital vs the still's EXIF focal / digital zoom). Shown in Settings.
  static String? lastCaptureCalibration;

  /// Last successfully loaded probe (sync access for Settings lines).
  static NativeZoomInfo? cached;

  static Future<NativeZoomInfo?> load({bool refresh = false}) {
    if (refresh || _cached == null) {
      _cached = _fetch().then((v) {
        if (v != null) cached = v;
        return v;
      });
    }
    return _cached!;
  }

  static Future<NativeZoomInfo?> _fetch() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      // Native side always replies (probe runs on a worker thread).
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getZoomInfo',
      );
      if (raw == null) return null;
      return NativeZoomInfo.fromMap(raw);
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('getZoomInfo failed: $e');
      _cached = null; // allow a retry on next load()
      return null;
    }
  }
}
