import '../services/ai_gate.dart';
import '../widgets/video_style_flow.dart';
import 'video_screen.dart';
import '../widgets/ai_gate_overlay.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/ai_config.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/capture_mode.dart';
import '../models/ai_style.dart';
import '../models/quality_tier.dart';
import '../models/style_preset.dart';
import '../services/ai_call.dart';
import '../services/account_service.dart';
import '../services/enhance_policy.dart';
import '../services/enhance_service.dart';
import '../services/vision.dart';
import '../widgets/text_sheet.dart';
import 'editor_screen.dart';
import '../services/entitlements.dart';
import '../services/night_retone.dart';
import '../services/premium_filters.dart';
import '../services/style_catalog.dart';
import '../services/zoom_range.dart';
import '../theme/app_theme.dart';
import '../widgets/ai_working_frame.dart';
import '../widgets/compare_slider.dart';
import '../services/macro.dart';
import '../widgets/pro_upgrade_sheet.dart';
import '../widgets/style_card_strip.dart';
import '../widgets/style_library_sheet.dart';
import 'look_screen.dart';
import '../widgets/credit_icon.dart';

/// v11.42 test builds: "Rejected: framing 0.26 — tap to view". Pure.
String rejectedViewLabel(AiFailureKind kind, double? score) {
  final what = kind == AiFailureKind.framingChanged ? 'framing' : 'structure';
  final sc = score == null ? '' : ' ${score.toStringAsFixed(2)}';
  return 'Rejected: $what$sc — tap to view';
}

class PreviewScreen extends StatefulWidget {
  const PreviewScreen({
    super.key,
    required this.imageFile,
    this.contextFile,
    this.captureZoom = 1.0,
    this.opticalLimit = 1.0,
    this.mode = CaptureMode.normal,
    this.tier = QualityTier.hd,
    this.night = false,
    this.nightNote,
    this.pendingLook,
    this.initialFilter = PremiumFilter.original,
    this.initialStrength = 1.0,
    this.initialAiFilter,
    this.aiMode = 'photo',
    this.subject,
    this.part,
    this.stepFiles = const [],
    this.zoomLadder = false,
    this.zoomClean = false,
    this.aiInputFile,
    this.subjectSure = false,
    this.spotSource,
    this.contextBoxed = false,
    this.macroLevel,
    this.enhanceService,
    this.source,
    this.captureNote,
  });

  /// Where the photo came from (v10 enhance rules). Defaults from [mode]:
  /// PRO AI capture vs Normal capture. Gallery picks pass
  /// [PhotoSource.gallery] (no enhance — creative Styles / describe only).
  final PhotoSource? source;

  /// Free on-device mode note, e.g. "HDR · 3 frames merged" or
  /// "Portrait · background blur".
  final String? captureNote;

  /// Exact on-screen region at full resolution (what gets enhanced / saved).
  final File imageFile;

  /// Small full-frame copy for AI scene context (digital-zoom shots only).
  final File? contextFile;

  /// Effective zoom the shot was captured at (camera × digital). Gallery = 1.
  final double captureZoom;

  /// Device optical-quality limit at capture time (free AI up to here).
  final double opticalLimit;

  /// Normal = show as captured (no AI); Pro = auto AI enhance (gated by
  /// Pro / credits / starter trials).
  final CaptureMode mode;
  final QualityTier tier;

  /// Night mode shot: Pro AI enhance adds the night prompt.
  final bool night;

  /// e.g. "Night · 3 frames merged" (free part, shown in the status line).
  final String? nightNote;

  /// Style chosen from the camera quick menu before "Take photo": the look
  /// sheet opens automatically once the photo is ready.
  final PendingLook? pendingLook;

  /// Premium colour filter picked on the camera. NORMAL → applied on
  /// device (free, final). PRO AI → rendered by the AI (hidden per-filter
  /// prompt, tier credits on success only).
  final PremiumFilter initialFilter;
  final double initialStrength;

  /// v11 Pro AI mode add-on: photo | portrait | macro (night = [night]).
  final String aiMode;

  /// Macro subject label (on-device image labeling).
  final String? subject;

  /// v11.15 cloud-detected zoomed spot.
  final String? part;

  /// v11.12 Macro: boxed 2x / 3x / 4x step photos (sent before the crop).
  final List<File> stepFiles;

  /// v11.30 100x zoom ladder: [stepFiles] are boxed lower-zoom references.
  final bool zoomLadder;
  final bool zoomClean;

  /// v11.13 Extreme: tighter spot sent instead of the crop.
  final File? aiInputFile;

  /// v11.9: clear subject label (prompt treats it as true).
  final bool subjectSure;

  /// v11.29 where the sent spot ([part]) came from: check / step / fallback.
  final String? spotSource;

  /// v11.9: [contextFile] is the boxed low-zoom snapshot.
  final bool contextBoxed;

  /// v11.1 Macro depth level (from the zoom at shutter time).
  final MacroLevel? macroLevel;

  /// AI filter pre-selected on the camera screen (Pro · AI mode only).
  final StylePreset? initialAiFilter;

  /// Tests can inject a fake.
  final EnhanceService? enhanceService;

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late final EnhanceService _enhance =
      widget.enhanceService ?? EnhanceService();

  /// Original capture / gallery pick — AI filters re-run from this.
  late final File _original;
  late File _current;

  /// Latest AI result; free local filters apply on top of it.
  File? _aiBase;

  bool _busy = false;
  bool _initialEnhanceDone = false;
  String _overlayLabel = 'Enhancing';

  /// Lighter shimmer (no vignette) for non-AI work like saving.
  bool _overlayLight = false;
  String? _status;
  bool _showFilters = false;
  PremiumFilter _filter = PremiumFilter.original;
  double _strength = 1.0;

  /// Before/after compare (original vs current).
  bool _compare = false;

  /// A paid Macro AI result is on screen ("Try again · 🪙N" offered).
  bool _macroDone = false;

  /// v11 Pro Night guard hit on the last AI run (AI result not used).
  AiFailureKind? _guard;

  /// v11.42 test builds: the rejected AI result (tap to view; refunded).
  File? _rejected;
  bool _viewRejected = false;
  double? _guardScore;
  EnhanceJob? _guardJob;

  /// Starter trials used on this screen → small Pro upsell chip.
  final Set<StarterTrial> _trialsUsed = {};

  PhotoSource get _source =>
      widget.source ??
      (widget.mode == CaptureMode.pro
          ? PhotoSource.proCapture
          : PhotoSource.normalCapture);

  late final PreviewActions _actions = previewActionsFor(_source);

  String? get _freeNote {
    final parts = [?widget.nightNote, ?widget.captureNote];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  void initState() {
    super.initState();
    _original = widget.imageFile;
    _current = widget.imageFile;
    _strength = widget.initialStrength.clamp(0.0, 1.0);
    if (!_actions.autoEnhance) {
      // Normal capture / gallery: no enhance (v10: enhance only at capture
      // time in PRO AI). Creative Styles / describe still available.
      _initialEnhanceDone = true;
      final note = _freeNote;
      _status = _source == PhotoSource.gallery
          ? 'Gallery photo · free edits, or AI Styles / Custom prompt'
          : (note != null
                ? '$note · no AI'
                : 'Normal · photo as captured (filters are free)');
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (!widget.initialFilter.isOriginal) {
          await _applyLocal(widget.initialFilter);
        }
        _openPendingLook();
      });
      return;
    }
    // Pro (AI) mode: capture → preview → auto enhance immediately, then the
    // pre-selected normal filter (if any) on top.
    unawaited(_autoEnhanceThenFilter());
  }

  /// v11.52 before-AI window (null = no window open).
  Completer<AiGateChoice>? _gate;
  bool _gateAsk = false;
  String _gateLabel = '';

  /// 3-second Cancel window (or Cross / Tick) before any AI is sent.
  Future<bool> _confirmBeforeAi(String label) async {
    if (!AiGate.enabled) return true;
    final ask = await AiGate.askBeforeEnhancing();
    if (!mounted) return false;
    final c = Completer<AiGateChoice>();
    setState(() {
      _gate = c;
      _gateAsk = ask;
      _gateLabel = label;
    });
    final choice = await c.future;
    if (!mounted) return false;
    setState(() => _gate = null);
    return choice == AiGateChoice.start;
  }

  /// Cancelled in the window: no AI call, no credits; keep + save the
  /// original like a normal (non-AI) shot.
  Future<void> _cancelledBeforeAi() async {
    const note = 'Cancelled, saved original · no AI, no credits';
    setState(() {
      _initialEnhanceDone = true;
      _status = note;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Cancelled, saved original')));
    await _save();
    if (mounted) setState(() => _status = note);
  }

  Future<void> _autoEnhanceThenFilter() async {
    final ai = widget.initialAiFilter;
    final go = await _confirmBeforeAi(
      aiGateLabel(
        zoom: widget.captureZoom,
        night: widget.night,
        aiMode: widget.aiMode,
        macroLabel: widget.macroLevel?.label,
        filterLabel: ai?.label,
      ),
    );
    if (!mounted) return;
    if (!go) {
      await _cancelledBeforeAi();
      return;
    }
    if (ai != null) {
      await _runAi(
        _job(aiFilter: ai),
        label: 'AI · ${ai.label}',
        upsellOnDeny: false,
      );
    } else {
      await _autoEnhance();
    }
    // AI didn't render the colour filter (no server/key, failure) → the
    // free on-device version so the chosen look is still there.
    if (mounted &&
        !widget.initialFilter.isOriginal &&
        _guard == null &&
        _aiBase == null) {
      await _applyLocal(widget.initialFilter);
    }
    _openPendingLook();
  }

  bool _pendingOpened = false;

  void _openPendingLook() {
    final pl = widget.pendingLook;
    if (pl == null || _pendingOpened || !mounted) return;
    _pendingOpened = true;
    unawaited(
      _openLook(style: pl.style, initialPrompt: pl.customPrompt, tier: pl.tier),
    );
  }

  /// Styles strip / library → look sheet (sample + this photo) → result.
  Future<void> _openLook({
    AiStyle? style,
    String? initialPrompt,
    QualityTier? tier,
  }) => startLook(
    context,
    photo: _current,
    style: style,
    tier: tier ?? widget.tier,
    initialPrompt: initialPrompt,
  );

  Future<void> _openLibrary() async {
    final pick = await showStyleLibrarySheet(context);
    if (pick == null || !mounted) return;
    if (pick.custom) {
      // v11.56: Custom window (AI Photo | AI Video) with this photo.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VideoScreen(
            custom: true,
            customPhotoFirst: !pick.video,
            photo: _current,
            lookPhoto: _current,
            tier: widget.tier,
          ),
        ),
      );
      return;
    }
    if (pick.video) {
      // v11.54: this photo → confirm sheet (presets) / Custom video.
      String? res;
      if (!pick.custom) {
        res = await showVideoConfirmSheet(context, style: pick.style!, photo: _current);
        if (res == null || !mounted) return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => VideoScreen(
            preset: pick.style,
            photo: _current,
            resolution: res,
            startCustom: pick.custom,
          ),
        ),
      );
      return;
    }
    await _openLook(style: pick.style);
  }

  EnhanceJob _job({StylePreset? aiFilter}) => EnhanceJob(
    image: widget.aiInputFile ?? _original,
    steps: widget.stepFiles,
    zoomLadder: widget.zoomLadder,
    zoomClean: widget.zoomClean,
    context: widget.contextFile,
    tier: widget.tier,
    zoom: widget.captureZoom,
    opticalLimit: widget.opticalLimit,
    aiFilter: aiFilter,
    night: widget.night,
    mode: widget.aiMode,
    subject: widget.subject,
    part: widget.part,
    subjectSure: widget.subjectSure,
    contextBoxed: widget.contextBoxed,
    macroLevel: widget.macroLevel?.id,
    // v11.9: colour filters are off at Microscope / Extreme.
    colorFilter:
        aiFilter == null &&
            !widget.initialFilter.isOriginal &&
            !(widget.macroLevel?.isMicroscopic ?? false)
        ? widget.initialFilter
        : null,
  );

  String get _modeLabel {
    if (widget.night) return 'Night';
    return switch (widget.aiMode) {
      'portrait' => 'Portrait',
      'macro' => (widget.macroLevel ?? MacroLevel.macro).label,
      _ => '',
    };
  }

  Future<void> _autoEnhance() async {
    final m = _modeLabel;
    final f = widget.initialFilter;
    final label = m.isNotEmpty
        ? 'AI · $m'
        : (f.isOriginal ? 'AI · Enhancing' : 'AI · ${f.label}');
    // v11.29 Macro: the frames are done; the user may move.
    await _runAi(
      _job(),
      label: _isMacro ? kProcessingMoveNow : label,
      upsellOnDeny: false,
    );
  }

  bool get _isMacro => widget.aiMode == 'macro' && !widget.night;

  bool get _isMicroscope =>
      _isMacro && (widget.macroLevel?.isMicroscopic ?? false);

  /// v11.1 Macro "Try again · 🪙N": a normal paid run (full tier credits).
  /// Only technical failures are free; there is no refund check in Macro.
  Future<void> _retryMacro() async {
    final m = _modeLabel;
    await _runAi(_job(), label: 'AI · $m', upsellOnDeny: true);
  }

  /// Retry after a structure-guard rejection (nothing was charged).
  Future<void> _retryGuard() async {
    final j = _guardJob;
    if (j == null) return;
    await _runAi(
      j,
      label: j.isNight ? 'AI · Night' : 'AI · Enhancing',
      upsellOnDeny: false,
    );
  }

  /// "Normal Night" after a too-dark Pro Night shot: bright on-device
  /// night tone, free, no AI.
  Future<void> _useNormalNight() async {
    setState(() {
      _busy = true;
      _overlayLabel = 'Night';
      _overlayLight = true;
    });
    try {
      final out = await retoneNightBright(
        _original,
        outDir: (await getTemporaryDirectory()).path,
      );
      if (!mounted) return;
      setState(() {
        _current = out;
        _aiBase = out;
        _guard = null;
        _rejected = null;
        _viewRejected = false;
        _guardJob = null;
        _filter = PremiumFilter.original;
        _status = 'Normal Night · on-device · free';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Night tone failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runAiFilter(StylePreset f) async {
    await _runAi(
      _job(aiFilter: f),
      label: 'AI · ${f.label}',
      upsellOnDeny: true,
    );
  }

  AiCancelToken? _aiCancel;
  int _aiRunId = 0;

  /// Cancel button on the wave overlay: keep the photo as taken, no charge.
  void _cancelAi() {
    _aiCancel?.cancel();
    _aiRunId++;
    setState(() {
      _busy = false;
      _initialEnhanceDone = true;
      _status = 'AI cancelled — no credits used. Photo kept as taken.';
    });
  }

  @override
  void dispose() {
    _aiCancel?.cancel();
    super.dispose();
  }

  Future<void> _runAi(
    EnhanceJob job, {
    required String label,
    required bool upsellOnDeny,
  }) async {
    _aiCancel?.cancel();
    final token = _aiCancel = AiCancelToken();
    final id = ++_aiRunId;
    setState(() {
      _busy = true;
      _overlayLabel = label;
      _overlayLight = false;
      _status = null;
      _showFilters = false;
      _compare = false;
      _macroDone = false;
      _guard = null;
      _rejected = null;
      _viewRejected = false;
      _guardJob = null;
    });
    try {
      final r = await _enhance.enhance(job, cancel: token);
      if (!mounted || id != _aiRunId) return;
      if (r.cancelled) return;
      _handleResult(r, job, upsellOnDeny: upsellOnDeny);
    } catch (e) {
      if (!mounted || id != _aiRunId) return;
      setState(() {
        _initialEnhanceDone = true;
        _status = 'Enhance failed — no credits used';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Enhance failed: $e')));
    } finally {
      if (mounted && id == _aiRunId) setState(() => _busy = false);
    }
  }

  void _handleResult(
    EnhanceResult r,
    EnhanceJob job, {
    required bool upsellOnDeny,
  }) {
    final guard = r.guard;
    if (guard != null) {
      // Pro Night guard: AI result not used, nothing charged, photo kept.
      setState(() {
        _initialEnhanceDone = true;
        _guard = guard;
        _guardJob = job;
        _current = _original;
        _rejected = AiConfig.hasEmbeddedApiKey ? r.rejectedFile : null;
        _guardScore = r.structure;
        _viewRejected = false;
        _aiBase = null;
        _status = aiFailureMessage(guard);
        // v11.31 key builds: framing similarity in the debug line.
        if (AiConfig.hasEmbeddedApiKey &&
            guard == AiFailureKind.framingChanged &&
            r.structure != null) {
          _status = '$_status · framing ${r.structure!.toStringAsFixed(2)}';
        }
      });
      return;
    }
    final denied = r.denied;
    if (denied != null) {
      setState(() {
        _initialEnhanceDone = true;
        _status = denyMessage(denied);
      });
      if (upsellOnDeny) {
        unawaited(showProUpgradeSheet(context, reason: denyMessage(denied)));
      } else {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(denyMessage(denied)),
              action: SnackBarAction(
                label: 'Pro ₹99',
                onPressed: () => showProUpgradeSheet(context),
              ),
            ),
          );
      }
      return;
    }
    setState(() {
      _initialEnhanceDone = true;
      if (r.file != null) {
        _current = r.file!;
        _filter = PremiumFilter.original;
      }
      if (r.usedAi) {
        _aiBase = r.file;
        _macroDone = _isMacro;
        if (_isMacro) _compare = true;
        _trialsUsed.addAll(r.trialsUsed);
        final cost = r.trialsUsed.isNotEmpty
            ? 'Starter trial · free'
            : '${r.creditsCharged} credit${r.creditsCharged == 1 ? '' : 's'}';
        final ctx = r.contextUsed ? ' · scene context' : '';
        final m = _modeLabel;
        final mode = m.isEmpty
            ? ''
            : job.aiMode == 'macro'
            // v11.29: the spot actually sent, not the main subject.
            ? ' · ${widget.macroLevel == null ? m : macroLevelName(widget.macroLevel!)}${(widget.macroLevel?.isMicroscopic ?? false) ? macroDetectNote(widget.macroLevel, job.part) : macroSpotSuffix(job.part)}'
            : ' · $m';
        final cf = job.colorFilter;
        final look = cf == null || cf.isOriginal ? '' : ' · ${cf.label}';
        final free = widget.captureNote == null
            ? ''
            : ' · ${widget.captureNote}';
        final fr =
            AiConfig.hasEmbeddedApiKey && job.isLadder && r.structure != null
            ? ' · framing ${r.structure!.toStringAsFixed(2)}'
            : '';
        _status =
            'AI Enhanced$mode$look$free · ${job.tier.label} · $cost$ctx$fr';
      } else if (r.aiUnavailable) {
        _status = 'Local enhance · add a server URL in Settings for AI';
      } else if (r.fellBackFromAi) {
        _status = 'AI did not run — no credits used (local filter applied)';
      }
    });
    if (r.fellBackFromAi) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'AI enhance failed — local filter used, no credits. '
            '${r.aiError ?? ''}',
          ),
        ),
      );
    }
  }

  /// Free on-device premium filter (LUT/matrix, skin-aware) at [_strength]
  /// on top of the AI result (or the original).
  Future<void> _applyLocal(PremiumFilter f, {double? strength}) async {
    final base = _aiBase ?? _original;
    final st = strength ?? _strength;
    if (f.isOriginal || st <= 0.001) {
      setState(() {
        _current = base;
        _filter = f;
      });
      return;
    }
    setState(() {
      _busy = true;
      _overlayLabel = f.label;
      _overlayLight = true;
    });
    try {
      final out = await applyPremiumFilter(
        base,
        f,
        strength: st,
        outDir: (await getTemporaryDirectory()).path,
      );
      if (!mounted) return;
      setState(() {
        _current = out;
        _filter = f;
        _strength = st;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Filter failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Free editor (crop / rotate / adjust). Local filters re-apply on top.
  Future<void> _openEditor() async {
    final out = await Navigator.of(context).push<File>(
      MaterialPageRoute(builder: (_) => EditorScreen(file: _current)),
    );
    if (out == null || !mounted) return;
    setState(() {
      _current = out;
      _aiBase = out;
      _filter = PremiumFilter.original;
      _status = 'Edited · free';
    });
  }

  /// On-device text recognition → sheet with "Copy text".
  Future<void> _copyText() async {
    setState(() {
      _busy = true;
      _overlayLabel = 'Reading text';
      _overlayLight = true;
    });
    String? text;
    try {
      text = await StillVision.readText(_current.path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final t = text?.trim() ?? '';
    if (t.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No text found in this photo')),
      );
      return;
    }
    await showTextSheet(context, t);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _overlayLabel = 'Saving';
      _overlayLight = true;
    });
    try {
      final hasAccess = await Gal.hasAccess(toAlbum: true);
      if (!hasAccess) {
        final granted = await Gal.requestAccess(toAlbum: true);
        if (!granted) {
          await _saveToAppFiles();
          return;
        }
      }
      await Gal.putImage(_current.path, album: 'AI Camera');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to gallery · AI Camera album')),
      );
    } catch (e) {
      try {
        await _saveToAppFiles();
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToAppFiles() async {
    final docs = await getApplicationDocumentsDirectory();
    final ext = p.extension(_current.path).isEmpty
        ? '.jpg'
        : p.extension(_current.path);
    final dest = File(
      p.join(
        docs.path,
        'AICamera_${DateTime.now().millisecondsSinceEpoch}$ext',
      ),
    );
    await _current.copy(dest.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved to app files:\n${dest.path}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = (!_initialEnhanceDone && _busy) ? 'Enhancing' : 'Preview';
    final zoomTag = widget.captureZoom > 1.01
        ? ' · ${formatZoom(widget.captureZoom)}x'
        : '';

    final gate = _gate;
    return Scaffold(
      body: Stack(
        children: [
          _body(zoomTag, title),
          if (gate != null)
            Positioned.fill(
              child: AiGateOverlay(
                photo: _original,
                label: _gateLabel,
                ask: _gateAsk,
                duration: AiGate.duration,
                onChoice: (c) {
                  if (!gate.isCompleted) gate.complete(c);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(String zoomTag, String title) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
            child: Row(
              children: [
                IconButton(
                  // v11.27: X = fresh Macro start on the camera.
                  onPressed: _busy
                      ? null
                      : () => Navigator.pop(context, kPreviewClosed),
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    '$title$zoomTag',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('compare_toggle'),
                  tooltip: 'Before / after',
                  onPressed: _busy || _current.path == _original.path
                      ? null
                      : () => setState(() => _compare = !_compare),
                  icon: Icon(
                    Icons.compare_rounded,
                    color: _compare ? AppColors.proGold : null,
                  ),
                ),
                IconButton(
                  key: const ValueKey('copy_text'),
                  tooltip: 'Copy text',
                  onPressed: _busy ? null : _copyText,
                  icon: const Icon(Icons.text_snippet_outlined),
                ),
                const LiveCreditsPill(),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: AiWorkingFrame(
                active: _busy,
                light: _overlayLight,
                label: _overlayLabel,
                showElapsed: !_overlayLight,
                onCancel: _overlayLight ? null : _cancelAi,
                // Cross-fade original → enhanced result when it lands.
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 420),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, if (current != null) current],
                  ),
                  child: _compare && _current.path != _original.path
                      ? CompareSlider(
                          key: const ValueKey('compare_slider'),
                          before: _original,
                          after: _current,
                        )
                      : Image.file(
                          _current,
                          fit: BoxFit.contain,
                          key: ValueKey(_current.path),
                          gaplessPlayback: true,
                        ),
                ),
              ),
            ),
          ),
          if (_status != null && !_busy)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: CreditText(
                _status!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          if (_macroDone && widget.macroLevel != null && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                macroLevelSentLabel(
                  widget.macroLevel!,
                  spot: widget.part,
                  source: widget.spotSource,
                ),
                key: const ValueKey('macro_level_sent'),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          if (_macroDone && _isMicroscope && !_busy)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                kAiImaginedLabel,
                key: ValueKey('ai_imagined_label'),
                style: TextStyle(color: AppColors.proGold, fontSize: 12),
              ),
            ),
          if (_macroDone && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                key: const ValueKey('macro_try_again'),
                onPressed: _retryMacro,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: CreditText(
                  macroRetryLabel(
                    macroRetryCredits(
                      widget.macroLevel,
                      widget.tier.credits,
                      quality: widget.tier.id,
                    ),
                  ),
                ),
              ),
            ),
          if (_guard != null && !_busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                key: const ValueKey('guard_actions'),
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  if (_guard == AiFailureKind.tooDark) ...[
                    FilledButton.tonal(
                      key: const ValueKey('guard_normal_night'),
                      onPressed: _useNormalNight,
                      child: const Text('Normal Night'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('guard_flash_on'),
                      onPressed: () => Navigator.pop(context, 'flash_on'),
                      child: const Text('Flash on'),
                    ),
                  ] else ...[
                    if (_rejected != null)
                      TextButton(
                        key: const ValueKey('guard_view_rejected'),
                        onPressed: () => setState(() {
                          _viewRejected = !_viewRejected;
                          _current = _viewRejected ? _rejected! : _original;
                        }),
                        child: Text(
                          _viewRejected
                              ? 'Showing rejected result — tap for original'
                              : rejectedViewLabel(_guard!, _guardScore),
                        ),
                      ),
                    FilledButton.tonal(
                      key: const ValueKey('guard_retry'),
                      onPressed: _retryGuard,
                      child: Text(
                        _guard == AiFailureKind.framingChanged
                            ? 'Try again'
                            : 'Retry',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (_actions.captureTip && !_busy)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Row(
                key: ValueKey('pro_capture_tip'),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.auto_awesome, size: 13, color: AppColors.proGold),
                  SizedBox(width: 5),
                  Text(
                    kProCaptureTip,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          if (_trialsUsed.isNotEmpty && !_busy)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: TrialUpsellChip(),
            ),
          if (_initialEnhanceDone && !_showFilters)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: _StylesStrip(
                enabled: !_busy,
                onStyle: (s) => _openLook(style: s),
                onCustom: () => _openLook(),
                onSeeAll: _openLibrary,
              ),
            ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: _FiltersPanel(
                enabled: !_busy,
                showAi: _actions.aiFilters,
                selected: _filter,
                strength: _strength,
                onLocal: (f) => _applyLocal(f),
                onStrength: (v) => setState(() => _strength = v),
                onStrengthEnd: (v) => _applyLocal(_filter, strength: v),
                onAi: _runAiFilter,
              ),
            ),
            crossFadeState: _showFilters
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 220),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _ActionButton(
                        icon: Icons.palette_outlined,
                        label: 'Filters',
                        filled: true,
                        onPressed: _busy
                            ? null
                            : () =>
                                  setState(() => _showFilters = !_showFilters),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _ActionButton(
                        key: const ValueKey('edit_photo'),
                        icon: Icons.tune_rounded,
                        label: 'Edit',
                        onPressed: _busy ? null : _openEditor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.save_alt_rounded,
                        label: 'Save',
                        onPressed: _busy ? null : _save,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.replay_rounded,
                        label: 'Retake',
                        onPressed: _busy ? null : () => Navigator.pop(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Post-capture "Styles" strip (AI looks, every style costs credits).
class _StylesStrip extends StatefulWidget {
  const _StylesStrip({
    required this.enabled,
    required this.onStyle,
    required this.onCustom,
    required this.onSeeAll,
  });

  final bool enabled;
  final ValueChanged<AiStyle> onStyle;
  final VoidCallback onCustom;
  final VoidCallback onSeeAll;

  @override
  State<_StylesStrip> createState() => _StylesStripState();
}

class _StylesStripState extends State<_StylesStrip> {
  @override
  void initState() {
    super.initState();
    unawaited(StyleCatalog.instance.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    final account = AccountService.instance;
    return ValueListenableBuilder<List<AiStyle>>(
      valueListenable: StyleCatalog.instance.styles,
      builder: (context, styles, _) => ValueListenableBuilder<CreditState?>(
        valueListenable: account.state,
        builder: (context, st, _) => StyleCardStrip(
          styles: styles,
          isPro: st?.isPro(account.now) ?? false,
          trialAvailable: st?.trialAvailable(StarterTrial.libraryStyle) ?? true,
          enabled: widget.enabled,
          onStyle: widget.onStyle,
          onCustom: widget.onCustom,
          onSeeAll: widget.onSeeAll,
        ),
      ),
    );
  }
}

/// Free local filters (everyone) + AI filters (Pro or 1 starter trial).
class _FiltersPanel extends StatelessWidget {
  const _FiltersPanel({
    required this.enabled,
    required this.showAi,
    required this.selected,
    required this.strength,
    required this.onLocal,
    required this.onStrength,
    required this.onStrengthEnd,
    required this.onAi,
  });

  final bool enabled;

  /// AI filters only on PRO AI captures (v10: no post-capture enhance).
  final bool showAi;
  final PremiumFilter selected;
  final double strength;
  final ValueChanged<PremiumFilter> onLocal;
  final ValueChanged<double> onStrength;
  final ValueChanged<double> onStrengthEnd;
  final ValueChanged<StylePreset> onAi;

  @override
  Widget build(BuildContext context) {
    final account = AccountService.instance;
    return ValueListenableBuilder<CreditState?>(
      valueListenable: account.state,
      builder: (context, s, _) {
        final pro = s?.isPro(account.now) ?? false;
        final trial = s?.trialAvailable(StarterTrial.aiFilter) ?? true;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _PanelLabel('Free filters (no AI)'),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final f in PremiumFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        key: ValueKey('local_${f.id}'),
                        label: Text(f.label),
                        selected: f == selected,
                        onSelected: enabled ? (_) => onLocal(f) : null,
                      ),
                    ),
                ],
              ),
            ),
            if (!selected.isOriginal)
              Row(
                children: [
                  Text(
                    'Strength ${(strength * 100).round()}%',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      key: const ValueKey('preview_strength'),
                      value: strength.clamp(0.0, 1.0),
                      divisions: 20,
                      onChanged: enabled ? onStrength : null,
                      onChangeEnd: enabled ? onStrengthEnd : null,
                    ),
                  ),
                ],
              ),
            if (showAi) ...[
              const SizedBox(height: 6),
              _PanelLabel(
                pro
                    ? 'AI filters'
                    : (trial
                          ? 'AI filters · 1 free trial'
                          : 'AI filters · Pro'),
              ),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final f in kStylePresets)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          key: ValueKey('ai_${f.id}'),
                          avatar: Icon(
                            pro
                                ? f.icon
                                : (trial ? Icons.card_giftcard : Icons.lock),
                            size: 16,
                            color: AppColors.proGold,
                          ),
                          label: Text(f.label),
                          onPressed: enabled ? () => onAi(f) : null,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PanelLabel extends StatelessWidget {
  const _PanelLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4, left: 2),
    child: Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );

    if (filled) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: child,
      );
    }

    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: BorderSide(
          color: AppColors.textSecondary.withValues(alpha: 0.35),
        ),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: child,
    );
  }
}
