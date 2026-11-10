import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// v11.58: a local notification when a background AI video finishes, fails
/// or times out (the user can leave the video screen while it is made).
/// Every call is best-effort: a missing permission never breaks the job.
class VideoNotifier {
  VideoNotifier._();
  static final VideoNotifier instance = VideoNotifier._();

  /// Tests replace this to capture notifications.
  static void Function(String title, String body)? debugSink;

  final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  static const _channelId = 'ai_video';
  static const _id = 5801;

  Future<void> _init() async {
    if (_ready) return;
    await _p.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _ready = true;
  }

  /// Asks for the Android 13+ notification permission (when a video starts).
  Future<void> requestPermission() async {
    if (debugSink != null || kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _init();
      await _p
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }

  Future<void> show(String title, String body) async {
    final sink = debugSink;
    if (sink != null) {
      sink(title, body);
      return;
    }
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _init();
      await _p.show(
        id: _id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'AI video',
            channelDescription: 'Tells you when your AI video is ready',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (_) {}
  }
}
