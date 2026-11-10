import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/ai_config.dart';
import '../models/quality_tier.dart';
import '../models/style_preset.dart';
import 'account_service.dart';
import 'ai_call.dart';
import 'entitlements.dart';
import 'image_guard.dart';
import 'macro.dart' show macroCreditsFor, macroInputPlan;
import 'local_filters.dart';
import 'color_match.dart';
import 'mode_prompts.dart';
import 'openrouter_client.dart';
import 'premium_filters.dart';
import 'prompt_builder.dart';
import 'server_api_client.dart';
import 'zoom_ladder.dart'
    show kLadderImageLong, kLadderMainLong, kLadderMaxRefs;

enum EnhanceBackend { openRouter, server, local }

/// One AI enhance request (auto-enhance after capture, or an AI filter).
class EnhanceJob {
  const EnhanceJob({
    required this.image,
    this.context,
    this.tier = QualityTier.hd,
    this.zoom = 1.0,
    this.opticalLimit = 1.0,
    this.aiFilter,
    this.night = false,
    this.mode = 'photo',
    this.colorFilter,
    this.subject,
    this.part,
    this.macroLevel,
    this.subjectSure = false,
    this.contextBoxed = false,
    this.steps = const [],
    this.zoomLadder = false,
    this.zoomClean = false,
  });

  /// v11.34 high zoom (2x+ photo): the zoom clean-up prompt, final photo
  /// only (flagships, or a ladder with no matching checkpoint).
  final bool zoomClean;
  bool get isZoomClean => zoomClean && aiMode == 'photo' && !isLadder;
  bool get isZoomJob => isLadder || isZoomClean;

  /// v11.30 100x zoom ladder: [steps] are boxed lower-zoom references (sent
  /// first), [image] is the final photo (sent last). All at 768 px.
  final bool zoomLadder;

  bool get isLadder => zoomLadder && aiMode != 'macro' && steps.isNotEmpty;

  /// v11.12 Macro: boxed 2x / 3x / 4x step photos (sent before the crop).
  final List<File> steps;

  /// v11.9: [subject] is a clear label (user pick / known label) → the
  /// prompt treats it as true; else the AI identifies the subject itself.
  final bool subjectSure;

  /// v11.9: [context] is the sharp low-zoom snapshot with the zoomed region
  /// boxed in red.
  final bool contextBoxed;

  /// Exact on-screen crop (full resolution) — the image to enhance.
  final File image;

  /// Small full-frame copy, scene context only (digital-zoom shots).
  final File? context;
  final QualityTier tier;
  final double zoom;
  final double opticalLimit;
  final StylePreset? aiFilter;

  /// Pro AI night: appends kNightPrompt right after the locked prompt
  /// (same credits as a normal enhance).
  final bool night;

  /// v11 Pro AI mode add-on: photo | portrait | night | macro. The server
  /// appends its hidden (admin-editable) prompt; only the id is sent.
  final String mode;

  /// v11 premium colour filter rendered by the AI (credits = tier only).
  final PremiumFilter? colorFilter;

  /// Macro: on-device image label of the subject (e.g. "flower").
  final String? subject;

  /// v11.15 Macro: cloud-detected zoomed spot (hint line).
  final String? part;

  /// v11.1 Macro depth level id (macro | close | microscope), decided by the
  /// zoom at shutter time.
  final String? macroLevel;

  /// Effective mode id ([night] = v10 flag).
  String get aiMode => night ? 'night' : mode;

  bool get isNight => aiMode == 'night';

  /// Macro at the Microscope level (8x–10x): its prompt is sent alone.
  /// v11.11 Extreme: simple prompt, spot only, no colour match.
  bool get isExtreme =>
      aiMode == 'macro' && (macroLevel == 'extreme' || macroLevel == 'ultra');

  /// v11.30 Extreme / Ultra: text prompt from the detected spot, no photo.
  /// v11.40: no spot detected → the zoomed view (+ context photos) instead.
  /// v11.47: Microscope too, but only with a detected spot ([part]).
  bool get deepTextOnly =>
      aiMode == 'macro' && macroTextOnly(macroLevel, subject, part);

  bool get isMicroscope =>
      aiMode == 'macro' &&
      (macroLevel == 'microscope' ||
          macroLevel == 'extreme' ||
          macroLevel == 'ultra');

  /// v11.9: no colour filter at Microscope / Extreme.
  String? get colorFilterId =>
      colorFilter == null || colorFilter!.isOriginal || isMicroscope
      ? null
      : colorFilter!.id;

  EnhanceSpec get spec => EnhanceSpec(
    tier: tier,
    zoom: zoom,
    opticalLimit: opticalLimit,
    aiFilter: aiFilter != null,
    // v11.26: Macro / Close 2, Microscope / Extreme / Ultra 5 credits.
    creditsOverride: aiMode == 'macro'
        ? macroCreditsFor(macroLevel, quality: tier.id)
        : null,
  );

  /// v11.26 AI inputs for this Macro level (crop + label; Microscope adds
  /// at most 2 step photos at 768 px; crop capped at 1536 px).
  ({int maxSteps, int? cropLong, int stepLong}) get macroInputs =>
      macroInputPlan(macroLevel);

  /// Step photos actually sent with this job.
  List<File> get sentSteps => aiMode == 'macro'
      ? (deepTextOnly
            ? const <File>[]
            : steps.take(macroInputs.maxSteps).toList())
      : isLadder
      ? steps.take(kLadderMaxRefs).toList()
      : const [];

  /// Long side of the main image upload (null = default).
  int? get mainLong => aiMode == 'macro'
      ? macroInputs.cropLong
      : isLadder
      ? kLadderMainLong
      : null;

  int get stepLong => isLadder ? kLadderImageLong : macroInputs.stepLong;

  String? get stylePrompt {
    final f = aiFilter?.prompt.trim() ?? '';
    return f.isEmpty ? null : f;
  }

  /// Embedded-key TEST builds only (server builds send ids; release builds
  /// drop this branch at compile time, so the hidden prompts aren't shipped).
  String prompt({required bool hasContext}) {
    // v11.5 Macro: the level prompt explains both images (crop + boxed
    // full frame). Microscope sends ONLY its own prompt.
    if (AiConfig.kHasEmbeddedKey && aiMode == 'macro') {
      // v11.12: the level prompt alone (step photos first, crop last).
      final mp = macroPrompt(
        subject,
        level: macroLevel ?? 'macro',
        zoom: zoom,
        part: part,
      );
      final cf = colorFilterId;
      final cp = cf == null ? null : kColorFilterPrompts[cf];
      // v11.40: wider context photos line (not Microscope: its own prompt).
      final ctx =
          hasContext && sentSteps.isNotEmpty && macroLevel != 'microscope'
          ? ' $kMacroContextLine'
          : '';
      return cp == null ? '$mp$ctx' : '$mp$ctx $cp';
    }
    if (AiConfig.kHasEmbeddedKey &&
        (isZoomClean || (isLadder && !hasContext))) {
      // v11.34: the zoom clean-up prompt alone (+ chosen look).
      final cf = colorFilterId;
      final cp = cf == null ? null : kColorFilterPrompts[cf];
      final st = stylePrompt;
      return [
        kZoomCleanPrompt,
        if (st != null) 'Style: $st',
        if (cp != null) 'Color look: $cp $kColorFilterTail',
      ].join(' ');
    }
    if (AiConfig.kHasEmbeddedKey && isLadder && hasContext) {
      // v11.30: the ladder prompt (+ chosen look), nothing else.
      final cf = colorFilterId;
      final cp = cf == null ? null : kColorFilterPrompts[cf];
      final st = stylePrompt;
      return [
        kZoomLadderPrompt,
        if (st != null) 'Style: $st',
        if (cp != null) 'Color look: $cp $kColorFilterTail',
      ].join(' ');
    }
    String? modePrompt;
    String? colorPrompt;
    if (AiConfig.kHasEmbeddedKey) {
      modePrompt = switch (aiMode) {
        'portrait' => kPortraitPrompt,
        'macro' => macroPrompt(
          subject,
          level: macroLevel ?? 'macro',
          part: part,
        ),
        'night' => kNightPrompt,
        _ => null,
      };
      final cf = colorFilterId;
      colorPrompt = cf == null ? null : kColorFilterPrompts[cf];
    }
    return buildEnhancePrompt(
      hasContextImage: hasContext,
      zoom: zoom,
      opticalLimit: opticalLimit,
      tier: tier,
      stylePrompt: stylePrompt,
      night: isNight,
      modePrompt: modePrompt,
      colorPrompt: colorPrompt,
      contextBoxed: contextBoxed,
    );
  }
}

/// v11.42: the framing check runs only when reference photos were actually
/// sent with the request (cheap-phone 100x ladder). Pure.
bool framingCheckApplies({required bool ladder, required bool contextUsed}) =>
    ladder && contextUsed;

class EnhanceResult {
  const EnhanceResult({
    this.file,
    this.backend,
    this.denied,
    this.fellBackFromAi = false,
    this.aiUnavailable = false,
    this.aiError,
    this.creditsCharged = 0,
    this.trialsUsed = const [],
    this.contextUsed = false,
    this.cancelled = false,
    this.guard,
    this.structure,
    this.rejectedFile,
  });

  /// v11.42 test builds: the AI result a check rejected (still refunded),
  /// viewable from the preview ("Rejected: framing 0.26 — tap to view").
  final File? rejectedFile;

  /// v11 Pro Night guard: [AiFailureKind.tooDark] (AI not called) or
  /// [AiFailureKind.structureChanged] (AI result rejected). Nothing charged;
  /// the photo stays as captured.
  final AiFailureKind? guard;

  /// Structure similarity of the accepted / rejected night result.
  final double? structure;

  /// User cancelled: keep the photo as taken, nothing charged.
  final bool cancelled;

  /// New image to show (null when denied → keep the photo as captured).
  final File? file;
  final EnhanceBackend? backend;

  /// Entitlement refusal (no AI call made, nothing charged).
  final DenyReason? denied;

  /// AI call failed → local filter used, nothing charged.
  final bool fellBackFromAi;

  /// No server URL and no embedded test key → local filter, nothing charged.
  final bool aiUnavailable;
  final String? aiError;
  final int creditsCharged;
  final List<StarterTrial> trialsUsed;
  final bool contextUsed;

  bool get usedAi =>
      backend == EnhanceBackend.openRouter || backend == EnhanceBackend.server;
}

/// Orchestrates gating → AI call → charge-on-success → local fallback.
///
/// Routing: Settings server URL → enhance-server (key + ledger on server);
/// else embedded TEST key → OpenRouter direct + [LocalLedger];
/// else → local filter only (no credits used).
class EnhanceService {
  EnhanceService({
    OpenRouterClient? openRouter,
    ServerApiClient? server,
    AccountService? account,
    Future<Directory> Function()? tempDir,
  }) : _openRouter = openRouter ?? OpenRouterClient(),
       _server = server ?? ServerApiClient(),
       _accountOverride = account,
       _tempDir = tempDir ?? getTemporaryDirectory;

  final OpenRouterClient _openRouter;
  final ServerApiClient _server;
  final AccountService? _accountOverride;
  final Future<Directory> Function() _tempDir;

  AccountService get _account => _accountOverride ?? AccountService.instance;

  /// [cancel] aborts the AI request; a cancelled enhance is never charged
  /// and does not fall back to a local filter.
  Future<EnhanceResult> enhance(EnhanceJob job, {AiCancelToken? cancel}) async {
    final spec = job.spec;
    final decision = await _account.precheck(spec);
    if (!decision.allowed) {
      return EnhanceResult(denied: decision.reason);
    }

    final url = await _account.serverUrl();
    if (url.isNotEmpty) {
      // Server path: the server runs both night guards itself.
      try {
        final r = await _server.enhance(
          baseUrl: url,
          deviceId: await _account.deviceId(),
          image: job.image,
          // v11.26: Macro sends no wide context photo.
          context: job.aiMode == 'macro' || job.isZoomJob ? null : job.context,
          tier: job.tier,
          zoom: job.zoom,
          opticalLimit: job.opticalLimit,
          filterId: job.aiFilter?.id,
          night: job.isNight,
          mode: job.aiMode,
          colorFilter: job.colorFilterId,
          subject: job.subject,
          part: job.aiMode == 'macro' ? job.part : null,
          macroLevel: job.aiMode == 'macro' ? job.macroLevel : null,
          subjectSure: job.subjectSure,
          contextBoxed:
              job.aiMode != 'macro' && job.contextBoxed && job.context != null,
          steps: job.sentSteps,
          zoomLadder: job.isLadder,
          zoomClean: job.isZoomClean,
          mainLong: job.mainLong,
          stepLong: job.stepLong,
          cancel: cancel,
        );
        final file = await _writeBytes(r.bytes, 'server');
        await _account.onServerResult(r.account);
        return EnhanceResult(
          file: file,
          backend: EnhanceBackend.server,
          creditsCharged: r.creditsCharged,
          trialsUsed: r.trialsUsed,
          contextUsed: r.contextUsed,
          structure: r.structure,
        );
      } on ServerApiException catch (e) {
        if (e.denyReason != null) {
          await _account.refresh();
          return EnhanceResult(denied: e.denyReason);
        }
        if (e.failureKind == AiFailureKind.tooDark ||
            e.failureKind == AiFailureKind.structureChanged) {
          return EnhanceResult(guard: e.failureKind, aiError: e.message);
        }
        return _fallback(job, e, cancel);
      } catch (e) {
        return _fallback(job, e, cancel);
      }
    }

    if (_openRouter.isConfigured) {
      // Test-key path: same Pro Night guards as the server, on device.
      Uint8List? src;
      if (job.isNight) {
        try {
          src = await job.image.readAsBytes();
          final sig = await nightSignalOf(src);
          debugPrint('Pro Night signal: $sig');
          if (sig.tooDark) {
            return const EnhanceResult(
              guard: AiFailureKind.tooDark,
              aiError: kTooDarkMessage,
            );
          }
        } catch (e) {
          debugPrint('Night signal failed: $e');
        }
      }
      final macro = job.aiMode == 'macro';
      // v11.39: Macro / Close / Microscope crop with softened colour noise.
      var sendImage = job.image;
      if (macro && !job.isExtreme && !job.deepTextOnly) {
        try {
          final soft = await softenChroma(await job.image.readAsBytes());
          sendImage = await _writeBytes(soft, 'macro_in');
        } catch (e) {
          debugPrint('Chroma clean-up skipped: $e');
        }
      }
      try {
        final r = await _openRouter.enhanceImages(
          image: sendImage,
          // Macro: boxed step photos first, then the crop (the boxed
          // shutter frame only when no step photo exists).
          context: macro || job.isZoomJob ? null : job.context,
          // v11.19 Extreme: the zoomed crop only.
          // v11.26: Macro / Close / Extreme / Ultra crop only; Microscope
          // ≤2 step photos at 768 px. Crop capped at 1536 px (not deep).
          leading: job.sentSteps,
          mainLong: job.mainLong,
          leadingLong: job.stepLong,
          // v11.30: Extreme / Ultra send no photo — spot text prompt only.
          textOnly: macro && job.deepTextOnly,
          // v11.31 zoom ladder: final photo first, reference crops after.
          leadingAfterMain: job.isLadder,
          tier: job.tier,
          promptFor: (hasContext) => job.prompt(hasContext: hasContext),
          cancel: cancel,
        );
        cancel?.throwIfCancelled();
        double? structure;
        if (job.isNight && src != null) {
          final (ok, sim) = await structureCheck(src, r.bytes);
          structure = sim;
          debugPrint('Pro Night structure: ${sim.toStringAsFixed(3)}');
          if (!ok) {
            return EnhanceResult(
              guard: AiFailureKind.structureChanged,
              aiError: kStructureChangedMessage,
              structure: sim,
              rejectedFile: await _keepRejected(r.bytes),
            );
          }
        }
        if (framingCheckApplies(
          ladder: job.isLadder,
          contextUsed: r.contextUsed,
        )) {
          // v11.31 free framing check: a result framed like a reference
          // (not the final photo) is dropped, nothing charged.
          // v11.42: ONLY when reference photos were sent (cheap-phone 100x
          // ladder) — a single-photo zoom (e.g. the moon at 83x) is never
          // refused by it.
          try {
            final (ok, sim) = await framingCheck(
              await job.image.readAsBytes(),
              r.bytes,
            );
            structure = sim;
            debugPrint('Zoom framing: ${sim.toStringAsFixed(3)}');
            if (!ok) {
              return EnhanceResult(
                guard: AiFailureKind.framingChanged,
                aiError: kFramingChangedMessage,
                structure: sim,
                rejectedFile: await _keepRejected(r.bytes),
              );
            }
          } catch (e) {
            debugPrint('Framing check skipped: $e');
          }
        }
        var bytes = r.bytes;
        if (macro &&
            job.colorFilterId == null &&
            !job.isExtreme &&
            !job.deepTextOnly) {
          // v11.5: colours follow the real source crop (server does the same).
          try {
            bytes = await matchColors(bytes, await sendImage.readAsBytes());
          } catch (e) {
            debugPrint('Macro colour match skipped: $e');
          }
        }
        final file = await _writeBytes(bytes, 'flare');
        // Charge only now that the AI result is in hand.
        await _account.commitLocal(spec);
        if (r.fellBackToSingleImage) {
          debugPrint('Enhance: context image unsupported, used crop only');
        }
        return EnhanceResult(
          file: file,
          backend: EnhanceBackend.openRouter,
          creditsCharged: decision.credits,
          trialsUsed: decision.trials,
          contextUsed: r.contextUsed,
          structure: structure,
        );
      } catch (e) {
        return _fallback(job, e, cancel);
      }
    }

    // No AI configured (release APK without server URL).
    final local = await applyLocalFilter(
      job.image,
      LocalFilter.auto,
      outDir: (await _tempDir()).path,
    );
    return EnhanceResult(
      file: local,
      backend: EnhanceBackend.local,
      aiUnavailable: true,
    );
  }

  Future<EnhanceResult> _fallback(
    EnhanceJob job,
    Object error, [
    AiCancelToken? cancel,
  ]) async {
    if ((cancel?.isCancelled ?? false) || error is AiCancelledException) {
      return const EnhanceResult(cancelled: true);
    }
    debugPrint('AI enhance failed (nothing charged): $error');
    File? local;
    try {
      local = await applyLocalFilter(
        job.image,
        LocalFilter.auto,
        outDir: (await _tempDir()).path,
      );
    } catch (_) {}
    return EnhanceResult(
      file: local,
      backend: EnhanceBackend.local,
      fellBackFromAi: true,
      aiError: '$error',
    );
  }

  /// v11.42: keep a rejected AI result on test builds only (never shown as
  /// the result; nothing charged).
  Future<File?> _keepRejected(Uint8List bytes) async {
    if (!AiConfig.hasEmbeddedApiKey) return null;
    try {
      return await _writeBytes(bytes, 'rejected');
    } catch (_) {
      return null;
    }
  }

  Future<File> _writeBytes(Uint8List bytes, String suffix) async {
    final dir = await _tempDir();
    final isPng = bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50;
    final out = File(
      p.join(
        dir.path,
        'ai_camera_${suffix}_${DateTime.now().millisecondsSinceEpoch}'
        '.${isPng ? 'png' : 'jpg'}',
      ),
    );
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }
}
