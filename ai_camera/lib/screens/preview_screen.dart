import '../services/ai_gate.dart';
import '../widgets/video_style_flow.dart';
import 'video_screen.dart';
import '../widgets/ai_gate_overlay.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../config/ai_config.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/features_v1169.dart';
import '../config/features_v1170.dart';
import '../widgets/slim_style_row.dart';
import 'photo_editor_screen.dart';
import '../models/capture_mode.dart';
import '../models/photo_look.dart';
import '../services/tone.dart';
import '../services/tone_proxy.dart';
import '../widgets/tone_bar.dart';
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
import '../services/gate_detect.dart' show GateDetect;
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
    this.zoomSourceFile,
    this.zoomSourceOnly = false,
    this.clearRef = false,
    this.aiInputFile,
    this.subjectSure = false,
    this.spotSource,
    this.contextBoxed = false,
    this.macroLevel,
    this.gateDetect,
    this.enhanceService,
    this.source,
    this.captureNote,
    this.zoomLabel,
    this.photoLook,
    this.tonePreset = TonePreset.auto,
    this.toneEnabled = true,
  });

  /// v11.69 Pro Photo look (Natural = Sunburst, Studio = Flare).
  final PhotoLook? photoLook;

  /// v11.69 Tone preset picked on the camera (Normal captures).
  final TonePreset tonePreset;

  /// v11.69 free Auto Tone / presets after a Normal capture (flags too).
  final bool toneEnabled;

  /// v11.61: e.g. "Beyond clear range, AI-enhanced" — the zoom went past the
  /// real detail this phone captured; shown on the result.
  final String? zoomLabel;

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

  /// v11.59 sharp-source zoom: the aligned sharp lower-zoom crop the AI
  /// works from ([imageFile] = the final zoom, framing only).
  final File? zoomSourceFile;

  /// v11.62: send only [zoomSourceFile] (no blurry final frame).
  final bool zoomSourceOnly;

  /// v11.13 Extreme: tighter spot sent instead of the crop.
  final File? aiInputFile;

  /// v11.67 [zoomSourceFile] is the clear reference crop (the photo at the
  /// clear limit) → its prompt line is added.
  final bool clearRef;

  /// v11.67 the 5x / 10x zoom-gate detection (macro shots; empty = none
  /// reached) → simple Macro / Close / Microscope prompts.
  final GateDetect? gateDetect;

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

  /// v11.66 test builds: per-step timing line of the last AI enhance.
  String? _timing;
  bool _showFilters = false;
  PremiumFilter _filter = PremiumFilter.original;
  double _strength = 1.0;

  /// Before/after compare (original vs current).
  bool _compare = false;

  /// A paid Macro AI result is on screen ("Try again · 🪙N" offered).
  bool _macroDone = false;

  /// v11.58: a bad Microscope / Extreme / Ultra result can be refunded
  /// once (local test-key charge; same credit buckets given back).
  EnhanceDecision? _refundable;
  bool _refunding = false;

  /// v11 Pro Night guard hit on the last AI run (AI result not used).
  AiFailureKind? _guard;

  /// v11.42 test builds: the rejected AI result (tap to view; refunded).
  File? _rejected;
  bool _viewRejected = false;
  double? _guardScore;
  EnhanceJob? _guardJob;

  /// Starter trials used on this screen → small Pro upsell chip.
  final Set<StarterTrial> _trialsUsed = {};

  // ---- v11.69 free tone (Normal captures, single frame, on device) -------
  ToneProxy? _toneProxy;
  ToneParams _toneAuto = ToneParams.zero;
  bool _toneAutoOn = false;
  TonePreset _tonePreset = TonePreset.auto;
  ToneParams _toneManual = ToneParams.zero;

  /// Live preview of the current tone (small; the full-res file follows).
  ui.Image? _toneImage;
  bool _toneRendering = false;
  bool _toneDirty = false;

  /// Full-resolution toned file and the tone it was made with.
  File? _toneFile;
  String? _toneFileKey;
  Future<void>? _toneCommitting;
  String? _toneCommittingKey;
  Timer? _toneIdle;

  /// Press-and-hold on the photo → the original.
  bool _holdOriginal = false;

  /// After Edit the tone is baked in (bar hidden).
  bool _toneLocked = false;

  bool get _toneAllowed =>
      (kAutoTone || kTonePresets) &&
      widget.toneEnabled &&
      _source == PhotoSource.normalCapture &&
      !_toneLocked;

  /// Tone bar visible (photo decoded).
  bool get _toneReady => _toneAllowed && _toneProxy != null;

  ToneParams get _toneTotal => composeTone(
    auto: _toneAuto,
    autoOn: _toneAutoOn,
    preset: kTonePresets ? _tonePreset : TonePreset.auto,
    manual: _toneManual,
  );
  bool get _toneMono => kTonePresets && _tonePreset.mono;
  bool get _toneChanged =>
      toneChangesPhoto(_toneTotal, _toneMono ? TonePreset.bw : TonePreset.auto);
  String get _toneKey => '${_toneTotal.key}|$_toneMono';
  bool get _toneCanReset =>
      _toneAutoOn || _tonePreset != TonePreset.auto || !_toneManual.isNeutral;

  /// The small live preview is shown until the full-res file is ready.
  bool get _toneProxyVisible =>
      _toneReady &&
      _toneChanged &&
      _toneImage != null &&
      _toneFileKey != _toneKey &&
      _filter.isOriginal;

  String get _toneStatus {
    final parts = [
      if (_toneAutoOn) 'Auto Tone',
      if (kTonePresets && _tonePreset != TonePreset.auto) _tonePreset.label,
      if (!_toneManual.isNeutral) 'Adjusted',
    ];
    final note = _freeNote;
    final t = parts.isEmpty ? 'Original' : parts.join(' · ');
    return '${note == null ? '' : '$note · '}$t · free, no AI';
  }

  Future<void> _initTone() async {
    final px = await ToneProxy.load(_original);
    if (!mounted || px == null || !_toneAllowed) return;
    setState(() {
      _toneProxy = px;
      _toneAuto = autoToneFor(px.stats);
      _status = _toneStatus;
    });
    _onToneChanged();
  }

  void _onToneChanged() {
    if (!_toneReady) return;
    _toneIdle?.cancel();
    if (!_toneChanged) {
      final old = _toneImage;
      setState(() {
        _toneImage = null;
        if (_aiBase != null && _aiBase == _toneFile) _aiBase = null;
        if (_filter.isOriginal) _current = _aiBase ?? _original;
        _status = _toneStatus;
      });
      old?.dispose();
      if (!_filter.isOriginal) unawaited(_applyLocal(_filter));
      return;
    }
    setState(() => _status = _toneStatus);
    if (_toneFileKey == _toneKey && _toneFile != null) {
      setState(() {
        _aiBase = _toneFile;
        if (_filter.isOriginal) _current = _toneFile!;
      });
      if (!_filter.isOriginal) unawaited(_applyLocal(_filter));
      return;
    }
    unawaited(_renderToneProxy());
    // Full resolution once the user pauses (Save waits for it anyway).
    _toneIdle = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_commitTone());
    });
  }

  Future<void> _renderToneProxy() async {
    final px = _toneProxy;
    if (px == null) return;
    if (_toneRendering) {
      _toneDirty = true;
      return;
    }
    _toneRendering = true;
    try {
      do {
        _toneDirty = false;
        final t = _toneTotal;
        final mono = _toneMono;
        final im = await px.render(t, mono: mono);
        if (!mounted) {
          im.dispose();
          return;
        }
        final old = _toneImage;
        setState(() => _toneImage = im);
        old?.dispose();
      } while (_toneDirty && mounted);
    } catch (e) {
      debugPrint('Tone preview failed: $e');
    } finally {
      _toneRendering = false;
    }
  }

  /// Renders the full-resolution toned file for the current tone.
  Future<void> _commitTone() {
    if (!_toneReady || !_toneChanged) return Future.value();
    final key = _toneKey;
    if (_toneFileKey == key && _toneFile != null) return Future.value();
    if (_toneCommitting != null && _toneCommittingKey == key) {
      return _toneCommitting!;
    }
    final t = _toneTotal;
    final mono = _toneMono;
    final f = () async {
      try {
        final file = await renderToneFile(
          _original,
          t,
          mono: mono,
          outDir: (await getTemporaryDirectory()).path,
        );
        if (!mounted) return;
        if (key != _toneKey) {
          unawaited(file.delete().then((_) {}, onError: (_) {}));
          return;
        }
        final prev = _toneFile;
        setState(() {
          _toneFile = file;
          _toneFileKey = key;
          _aiBase = file;
          if (_filter.isOriginal) _current = file;
        });
        if (prev != null && prev.path != file.path) {
          unawaited(prev.delete().then((_) {}, onError: (_) {}));
        }
        if (!_filter.isOriginal) await _applyLocal(_filter);
      } finally {
        if (_toneCommittingKey == key) {
          _toneCommitting = null;
          _toneCommittingKey = null;
        }
      }
    }();
    _toneCommitting = f;
    _toneCommittingKey = key;
    return f;
  }

  /// Before Save / Edit / Styles: the full-res toned file must exist.
  Future<void> _ensureTone() async {
    if (!_toneReady || !_toneChanged || _toneFileKey == _toneKey) return;
    _toneIdle?.cancel();
    setState(() {
      _busy = true;
      _overlayLabel = 'Applying tone';
      _overlayLight = true;
    });
    try {
      for (var i = 0; i < 3 && mounted && _toneFileKey != _toneKey; i++) {
        await _commitTone();
      }
    } catch (e) {
      debugPrint('Tone render failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tone could not be applied')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setToneAuto(bool on) {
    setState(() => _toneAutoOn = on);
    _onToneChanged();
  }

  void _setTonePreset(TonePreset t) {
    setState(() => _tonePreset = t);
    _onToneChanged();
  }

  /// One tap: back to the photo exactly as captured.
  void _resetTone() {
    setState(() {
      _toneAutoOn = false;
      _tonePreset = TonePreset.auto;
      _toneManual = ToneParams.zero;
    });
    _onToneChanged();
  }

  Future<void> _openToneSliders() async {
    await showToneSliders(
      context,
      initial: _toneManual,
      onChanged: (v) {
        if (!mounted) return;
        setState(() => _toneManual = v);
        _onToneChanged();
      },
    );
  }

  /// v11.70: the tier the Pro AI enhance really uses (single tier).
  /// Macro keeps its own level tier (unchanged).
  QualityTier get _enhanceTier =>
      widget.aiMode == 'macro' ? widget.tier : enhanceTierFor(widget.tier);

  /// v11.70: the edited copy already written to the gallery by the editor
  /// (Save then doesn't add a duplicate).
  String? _savedPath;

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
      if (_toneAllowed) {
        // v11.69: Auto Tone on (not on Night merges: they have their own
        // tone mapping) + the camera's preset; rendered once decoded.
        _toneAutoOn = kAutoTone && widget.nightNote == null;
        _tonePreset = kTonePresets ? widget.tonePreset : TonePreset.auto;
        unawaited(_initTone());
      }
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
  }) async {
    await _ensureTone(); // v11.69
    if (!mounted) return;
    await startLook(
      context,
      photo: _current,
      style: style,
      tier: tier ?? widget.tier,
      initialPrompt: initialPrompt,
    );
  }

  Future<void> _openLibrary() async {
    final pick = await showStyleLibrarySheet(context);
    if (pick == null || !mounted) return;
    await _ensureTone(); // v11.69
    if (!mounted) return;
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
        res = await showVideoConfirmSheet(
          context,
          style: pick.style!,
          photo: _current,
        );
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
    zoomSource: widget.zoomSourceFile,
    zoomSourceOnly: widget.zoomSourceOnly,
    clearRef: widget.clearRef && widget.zoomSourceFile != null,
    context: widget.contextFile,
    tier: _enhanceTier, // v11.70 single tier
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
    gate: widget.aiMode == 'macro' ? widget.gateDetect : null, // v11.67
    photoLook: widget.photoLook, // v11.69
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

  /// v11.58: give back the credits of a bad Microscope result (once) and
  /// show the photo as taken again.
  Future<void> _refundBadResult() async {
    final d = _refundable;
    if (d == null || _refunding) return;
    setState(() => _refunding = true);
    try {
      await AccountService.instance.refundLocal(d);
      if (!mounted) return;
      setState(() {
        _refundable = null;
        _current = _original;
        _aiBase = null;
        _compare = false;
        _status =
            'Credits refunded ($kCreditGlyph${d.credits}). Photo kept as taken.';
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not refund. Please try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _refunding = false);
    }
  }

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
    _toneIdle?.cancel();
    _toneImage?.dispose();
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
      _timing = null;
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
      if (guard == AiFailureKind.network) {
        // v11.59: offline → the exact message, spinner already off (finally
        // in _runAi), Retry stays available; nothing was charged.
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text(kCheckInternetMessage)));
      }
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
      _timing = AiConfig.hasEmbeddedApiKey ? r.timings?.line() : null;
      if (r.file != null) {
        _current = r.file!;
        _filter = PremiumFilter.original;
      }
      if (r.usedAi) {
        _aiBase = r.file;
        _macroDone = _isMacro;
        final lc = r.localCharge;
        _refundable = _isMicroscope && lc != null && lc.credits > 0 ? lc : null;
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
            'AI Enhanced$mode$look$free${kSingleEnhanceTier ? '' : ' · ${job.tier.label}'} · $cost$ctx$fr';
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
    await _ensureTone(); // v11.69
    if (!mounted) return;
    if (kEditorV1170) {
      // v11.70: Crop · Adjust · Retouch · Skin Tone; saves a new copy.
      final ed = await Navigator.of(context).push<EditedPhoto>(
        MaterialPageRoute(builder: (_) => PhotoEditorScreen(file: _current)),
      );
      if (ed == null || !mounted) return;
      _toneIdle?.cancel();
      setState(() {
        _current = ed.file;
        _aiBase = ed.file;
        _filter = PremiumFilter.original;
        _compare = false;
        _savedPath = ed.savedToGallery ? ed.file.path : null;
        _status = ed.savedToGallery
            ? 'Edited copy saved · original kept · free'
            : 'Edited · free · tap Save to keep it';
        _toneLocked = true;
      });
      return;
    }
    final out = await Navigator.of(context).push<File>(
      MaterialPageRoute(builder: (_) => EditorScreen(file: _current)),
    );
    if (out == null || !mounted) return;
    _toneIdle?.cancel();
    setState(() {
      _current = out;
      _aiBase = out;
      _filter = PremiumFilter.original;
      _status = 'Edited · free';
      _toneLocked = true; // v11.69: the tone is baked into the edit
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
    await _ensureTone(); // v11.69
    if (!mounted) return;
    if (_savedPath != null && _savedPath == _current.path) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Already saved to gallery')));
      return;
    }
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
      _savedPath = _current.path;
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

  /// v11.69: press and hold the photo → the original as captured; release →
  /// back to the toned photo. Only after a Normal capture with a tone on.
  Widget _holdToCompare(Widget child) {
    if (!_toneReady) return child;
    final can = !_busy && (_toneChanged || _current.path != _original.path);
    return GestureDetector(
      key: const ValueKey('hold_to_compare'),
      behavior: HitTestBehavior.opaque,
      onLongPressStart: can
          ? (_) => setState(() => _holdOriginal = true)
          : null,
      onLongPressEnd: (_) => setState(() => _holdOriginal = false),
      onLongPressCancel: () => setState(() => _holdOriginal = false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (_holdOriginal) ...[
            ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Image.file(
                _original,
                key: const ValueKey('hold_original'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
              ),
            ),
            const Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: Center(child: _OriginalTag()),
            ),
          ],
        ],
      ),
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
          kPreviewV1170 ? _bodyV1170(zoomTag, title) : _body(zoomTag, title),
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

  /// Macro / guard / refund / tip / trial widgets under the photo (both
  /// layouts).
  List<Widget> _resultExtras() => [
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
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
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
    if (_macroDone && _refundable != null && !_busy)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextButton.icon(
          key: const ValueKey('micro_refund'),
          onPressed: _refunding ? null : _refundBadResult,
          icon: const Icon(Icons.undo_rounded, size: 18),
          label: CreditText(
            'Bad result? Refund $kCreditGlyph${_refundable!.credits}',
          ),
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
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
    if (_trialsUsed.isNotEmpty && !_busy)
      const Padding(padding: EdgeInsets.only(top: 6), child: TrialUpsellChip()),
  ];

  // ---- v11.70 layout ---------------------------------------------------------

  Widget _photoView({required bool zoomable}) {
    final Widget photo = AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: _compare && _current.path != _original.path
          ? CompareSlider(
              key: const ValueKey('compare_slider'),
              before: _original,
              after: _current,
            )
          : _toneProxyVisible
          ? RawImage(
              key: const ValueKey('tone_proxy'),
              image: _toneImage,
              fit: BoxFit.contain,
            )
          : Image.file(
              _current,
              fit: BoxFit.contain,
              key: ValueKey(_current.path),
              gaplessPlayback: true,
            ),
    );
    if (!zoomable || _compare) return photo;
    return InteractiveViewer(
      key: const ValueKey('preview_pinch_zoom'),
      maxScale: 6,
      child: GestureDetector(
        key: const ValueKey('preview_photo_tap'),
        behavior: HitTestBehavior.opaque,
        onTap: _busy ? null : _openFullscreen,
        child: photo,
      ),
    );
  }

  /// Tap the photo → fullscreen, pinch to zoom.
  Future<void> _openFullscreen() async {
    await _ensureTone();
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => FullscreenPhoto(file: _current),
        transitionsBuilder: (_, a, _, child) =>
            FadeTransition(opacity: a, child: child),
      ),
    );
  }

  Widget _bodyV1170(String zoomTag, String title) {
    final status = (_status != null && !_busy) ? _status : null;
    final timing = (_timing != null && !_busy && AiConfig.hasEmbeddedApiKey)
        ? _timing
        : null;
    final account = AccountService.instance;
    return SafeArea(
      child: Column(
        children: [
          SizedBox(
            height: 46,
            child: Row(
              children: [
                IconButton(
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
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('compare_toggle'),
                  tooltip: 'Before / after',
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      _busy ||
                          (_current.path == _original.path &&
                              !_toneProxyVisible)
                      ? null
                      : () async {
                          await _ensureTone(); // v11.69
                          if (mounted) setState(() => _compare = !_compare);
                        },
                  icon: Icon(
                    Icons.compare_rounded,
                    color: _compare ? AppColors.proGold : null,
                  ),
                ),
                IconButton(
                  key: const ValueKey('copy_text'),
                  tooltip: 'Copy text',
                  visualDensity: VisualDensity.compact,
                  onPressed: _busy ? null : _copyText,
                  icon: const Icon(Icons.text_snippet_outlined),
                ),
                const LiveCreditsPill(),
                const SizedBox(width: 8),
              ],
            ),
          ),
          // Big, edge to edge.
          Expanded(
            child: AiWorkingFrame(
              active: _busy,
              light: _overlayLight,
              label: _overlayLabel,
              showElapsed: !_overlayLight,
              onCancel: _overlayLight ? null : _cancelAi,
              note: kAiBlurNote,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black,
                    child: _holdToCompare(_photoView(zoomable: true)),
                  ),
                  if (widget.zoomLabel case final zl?)
                    Positioned(
                      top: 8,
                      left: 12,
                      right: 12,
                      child: Center(
                        child: _OverlayPill(
                          key: const ValueKey('zoom_clear_label'),
                          icon: Icons.auto_awesome_rounded,
                          text: zl,
                          gold: true,
                        ),
                      ),
                    ),
                  if (!_busy)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _RoundIcon(
                        key: const ValueKey('preview_fullscreen'),
                        icon: Icons.fullscreen_rounded,
                        onTap: _openFullscreen,
                      ),
                    ),
                  if (status != null || timing != null)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            key: const ValueKey('preview_info_overlay'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (status != null)
                                  CreditText(
                                    status,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                    ),
                                  ),
                                if (timing != null)
                                  Text(
                                    timing,
                                    key: const ValueKey('ai_timing_line'),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 10,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          ..._resultExtras(),
          if (_toneReady)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ToneBar(
                autoOn: _toneAutoOn,
                preset: _tonePreset,
                enabled: !_busy,
                canReset: _toneCanReset,
                showAuto: kAutoTone,
                showPresets: kTonePresets,
                onAuto: _setToneAuto,
                onPreset: _setTonePreset,
                onAdjust: _openToneSliders,
                onReset: _resetTone,
              ),
            ),
          if (_initialEnhanceDone)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ValueListenableBuilder<CreditState?>(
                valueListenable: account.state,
                builder: (context, st, _) {
                  final pro = st?.isPro(account.now) ?? false;
                  final trial =
                      st?.trialAvailable(StarterTrial.aiFilter) ?? true;
                  return _SlimStyles(
                    enabled: !_busy,
                    isPro: pro,
                    aiFilters: _actions.aiFilters ? kStylePresets : const [],
                    aiFilterCost: _enhanceTier.credits,
                    aiFilterLocked: !pro && !trial,
                    aiFilterTrial: !pro && trial,
                    onAiFilter: _runAiFilter,
                    onStyle: (s) => _openLook(style: s),
                    onCustom: () => _openLook(),
                    onSeeAll: _openLibrary,
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    key: const ValueKey('edit_photo'),
                    icon: Icons.tune_rounded,
                    label: 'Edit',
                    compact: true,
                    onPressed: _busy ? null : _openEditor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionButton(
                    key: const ValueKey('preview_save'),
                    icon: Icons.save_alt_rounded,
                    label: 'Save',
                    filled: true,
                    compact: true,
                    onPressed: _busy ? null : _save,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionButton(
                    key: const ValueKey('preview_retake'),
                    icon: Icons.replay_rounded,
                    label: 'Retake',
                    compact: true,
                    onPressed: _busy ? null : () => Navigator.pop(context),
                  ),
                ),
              ],
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
                  onPressed:
                      _busy ||
                          (_current.path == _original.path &&
                              !_toneProxyVisible)
                      ? null
                      : () async {
                          await _ensureTone(); // v11.69
                          if (mounted) setState(() => _compare = !_compare);
                        },
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
          if (widget.zoomLabel case final zl?)
            Padding(
              key: const ValueKey('zoom_clear_label'),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 16,
                    color: AppColors.proGold,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      zl,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.proGold,
                      ),
                    ),
                  ),
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
                note: kAiBlurNote,
                // Cross-fade original → enhanced result when it lands.
                // v11.69: press and hold → the original (tone compare).
                child: _holdToCompare(
                  AnimatedSwitcher(
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
                        : _toneProxyVisible
                        ? RawImage(
                            key: const ValueKey('tone_proxy'),
                            image: _toneImage,
                            fit: BoxFit.contain,
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
          if (_timing != null && !_busy && AiConfig.hasEmbeddedApiKey)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                _timing!,
                key: const ValueKey('ai_timing_line'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ..._resultExtras(),
          if (_toneReady && !_showFilters)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ToneBar(
                autoOn: _toneAutoOn,
                preset: _tonePreset,
                enabled: !_busy,
                canReset: _toneCanReset,
                showAuto: kAutoTone,
                showPresets: kTonePresets,
                onAuto: _setToneAuto,
                onPreset: _setTonePreset,
                onAdjust: _openToneSliders,
                onReset: _resetTone,
              ),
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
                showLocal: !kNoFiltersPanel,
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
                    // v11.70: without free filters, Filters stays only for
                    // the AI filters (Pro AI captures).
                    if (!kNoFiltersPanel || _actions.aiFilters) ...[
                      Expanded(
                        flex: 3,
                        child: _ActionButton(
                          icon: Icons.palette_outlined,
                          label: 'Filters',
                          filled: true,
                          onPressed: _busy
                              ? null
                              : () => setState(
                                  () => _showFilters = !_showFilters,
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
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
    this.showLocal = true,
    required this.showAi,
    required this.selected,
    required this.strength,
    required this.onLocal,
    required this.onStrength,
    required this.onStrengthEnd,
    required this.onAi,
  });

  final bool enabled;

  /// v11.70: false → no free on-device filters ([kNoFiltersPanel]).
  final bool showLocal;

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
            if (showLocal) const _PanelLabel('Free filters (no AI)'),
            if (showLocal)
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
            if (showLocal && !selected.isOriginal)
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
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  /// v11.70 smaller buttons (one row of three).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: compact ? 18 : 20),
        SizedBox(width: compact ? 6 : 8),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: compact ? 13 : null,
          ),
        ),
      ],
    );

    if (filled) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 12 : 14),
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
        padding: EdgeInsets.symmetric(vertical: compact ? 10 : 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(compact ? 12 : 14),
        ),
      ),
      child: child,
    );
  }
}

/// v11.69 "Original" tag while the photo is held.
class _OriginalTag extends StatelessWidget {
  const _OriginalTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(99),
    ),
    child: const Text(
      'Original',
      style: TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// v11.70 small pill over the photo.
class _OverlayPill extends StatelessWidget {
  const _OverlayPill({
    super.key,
    required this.icon,
    required this.text,
    this.gold = false,
  });

  final IconData icon;
  final String text;
  final bool gold;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: gold ? AppColors.proGold : Colors.white),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: gold ? AppColors.proGold : Colors.white,
            ),
          ),
        ),
      ],
    ),
  );
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({super.key, required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black.withValues(alpha: 0.45),
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    ),
  );
}

/// v11.70 slim Styles row bound to the style catalog.
class _SlimStyles extends StatefulWidget {
  const _SlimStyles({
    required this.enabled,
    required this.isPro,
    required this.aiFilters,
    required this.aiFilterCost,
    required this.aiFilterLocked,
    required this.aiFilterTrial,
    required this.onAiFilter,
    required this.onStyle,
    required this.onCustom,
    required this.onSeeAll,
  });

  final bool enabled;
  final bool isPro;
  final List<StylePreset> aiFilters;
  final int aiFilterCost;
  final bool aiFilterLocked;
  final bool aiFilterTrial;
  final ValueChanged<StylePreset> onAiFilter;
  final ValueChanged<AiStyle> onStyle;
  final VoidCallback onCustom;
  final VoidCallback onSeeAll;

  @override
  State<_SlimStyles> createState() => _SlimStylesState();
}

class _SlimStylesState extends State<_SlimStyles> {
  @override
  void initState() {
    super.initState();
    unawaited(StyleCatalog.instance.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<AiStyle>>(
      valueListenable: StyleCatalog.instance.styles,
      builder: (context, styles, _) => SlimStyleRow(
        styles: styles,
        enabled: widget.enabled,
        isPro: widget.isPro,
        aiFilters: widget.aiFilters,
        aiFilterCost: widget.aiFilterCost,
        aiFilterLocked: widget.aiFilterLocked,
        aiFilterTrial: widget.aiFilterTrial,
        onAiFilter: widget.onAiFilter,
        onStyle: widget.onStyle,
        onCustom: widget.onCustom,
        onSeeAll: widget.onSeeAll,
      ),
    );
  }
}

/// v11.70 fullscreen photo: pinch to zoom, double-tap to zoom, tap to close.
class FullscreenPhoto extends StatefulWidget {
  const FullscreenPhoto({super.key, required this.file});
  final File file;

  @override
  State<FullscreenPhoto> createState() => _FullscreenPhotoState();
}

class _FullscreenPhotoState extends State<FullscreenPhoto> {
  final _ctl = TransformationController();
  TapDownDetails? _dbl;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_ctl.value.getMaxScaleOnAxis() > 1.01) {
      _ctl.value = Matrix4.identity();
      return;
    }
    final p = _dbl?.localPosition ?? Offset.zero;
    const s = 2.5;
    _ctl.value = Matrix4.identity()
      ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('fullscreen_photo'),
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            onDoubleTapDown: (d) => _dbl = d,
            onDoubleTap: _toggleZoom,
            child: InteractiveViewer(
              transformationController: _ctl,
              maxScale: 8,
              child: Center(
                child: Image.file(
                  widget.file,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                key: const ValueKey('fullscreen_close'),
                color: Colors.white,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
