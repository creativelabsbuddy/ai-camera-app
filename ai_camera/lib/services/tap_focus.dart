import 'dart:async';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'focus_mapping.dart';
import 'zoom_assist.dart' show tapSurvivesZoom, kTapPausesBright;

/// The camera calls the focus logic needs (a [CameraController] in the app,
/// a fake in tests).
abstract class FocusOps {
  Future<void> setFocusPoint(Offset? point);
  Future<void> setExposurePoint(Offset? point);
  Future<void> setFocusMode(FocusMode mode);
  Future<void> setExposureMode(ExposureMode mode);
}

class CameraFocusOps implements FocusOps {
  CameraFocusOps(this.controller);
  final CameraController controller;

  @override
  Future<void> setFocusPoint(Offset? p) =>
      controller.setFocusPoint(p == null ? null : Offset(p.dx, p.dy));
  @override
  Future<void> setExposurePoint(Offset? p) =>
      controller.setExposurePoint(p == null ? null : Offset(p.dx, p.dy));
  @override
  Future<void> setFocusMode(FocusMode mode) => controller.setFocusMode(mode);
  @override
  Future<void> setExposureMode(ExposureMode mode) =>
      controller.setExposureMode(mode);
}

/// Tap-to-focus / AE-AF lock state machine.
///
/// * Default: continuous AF + auto AE (CONTINUOUS_PICTURE on CameraX).
/// * Tap: AF + AE metering at the tapped point; returns to continuous after
///   [hold] (or on zoom / lens / ratio change).
/// * Long-press: same, then AF + AE locked ("AE/AF lock") until the next
///   tap or a zoom / lens / ratio change.
/// * Shutter: [preCapture] runs an AF pass (tapped point, else centre) and
///   waits up to [preCaptureWait] so stills are never taken mid-hunt.
///
/// Every camera call is guarded — a plugin error never breaks the camera.
class TapFocusController extends ChangeNotifier {
  TapFocusController({
    this.hold = kTapFocusHold,
    this.preCaptureWait = kPreCaptureFocusWait,
    this.recentWindow = kRecentFocusWindow,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Duration hold;
  final Duration preCaptureWait;
  final Duration recentWindow;
  final DateTime Function() _now;

  FocusOps? _ops;
  Timer? _resetTimer;
  int _seq = 0;
  bool _disposed = false;
  bool _modesLocked = false;

  /// Ring position (frame coordinates) — null = no ring.
  Offset? ringPosition;

  /// Normalised metering point currently applied (null = continuous AF).
  Offset? point;
  bool locked = false;
  bool focused = false;
  DateTime? lastFocusAt;

  /// v11.35 zoom at the last tap (a small zoom change keeps the tap).
  double tapZoom = 1;

  /// v11.35 auto bright-region lock (routed here so it never fights a tap).
  bool brightOn = false;

  /// Called on every user tap / long-press (home cancels the bright lock).
  VoidCallback? onUserTap;

  /// True while a user tap should keep auto bright metering paused.
  bool get tapPausesBright =>
      point != null &&
      lastFocusAt != null &&
      _now().difference(lastFocusAt!) < kTapPausesBright;

  /// Bright-region lock: AE + AF on [p] (camera-frame point), AF locked.
  /// Ignored while the user's tap / lock is active.
  Future<bool> brightLock(Offset p) async {
    final ops = _ops;
    if (ops == null || isActive || tapPausesBright) return false;
    brightOn = true;
    await _guard(() => ops.setExposurePoint(p));
    await _guard(() => ops.setFocusPoint(p).timeout(hold));
    await _guard(() => ops.setFocusMode(FocusMode.locked));
    return true;
  }

  /// Ends the bright lock (back to continuous AF / auto AE points).
  Future<void> brightRelease() async {
    final ops = _ops;
    if (!brightOn) return;
    brightOn = false;
    if (ops == null || isActive) return;
    await _guard(() => ops.setFocusMode(FocusMode.auto));
    await _guard(() => ops.setExposurePoint(null));
    await _guard(() => ops.setFocusPoint(null));
  }

  /// Bumped for every new tap (ring animation key).
  int get seq => _seq;

  bool get isActive => point != null || locked;

  /// Face-priority metering point (preview-normalised, as displayed) set
  /// by the live face detector when the user hasn't tapped.
  Offset? facePoint;
  DateTime? faceAt;

  /// Face points older than this are ignored by [preCapture].
  static const faceFresh = Duration(seconds: 2);

  /// Meters AF + AE on a detected face (no ring). Ignored while the user's
  /// tap focus or AE/AF lock is active.
  Future<void> faceMeter(Offset previewPoint) async {
    final ops = _ops;
    if (ops == null || isActive) return;
    final p = Offset(
      previewPoint.dx.clamp(0.0, 1.0),
      previewPoint.dy.clamp(0.0, 1.0),
    );
    facePoint = p;
    faceAt = _now();
    await _guard(() => ops.setExposurePoint(p));
    await _guard(() => ops.setFocusPoint(p).timeout(hold));
  }

  /// Faces left the frame: forget the face point (CameraX returns to
  /// continuous AF on its own after the metering action times out).
  void clearFace() {
    facePoint = null;
    faceAt = null;
  }

  /// New camera controller (init / lens switch): back to continuous AF/AE.
  Future<void> attach(FocusOps? ops) async {
    _resetTimer?.cancel();
    _ops = ops;
    _modesLocked = false;
    _clear();
    if (ops == null) return;
    await _guard(() => ops.setFocusMode(FocusMode.auto));
    await _guard(() => ops.setExposureMode(ExposureMode.auto));
  }

  /// Tap ([lock] = false) or long-press ([lock] = true) on the preview.
  Future<void> focusAt(
    Offset local,
    PreviewGeometry geometry, {
    bool lock = false,
    double zoom = 1,
  }) async {
    final ops = _ops;
    final p = tapToPreviewPoint(local, geometry);
    if (ops == null || p == null) return;
    // v11.35: a tap overrides the auto bright lock.
    brightOn = false;
    tapZoom = zoom;
    onUserTap?.call();
    _resetTimer?.cancel();
    final mySeq = ++_seq;
    ringPosition = local;
    point = p;
    locked = lock;
    focused = false;
    lastFocusAt = _now();
    _notify();

    if (_modesLocked) {
      await _guard(() => ops.setFocusMode(FocusMode.auto));
      await _guard(() => ops.setExposureMode(ExposureMode.auto));
      _modesLocked = false;
    }
    // AE first (returns quickly), then AF (completes when focus settles).
    await _guard(() => ops.setExposurePoint(p));
    final ok = await _guard(() => ops.setFocusPoint(p).timeout(hold));
    if (_disposed || mySeq != _seq) return;
    focused = ok;
    if (lock) {
      await _guard(() => ops.setFocusMode(FocusMode.locked));
      await _guard(() => ops.setExposureMode(ExposureMode.locked));
      _modesLocked = true;
    } else {
      // v11.35: at high zoom the tap holds longer (exposure + focus stay).
      _resetTimer = Timer(
        zoom >= 5 ? kTapPausesBright : hold,
        () => unawaited(reset()),
      );
    }
    _notify();
  }

  /// Back to continuous AF / auto AE (timer, zoom, lens or ratio change).
  Future<void> reset() async {
    _resetTimer?.cancel();
    final ops = _ops;
    final hadPoint = point != null;
    final wasLocked = _modesLocked;
    _seq++;
    _clear();
    _notify();
    if (ops == null) return;
    if (wasLocked) {
      await _guard(() => ops.setFocusMode(FocusMode.auto));
      await _guard(() => ops.setExposureMode(ExposureMode.auto));
      _modesLocked = false;
    }
    if (hadPoint || wasLocked) {
      await _guard(() => ops.setExposurePoint(null));
      await _guard(() => ops.setFocusPoint(null));
    }
  }

  /// Zoom / lens / ratio change = new scene: drop tap focus + lock.
  /// v11.35: a small zoom change ([zoom] within 1.25x of the tap's) keeps
  /// the tap.
  void onSceneChange({double? zoom}) {
    if (!isActive) return;
    if (zoom != null && !locked && tapSurvivesZoom(tapZoom, zoom)) return;
    unawaited(reset());
  }

  /// Before a still: make sure AF has converged. Returns true when an AF
  /// pass was started by us (so the caller can call [afterCapture]).
  Future<bool> preCapture() async {
    final ops = _ops;
    if (ops == null || locked) return false;
    final last = lastFocusAt;
    if (point != null &&
        last != null &&
        _now().difference(last) < recentWindow &&
        focused) {
      return false; // User just focused here and AF converged.
    }
    final fa = faceAt;
    final face =
        facePoint != null && fa != null && _now().difference(fa) < faceFresh
        ? facePoint
        : null;
    final p = point ?? face ?? const Offset(0.5, 0.5);
    await _guard(() => ops.setFocusPoint(p).timeout(preCaptureWait));
    return point == null;
  }

  /// v11.39 cheap phones, zoomed preview: one centre AF scan after the
  /// zoom settles (no ring, no lock); skipped when the user tapped or
  /// locked. CameraX returns to continuous AF by itself after ~5 s.
  Future<void> centrePass() async {
    final ops = _ops;
    if (ops == null || locked || point != null) return;
    await _guard(
      () => ops.setFocusPoint(const Offset(0.5, 0.5)).timeout(preCaptureWait),
    );
  }

  /// After a still that used a synthetic (centre) AF pass: back to
  /// continuous AF right away.
  Future<void> afterCapture(bool startedByUs) async {
    final ops = _ops;
    if (!startedByUs || ops == null || point != null || locked) return;
    await _guard(() => ops.setFocusPoint(null));
  }

  void _clear() {
    facePoint = null;
    faceAt = null;
    ringPosition = null;
    point = null;
    locked = false;
    focused = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Future<bool> _guard(Future<void> Function() f) async {
    try {
      await f();
      return true;
    } catch (e) {
      debugPrint('Focus call failed: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _resetTimer?.cancel();
    super.dispose();
  }
}
