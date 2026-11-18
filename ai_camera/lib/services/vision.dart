import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/shoot_mode.dart';
import 'frame_stats.dart';
import 'live_policies.dart';
import 'scene_suggest.dart';

/// Results of the live stream, in UPRIGHT-image normalised coordinates
/// (0..1, as the sensor image would look upright and NOT mirrored). The
/// camera screen maps them onto the (possibly mirrored, cropped, zoomed)
/// preview.
class LiveVision {
  const LiveVision({
    this.faces = const [],
    this.barcodes = const [],
    this.labels = const [],
    this.stats,
    this.seq = 0,
  });

  final List<LiveFace> faces;
  final List<String> barcodes;
  final List<SceneLabel> labels;

  /// v11: luma / sharpness / thumbnail of the latest analysed frame.
  final FrameStats? stats;
  final int seq;

  LiveVision copyWith({
    List<LiveFace>? faces,
    List<String>? barcodes,
    List<SceneLabel>? labels,
    FrameStats? stats,
    bool clearStats = false,
  }) => LiveVision(
    faces: faces ?? this.faces,
    barcodes: barcodes ?? this.barcodes,
    labels: labels ?? this.labels,
    stats: clearStats ? null : (stats ?? this.stats),
    seq: seq + 1,
  );

  static const empty = LiveVision();
}

/// Lazily-created ML Kit detectors (on-device; models bundled or via
/// Google Play services — see README "ML Kit footprint").
class _Detectors {
  FaceDetector? _face;
  BarcodeScanner? _barcode;
  ImageLabeler? _labeler;

  FaceDetector get face => _face ??= FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: true, // smile
      enableTracking: true,
      enableLandmarks: true, // v11.10 Macro zoom-aware face-part label
      minFaceSize: 0.08,
      performanceMode: FaceDetectorMode.fast,
    ),
  );
  BarcodeScanner get barcode =>
      _barcode ??= BarcodeScanner(formats: [BarcodeFormat.all]);
  ImageLabeler get labeler => _labeler ??= ImageLabeler(
    options: ImageLabelerOptions(confidenceThreshold: 0.6),
  );

  Future<void> close() async {
    await _face?.close();
    await _barcode?.close();
    await _labeler?.close();
    _face = null;
    _barcode = null;
    _labeler = null;
  }
}

/// Runs the active analyzers on the camera image stream (one frame at a
/// time, per-analyzer rate limits, frames dropped while busy).
/// v11.42: zoom above which live analysis is throttled.
const double kThrottleZoom = 5;

/// v11.42: min gap between analysed frames above [kThrottleZoom] (~6.7/s).
const int kThrottleGapMs = 150;

/// Skip this frame (high zoom, too soon after the last analysed one)? Pure.
bool throttleFrame({
  required double zoom,
  required DateTime? last,
  required DateTime now,
}) =>
    zoom > kThrottleZoom &&
    last != null &&
    now.difference(last).inMilliseconds < kThrottleGapMs;

class LiveVisionEngine extends ValueNotifier<LiveVision> {
  LiveVisionEngine() : super(LiveVision.empty);

  /// v11.35 digital crop on screen: frame stats also sample the visible
  /// centre 1/cropZoom of the camera frame.
  double cropZoom = 1;

  /// v11.60: add the whole-frame tracking proxy to frame stats (cheap-phone
  /// zoom tracking only; off = no extra work).
  bool trackFrames = false;

  /// v11.42: user zoom; above [kThrottleZoom] frames are analysed at most
  /// every [kThrottleGapMs] ms (~6–7 per second).
  double zoom = 1;

  /// v11.42 debug overlay: analysis frame size + analysed frames per second.
  int frameWidth = 0, frameHeight = 0;
  double analysedFps = 0;
  DateTime? _lastAnalysed;

  final _det = _Detectors();
  final _sched = AnalyzerScheduler();
  CameraController? _controller;
  InputImageRotation _rotation = InputImageRotation.rotation90deg;
  Set<LiveAnalyzer> _active = const {};
  bool _streaming = false;
  bool _paused = false;
  bool _disposed = false;

  Set<LiveAnalyzer> get active => _active;

  /// New controller (init / lens switch / resume).
  Future<void> attach(CameraController? c) async {
    await _stop();
    _controller = c;
    _sched.reset();
    value = LiveVision.empty;
    if (c != null) {
      _rotation =
          InputImageRotationValue.fromRawValue(
            c.description.sensorOrientation,
          ) ??
          InputImageRotation.rotation90deg;
    }
    await _sync();
  }

  Future<void> setAnalyzers(Set<LiveAnalyzer> analyzers) async {
    if (setEquals(analyzers, _active)) return;
    final dropped = _active.difference(analyzers);
    _active = Set.unmodifiable(analyzers);
    if (dropped.isNotEmpty) {
      value = value.copyWith(
        faces: dropped.contains(LiveAnalyzer.faces) ? const [] : null,
        barcodes: dropped.contains(LiveAnalyzer.barcodes) ? const [] : null,
        labels: dropped.contains(LiveAnalyzer.labels) ? const [] : null,
        clearStats: dropped.contains(LiveAnalyzer.frameStats),
      );
    }
    await _sync();
  }

  /// Stop the stream while a still is being captured.
  /// [keepStream]: v11.8 — skip frames instead of stopping the stream
  /// (stop/start rebinds CameraX use cases and can downgrade the preview).
  Future<void> pause({bool keepStream = false}) async {
    _paused = true;
    if (!keepStream) await _stop();
  }

  Future<void> resume() async {
    _paused = false;
    await _sync();
  }

  Future<void> _sync() async {
    final c = _controller;
    final want = !_paused && !_disposed && _active.isNotEmpty;
    if (want && !_streaming && c != null && c.value.isInitialized) {
      try {
        _streaming = true;
        await c.startImageStream(_onFrame);
      } catch (e) {
        _streaming = false;
        debugPrint('Image stream unavailable: $e');
      }
    } else if (!want) {
      await _stop();
    }
  }

  Future<void> _stop() async {
    final c = _controller;
    if (!_streaming || c == null) {
      _streaming = false;
      return;
    }
    _streaming = false;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (e) {
      debugPrint('stopImageStream: $e');
    }
  }

  InputImage? _input(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format != InputImageFormat.nv21) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_disposed || _paused) return;
    final now = DateTime.now();
    frameWidth = image.width;
    frameHeight = image.height;
    final last = _lastAnalysed;
    if (throttleFrame(zoom: zoom, last: last, now: now)) return;
    final due = _sched.due(_active, now);
    if (due.isEmpty) return;
    final input = _input(image);
    if (input == null) return;
    if (last != null) {
      final dt = now.difference(last).inMicroseconds / 1e6;
      if (dt > 0) analysedFps = analysedFps * 0.8 + (1 / dt) * 0.2;
    }
    _lastAnalysed = now;
    _sched.busy = true;
    final rotated =
        _rotation == InputImageRotation.rotation90deg ||
        _rotation == InputImageRotation.rotation270deg;
    final uw = (rotated ? image.height : image.width).toDouble();
    final uh = (rotated ? image.width : image.height).toDouble();
    var next = value;
    try {
      if (due.contains(LiveAnalyzer.frameStats)) {
        final plane = image.planes.first;
        next = next.copyWith(
          stats: frameStatsFromNv21(
            plane.bytes,
            image.width,
            image.height,
            bytesPerRow: plane.bytesPerRow,
            rotation: _rotation.rawValue,
            cropZoom: cropZoom,
            track: trackFrames,
          ),
        );
      }
      if (due.contains(LiveAnalyzer.faces)) {
        final faces = await _det.face.processImage(input);
        next = next.copyWith(
          faces: [
            for (final f in faces)
              LiveFace(
                box: Rect.fromLTRB(
                  f.boundingBox.left / uw,
                  f.boundingBox.top / uh,
                  f.boundingBox.right / uw,
                  f.boundingBox.bottom / uh,
                ),
                smiling: f.smilingProbability,
                trackingId: f.trackingId,
                parts: {
                  for (final e in {
                    'leftEye': FaceLandmarkType.leftEye,
                    'rightEye': FaceLandmarkType.rightEye,
                    'mouth': FaceLandmarkType.bottomMouth,
                    'nose': FaceLandmarkType.noseBase,
                  }.entries)
                    if (f.landmarks[e.value] != null)
                      e.key: Offset(
                        f.landmarks[e.value]!.position.x / uw,
                        f.landmarks[e.value]!.position.y / uh,
                      ),
                },
              ),
          ],
        );
      }
      if (due.contains(LiveAnalyzer.barcodes)) {
        final codes = await _det.barcode.processImage(input);
        next = next.copyWith(
          barcodes: [
            for (final b in codes)
              if ((b.rawValue ?? '').trim().isNotEmpty) b.rawValue!,
          ],
        );
      }
      if (due.contains(LiveAnalyzer.labels)) {
        final labels = await _det.labeler.processImage(input);
        next = next.copyWith(
          labels: [for (final l in labels) SceneLabel(l.label, l.confidence)],
        );
      }
      if (!_disposed) value = next;
    } catch (e) {
      debugPrint('Live vision frame failed: $e');
    } finally {
      _sched.busy = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stop());
    unawaited(_det.close());
    super.dispose();
  }
}

/// Still-photo helpers (single-image ML Kit calls). Every call is guarded:
/// failures return null so the free feature degrades gracefully.
class StillVision {
  /// Test hooks.
  static Future<int?> Function(String path) faceCounter = _countFaces;
  static Future<String?> Function(String path) textReader = _readText;
  static Future<List<SceneLabel>?> Function(String path) labeler = _label;

  static void reset() {
    faceCounter = _countFaces;
    textReader = _readText;
    labeler = _label;
  }

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<int?> _countFaces(String path) async {
    if (!_supported) return null;
    final d = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.05,
      ),
    );
    try {
      return (await d.processImage(InputImage.fromFilePath(path))).length;
    } finally {
      await d.close();
    }
  }

  static Future<String?> _readText(String path) async {
    if (!_supported) return null;
    final r = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      return (await r.processImage(InputImage.fromFilePath(path))).text;
    } finally {
      await r.close();
    }
  }

  /// v11 Macro: on-device label of a still (subject chip fallback).
  static Future<List<SceneLabel>?> _label(String path) async {
    if (!_supported) return null;
    final l = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.55),
    );
    try {
      final r = await l.processImage(InputImage.fromFilePath(path));
      return [for (final x in r) SceneLabel(x.label, x.confidence)];
    } finally {
      await l.close();
    }
  }

  static Future<T?> _guard<T>(Future<T?> Function() f, Duration t) async {
    try {
      return await f().timeout(t);
    } catch (e) {
      debugPrint('Still vision failed: $e');
      return null;
    }
  }

  static Future<int?> countFaces(String path) =>
      _guard(() => faceCounter(path), const Duration(seconds: 5));
  static Future<String?> readText(String path) =>
      _guard(() => textReader(path), const Duration(seconds: 10));
  static Future<List<SceneLabel>?> labels(String path) =>
      _guard(() => labeler(path), const Duration(seconds: 6));
}
