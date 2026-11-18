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

typedef TierUpscaleResult = ({Uint8List bytes, UpscaleOutcome outcome, double cost});

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
  if (target == null) return (bytes: bytes, outcome: UpscaleOutcome.none, cost: 0.0);
  final rs = resize ?? resizeToLongSide;
  final rw = runware ?? RunwareClient(timeout: AiConfig.upscaleTimeout);
  try {
    if (!rw.isConfigured) throw const AiFailure(AiFailureKind.other, 'Runware is not set up');
    final up = await rw.upscale(bytes, cancel: cancel);
    cancel?.throwIfCancelled();
    return (bytes: await rs(up.image, target), outcome: UpscaleOutcome.esrgan, cost: up.cost);
  } on AiCancelledException {
    rethrow;
  } catch (e) {
    cancel?.throwIfCancelled();
    debugPrint('Tier upscale failed (${tier.id}), resize fallback: $e');
    try {
      return (bytes: await rs(bytes, target), outcome: UpscaleOutcome.resize, cost: 0.0);
    } catch (e2) {
      debugPrint('Fallback resize failed, delivering as-is: $e2');
      return (bytes: bytes, outcome: UpscaleOutcome.none, cost: 0.0);
    }
  }
}
