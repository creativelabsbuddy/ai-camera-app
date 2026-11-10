import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vision.dart';

/// On-device "is there a person?" check before spending credits on an
/// outfit / person look. v10: ML Kit face detection (same detector as the
/// live camera; finds turned / tilted faces), falling back to Android's
/// built-in android.media.FaceDetector. Returns null when unknown (no
/// platform support / error) — callers then just proceed.
class PersonCheck {
  static const _channel = MethodChannel('ai_camera/person');

  /// Test hook.
  static Future<bool?> Function(File photo) detector = _detect;

  static void reset() => detector = _detect;

  static Future<bool?> hasPerson(File photo) async {
    try {
      return await detector(photo).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Person check skipped: $e');
      return null;
    }
  }

  static Future<bool?> _detect(File photo) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    final ml = await StillVision.countFaces(photo.path);
    if (ml != null) return ml > 0;
    final n = await _channel.invokeMethod<int>('countFaces', {
      'path': photo.path,
    });
    if (n == null || n < 0) return null;
    return n > 0;
  }
}
