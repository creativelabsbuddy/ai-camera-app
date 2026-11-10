import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin bridge to Android runtime CAMERA permission.
/// Avoids permission_handler (Gradle/Kotlin break on this Flutter pin).
class CameraPermission {
  static const _channel = MethodChannel('com.ankush.ai_camera/permissions');

  static Future<bool> ensureGranted() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS prompts on CameraController.initialize().
      return true;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      final already = await _channel.invokeMethod<bool>('checkCamera');
      if (already == true) return true;
      final granted = await _channel.invokeMethod<bool>('requestCamera');
      return granted == true;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      // Fallback: let camera plugin attempt init (may still prompt).
      return true;
    }
  }
}
