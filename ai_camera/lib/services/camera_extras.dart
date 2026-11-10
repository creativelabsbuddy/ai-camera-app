import 'dart:convert';

import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// v11.35 extras from the vendored camera_android_camerax fork
/// (packages/camera_android_camerax/FORK.md). Every call is guarded.
class CameraExtras {
  static const _ch = MethodChannel('ai_camera/camerax_extras');

  /// Metering area (share of the camera frame) for taps / bright metering.
  static void setMeteringSize(double size) {
    try {
      AndroidCameraCameraX.meteringPointSize = size;
    } catch (_) {}
  }

  static Future<Map<String, Object?>> info() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('info');
      return m ?? const {};
    } catch (e) {
      debugPrint('Camera extras info failed: $e');
      return const {};
    }
  }

  /// Focus to infinity and/or manual exposure. Returns what was applied.
  static Future<String> setManual({
    bool focusInfinity = false,
    int? exposureNs,
    int? iso,
  }) async {
    try {
      return await _ch.invokeMethod<String>('setManual', {
            'focusInfinity': focusInfinity,
            'exposureNs': exposureNs,
            'iso': iso,
          }) ??
          '';
    } catch (e) {
      return 'failed';
    }
  }

  /// v11.42: OIS (where the lens has it) + preview EIS (API 33+, where
  /// offered). Returns what was applied ('OIS EIS-preview', 'not supported').
  static Future<String> setStabilization(bool on) async {
    try {
      return await _ch.invokeMethod<String>('setStabilization', {'on': on}) ??
          '';
    } catch (e) {
      return 'failed';
    }
  }

  static Future<void> clearManual() async {
    try {
      await _ch.invokeMethod<void>('clearManual');
    } catch (_) {}
  }
}

/// Short lens / exposure line for the debug note. Pure.
String lensInfoText(Map<String, Object?> m) {
  if (m.isEmpty) return 'lens info —';
  String n(Object? v, [int d = 2]) =>
      v is num ? v.toStringAsFixed(d) : (v?.toString() ?? '—');
  final exp = m['exposureNs'];
  final shutter = exp is num && exp > 0 ? '1/${(1e9 / exp).round()}s' : '—';
  return 'cam ${m['cameraId'] ?? '—'} active ${m['activePhysicalId'] ?? '—'} '
      'ratio ${n(m['zoomRatio'])} · focus ${n(m['focusDistance'])}D '
      '(af ${m['afState'] ?? '—'}) · $shutter ISO ${m['iso'] ?? '—'} '
      '· comp ${m['aeComp'] ?? '—'} [${m['aeCompMin'] ?? '?'}..${m['aeCompMax'] ?? '?'}]'
      '${m['manualOn'] == true ? ' · manual' : ''}'
      '${m['manualSensor'] == true ? '' : ' · no manual sensor'}';
}

// ---------------------------------------------------------------------------
// v11.35 per-phone telephoto check (active physical lens at 3x / 10x).
// ---------------------------------------------------------------------------

const String kLensCheckKey = 'lens_check_v1';

/// Camera zooms checked (± tolerance).
const List<double> kLensCheckZooms = [1, 3, 10];

double? lensCheckSlot(double cameraZoom) {
  for (final z in kLensCheckZooms) {
    if ((cameraZoom - z).abs() <= z * 0.08) return z;
  }
  return null;
}

/// Active physical lens id seen at 1x / 3x / 10x on this phone.
class LensCheck {
  LensCheck([Map<String, String>? seen]) : seen = {...?seen};
  final Map<String, String> seen;

  bool record(double slot, String? id) {
    if (id == null || id.isEmpty) return false;
    final k = slot.toStringAsFixed(0);
    if (seen[k] == id) return false;
    seen[k] = id;
    return true;
  }

  /// true = a different lens than at 1x (telephoto used), false = same lens
  /// (digital crop), null = not seen yet.
  bool? teleAt(double slot) {
    final one = seen['1'];
    final t = seen[slot.toStringAsFixed(0)];
    if (one == null || t == null) return null;
    return t != one;
  }

  /// 10x lens reached through the logical camera?
  bool? get tenXReachable {
    final ten = seen['10'];
    final three = seen['3'];
    if (ten == null) return null;
    if (three != null && ten == three) return false;
    return teleAt(10);
  }

  String get text {
    String s(double z) {
      final v = teleAt(z);
      return v == null
          ? '?'
          : (v ? 'tele ${seen[z.toStringAsFixed(0)]}' : 'crop');
    }

    return 'lens 1x ${seen['1'] ?? '?'} · 3x ${s(3)} · 10x ${s(10)}';
  }

  String encode() => jsonEncode(seen);
  static LensCheck decode(String? raw) {
    try {
      final m = jsonDecode(raw ?? '') as Map<String, dynamic>;
      return LensCheck({for (final e in m.entries) e.key: '${e.value}'});
    } catch (_) {
      return LensCheck();
    }
  }
}
