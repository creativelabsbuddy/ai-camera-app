import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/ai_config.dart';
import '../models/ai_style.dart';
import '../models/quality_tier.dart';
import 'custom_prompt_policy.dart';
import 'enhance_policy.dart';
import 'account_service.dart';
import 'ai_call.dart';
import 'entitlements.dart';
import 'local_style_prompts.dart';
import 'openrouter_client.dart';
import 'filter_catalog.dart';
import 'prompt_builder.dart';
import 'runware_client.dart';
import 'server_api_client.dart';

/// Library styles always render at Full HD params (Flare `medium`); the cost
/// is the style's own credit cost set in the admin panel.
const QualityTier kLookStyleTier = QualityTier.fullHd;

/// Quality choices offered for a custom change. Ultra HD / 4K map to Flare
/// `high`, which roughly doubled latency and cost in v9.1 measurements
/// without a visible gain for edits, so edits offer HD (low) / Full HD
/// (medium) only.
const List<QualityTier> kLookTiers = [QualityTier.hd, QualityTier.fullHd];

/// Clamp any capture tier to a look tier (UHD / 4K → Full HD).
QualityTier lookTierFor(QualityTier t) => t.isPremium ? QualityTier.fullHd : t;

/// One AI look request: a library style OR a custom prompt. Always ONE
/// image (v11.56: the "4 variations" option was removed).
class LookJob {
  const LookJob({
    required this.image,
    this.style,
    this.customPrompt,
    this.tier = QualityTier.hd,
  }) : assert(style != null || customPrompt != null);

  /// The user's photo (original — never overwritten).
  final File image;
  final AiStyle? style;
  final String? customPrompt;

  /// Custom change only: chosen quality (cost = tier credits per image).
  final QualityTier tier;

  bool get isStyle => style != null;

  QualityTier get effectiveTier => isStyle ? kLookStyleTier : lookTierFor(tier);

  int get creditCostPerImage => style?.creditCost ?? lookTierFor(tier).credits;

  /// Person library styles: warn before spending when no face is found.
  /// Custom changes are never pre-checked (users may type anything).
  bool get needsPerson => style?.needsPerson ?? false;

  LookSpec get spec => LookSpec(
    creditCost: creditCostPerImage,
    proOnly: style?.proOnly ?? false,
    isStyle: isStyle,
  );

  String get label => style?.name ?? 'Your change';

}

enum LookBackend { server, openRouter }

class LookResult {
  const LookResult({
    this.files = const [],
    this.backend,
    this.denied,
    this.error,
    this.unavailable = false,
    this.creditsCharged = 0,
    this.trialsUsed = const [],
    this.costUsd,
    this.failure,
  });

  final List<File> files;
  final LookBackend? backend;

  /// Refused before any AI call (nothing charged).
  final DenyReason? denied;

  /// AI failed (nothing charged).
  final String? error;

  /// Why it failed (drives the status message); null on success.
  final AiFailureKind? failure;

  bool get cancelled => failure == AiFailureKind.cancelled;

  /// No server URL and no test key → styles can't run in this build.
  final bool unavailable;
  final int creditsCharged;
  final List<StarterTrial> trialsUsed;
  final double? costUsd;

  bool get ok => files.isNotEmpty;
}

/// Hidden prompt of a bundled seed style — ONLY in key-embedded TEST builds
/// (no server). The `kHasEmbeddedKey` compile-time guard lets the release
/// compiler drop [kLocalSeedStylePrompts] entirely.
String? localSeedStylePrompt(String id) {
  if (AiConfig.kHasEmbeddedKey) {
    // v11.51: camera filters (public prompts: DB list or built-in Vivid).
    return kLocalSeedStylePrompts[id] ?? FilterCatalog.instance.promptFor(id);
  }
  return null;
}

/// v11.58: the model that actually renders [style] in a key TEST build.
/// Custom changes and unknown models use the Custom model (Flare); Runware
/// without a key falls back to Custom too.
String styleModelFor(AiStyle? style, {required bool runwareReady}) {
  if (style == null) return kStyleModelCustom;
  final m = normalizeStyleModel(style.model);
  if (m == kStyleModelRunware && !runwareReady) return kStyleModelCustom;
  return m;
}

/// Gating → AI → charge on success (never on failure).
class LookService {
  LookService({
    ServerApiClient? server,
    OpenRouterClient? openRouter,
    AccountService? account,
    Future<Directory> Function()? tempDir,
    String? Function(String styleId)? localPromptFor,
    RunwareClient? runware,
  }) : _server = server ?? ServerApiClient(),
       _openRouter = openRouter ?? OpenRouterClient(),
       _runware = runware ?? RunwareClient(),
       _accountOverride = account,
       _tempDir = tempDir ?? getTemporaryDirectory,
       _localPromptFor = localPromptFor ?? localSeedStylePrompt;

  final ServerApiClient _server;
  final OpenRouterClient _openRouter;
  final RunwareClient _runware;
  final AccountService? _accountOverride;
  final Future<Directory> Function() _tempDir;
  final String? Function(String styleId) _localPromptFor;

  AccountService get _account => _accountOverride ?? AccountService.instance;

  static LookResult _failed(Object e) {
    final kind = classifyAiError(e);
    debugPrint('Look failed (nothing charged, $kind): $e');
    return LookResult(error: '$e', failure: kind);
  }

  /// Gating → AI → charge on success. [cancel] aborts the request; a
  /// cancelled or failed look is never charged (even if the AI answers
  /// after the user cancelled).
  Future<LookResult> apply(LookJob job, {AiCancelToken? cancel}) async {
    final custom = job.isStyle ? null : job.customPrompt ?? '';
    if (custom != null && blockedCustomPromptReason(custom) != null) {
      return const LookResult(
        error: 'Blocked by the safety list',
        failure: AiFailureKind.blocked,
      );
    }
    // v10: "enhance / HD / sharp" only → tip, no AI call, no credits.
    if (custom != null && isEnhanceOnlyPrompt(custom)) {
      return const LookResult(
        error: 'Enhance happens at capture',
        failure: AiFailureKind.enhanceOnly,
      );
    }
    final decision = await _account.precheckLook(job.spec);
    if (!decision.allowed) return LookResult(denied: decision.reason);
    if (cancel?.isCancelled ?? false) {
      return const LookResult(
        error: 'Cancelled',
        failure: AiFailureKind.cancelled,
      );
    }

    final url = await _account.serverUrl();
    if (url.isNotEmpty) {
      try {
        final r = await _server.applyLook(
          baseUrl: url,
          deviceId: await _account.deviceId(),
          image: job.image,
          styleId: job.style?.id,
          customPrompt: job.customPrompt,
          tier: job.effectiveTier,
          cancel: cancel,
        );
        // The server only charges a request that is still connected; if
        // the user cancelled just as it finished, sync the balance anyway.
        await _account.onServerResult(r.account);
        return LookResult(
          files: await _write(r.images, 'look'),
          backend: LookBackend.server,
          creditsCharged: r.creditsCharged,
          trialsUsed: r.trialsUsed,
          costUsd: r.costUsd,
        );
      } on ServerApiException catch (e) {
        if (e.denyReason != null) {
          await _account.refresh();
          return LookResult(denied: e.denyReason);
        }
        return _failed(e.failure ?? e);
      } catch (e) {
        return _failed(e);
      }
    }

    if (_openRouter.isConfigured) {
      String? stylePrompt;
      if (job.style != null) {
        stylePrompt = _localPromptFor(job.style!.id);
        if (stylePrompt == null) {
          return const LookResult(
            error: 'This style needs the server (no local prompt)',
            failure: AiFailureKind.other,
          );
        }
      }
      final prompt = buildLookPrompt(
        stylePrompt: stylePrompt,
        customPrompt: job.isStyle ? null : job.customPrompt,
      );
      Future<({List<Uint8List> images, double cost})> custom() => _openRouter.generateLook(
        image: job.image,
        prompt: prompt,
        tier: job.effectiveTier,
        n: 1,
        cancel: cancel,
      );
      try {
        ({List<Uint8List> images, double cost})? r;
        // v11.58: per-style model; on failure fall back to Custom (Flare).
        final model = styleModelFor(job.style, runwareReady: _runware.isConfigured);
        if (model != kStyleModelCustom) {
          try {
            if (model == kStyleModelRunware) {
              final x = await _runware.generate(image: job.image, prompt: prompt, cancel: cancel);
              r = (images: [x.image], cost: x.cost);
            } else {
              r = await _openRouter.generateLook(
                image: job.image,
                prompt: prompt,
                tier: job.effectiveTier,
                n: 1,
                cancel: cancel,
                model: AiConfig.kleinModel,
              );
            }
          } on AiCancelledException {
            rethrow;
          } catch (e) {
            if (cancel?.isCancelled ?? false) rethrow;
            debugPrint('Style model $model failed ($e) — falling back to Custom');
            r = null;
          }
        }
        r ??= await custom();
        if (cancel?.isCancelled ?? false) throw const AiCancelledException();
        // One image; charged only now (success).
        final charged = await _account.commitLocalLook(job.spec);
        return LookResult(
          files: await _write(r.images.take(1).toList(), 'look'),
          backend: LookBackend.openRouter,
          creditsCharged: charged.credits,
          trialsUsed: charged.trials,
          costUsd: r.cost,
        );
      } catch (e) {
        return _failed(e);
      }
    }

    return const LookResult(unavailable: true);
  }

  Future<List<File>> _write(List<Uint8List> images, String tag) async {
    final dir = await _tempDir();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final out = <File>[];
    for (var i = 0; i < images.length; i++) {
      final b = images[i];
      final png = b.length > 4 && b[0] == 0x89 && b[1] == 0x50;
      final f = File(
        p.join(dir.path, 'ai_${tag}_${stamp}_$i.${png ? 'png' : 'jpg'}'),
      );
      await f.writeAsBytes(b, flush: true);
      out.add(f);
    }
    return out;
  }
}
