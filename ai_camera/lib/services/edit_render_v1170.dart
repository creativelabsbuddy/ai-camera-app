import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'edit_v1170.dart';
import 'photo_edit.dart' show clampCrop;

/// v11.70 editor I/O: live proxy render, full-resolution save, on-device
/// face detection (ML Kit). The original file is never touched.

/// Renders the pixel part of [r] on a proxy copy (background isolate).
Future<Uint8List> renderEditProxy(
  Uint8List rgba,
  int w,
  int h,
  EditRecipe r,
  List<FaceGeom> faces,
) {
  final recipe = jsonEncode(r.toJson());
  final fj = jsonEncode([for (final f in faces) f.toJson()]);
  return compute(_proxyJob, (rgba, w, h, recipe, fj));
}

List<FaceGeom> _faces(String fj) => [
  for (final f in (jsonDecode(fj) as List)) ?FaceGeom.fromJson(f),
];

Uint8List _proxyJob((Uint8List, int, int, String, String) a) {
  final out = Uint8List.fromList(a.$1);
  renderEditPixels(
    out,
    a.$2,
    a.$3,
    EditRecipe.fromJson(jsonDecode(a.$4) as Map<String, dynamic>),
    faces: _faces(a.$5),
  );
  return out;
}

/// Pure full pipeline on an `image` [src]: pixels (retouch → skin tone →
/// adjust), then rotate → crop.
img.Image applyEditRecipe(
  img.Image src,
  EditRecipe r, {
  List<FaceGeom> faces = const [],
}) {
  var im = src.numChannels == 4 ? src : src.convert(numChannels: 4);
  if (r.hasPixels) {
    final rgba = im.getBytes(order: img.ChannelOrder.rgba);
    renderEditPixels(rgba, im.width, im.height, r, faces: faces);
    final whole =
        rgba.offsetInBytes == 0 &&
        rgba.lengthInBytes == rgba.buffer.lengthInBytes;
    im = img.Image.fromBytes(
      width: im.width,
      height: im.height,
      bytes: (whole ? rgba : Uint8List.fromList(rgba)).buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  }
  final turns = r.quarterTurns % 4;
  if (turns != 0) im = img.copyRotate(im, angle: 90 * turns);
  final c = clampCrop(r.crop, minSize: 0.01);
  if (c != const Rect.fromLTWH(0, 0, 1, 1)) {
    final x = (c.left * im.width).round();
    final y = (c.top * im.height).round();
    final cw = math.max(
      1,
      math.min(im.width - x, (c.width * im.width).round()),
    );
    final ch = math.max(
      1,
      math.min(im.height - y, (c.height * im.height).round()),
    );
    im = img.copyCrop(im, x: x, y: y, width: cw, height: ch);
  }
  return im;
}

/// Full-resolution render of [src] → a NEW JPEG in [outDir] (isolate).
Future<File> renderEditFile(
  File src,
  EditRecipe r,
  List<FaceGeom> faces, {
  required String outDir,
  int quality = 95,
}) async {
  final path = src.path;
  final out = p.join(
    outDir,
    'ai_camera_edit_${DateTime.now().microsecondsSinceEpoch}.jpg',
  );
  final recipe = jsonEncode(r.toJson());
  final fj = jsonEncode([for (final f in faces) f.toJson()]);
  await Isolate.run(() {
    final raw = img.decodeImage(File(path).readAsBytesSync());
    if (raw == null) throw StateError('Unsupported image');
    final res = applyEditRecipe(
      img.bakeOrientation(raw),
      EditRecipe.fromJson(jsonDecode(recipe) as Map<String, dynamic>),
      faces: _faces(fj),
    );
    File(out).writeAsBytesSync(img.encodeJpg(res, quality: quality));
  });
  return File(out);
}

// ---------------------------------------------------------------------------
// Face detection (ML Kit, on device)
// ---------------------------------------------------------------------------

List<Offset> _pts(Face f, FaceContourType t, int w, int h) => [
  for (final q in f.contours[t]?.points ?? const <math.Point<int>>[])
    Offset(q.x / w, q.y / h),
];

List<Offset> _band(List<Offset> top, List<Offset> bottom) {
  if (top.length < 2 || bottom.length < 2) return const [];
  final a = [...top]..sort((x, y) => x.dx.compareTo(y.dx));
  final b = [...bottom]..sort((x, y) => y.dx.compareTo(x.dx));
  return [...a, ...b];
}

/// ML Kit [Face] → normalised [FaceGeom] ([w]×[h] = the detected image).
FaceGeom faceGeomFrom(Face f, int w, int h) {
  final bb = f.boundingBox;
  final box = Rect.fromLTRB(
    (bb.left / w).clamp(0.0, 1.0),
    (bb.top / h).clamp(0.0, 1.0),
    (bb.right / w).clamp(0.0, 1.0),
    (bb.bottom / h).clamp(0.0, 1.0),
  );
  return FaceGeom(
    box: box,
    oval: _pts(f, FaceContourType.face, w, h),
    leftEye: _pts(f, FaceContourType.leftEye, w, h),
    rightEye: _pts(f, FaceContourType.rightEye, w, h),
    leftBrow: _band(
      _pts(f, FaceContourType.leftEyebrowTop, w, h),
      _pts(f, FaceContourType.leftEyebrowBottom, w, h),
    ),
    rightBrow: _band(
      _pts(f, FaceContourType.rightEyebrowTop, w, h),
      _pts(f, FaceContourType.rightEyebrowBottom, w, h),
    ),
    lipsOuter: _band(
      _pts(f, FaceContourType.upperLipTop, w, h),
      _pts(f, FaceContourType.lowerLipBottom, w, h),
    ),
    mouthInner: _band(
      _pts(f, FaceContourType.upperLipBottom, w, h),
      _pts(f, FaceContourType.lowerLipTop, w, h),
    ),
  );
}

/// Detects faces on the (upright) proxy pixels. Never throws: no ML Kit /
/// no face → empty list (Retouch then explains there is no face).
Future<List<FaceGeom>> detectFaceGeoms(
  Uint8List rgba,
  int w,
  int h, {
  required String tmpDir,
}) async {
  FaceDetector? d;
  File? tmp;
  try {
    final path = p.join(
      tmpDir,
      'ai_camera_edit_faces_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await compute(_writeJpg, (rgba, w, h, path));
    tmp = File(path);
    d = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: true,
        enableLandmarks: true,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.06,
      ),
    );
    final faces = await d.processImage(InputImage.fromFilePath(path));
    faces.sort(
      (a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(
        a.boundingBox.width * a.boundingBox.height,
      ),
    );
    return [for (final f in faces.take(6)) faceGeomFrom(f, w, h)];
  } catch (e) {
    debugPrint('Editor face detection unavailable: $e');
    return const [];
  } finally {
    unawaited(d?.close().then((_) {}, onError: (_) {}));
    unawaited(tmp?.delete().then((_) {}, onError: (_) {}));
  }
}

void _writeJpg((Uint8List, int, int, String) a) {
  final im = img.Image.fromBytes(
    width: a.$2,
    height: a.$3,
    bytes: Uint8List.fromList(a.$1).buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  File(a.$4).writeAsBytesSync(img.encodeJpg(im, quality: 90));
}
