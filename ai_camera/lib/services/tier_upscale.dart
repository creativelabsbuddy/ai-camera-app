import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/ai_config.dart';
import '../models/quality_tier.dart';
import 'ai_call.dart';
import 'runware_client.dart';
import 'upload_prep.dart' show resizeToLongSide;

/// How a tier result was sized (v11.65).
enum UpscaleOutcome {
  /// HD: delivered exactly as Flare returned it.
  none,

  /// Real-ESRGAN 2x on Runware, then resized to the tier's long side.
  esrgan,

  /// Upscale failed / unavailable → the Flare image resized to the tier.
  resize,
}

/// v11.66: [upscaleMs] / [resizeMs] for the test-build timing line (null
/// when that step did not run).
typedef TierUpscaleResult = ({
  Uint8List bytes,
  UpscaleOutcome outcome,
  double cost,
  int? upscaleMs,
  int? resizeMs,
});

/// v11.65: Full HD / Ultra HD = Real-ESRGAN 2x ([AiConfig.runwareUpscaleModel])
/// then resize to [QualityTier.upscaleLongSide]. Never throws for an upscale
/// problem (e.g. Runware `insufficientCredits`): it falls back to resizing
/// the Flare image so the shot is still delivered (and charged normally).
/// Only a cancel is rethrown.
Future<TierUpscaleResult> upscaleForTier(
  Uint8List bytes,
  QualityTier tier, {
  RunwareClient? runware,
  AiCancelToken? cancel,
  Future<Uint8List> Function(Uint8List, int)? resize,
}) async {
  final target = tier.upscaleLongSide;
  if (target == null) {
    return (
      bytes: bytes,
      outcome: UpscaleOutcome.none,
      cost: 0.0,
      upscaleMs: null,
      resizeMs: null,
    );
  }
  final rs = resize ?? resizeToLongSide;
  final rw = runware ?? RunwareClient(timeout: AiConfig.upscaleTimeout);
  final sw = Stopwatch()..start();
  int? upMs;
  try {
    if (!rw.isConfigured) throw const AiFailure(AiFailureKind.other, 'Runware is not set up');
    final up = await rw.upscale(bytes, cancel: cancel);
    cancel?.throwIfCancelled();
    upMs = sw.elapsedMilliseconds;
    final r0 = sw.elapsedMilliseconds;
    final out = await rs(up.image, target);
    return (
      bytes: out,
      outcome: UpscaleOutcome.esrgan,
      cost: up.cost,
      upscaleMs: upMs,
      resizeMs: sw.elapsedMilliseconds - r0,
    );
  } on AiCancelledException {
    rethrow;
  } catch (e) {
    cancel?.throwIfCancelled();
    debugPrint('Tier upscale failed (${tier.id}), resize fallback: $e');
    // The failed upscale attempt still took time (e.g. empty wallet).
    upMs ??= sw.elapsedMilliseconds;
    final r0 = sw.elapsedMilliseconds;
    try {
      final out = await rs(bytes, target);
      return (
        bytes: out,
        outcome: UpscaleOutcome.resize,
        cost: 0.0,
        upscaleMs: upMs,
        resizeMs: sw.elapsedMilliseconds - r0,
      );
    } catch (e2) {
      debugPrint('Fallback resize failed, delivering as-is: $e2');
      return (
        bytes: bytes,
        outcome: UpscaleOutcome.none,
        cost: 0.0,
        upscaleMs: upMs,
        resizeMs: null,
      );
    }
  }
}
