import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'night_plan.dart';

/// v11 bridges to the native camera helpers in MainActivity:
/// * `ai_camera/bokeh` — Portrait (NORMAL) through the phone maker's BOKEH
///   CameraX extension (BokehSession.kt),
/// * `ai_camera/night` — Camera2 manual-exposure night burst + streaming
///   merge (NightCapture.kt / NightMerge.kt).
class BokehStart {
  const BokehStart({
    required this.textureId,
    required this.handlesCropAndRotation,
    required this.sensorOrientation,
    this.minZoom = 1,
    this.maxZoom = 1,
  });
  final int textureId;
  final bool handlesCropAndRotation;
  final int sensorOrientation;
  final double minZoom;
  final double maxZoom;
}

class BokehBridge {
  BokehBridge._();
  static const _ch = MethodChannel('ai_camera/bokeh');

  /// Test hook: replaces the platform availability probe.
  static Future<bool> Function(bool front)? availabilityOverride;

  static final Map<bool, bool> _cache = {};

  static bool? cached(bool front) => _cache[front];

  /// Vendor BOKEH extension available for this lens? (cached; false on any
  /// error — never a fake blur).
  static Future<bool> available({required bool front}) async {
    final c = _cache[front];
    if (c != null) return c;
    bool v;
    try {
      final o = availabilityOverride;
      v = o != null
          ? await o(front)
          : (await _ch
                    .invokeMethod<bool>('available', {'front': front})
                    .timeout(const Duration(seconds: 4))) ==
                true;
    } catch (e) {
      debugPrint('Bokeh availability probe failed: $e');
      v = false;
    }
    _cache[front] = v;
    return v;
  }

  /// Start failed on this lens → treat as unsupported for this session.
  static void markUnavailable({required bool front}) => _cache[front] = false;

  @visibleForTesting
  static void resetForTest() {
    _cache.clear();
    availabilityOverride = null;
  }

  static Future<BokehStart> start({
    required bool front,
    double zoom = 1,
  }) async {
    final m = await _ch.invokeMapMethod<String, Object?>('start', {
      'front': front,
      'zoom': zoom,
    });
    if (m == null) throw StateError('bokeh start returned nothing');
    return BokehStart(
      textureId: (m['textureId'] as num).toInt(),
      handlesCropAndRotation: m['handlesCropAndRotation'] == true,
      sensorOrientation: (m['sensorOrientation'] as num?)?.toInt() ?? 90,
      minZoom: (m['minZoom'] as num?)?.toDouble() ?? 1,
      maxZoom: (m['maxZoom'] as num?)?.toDouble() ?? 1,
    );
  }

  static Future<String> capture(String dir) async {
    final p = await _ch.invokeMethod<String>('capture', {'dir': dir});
    if (p == null) throw StateError('bokeh capture returned nothing');
    return p;
  }

  static Future<void> setZoom(double zoom) async {
    try {
      await _ch.invokeMethod<void>('setZoom', {'zoom': zoom});
    } catch (_) {}
  }

  static Future<void> focus(double x, double y) async {
    try {
      await _ch.invokeMethod<bool>('focus', {'x': x, 'y': y});
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }
}

/// Native night result (merged, tone-mapped, upright JPEG).
class NightMergeResult {
  const NightMergeResult({
    required this.path,
    required this.used,
    required this.offered,
    this.manual = false,
    this.frameExposureMs,
    this.frameIso,
    this.mean,
  });

  final String path;
  final int used;
  final int offered;

  /// Camera2 manual exposure was used (longer per-frame shutter).
  final bool manual;
  final double? frameExposureMs;
  final int? frameIso;
  final double? mean;

  static NightMergeResult fromMap(Map<String, Object?> m) => NightMergeResult(
    path: '${m['path']}',
    used: (m['used'] as num?)?.toInt() ?? 1,
    offered: (m['offered'] as num?)?.toInt() ?? 1,
    manual: m['manual'] == true,
    frameExposureMs: (m['frameExposureMs'] as num?)?.toDouble(),
    frameIso: (m['frameIso'] as num?)?.toInt(),
    mean: (m['mean'] as num?)?.toDouble(),
  );

  @override
  String toString() =>
      'NightMergeResult($used/$offered, manual=$manual, '
      'exp=${frameExposureMs?.toStringAsFixed(1)}ms, iso=$frameIso, '
      'mean=${mean?.toStringAsFixed(3)})';
}

class NightBridge {
  NightBridge._();
  static const _ch = MethodChannel('ai_camera/night');

  /// Camera2 burst (the Flutter camera must be closed first).
  static Future<NightMergeResult> capture({
    required String cameraId,
    required NightPlan plan,
    required double zoom,
    required String outDir,
  }) async {
    final m = await _ch
        .invokeMapMethod<String, Object?>('capture', {
          'cameraId': cameraId,
          'frames': plan.frames,
          'boost': plan.boost,
          'maxFrameMs': plan.maxFrameMs,
          'zoom': zoom,
          'tone': plan.tone.name,
          'outDir': outDir,
        })
        .timeout(Duration(seconds: 12 + plan.frames));
    if (m == null) throw StateError('night capture returned nothing');
    return NightMergeResult.fromMap(m);
  }

  /// Merge camera-plugin JPEG frames natively (fallback path).
  static Future<NightMergeResult> mergeJpegs({
    required List<String> paths,
    required String out,
    required NightTone tone,
  }) async {
    final m = await _ch
        .invokeMapMethod<String, Object?>('mergeJpegs', {
          'paths': paths,
          'out': out,
          'tone': tone.name,
        })
        .timeout(const Duration(seconds: 40));
    if (m == null) throw StateError('night merge returned nothing');
    return NightMergeResult.fromMap(m);
  }
}
