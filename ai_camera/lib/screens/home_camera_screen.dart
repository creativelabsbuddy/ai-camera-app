import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'dart:ui' show FrameTiming;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, DeviceOrientation, HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/camera_options.dart';
import '../models/capture_mode.dart';
import '../models/pose_photo.dart';
import '../models/quality_tier.dart';
import '../models/shoot_mode.dart';
import '../models/style_preset.dart';
import '../services/account_service.dart';
import '../services/barcode_actions.dart';
import '../services/camera_permission.dart';
import '../services/capture_crop.dart';
import '../services/document_scan.dart';
import '../services/enhance_policy.dart';
import '../services/entitlements.dart';
import '../services/focus_mapping.dart';
import '../services/hdr_merge.dart';
import '../services/live_look.dart';
import '../services/live_policies.dart';
import '../services/frame_stats.dart';
import '../services/image_guard.dart';
import '../services/context_snapshot.dart';
import '../config/ai_config.dart';
import '../services/macro.dart';
import '../services/macro_box.dart';
import '../services/micro_lock.dart';
import '../services/mode_prompts.dart' show kMacroGeneralSubject;
import '../widgets/credit_icon.dart';
import '../widgets/styles_quick_panel.dart';
import '../widgets/video_style_flow.dart';
import '../services/video_service.dart';
import '../services/video_style_catalog.dart';
import '../widgets/macro_level_chips.dart';
import '../services/subject_detector.dart';
import '../services/native_camera.dart';
import '../services/night_retone.dart';
import '../services/premium_filters.dart';
import '../services/optical_profile.dart';
import '../services/pose_catalog.dart';
import '../services/scene_suggest.dart';
import '../services/night_pipeline.dart';
import '../services/zoom_ladder.dart';
import '../services/burst_merge.dart';
import '../services/image_register.dart' show GreyImage, Similarity;
import '../services/tracked_source.dart';
import '../services/zoom_preview_policy.dart';
import '../services/zoom_root.dart';
import '../services/zoom_tracker.dart';
import '../services/zoom_tracker_worker.dart';
import '../services/zoom_source.dart';
import '../services/network_check.dart';
import '../services/zoom_assist.dart';
import '../services/camera_extras.dart';
import '../services/style_catalog.dart';
import '../services/saved_styles.dart';
import '../services/style_samples.dart';
import '../services/filter_catalog.dart';
import '../models/ai_style.dart';
import 'video_screen.dart';
import '../services/tap_focus.dart';
import '../services/vision.dart';
import '../services/zoom_badge.dart';
import '../services/zoom_chips.dart';
import '../services/zoom_info.dart';
import '../services/zoom_range.dart';
import '../services/zoom_ruler.dart';
import '../services/steady.dart';
import '../theme/app_theme.dart';
import '../widgets/document_sheet.dart';

import '../widgets/focus_ring.dart';
import '../widgets/freeze_frame.dart';
import '../widgets/live_overlays.dart';
import '../widgets/mode_strip.dart';
import '../widgets/night_sheets.dart';
import '../widgets/pose_reference.dart';
import '../widgets/pose_strip.dart';
import '../widgets/pro_upgrade_sheet.dart';
import '../widgets/quality_sheet.dart';
import '../widgets/quick_menu_bar.dart';
import '../widgets/top_flash_button.dart';
import '../widgets/style_library_sheet.dart';
import '../widgets/transient_notice.dart';
import '../widgets/zoom_pill.dart';
import '../widgets/zoom_ruler.dart';
import 'look_screen.dart';
import 'preview_screen.dart';
import 'settings_screen.dart';

/// Strip shown above the shutter while picked from the quick menu.
enum _Panel { none, filters }

const _kNightFlashKey = 'night_flash_v11';
const _kNightTipsSeenKey = 'pro_night_tips_seen_v11';

/// v11.54 "Styles are here" tooltip + NEW sparkle (shown until seen once).
const kStylesHintSeenKey = 'styles_hint_seen_v1154';

class HomeCameraScreen extends StatefulWidget {
  const HomeCameraScreen({super.key});

  @override
  State<HomeCameraScreen> createState() => _HomeCameraScreenState();
}

class _HomeCameraScreenState extends State<HomeCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  CameraLensDirection _lens = CameraLensDirection.back;

  bool _initializing = true;
  bool _setupLocked = false;
  bool _permissionDenied = false;
  String? _error;
  final _picker = ImagePicker();

  // Frame ratio (4:3 default = full sensor frame, no crop). Quick menu.
  FrameRatio _ratio = FrameRatio.r4x3;
  bool _processingCapture = false;

  // Zoom. [_range] = phone-wise range (see services/zoom_range.dart).
  // [_zoom] is the user-facing selection (up to 100x for everyone); the
  // camera itself never goes past its real max. Beyond that [_digitalZoom]
  // centre-crops the preview and, on shutter, the full-res still.
  ZoomRange _range = ZoomRange.none;

  /// Per-device optical facts (Camera2): usable lens factors, optical limit
  /// (free AI up to here), AI-recoverable limit (~7×, warning above).
  OpticalProfile _optical = OpticalProfile.fallback;
  ZoomChipSet _chips = ZoomChipSet.single;
  double _zoom = 1.0;
  double _cameraZoom = 1.0;
  double _digitalZoom = 1.0;
  double _pinchBaseZoom = 1.0;
  bool _zoomInFlight = false;
  double? _pendingZoom;

  // Normal (plain camera) vs Pro (auto AI enhance). Persisted; default Normal.
  CaptureMode _mode = CaptureMode.normal;

  // Pre-selected AI quality (top-right chip) and AI filter (Pro AI mode).
  QualityTier _tier = QualityTier.hd;
  StylePreset? _aiFilter;

  /// AI style picked from the quick menu before "Take photo": its look sheet
  /// opens on the preview once the photo is ready.
  PendingLook? _pendingLook;

  /// v11.54 video style picked with "Take photo": the next shot opens
  /// its confirm sheet.
  AiStyle? _pendingVideo;

  /// v11.54 first-run "Styles are here" tooltip / NEW sparkle.
  bool _stylesHint = false;

  // Night mode (quick-menu moon): free burst merge + exposure boost; Pro AI
  // adds the night prompt. Orthogonal to NORMAL / PRO AI.
  bool _night = false;
  double _maxExposureOffset = 0;
  double _minExposureOffset = 0;

  /// v11.34 bright small region in a dark frame (high zoom): meter + focus
  /// on it. Generic luminance only.
  final BrightMeter _bright = BrightMeter();
  bool _brightApplied = false; // v11.36: = far-bright latch on

  /// v11.36 Zoom mode (chip): > 10x + heavy logic only when on.
  bool _zoomMode = false;

  // v11.42 stability: gyro steadiness above 10x, stabilisation, debug line.
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  final SteadyMeter _steady = SteadyMeter();
  bool _steadyMoving = false;
  String _stabText = '';
  bool _debugOverlay = false;
  double _uiFps = 0;
  int _fpsFrames = 0;
  DateTime _fpsSince = DateTime.now();
  Timer? _debugTicker;
  bool _latchSuppressed = false; // "Auto focus" chip until zoom < 3x
  bool _latchManual = false;
  int _latchNs = kLatchStartNs;
  int _latchTop = 0;
  double _latchEv = 0;
  String _latchText = '';
  DateTime? _latchLastSpot;
  DateTime? _latchStep;
  Offset? _latchMeterPoint; // tapped area (visible crop coords)
  BrightSpot? _lastSpot;
  bool _overlayOn = true;
  Timer? _overlayTimer;
  Map<String, Object?> _overlayInfo = const {};
  DateTime? _zoomHintAt;
  LensCheck _lensCheck = LensCheck();
  Timer? _lensTimer;

  /// v11.34 cheap phones: walk through checkpoints (never skipped).
  double? _walkTarget;
  bool _walking = false;
  bool _slowHintShown = false;

  /// v11.34 subject changed between checkpoints; per-phone clear limit.
  bool _subjectChanged = false;
  double? _clearLimit;
  bool _clearLimitBusy = false;
  // v11.61 ROOT reference: still long side + real zoom (real-pixel gate).
  int? _rootStillLong;
  RefZoomLabel? _rootLabel;
  String? _ladderDbg;

  /// v11.59 what the last zoom shutter really sent (source, match, sizes).
  String? _zoomSendDbg;
  final GlobalKey _menuKey = GlobalKey(debugLabel: 'four_dot');
  bool _holdSteady = false;

  // Continuous zoom ruler (long-press / drag the pill, or pinch).
  bool _rulerOpen = false;
  Timer? _rulerTimer;

  bool _captureLock = false;

  /// Tap-to-focus / AE-AF lock (continuous AF otherwise).
  final TapFocusController _focus = TapFocusController();
  double _rulerDragZoom = 1.0;
  double _rulerDragDx = 0;

  // v11 premium colour filter: live preview (free). NORMAL final = on-device
  // LUT; PRO AI final = AI (hidden per-filter prompt, credits on success).
  final PremiumFilter _premium =
      PremiumFilter.original; // v11.51: no colour filters
  final double _strength = 1.0;

  // Quick menu (four-dot button) and the strip it opens above the shutter.
  bool _menuOpen = false;
  _Panel _panel = _Panel.none;
  FlashChoice _flash = FlashChoice.off;
  TimerChoice _timer = TimerChoice.off;
  int? _countdown;
  Timer? _countdownTimer;

  /// Last shot → bottom-left gallery thumbnail.
  File? _lastShot;

  /// Brief centre toast (flash / timer / ratio / quality changes).
  String? _toast;
  int _toastSeq = 0;

  final AccountService _account = AccountService.instance;

  // ---- v10: shooting modes + free on-device live vision ----------------
  ShootMode _shootMode = ShootMode.photo;
  CameraFeatures _features = const CameraFeatures();
  final LiveVisionEngine _vision = LiveVisionEngine();
  final SmileTrigger _smile = SmileTrigger();
  final FaceFocusPolicy _faceFocus = FaceFocusPolicy();
  final SuggestionGate _tipGate = SuggestionGate();
  SceneSuggestion? _tip;
  Timer? _tipTimer;
  List<SceneLabel> _lastLabels = const [];
  ScanAction? _scan;
  String? _scanDismissed;
  DateTime? _scanSeenAt;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  double _roll = 0;
  bool _flat = false;

  /// Latest viewfinder geometry (for mapping analysis points on screen).
  PreviewGeometry? _geometry;

  // Pose mode (real reference photos; no outline, no auto-capture).
  List<String> _poseCategories = kPoseCategories;
  String _poseCategory = kPoseCategories.first;
  PosePhoto? _pose;

  /// The Flutter camera currently open (for hand-overs to native capture).
  CameraDescription? _description;

  // v11 Night: own flash choice (Off / Auto / On, default Auto), "Hold
  // still" countdown, freeze frame while the native burst owns the camera.
  FlashChoice _nightFlash = FlashChoice.auto;
  int? _nightCountdown;

  /// Latest frame stats (live luma, sharpness, freeze-frame thumbnail).
  FrameStats? _lastStats;
  String? _nightStage;

  // v11 Portrait (NORMAL): the phone's own BOKEH extension session.
  BokehStart? _bokeh;
  bool _bokehBusy = false;
  bool _bokehResume = false;

  /// Scanner / picker activity on top: keep the camera (the plugin pauses
  /// and resumes it with the activity) so returning is instant.
  bool _externalActivity = false;

  // v11 Macro (PRO AI).

  /// v11.33 shutter box detection (free; one call in flight).
  final SubjectDetector _detector = SubjectDetector();

  /// v11.33 level chip (null = 1x), box check, Microscope hint photo.
  MacroLevel? _macroLevel;
  final MacroBoxCheck _boxCheck = MacroBoxCheck();
  ContextSnapshot? _microHint;

  /// v11.40 Macro / Close / Extreme / Ultra: wider context photos taken at
  /// the shutter (lower zoom steps), sent as extra references.
  List<ContextSnapshot> _macroCtx = const [];

  /// v11.58 Microscope levels: the 1.5x photo taken at the shutter, the
  /// object locked from it, and the camera zoom of the last macro still.
  ContextSnapshot? _microOneHalf;
  MicroLock? _microLock;
  double _macroShotCamera = 1;
  final Set<MacroLevel> _levelTipsShown = {};
  int _zoomAnimGen = 0;
  String? _boxDbg; // key-build debug line (last shutter detection)

  /// Macro quality: HD / Full HD (2K locked, "Coming soon"). Default Full HD.
  QualityTier _macroTier = QualityTier.hd; // v11.48: Macro default HD
  QualityTier get _effTier => _macroActive
      ? _macroTier
      : (_aiMode ? tierForZoom(_tier, _zoom, picked: _tierPicked) : _tier);

  /// Shake (frame difference between analysis thumbnails, 0..1).
  double _motion = 0;
  Uint8List? _prevThumb;

  bool _torchOn = false;
  bool _afterFrames = false; // frames captured → "you can move now"

  /// v11.30 100x zoom ladder (cheap phones): checkpoint photos.
  ZoomLadder? _ladder;
  Timer? _ladderTimer;
  bool _ladderBusy = false;

  // v11.60 wide→close tracking + live-preview policies (cheap phones).
  // Tracker runs in a worker isolate (one update in flight, stale frames
  // dropped); [_track] = its latest reply.
  TrackerWorker? _trackWorker;
  bool _trackWorkerStarting = false;
  bool _trackRebaseNext = false;
  GreyImage? _lastTrackGrey;
  DeviceOrientation? _trackOrient; // device orientation of the chain
  DateTime? _trackSettleUntil; // after a rotation / lens reset
  int? _trackRot; // still = analysis rotated cw by k·90 (verified)
  String? _trackLensId; // physical camera id of the chain
  DateTime? _lensPolledAt;
  bool _lensPollBusy = false;
  DateTime? _zoomChangedAt;
  DateTime? _lastAfNudge;
  Timer? _afReleaseTimer;
  Similarity? _prevTrack;
  double _trackMotion = 1;
  BurstJob? _burstJob;
  bool _ladderNoteShown = false;

  /// v11.9 context snapshot (sharp low-zoom still for the AI).
  ContextSnapshot? _ctxSnap;
  Timer? _ctxTimer;
  bool _ctxBusy = false;

  /// User chose a quality (no 30x Full HD default then).
  bool _tierPicked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _vision.addListener(_onVision);
    // Warm the native lens probe in parallel with permission / camera open.
    unawaited(ZoomInfoService.load());
    unawaited(_loadPrefs());
    unawaited(FilterCatalog.instance.ensureLoaded()); // v11.51
    unawaited(_loadClearLimit());
    unawaited(_loadLensCheck());
    unawaited(StyleCatalog.instance.ensureLoaded());
    unawaited(VideoStyleCatalog.instance.ensureLoaded()); // v11.54 quick row
    unawaited(SavedStyles.instance.ensureLoaded()); // v11.56 saved styles
    unawaited(StyleSamples.instance.ensureLoaded()); // v11.56 before/after
    unawaited(VideoService.instance.refreshOptions());
    unawaited(_loadStylesHint());
    unawaited(_refreshAccount());
    unawaited(_setupCamera());
  }

  Future<void> _refreshAccount() async {
    try {
      await _account.refresh();
    } catch (e) {
      debugPrint('Account refresh failed: $e');
    }
  }

  Future<void> _loadPrefs() async {
    unawaited(_loadDebugOverlay()); // v11.42 test builds
    try {
      final prefs = await SharedPreferences.getInstance();
      final m = CaptureMode.fromName(prefs.getString(CaptureMode.prefsKey));
      final t = QualityTier.pickable(prefs.getString(QualityTier.prefsKey));
      final fl = FlashChoice.fromName(prefs.getString(FlashChoice.prefsKey));
      final tm = TimerChoice.fromName(prefs.getString(TimerChoice.prefsKey));
      final nf = prefs.getString(_kNightFlashKey);
      CameraFeatures feats = const CameraFeatures();
      final fj = prefs.getString(CameraFeatures.prefsKey);
      if (fj != null) {
        try {
          feats = CameraFeatures.fromJson(
            (jsonDecode(fj) as Map).cast<String, Object?>(),
          );
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _features = feats;
          _mode = m;
          _tier = t;
          _flash = fl;
          _timer = tm;
          if (nf != null) _nightFlash = FlashChoice.fromName(nf);
        });
        unawaited(_applyFlash());
        _syncLevel();
      }
    } catch (_) {
      // Prefs unavailable: stay in-memory (default Normal / HD).
    }
  }

  Future<void> _savePref(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  bool get _aiMode => _mode == CaptureMode.pro;

  void _showToast(String text) {
    setState(() {
      _toast = text;
      _toastSeq++;
    });
  }

  void _snack(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 2200),
          content: CreditText(text),
          action: action,
        ),
      );
  }

  Future<void> _pickQuality() async {
    if (_macroActive) {
      // v11.33 Macro: HD / Full HD (2K locked, "Coming soon"); its own
      // quality (default Full HD), not saved globally.
      final m = await showMacroQualitySheet(context, _macroTier);
      if (m == null || !mounted) return;
      if (m != QualityTier.hd && m != QualityTier.fullHd) return;
      setState(() => _macroTier = m);
      final l = _macroLevel;
      _showToast(
        l == null
            ? 'Macro · ${m.label}'
            : 'Macro · ${m.label} · 🪙${macroCreditsFor(l.id, quality: m.id)}',
      );
      return;
    }
    final t = await showQualitySheet(context, _effTier);
    if (t == null || !mounted || t == QualityTier.k4) return;
    _tierPicked = true;
    setState(() => _tier = t);
    _showToast(
      '${t.label} · ${t.credits} credit${t.credits == 1 ? '' : 's'} per AI photo',
    );
    await _savePref(QualityTier.prefsKey, t.id);
  }

  // ---------------------------------------------------------------------------
  // Quick menu
  // ---------------------------------------------------------------------------

  void _toggleMenu(bool open) {
    setState(() {
      _menuOpen = open;
      // v11.54: the four-dot opens the Styles quick row with the menu.
      _panel = open ? _Panel.filters : _Panel.none;
    });
    if (open) unawaited(_dismissStylesHint());
  }

  Future<void> _loadStylesHint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool(kStylesHintSeenKey) ?? false;
      if (mounted && !seen) setState(() => _stylesHint = true);
    } catch (_) {}
  }

  /// Tooltip tapped or Styles opened: never shown again.
  Future<void> _dismissStylesHint() async {
    if (!_stylesHint) return;
    if (mounted) setState(() => _stylesHint = false);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kStylesHintSeenKey, true);
    } catch (_) {}
  }

  void _togglePanel(_Panel p) {
    setState(() => _panel = _panel == p ? _Panel.none : p);
  }

  /// Night uses its own flash choice (fired only for the flash shot).
  FlashMode get _previewFlashMode => _night ? FlashMode.off : _flash.mode;

  Future<void> _applyFlash() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFlashMode(_previewFlashMode);
    } catch (e) {
      debugPrint('Flash not available: $e');
    }
  }

  void _cycleFlash() {
    // v11.48: Flash and the Macro torch never fight: Flash turns it off.
    if (_torchOn) {
      setState(() => _torchOn = false);
    }
    if (_night) {
      _cycleNightFlash();
      return;
    }
    setState(() => _flash = _flash.next);
    _showToast(_flash.label);
    unawaited(_applyFlash());
    unawaited(_savePref(FlashChoice.prefsKey, _flash.name));
  }

  void _cycleTimer() {
    setState(() => _timer = _timer.next);
    _showToast(_timer.label);
    unawaited(_savePref(TimerChoice.prefsKey, _timer.name));
  }

  void _cycleRatio() {
    setState(() => _ratio = _ratio.next);
    _focus.onSceneChange();
    _showToast('Aspect ratio ${_ratio.label}');
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    if (mounted) unawaited(_refreshAccount());
    if (mounted) unawaited(_loadDebugOverlay());
  }

  /// Quick menu → Styles: full AI style library (works in every mode;
  /// each style costs credits). Then "Take photo" / "Choose from gallery".
  Future<void> _openStyles() async {
    unawaited(_dismissStylesHint());
    final pick = await showStyleLibrarySheet(context);
    if (pick == null || !mounted) return;
    if (pick.custom) return _openCustom(photoFirst: !pick.video);
    if (pick.video) return _startVideoStyle(pick.style!);
    await _applyStyle(pick.style);
  }

  /// v11.56 Custom window (AI Photo | AI Video). AI Photo → Take photo
  /// closes it and applies the prompt to the next shot.
  Future<void> _openCustom({required bool photoFirst}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => VideoScreen(
          custom: true,
          customPhotoFirst: photoFirst,
          tier: _effTier,
          onTakePhoto: (prompt, tier) {
            Navigator.of(ctx).pop();
            if (!mounted) return;
            setState(() {
              _pendingLook = PendingLook(customPrompt: prompt, tier: tier);
              _pendingVideo = null;
              _menuOpen = false;
              _panel = _Panel.none;
            });
            _showToast('Take a photo to apply ${_pendingLook!.label}');
          },
        ),
      ),
    );
    if (mounted) unawaited(_refreshAccount());
  }

  /// v11.53 camera AI video screen (presets or custom).
  Future<void> _openVideo({
    AiStyle? preset,
    File? photo,
    String? resolution,
    bool startCustom = false,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoScreen(
          preset: preset,
          photo: photo,
          resolution: resolution,
          startCustom: startCustom,
        ),
      ),
    );
    if (mounted) unawaited(_refreshAccount());
  }

  /// v11.57 video style card: image-to-video only. Uses the last captured
  /// photo (or [photo] when already known) and opens the confirm sheet
  /// directly. No Take photo / gallery picker. No photo → toast and stop.
  Future<void> _startVideoStyle(AiStyle s, {File? photo}) async {
    final f = photo ??
        (_lastShot != null && _lastShot!.existsSync() ? _lastShot : null);
    if (f == null) {
      _showToast('Take a photo first');
      return;
    }
    if (!mounted) return;
    final res = await showVideoConfirmSheet(context, style: s, photo: f);
    if (res == null || !mounted) return;
    await _openVideo(preset: s, photo: f, resolution: res);
  }

  /// Style (or custom when null) → "Take photo" / "Choose from gallery".
  Future<void> _applyStyle(AiStyle? style) async {
    final pick = (style: style);
    await startLookWithoutPhoto(
      context,
      style: pick.style,
      tier: _effTier,
      onTakePhoto: (r) {
        setState(() {
          _pendingLook = PendingLook(
            style: pick.style,
            customPrompt: r.customPrompt,
            tier: r.tier,
          );
          _pendingVideo = null;
          _menuOpen = false;
          _panel = _Panel.none;
        });
        _showToast('Take a photo to apply ${_pendingLook!.label}');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Night mode
  // ---------------------------------------------------------------------------

  /// Quick-menu moon / Night badge: same as picking NIGHT in the strip.
  void _toggleNight() {
    unawaited(_setShootMode(_night ? ShootMode.photo : ShootMode.night));
  }

  /// Brighter live view while Night is on (same boost the burst uses).
  Future<void> _applyNightExposure() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final sel = selectCapturePipeline(
      night: _night,
      mode: _mode,
      flash: _flash,
      maxExposureOffset: _maxExposureOffset,
    );
    try {
      await c.setExposureOffset(sel.pipeline.exposureBoostEv);
    } catch (e) {
      debugPrint('Exposure offset not supported: $e');
    }
  }

  void _cycleNightFlash() {
    setState(() => _nightFlash = _nightFlash.next);
    _showToast('Night · ${_nightFlash.label}');
    unawaited(_savePref(_kNightFlashKey, _nightFlash.name));
  }

  /// Live luma (0..1) from the analysis stream (0.15 = unknown).
  double get _liveLuma => _vision.value.stats?.luma ?? 0.15;

  /// Pro Night tips: first time Pro Night is used, and the (i) button.
  Future<void> _maybeShowNightTips() async {
    if (!_aiMode || !_night) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kNightTipsSeenKey) ?? false) return;
      await prefs.setBool(_kNightTipsSeenKey, true);
    } catch (_) {
      return;
    }
    if (mounted) await showProNightTips(context);
  }

  /// v11.51 filter row: select before the shot (applied after Enhance
  /// through the Styles look path); null = deselect.
  void _onFilterSelect(AiStyle? f) {
    setState(() {
      _pendingLook = f == null ? null : PendingLook(style: f, tier: _effTier);
    });
    if (f != null) _showToast('${f.name} will be applied after the shot');
  }

  Future<void> _setMode(CaptureMode m) async {
    if (m == _mode) return;
    setState(() {
      _mode = m;
    });
    unawaited(_restoreAutoExposure()); // v11.46: no stale exposure
    if (m == CaptureMode.pro) unawaited(_aiReachable()); // v11.59 warm
    // v11.48: Macro is Pro-only, HDR is Normal-only → back to Photo.
    if (!ShootMode.stripFor(
      aiMode: m == CaptureMode.pro,
    ).contains(_shootMode)) {
      await _setShootMode(ShootMode.photo);
    }
    unawaited(_syncModeHardware());
    if (_night) unawaited(_maybeShowNightTips());
    _snack(
      m == CaptureMode.pro
          ? 'Pro AI on · photos are AI-enhanced automatically after capture'
          : 'Normal · no AI, photos exactly as captured',
    );
    await _savePref(CaptureMode.prefsKey, m.name);
  }

  @override
  void dispose() {
    _gyroSub?.cancel();
    _stopFpsMeter();
    _zoomAfTimer?.cancel();
    _afReleaseTimer?.cancel();
    _burstJob?.cancel();
    _trackWorker?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _ladderTimer?.cancel();
    _lensTimer?.cancel();
    _overlayTimer?.cancel();
    _overlayTimer = null;
    _countdownTimer?.cancel();
    _rulerTimer?.cancel();
    _tipTimer?.cancel();
    unawaited(_accelSub?.cancel());
    _vision.removeListener(_onVision);
    _vision.dispose();
    _focus.dispose();
    _nightTicker?.cancel();
    if (_bokeh != null) unawaited(BokehBridge.stop());
    final c = _controller;
    _controller = null;
    unawaited(c?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Skip lifecycle churn while the permission dialog is up or setup runs.
    if (_setupLocked) return;

    final c = _controller;
    if (state == AppLifecycleState.inactive) {
      _cancelCountdown();
      _cancelNightCountdown();
      // Document scanner / picker on top: the camera plugin pauses and
      // resumes with the activity, the preview keeps its last frame →
      // smooth return (no black "Opening camera…").
      if (_externalActivity) return;
      if (_bokeh != null) {
        _bokehResume = true;
        setState(() => _bokeh = null);
        unawaited(BokehBridge.stop());
        return;
      }
      if (c == null || !c.value.isInitialized) return;
      if (_brightApplied) unawaited(_releaseLatch()); // v11.39
      _controller = null;
      unawaited(_focus.attach(null));
      unawaited(() async {
        await _vision.attach(null); // stop the analysis stream first
        await c.dispose();
      }());
      return;
    }

    if (state == AppLifecycleState.resumed) {
      // New IST day → daily free credits reset.
      unawaited(_refreshAccount());
      _externalActivity = false;
      if (_bokehResume) {
        _bokehResume = false;
        unawaited(_startBokeh());
        return;
      }
      if (_bokeh != null || _bokehBusy || _processingCapture) return;
      if (_controller == null || !_controller!.value.isInitialized) {
        unawaited(_setupCamera());
      }
    }
  }

  Future<void> _setupCamera() async {
    if (_setupLocked) return;
    _setupLocked = true;
    // v11.39: a camera re-open must never inherit our manual exposure /
    // infinity focus (CameraX can keep Camera2 options on the same camera).
    if (_brightApplied) {
      await _releaseLatch();
    } else {
      await CameraExtras.clearManual();
    }

    if (mounted) {
      setState(() {
        _initializing = true;
        _error = null;
        _permissionDenied = false;
      });
    }

    try {
      if (kIsWeb ||
          !(defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        if (mounted) {
          setState(() {
            _initializing = false;
            _error =
                'Live camera needs an Android phone. Use Gallery to try the app.';
          });
        }
        return;
      }

      // 1) Ask for CAMERA on first open (Android MethodChannel).
      final granted = await CameraPermission.ensureGranted();
      if (!granted) {
        if (mounted) {
          setState(() {
            _initializing = false;
            _permissionDenied = true;
            _error =
                'Camera permission needed. Tap Allow Camera, then try again.';
          });
        }
        return;
      }

      // 2) Enumerate cameras after grant.
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _initializing = false;
            _error = 'No camera found on this device. Use Gallery instead.';
          });
        }
        return;
      }
      _cameras = cameras;

      final preferred =
          cameras.cast<CameraDescription?>().firstWhere(
            (c) => c!.lensDirection == _lens,
            orElse: () => null,
          ) ??
          cameras.first;

      await _openController(preferred);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _permissionDenied =
            e.code == 'CameraAccessDenied' ||
            e.code == 'CameraAccessDeniedWithoutPrompt';
        _error = _friendlyCameraError(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Camera failed to open.\n$e';
      });
    } finally {
      _setupLocked = false;
    }
  }

  Future<void> _openController(CameraDescription description) async {
    final previous = _controller;
    _controller = null;
    await previous?.dispose();

    // CameraX + ResolutionPreset.max => highest available stills with
    // CameraX's default 4:3 aspect strategy for BOTH preview and capture, so
    // the viewfinder shows exactly the captured sensor frame.
    final controller = CameraController(
      description,
      ResolutionPreset.max,
      enableAudio: false,
      // NV21 analysis frames for ML Kit (takePicture is still JPEG).
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    try {
      await controller.initialize();
    } catch (e) {
      await controller.dispose();
      rethrow;
    }
    // v11.42: OIS + preview EIS where the camera offers them.
    unawaited(
      CameraExtras.setStabilization(true).then((v) {
        _stabText = v;
        debugPrint('Stabilisation: $v');
      }),
    );

    // Real device zoom range (e.g. 0.6–10x on an ultra-wide capable logical
    // camera, 1–8x on many front cameras).
    var minZoom = 1.0;
    var maxZoom = 1.0;
    try {
      minZoom = await controller.getMinZoomLevel();
      maxZoom = await controller.getMaxZoomLevel();
    } catch (e) {
      debugPrint('Zoom range unavailable: $e');
    }
    if (!minZoom.isFinite || minZoom <= 0) minZoom = 1.0;
    if (!maxZoom.isFinite || maxZoom < minZoom) maxZoom = minZoom;

    // Phone-wise range: native Camera2 probe (back camera only) can report a
    // higher max and the telephoto multiplier (e.g. S24 Ultra 5x → 100x).
    ZoomRange range;
    var optical = OpticalProfile.fallback;
    if (description.lensDirection == CameraLensDirection.back) {
      NativeZoomInfo? info;
      try {
        info = await ZoomInfoService.load().timeout(
          const Duration(seconds: 3),
          onTimeout: () => null,
        );
      } catch (_) {}
      // 100x for everyone on the back camera (digital crop past the
      // camera's own max).
      range = computeZoomRange(
        controllerMin: minZoom,
        controllerMax: maxZoom,
        nativeReportedMax: info?.reportedMaxZoom,
        teleMultiplier: info?.teleMultiplier,
      );
      optical = computeOpticalProfile(info, controllerMax: maxZoom);
      ZoomInfoService.lastBackRange = range;
      ZoomInfoService.lastOptical = optical;
    } else {
      range = computeZoomRange(
        controllerMin: minZoom,
        controllerMax: maxZoom,
        displayTarget: null,
      );
    }
    final chips = buildZoomChipSet(range, optical: optical);
    debugPrint('Zoom: $range · $optical · $chips');

    final startZoom = 1.0.clamp(range.minZoom, range.hardwareMax).toDouble();
    if (startZoom != 1.0) {
      try {
        await controller.setZoomLevel(startZoom);
      } catch (_) {}
    }

    if (!mounted) {
      await controller.dispose();
      return;
    }
    try {
      await controller.setFlashMode(_previewFlashMode);
    } catch (e) {
      debugPrint('Flash not available: $e');
    }
    var maxEv = 0.0, minEv = 0.0;
    try {
      maxEv = await controller.getMaxExposureOffset();
      minEv = await controller.getMinExposureOffset();
    } catch (_) {}

    // Continuous AF (CONTINUOUS_PICTURE) + auto AE on every new
    // controller (init, lens switch, resume).
    await _focus.attach(CameraFocusOps(controller));
    if (!mounted) {
      await controller.dispose();
      return;
    }

    setState(() {
      _maxExposureOffset = maxEv.isFinite ? maxEv : 0;
      _minExposureOffset = minEv.isFinite ? minEv : 0;
      _bright.reset();
      _brightApplied = false;
      _controller = controller;
      _description = description;
      _lens = description.lensDirection;
      _resetLadder(); // new camera: old checkpoint photos no longer match
      _initializing = false;
      _error = null;
      _permissionDenied = false;
      _range = range;
      _optical = optical;
      _chips = chips;
      _zoom = startZoom;
      _cameraZoom = startZoom;
      _digitalZoom = 1.0;
      _pinchBaseZoom = startZoom;
      _pendingZoom = null;
      _zoomInFlight = false;
    });
    if (_night) unawaited(_applyNightExposure());
    // v11.33: Macro always opens at 1x (no level).
    if (_macroActive) _resetMacroFlow();
    if (_aiMode) unawaited(_aiReachable()); // v11.59 warm the check
    // Free on-device live vision (faces / QR / labels / frame stats) on the
    // new controller; analyzers follow the shooting mode.
    unawaited(_vision.attach(controller));
  }

  // ---------------------------------------------------------------------------
  // Zoom
  // ---------------------------------------------------------------------------

  /// Applies a requested (user-facing) zoom, up to displayMax for everyone.
  /// Up to deviceMax the camera zooms itself; beyond that the camera stays at
  /// its max and the rest is a centre digital crop (preview Transform.scale +
  /// capture crop).
  /// Coalesces rapid pinch updates so only one platform call is in flight at
  /// a time (latest value wins).
  /// v11.60 cheap phones: continuous AF stays in charge while zooming. Only
  /// when the zoom has rested and the camera ITSELF reports it is out of
  /// focus, one centre AF pass (≤ 1 per [kZoomAfCooldown]), then back to
  /// continuous AF. Never over a user tap / lock; no AF state → no nudge.
  Timer? _zoomAfTimer;
  void _scheduleZoomAf(double zoom) {
    _zoomAfTimer?.cancel();
    if (!_macroLowEnd ||
        _lens != CameraLensDirection.back ||
        zoom < 2.0 ||
        _macroActive) {
      return;
    }
    _zoomAfTimer = Timer(
      kZoomAfRest + const Duration(milliseconds: 50),
      () => unawaited(_zoomAfCheck()),
    );
  }

  Future<void> _zoomAfCheck() async {
    if (!mounted || _brightApplied || _processingCapture) return;
    final info = await CameraExtras.info();
    if (!mounted) return;
    final af = info['afState'];
    final now = DateTime.now();
    final due = zoomAfNudgeDue(
      lowEnd: _macroLowEnd,
      backLens: _lens == CameraLensDirection.back,
      zoom: _zoom,
      now: now,
      zoomChangedAt: _zoomChangedAt,
      lastNudgeAt: _lastAfNudge,
      afState: af is num ? af.toInt() : null,
      userFocus: _focus.point != null || _focus.locked,
      busy: _processingCapture || _brightApplied || _captureLock,
    );
    if (!due) return;
    _lastAfNudge = now;
    await _focus.centrePass();
    _afReleaseTimer?.cancel();
    _afReleaseTimer = Timer(kZoomAfRelease, () {
      if (mounted && !_processingCapture) {
        unawaited(_focus.afterCapture(true));
      }
    });
  }

  Future<void> _setZoom(double requested) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final plan = planZoom(requested: requested, range: _range);
    if ((plan.selected - _zoom).abs() < 0.005 &&
        (plan.digitalZoom - _digitalZoom).abs() < 0.001 &&
        _pendingZoom == null) {
      return;
    }

    setState(() {
      _zoom = plan.selected;
      _digitalZoom = plan.digitalZoom;
    });
    // New framing: tap point / AE-AF lock no longer valid (v11.35: a small
    // zoom change keeps the tap); the next zoom ends the tap's bright pause.
    _focus.onSceneChange(zoom: plan.selected);
    _zoomChangedAt = DateTime.now();
    _scheduleZoomAf(plan.selected);
    _vision.cropZoom = plan.digitalZoom;
    _vision.zoom = plan.selected;
    _syncGyro();
    // v11.60: metering region in CAMERA coords, never tiny (AF hunting).
    CameraExtras.setMeteringSize(meteringSizeForZoom(plan.digitalZoom));
    _scheduleLensCheck();
    _scheduleContextSnap();
    _onLadderZoom();

    final target = plan.cameraZoom;
    if ((target - _cameraZoom).abs() < 0.005 && _pendingZoom == null) return;
    _cameraZoom = target;
    _pendingZoom = target;
    if (_zoomInFlight) return;

    _zoomInFlight = true;
    try {
      while (_pendingZoom != null) {
        final next = _pendingZoom!;
        _pendingZoom = null;
        if (!identical(c, _controller) || !c.value.isInitialized) break;
        await c.setZoomLevel(next);
      }
    } catch (e) {
      debugPrint('setZoomLevel failed: $e');
    } finally {
      if (identical(c, _controller)) _zoomInFlight = false;
    }
  }

  /// User zoom (chips, ruler, pinch): haptic tick for every lens chip
  /// crossed, then [_setZoom].
  void _setZoomUser(double v) {
    final max = _userZoomMax;
    if (v > max + 0.05 && !_zoomModeActive) {
      final now = DateTime.now();
      if (_zoomHintAt == null ||
          now.difference(_zoomHintAt!) > const Duration(seconds: 3)) {
        _zoomHintAt = now;
        _showToast(kZoomModeHint);
      }
    }
    final target = v.clamp(_range.minZoom, max).toDouble();
    if (crossedTicks(_zoom, target, _chips.lensValues).isNotEmpty) {
      unawaited(HapticFeedback.selectionClick());
    }
    // v11.34 cheap phones: a fast jump walks through each checkpoint.
    if (_ladderMode && target > _zoom + 0.01) {
      final l = _ladder ??= ZoomLadder(hardwareMax: _range.hardwareMax);
      final walk = checkpointsToWalk(
        _zoom,
        target,
        l.checkpoints,
        l.takenCheckpoints,
      );
      if (walk.isNotEmpty || _walking) {
        _walkTarget = target;
        if (!_walking) unawaited(_walkCheckpoints());
        return;
      }
    } else if (_walking) {
      _walkTarget = null; // zooming out stops the walk
    }
    unawaited(_setZoom(target));
  }

  /// Zoom in through each missing checkpoint (short pause + photo), then
  /// to the latest target.
  Future<void> _walkCheckpoints() async {
    _walking = true;
    try {
      while (mounted && _walkTarget != null && _ladderMode) {
        final l = _ladder;
        if (l == null) break;
        final t = _walkTarget!;
        final walk = checkpointsToWalk(
          _zoom,
          t,
          l.checkpoints,
          l.takenCheckpoints,
        );
        if (walk.isEmpty) {
          await _setZoom(t);
          if (_walkTarget == t) break;
          continue;
        }
        final cp = walk.first;
        await _setZoom(cp);
        await _waitZoomSettled();
        await Future<void>.delayed(kLadderStepPause);
        if (_walkTarget == null) break;
        await _takeLadderShot();
      }
    } finally {
      _walking = false;
      _walkTarget = null;
    }
  }

  /// v11.36: no centre AF pass while the far-bright latch holds focus.
  Future<bool> _preCapture() =>
      _brightApplied ? Future.value(false) : _focus.preCapture();

  /// v11.36: Zoom mode is on and usable (Pro AI photo, back camera).
  bool get _zoomModeActive =>
      _zoomMode &&
      _snapshotMode &&
      !_macroActive &&
      _lens == CameraLensDirection.back;

  /// Max zoom the user can reach right now.
  double get _userZoomMax => _macroActive
      ? _macroMaxZoom // v11.41: macro levels 1x–10x
      // v11.46: Normal camera reaches the phone's own max (like stock).
      : _zoomModeActive ||
            _lens != CameraLensDirection.back ||
            _mode == CaptureMode.normal
      ? _range.displayMax
      : math.min(kNormalZoomMax, _range.displayMax);

  Future<void> _toggleZoomMode() async {
    if (!_zoomMode) {
      if (_mode == CaptureMode.normal) await _setMode(CaptureMode.pro);
      if (!mounted) return;
      // v11.46: enter Zoom mode with clean automatic exposure.
      await _restoreAutoExposure();
      if (!mounted) return;
      setState(() {
        _zoomMode = true;
        _latchSuppressed = false;
      });
      _showToast('Zoom mode on · up to ${formatZoom(_range.displayMax)}x');
    } else {
      setState(() => _zoomMode = false);
      await _leaveZoomMode();
      _showToast('Zoom mode off');
    }
  }

  /// Zoom mode off (or no longer usable): latch off, ladder dropped, zoom
  /// back within the normal range.
  Future<void> _leaveZoomMode() async {
    if (_brightApplied) await _releaseLatch();
    _resetLadder();
    if (_zoom > _userZoomMax + 0.01) await _setZoom(_userZoomMax);
  }

  /// v11.36 far-bright latch: relative bright spot at ≥ 5x on 3 frames →
  /// infinity focus + our shutter/ISO until < 3x, 30 s without a spot, the
  /// Auto focus chip, or Zoom mode off. No subject recognition.
  void _updateBright(FrameStats s) {
    if (!_zoomModeActive || _processingCapture && !_brightApplied) {
      if (_brightApplied && !_zoomModeActive) unawaited(_releaseLatch());
      return;
    }
    final g = s.cropLuma;
    if (g == null || g.length < kThumbW * kThumbH) return;
    final spot = findBrightSpot(g, kThumbW, kThumbH);
    _lastSpot = spot;
    final now = DateTime.now();
    if (_brightApplied) {
      if (spot != null) _latchLastSpot = now;
      final idle = now.difference(_latchLastSpot ?? now) > kLatchIdle;
      if (_cameraZoom < kLatchOffZoom - 0.01 || idle) {
        unawaited(_releaseLatch());
        return;
      }
      if (_latchManual &&
          (_latchStep == null ||
              now.difference(_latchStep!) >
                  const Duration(milliseconds: 400))) {
        _latchStep = now;
        final mp = _latchMeterPoint;
        final top = mp != null
            ? regionTop(g, kThumbW, kThumbH, mp)
            : (spot?.top ??
                  regionTop(
                    g,
                    kThumbW,
                    kThumbH,
                    const Offset(0.5, 0.5),
                    r: 0.5,
                  ));
        _latchTop = top;
        final next = nextLatchExposure(_latchNs, top);
        if (next != _latchNs) {
          _latchNs = next;
          unawaited(
            CameraExtras.setManual(
              focusInfinity: true,
              exposureNs: next,
              iso: kLatchIso,
            ),
          );
        }
      }
      return;
    }
    if (_latchSuppressed) {
      if (_cameraZoom < kLatchOffZoom) _latchSuppressed = false;
      return;
    }
    final on = _bright.update(_cameraZoom >= kLatchOnZoom - 0.01 ? spot : null);
    if (on && _bright.active) unawaited(_engageLatch());
  }

  Future<void> _engageLatch() async {
    final c = _controller;
    if (c == null || _brightApplied) return;
    _brightApplied = true;
    _latchLastSpot = DateTime.now();
    _latchNs = kLatchStartNs;
    _latchMeterPoint = null;
    _latchEv = 0;
    try {
      await _focus.reset();
      final res = await CameraExtras.setManual(
        focusInfinity: true,
        exposureNs: _latchNs,
        iso: kLatchIso,
      );
      _latchText = res;
      _latchManual = res.contains('exp');
      if (!_latchManual) {
        // No manual sensor: lowest EV CameraX allows.
        _latchEv = await c.setExposureOffset(_minExposureOffset);
      }
    } catch (e) {
      _latchText = 'latch failed: $e';
    }
    debugPrint('Far-bright latch on: $_latchText');
    if (mounted) setState(() {});
  }

  /// v11.46: plain automatic exposure (no manual sensor values, no AE
  /// lock, no stale tap/AE point); EV back to the mode's own value.
  Future<void> _restoreAutoExposure() async {
    if (_brightApplied) {
      await _releaseLatch();
      return;
    }
    _bright.reset();
    try {
      await CameraExtras.clearManual();
      await _focus.reset();
      final c = _controller;
      if (c != null && c.value.isInitialized) {
        try {
          await c.setExposureMode(ExposureMode.auto);
        } catch (_) {}
      }
      await _applyNightExposure();
    } catch (e) {
      debugPrint('Auto exposure restore failed: $e');
    }
  }

  Future<void> _releaseLatch() async {
    if (!_brightApplied) return;
    _brightApplied = false;
    _bright.reset();
    _latchManual = false;
    _latchMeterPoint = null;
    _latchEv = 0;
    try {
      await CameraExtras.clearManual();
      // v11.39: auto exposure back on for sure (no AE lock, EV restored).
      final c = _controller;
      if (c != null && c.value.isInitialized) {
        try {
          await c.setExposureMode(ExposureMode.auto);
        } catch (_) {}
      }
      await _applyNightExposure();
    } catch (e) {
      debugPrint('Latch release failed: $e');
    }
    debugPrint('Far-bright latch off');
    if (mounted) setState(() {});
  }

  /// "Auto focus" chip: leave the latch; stays off until zoom < 3x.
  Future<void> _exitLatch() async {
    _latchSuppressed = true;
    await _releaseLatch();
  }

  /// Tap while latched: focus stays at infinity, only the shutter is
  /// re-metered for the tapped area (mapped through the zoom crop).
  void _latchTap(Offset local, PreviewGeometry geometry) {
    final p = tapToPreviewPoint(local, geometry);
    if (p == null) return;
    final cp = frameToCrop(p, _digitalZoom);
    setState(() {
      _latchMeterPoint = Offset(
        cp.dx.clamp(0.0, 1.0).toDouble(),
        cp.dy.clamp(0.0, 1.0).toDouble(),
      );
    });
    _latchStep = null;
    _showToast('Exposure set here · focus stays far');
  }

  /// Active lens for the overlay: telephoto vs main crop.
  String get _activeLensText {
    final id = _overlayInfo['activePhysicalId'] as String?;
    final main = _lensCheck.seen['1'];
    if (id == null) return 'lens ? (no physical id)';
    if (main == null) return 'lens $id (1x lens not checked yet)';
    if (id == main) {
      return _cameraZoom >= 2
          ? 'MAIN camera cropped (id $id)'
          : 'main (id $id)';
    }
    return 'TELEPHOTO in use (id $id)';
  }

  ({bool lowEnd, String reason}) get _cameraClass {
    final o = _optical;
    final ps = _controller?.value.previewSize;
    return classifyCamera(
      backFactors: o.allFactors,
      sensorCropFactor: o.sensorCropFactor,
      previewLongSide: ps == null ? 0 : math.max(ps.width, ps.height).round(),
      hardwareMax: _range.hardwareMax,
    );
  }

  /// v11.36 live debug overlay lines (key builds).
  List<String> _overlayLines() {
    final info = _overlayInfo;
    final cls = _cameraClass;
    final sp = _lastSpot;
    final tp = _focus.point;
    final exp = info['exposureNs'] as num?;
    final ln = _ladder;
    return [
      'Zoom mode ${_zoomModeActive ? 'ON' : (_zoomMode ? 'on (inactive)' : 'off')} · ${cls.reason}',
      'lenses ${_optical.allFactors.map((f) => f.toStringAsFixed(1)).join('/')} · hw max ${_range.hardwareMax.toStringAsFixed(1)}x',
      sp == null
          ? 'bright –'
          : 'bright area ${(sp.area * 100).toStringAsFixed(1)}% rest ${sp.restMean.round()} top ${sp.top}',
      'latch ${_brightApplied ? 'ON' : (_latchSuppressed ? 'off (Auto focus)' : 'off')}'
          '${_brightApplied ? (_latchManual ? ' · ours 1/${(1e9 / _latchNs).round()}s ISO $kLatchIso top $_latchTop' : ' · EV ${_latchEv.toStringAsFixed(1)}') : ''}',
      'exp ${exp == null ? '?' : '1/${(1e9 / exp).round()}s'} ISO ${info['iso'] ?? '?'} · EV range [${_minExposureOffset.toStringAsFixed(1)}..${_maxExposureOffset.toStringAsFixed(1)}]',
      'focus ${info['afMode'] ?? info['afState'] ?? '?'} dist ${info['focusDistance'] ?? '?'}',
      'tap ${tp == null ? '–' : '(${tp.dx.toStringAsFixed(2)}, ${tp.dy.toStringAsFixed(2)})'}'
          '${_latchMeterPoint == null ? '' : ' · meter (${_latchMeterPoint!.dx.toStringAsFixed(2)}, ${_latchMeterPoint!.dy.toStringAsFixed(2)})'}',
      '${formatZoom(_zoom)}x = camera ${_cameraZoom.toStringAsFixed(2)}x × crop ${_digitalZoom.toStringAsFixed(2)}x',
      _activeLensText,
      '${_track.debugText} · ladder ${ln == null ? 'none' : (ln.shots.isEmpty ? 'empty' : ln.shots.map((e) => '${formatZoom(e.checkpoint)}${ln.isClear(e) ? '✓' : '✗'}').join(','))}',
      'chain ${_ladderDbg ?? '–'} · last zoom ${_zoomSendDbg ?? '–'}',
    ];
  }

  void _syncOverlayTimer() {
    final want = AiConfig.hasEmbeddedApiKey && _overlayOn && _cameraReady;
    if (!want) {
      _overlayTimer?.cancel();
      _overlayTimer = null;
      return;
    }
    _overlayTimer ??= Timer.periodic(const Duration(milliseconds: 700), (
      _,
    ) async {
      if (!mounted) return;
      final info = await CameraExtras.info();
      final slot = lensCheckSlot(_cameraZoom);
      if (slot != null &&
          _lensCheck.record(slot, info['activePhysicalId'] as String?)) {
        unawaited(_savePref(kLensCheckKey, _lensCheck.encode()));
      }
      if (mounted) setState(() => _overlayInfo = info);
    });
  }

  bool get _showZoomModeChip =>
      _cameraReady &&
      !_initializing &&
      _lens == CameraLensDirection.back &&
      _shootMode == ShootMode.photo &&
      !_macroActive &&
      !_processingCapture &&
      _range.displayMax > kNormalZoomMax + 0.5;

  Widget _buildDebugOverlay() {
    _syncOverlayTimer();
    if (!_overlayOn) {
      return GestureDetector(
        onTap: () => setState(() {
          _overlayOn = true;
          _syncOverlayTimer();
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          color: Colors.black54,
          child: const Text(
            'Debug',
            style: TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: () => setState(() {
        _overlayOn = false;
        _syncOverlayTimer();
      }),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.all(4),
        color: Colors.black54,
        child: Text(
          _overlayLines().join('\n'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9,
            height: 1.2,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  /// v11.36 debug note (photo info), same values as the overlay.
  Future<String> _zoomDebugLine() async {
    _overlayInfo = await CameraExtras.info();
    return [
      ..._overlayLines(),
      lensInfoText(_overlayInfo),
      _lensCheck.text,
    ].join(' | ');
  }

  /// v11.35: record which physical lens is active at 1x / 3x / 10x.
  void _scheduleLensCheck() {
    _lensTimer?.cancel();
    _overlayTimer?.cancel();
    _overlayTimer = null;
    if (lensCheckSlot(_cameraZoom) == null ||
        _lens != CameraLensDirection.back) {
      return;
    }
    _lensTimer = Timer(const Duration(milliseconds: 800), () async {
      final slot = lensCheckSlot(_cameraZoom);
      if (slot == null || !mounted) return;
      final info = await CameraExtras.info();
      if (_lensCheck.record(slot, info['activePhysicalId'] as String?)) {
        unawaited(_savePref(kLensCheckKey, _lensCheck.encode()));
        debugPrint('Lens check: ${_lensCheck.text}');
      }
    });
  }

  Future<void> _loadLensCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lensCheck = LensCheck.decode(prefs.getString(kLensCheckKey));
    } catch (_) {}
  }

  ZoomRulerScale get _rulerScale =>
      ZoomRulerScale(min: _range.minZoom, max: _userZoomMax);

  void _openRuler() {
    if (!_cameraReady || _range.displayMax <= _range.minZoom + 0.01) return;
    setState(() => _rulerOpen = true);
    _bumpRuler();
  }

  /// Keeps the ruler open while touched; hides 2.5 s after the last touch.
  void _bumpRuler() {
    _rulerTimer?.cancel();
    _rulerTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _rulerOpen = false);
    });
  }

  void _onPillDragStart() {
    _rulerDragZoom = _zoom;
    _rulerDragDx = 0;
    _openRuler();
  }

  void _onPillDragUpdate(double dx) {
    _rulerDragDx += dx;
    final w = MediaQuery.of(context).size.width;
    _setZoomUser(
      _rulerScale.scrub(
        from: _rulerDragZoom,
        dx: _rulerDragDx,
        extent: w * ZoomRuler.extentFactor,
      ),
    );
    _bumpRuler();
  }

  String _friendlyCameraError(CameraException e) {
    switch (e.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
        return 'Camera permission denied. Enable it in Settings, or use Gallery.';
      case 'CameraAccessRestricted':
        return 'Camera access is restricted on this device.';
      default:
        return 'Camera error (${e.code}): ${e.description ?? "unknown"}';
    }
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _busyForUi) return;
    final next = _lens == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    if (_bokeh != null) {
      // Native Portrait: restart the bokeh session on the other lens (or
      // fall back to the Flutter camera + note if it has no bokeh).
      await _stopBokeh(reopen: false);
      if (!mounted) return;
      setState(() => _lens = next);
      final ok = await BokehBridge.available(
        front: next == CameraLensDirection.front,
      );
      if (!mounted) return;
      if (ok) {
        await _startBokeh();
      } else {
        await _setupCamera();
      }
      return;
    }
    final target = _cameras.firstWhere(
      (c) => c.lensDirection == next,
      orElse: () => _cameras.first,
    );
    setState(() {
      _initializing = true;
      _lens = next;
      // Reset zoom state; real range is re-read for the new lens.
      _zoom = 1.0;
      _cameraZoom = 1.0;
      _digitalZoom = 1.0;
      _range = ZoomRange.none;
      _optical = OpticalProfile.fallback;
      _chips = ZoomChipSet.single;
      _pendingZoom = null;
    });
    try {
      await _openController(target);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Could not switch camera.\n$e';
      });
    }
    unawaited(_syncModeHardware());
  }

  bool get _busyForUi =>
      _initializing ||
      _setupLocked ||
      _processingCapture ||
      _bokehBusy ||
      (_bokeh == null && !(_controller?.value.isInitialized ?? false));

  /// Waits (briefly) until the last setZoomLevel has been applied so the
  /// still matches what is on screen.
  Future<void> _waitZoomSettled() async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 600));
    while ((_zoomInFlight || _pendingZoom != null) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  // ---------------------------------------------------------------------------
  // Shutter (+ self-timer)
  // ---------------------------------------------------------------------------

  bool get _cameraReady => _controller?.value.isInitialized ?? false;

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (_countdown != null && mounted) setState(() => _countdown = null);
  }

  /// Shutter tap: self-timer countdown first when set (tap again to cancel).
  void _onShutter() {
    if (_nightCountdown != null) {
      _cancelNightCountdown();
      return;
    }
    if (_countdown != null) {
      _cancelCountdown();
      return;
    }
    final route = _route;
    if (route.blocked) {
      _showBlockedNote(route.block);
      return;
    }
    // v11.48: no timer in Macro (no menu there).
    if (_timer == TimerChoice.off ||
        _macroActive || // v11.50: no timer in Macro (no menu there)
        !_cameraReady ||
        _processingCapture) {
      unawaited(_capture());
      return;
    }
    setState(() => _countdown = _timer.seconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final next = (_countdown ?? 1) - 1;
      if (next <= 0) {
        t.cancel();
        _countdownTimer = null;
        setState(() => _countdown = null);
        unawaited(_capture());
      } else {
        setState(() => _countdown = next);
      }
    });
  }

  /// Shutter ONLY (no background / zoom-time capture): full-res still at the
  /// camera's real (clamped) zoom, then crop exactly the on-screen region.
  Future<void> _capture() async {
    final route = _route;
    if (route.blocked) {
      _showBlockedNote(route.block);
      return;
    }
    if (_bokeh != null) {
      await _captureBokeh();
      return;
    }
    final c = _controller;
    if (c != null && c.value.isInitialized && !c.value.isTakingPicture) {
      if (_processingCapture || _captureLock) return;
      if (_shootMode == ShootMode.document) {
        await _scanDocument();
        return;
      }
      // v11.33 Macro: pick a level. v11.40: the box check only gives soft
      // hints — it never blocks the shutter.
      if (route.capture == CaptureKind.macroBurst && _macroLevel == null) {
        _snack(kPickMacroLevel);
        return;
      }
      // v11.59: Pro AI with no working internet → the exact message right
      // away, no capture / spinner, nothing charged (Normal is untouched).
      if (_aiMode && !NetworkCheck.instance.recentlyOnline) {
        _captureLock = true;
        bool ok;
        try {
          ok = await _aiReachable();
        } finally {
          _captureLock = false;
        }
        if (!mounted) return;
        if (!ok) {
          _snack(kCheckInternet);
          return;
        }
      }
      await _awaitContextSnap();
      if (!mounted) return;
      _captureLock = true;
      try {
        // v11.42: above 10x wait (≤1.5 s) until the phone is still ~0.3 s.
        await _waitSteady();
        if (!mounted) return;
        if (route.capture == CaptureKind.nightBurst) {
          await _captureNight(c);
        } else {
          // Live analysis pauses for the still / bracket / merge and while
          // the preview screen is open (frames skipped, stream kept).
          await _vision.pause(keepStream: true);
          await _captureWith(c, route);
        }
      } finally {
        _captureLock = false;
        if (mounted) unawaited(_vision.resume());
      }
      return;
    }

    if (_permissionDenied || _error != null) {
      _snack('Camera not ready — open Gallery or tap Retry');
      return;
    }
    if (_initializing || _bokehBusy) return;

    await _pickFromGallery(source: ImageSource.camera);
  }

  /// v11.59: AI reachable (or no AI configured → nothing to check).
  Future<bool> _aiReachable() async {
    final acct = AccountService.instance;
    final url = await acct.serverUrl();
    if (url.isEmpty && !AiConfig.hasEmbeddedApiKey) return true;
    NetworkCheck.instance.serverHost = url.isEmpty
        ? null
        : Uri.tryParse(url)?.host;
    return NetworkCheck.instance.online();
  }

  /// What is on screen at the moment of the tap.
  _ShotSnap _snap() => _ShotSnap(
    ratio: _ratio,
    digital: _digitalZoom,
    zoom: _zoom,
    mode: _mode,
    optical: _optical,
    tier: _effTier,
    // v11.50: only Macro has no menu → no filters / styles / looks there.
    aiFilter: _mode == CaptureMode.pro && !_macroActive ? _aiFilter : null,
    pending: _macroActive ? null : _pendingLook,
    premium: _macroActive ? PremiumFilter.original : _premium,
    strength: _strength,
  );

  /// Single / HDR / Macro (+ PRO AI Portrait = single + AI bokeh).
  Future<void> _captureWith(CameraController c, ModeRoute route) async {
    var snap = _snap();
    final hdr = route.capture == CaptureKind.hdrBracket;
    final macro = route.capture == CaptureKind.macroBurst;
    final level = macro ? _macroLevel : null;
    String? subject;
    String? microSpot; // v11.47 Microscope detected spot
    String? captureNote;
    setState(() {
      _processingCapture = true;
      _holdSteady = hdr;
      _afterFrames = false;
    });
    String shotPath;
    (double, double)? finalFrac;
    // v11.30 100x flow: cheap phones send ladder references, flagships one
    // photo only.
    final flow = !macro && !hdr && route.aiMode == 'photo' && _zoomModeActive
        ? zoomFlowFor(ai: snap.ai, lowEnd: _macroLowEnd, zoom: snap.zoom)
        : ZoomFlow.normal;
    if (flow == ZoomFlow.ladder) await _awaitLadderShot();
    // v11.9 coverage kept: Pro AI Zoom mode at ≥ 2x on cheap phones.
    final nativeZoomMerge =
        snap.ai &&
        _zoomModeActive &&
        shouldMergeZoom(
          lowEnd: _macroLowEnd,
          zoom: snap.zoom,
          opticalLimit: snap.optical.opticalLimit,
        );
    // v11.60: the tracked view at the shutter (fresh + valid only).
    // Same device orientation + a verified still rotation required.
    final trackOk =
        flow == ZoomFlow.ladder &&
        _trackFresh &&
        _trackRot != null &&
        _controller?.value.deviceOrientation == _trackOrient;
    final trackAtShutter = trackOk ? _track.rootToCur : null;
    final trackRot = _trackRot ?? 0;
    // v11.35 debug note on all phones (key builds): bright / EV / tap /
    // camera × crop / lens, read at the shutter.
    final zoomDbg =
        AiConfig.hasEmbeddedApiKey && snap.ai && route.aiMode == 'photo'
        ? await _zoomDebugLine()
        : null;
    try {
      await _waitZoomSettled();
      if (hdr) {
        shotPath = await _takeHdr(c, (note) => captureNote = note);
      } else if (macro) {
        var (path, note, crop) = await _takeMacro(c);
        String? lockName;
        String? lockPart;
        if (level != null && level.isMicroscopic) {
          // v11.58: lock the object at 1.5x, detect only its part at the
          // high zoom; mismatch → "Hold steady" + retake.
          final co = await _coordinatedMicro(c, path, note, crop);
          path = co.path;
          note = co.note;
          crop = co.crop;
          lockName = co.lock;
          lockPart = co.part;
          if (!mounted) return;
          final fail = co.fail;
          if (fail != null || lockName == null || lockPart == null) {
            // v11.59 F6: fail closed — no AI call, nothing charged.
            setState(() {
              _processingCapture = false;
              _holdSteady = false;
              _nightStage = null;
            });
            _snack(fail ?? kMicroNoMatch);
            return;
          }
        }
        shotPath = path;
        captureNote = note;
        // The still was taken at the optical limit: crop the user's region
        // from it at real pixels.
        snap = snap.withDigital(crop);
        // v11.39: Macro / Close / Microscope use general prompts — no
        // cloud subject detection. Extreme / Ultra try ONE detection on the
        // box area; v11.40: unclear → no refusal, the zoomed view (+ context
        // photos) is sent instead of the spot text.
        if (level != null && level.isMicroscopic && lockName != null && lockPart != null) {
          // v11.58: locked object + its part → material-aware text prompt.
          microSpot = lockPart;
          subject = lockName;
        } else {
          subject = kMacroGeneralSubject;
        }
        if (!mounted) return;
      } else if (route.capture == CaptureKind.single &&
          route.aiMode == 'photo' &&
          _shootMode == ShootMode.photo &&
          (!_aiMode || _zoomModeActive) &&
          _macroLowEnd &&
          _lens == CameraLensDirection.back &&
          (snap.digital > 1.2 || nativeZoomMerge)) {
        // v11.60 cheap phones: digitally zoomed (Normal, offline too) or a
        // Pro AI Zoom-mode shot at 2x … native max (v11.9 merge coverage,
        // now banded). Short adaptive burst, aligned robust denoise merge.
        final b = await _zoomBurst(c, snap, nativeZoom: nativeZoomMerge);
        shotPath = b.path;
        captureNote = b.note;
        if (b.frac != null) {
          finalFrac = b.frac;
          snap = snap.withDigital(1.0);
        }
      } else {
        shotPath = await _takeSingle(c);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processingCapture = false;
          _holdSteady = false;
        });
        _snack('Capture failed: $e');
      }
      return;
    }
    if (!mounted) return;
    if (zoomDbg != null) {
      captureNote = captureNote == null ? zoomDbg : '$captureNote · $zoomDbg';
    }
    await _openPreview(
      shotPath,
      snap,
      captureNote: captureNote,
      aiModeId: snap.ai ? route.aiMode : 'photo',
      subject: subject,
      // v11.47 Microscope: part = detected spot only (none → photo flow).
      part: (level?.isMicroscopic ?? false) ? microSpot : subject,
      spotSource: macro ? _detector.lastSpotModel : null,
      macroLevel: level,
      zoomFlow: flow,
      trackAtShutter: trackAtShutter,
      trackRot: trackRot,
      finalFrac: finalFrac,
    );
  }

  /// v11.60 the final visible region as fractions of the still.
  (double, double)? _finalFrac(CaptureCropResult crop) {
    final r = crop.crop, w = crop.sourceWidth, h = crop.sourceHeight;
    if (r == null || w == null || h == null || w <= 0 || h <= 0) return null;
    return (r.width / w, r.height / h);
  }

  /// Crop to the on-screen region, then the preview screen.
  Future<void> _openPreview(
    String shotPath,
    _ShotSnap snap, {
    String? captureNote,
    String? nightNote,
    bool aiNight = false,
    String aiModeId = 'photo',
    String? subject,
    String? part,
    String? spotSource,
    MacroLevel? macroLevel,
    CaptureMode? modeOverride,
    ZoomFlow zoomFlow = ZoomFlow.normal,
    Similarity? trackAtShutter,
    int trackRot = 0,
    (double, double)? finalFrac,
  }) async {
    setState(() {
      _processingCapture = true;
      _holdSteady = false;
    });
    // v11.59 sharp-source zoom: CLEAR checkpoint photos only (best first);
    // each is cut at the final area × kZoomSourceMargin and aligned to the
    // final area after the crop below.
    // v11.60: TRACKED clear references only (the final region is located in
    // each through the tracking chain, then strictly verified).
    final ladderRefs = zoomFlow == ZoomFlow.ladder
        ? (_ladder?.sourceCandidates(snap.zoom) ?? const <LadderShot>[])
              .where((s) => s.rootToRef != null && File(s.path).existsSync())
              .toList()
        : const <LadderShot>[];
    final ctxSnap =
        snap.ai &&
            zoomFlow == ZoomFlow.normal &&
            modeOverride != CaptureMode.normal &&
            aiModeId == 'photo' &&
            useSnapshot(_ctxSnap, snap.zoom) &&
            File(_ctxSnap!.path).existsSync()
        ? _ctxSnap
        : null;
    final hint = _microHint;
    final microHint =
        aiModeId == 'macro' &&
            snap.ai &&
            macroLevel == MacroLevel.microscope &&
            hint != null &&
            File(hint.path).existsSync() &&
            snapshotRegionZoom(snap.zoom, hint.cameraZoom) > 1.05
        ? hint
        : null;
    // v11.40: wider context photos (Macro / Close / Extreme / Ultra).
    final macroCtx = aiModeId == 'macro' && snap.ai
        ? [
            for (final s in _macroCtx)
              if (File(s.path).existsSync() &&
                  snapshotRegionZoom(snap.zoom, s.cameraZoom) >=
                      kMacroCtxMinWider)
                s,
          ]
        : const <ContextSnapshot>[];
    CaptureCropResult crop;
    try {
      crop = await processCapture(
        shotPath,
        portraitRatio: snap.ratio.portrait,
        label: snap.digital > 1.001
            ? '${snap.ratio.label}_z${(snap.digital * 10).round()}'
            : snap.ratio.label,
        digitalZoom: snap.digital,
        // Context image only matters when the AI will see this shot.
        writeContext: snap.ai && modeOverride != CaptureMode.normal,
        // v11.5 Macro: crop + full frame with the region boxed.
        macroBox: aiModeId == 'macro' && snap.ai,
        // v11.9: sharp low-zoom snapshot with the zoomed region boxed.
        snapshotPath: ctxSnap?.path,
        snapshotZoom: ctxSnap == null
            ? 1.0
            : snapshotRegionZoom(snap.zoom, ctxSnap.cameraZoom),
        // v11.33 Microscope: the free 1x–2x hint photo (cropped); 100x
        // ladder: its references.
        // v11.46: step photos (all levels) win over the Microscope hint.
        stepPhotos: macroCtx.isNotEmpty
            ? [
                for (final s in macroCtx)
                  (s.path, snapshotRegionZoom(snap.zoom, s.cameraZoom)),
              ]
            : microHint != null
            ? [
                (
                  microHint.path,
                  snapshotRegionZoom(snap.zoom, microHint.cameraZoom),
                ),
              ]
            : const [],
        // v11.42: context photos cut to ~2.5x the main shot's area (really
        // wider, never nearly the same area). v11.60: ladder references are
        // cut at their TRACKED region below, not at the centre here.
        stepCropMargin: macroCtx.isNotEmpty
            ? kMacroCtxMargin
            : microHint == null
            ? 0
            : kLadderRefMargin,
      );
    } catch (e) {
      debugPrint('Crop failed, using original: $e');
      crop = CaptureCropResult(path: shotPath);
    } finally {
      if (mounted) {
        setState(() {
          _processingCapture = false;
          _holdSteady = false;
        });
      }
    }
    // v11.59 sharp-source zoom (cheap phones): the sharpest matching clear
    // checkpoint photo, aligned to the final area, becomes the AI's source;
    // the final is the framing reference only. Past the phone's clear limit
    // with no usable match → no AI call, nothing charged (fail closed).
    // v11.61: the low-zoom ROOT (+ clear tracked steps) are the sources; no
    // "final is sharp enough" exemption past the clear limit; the real
    // pixels of the root's region decide the "Beyond clear range" label and
    // an absurdly tiny region fails closed.
    File? zoomSource;
    String? zoomLabel;
    if (zoomFlow == ZoomFlow.ladder) {
      final l = _ladder;
      final root = l?.root;
      final clearLim = _pixelClearLimit;
      final beyond = beyondClearRange(snap.zoom, clearLim);
      var finalClear = false;
      if (l != null && l.shots.isNotEmpty && !beyond) {
        try {
          finalClear = isClearPhoto(
            await photoSharpness(shotPath),
            l.refSharpness,
          );
        } catch (_) {}
      }
      final need = zoomNeedsSource(
        ladderFlow: true,
        zoom: snap.zoom,
        opticalLimit: snap.optical.opticalLimit,
        clearLimit: _clearLimit,
        finalClear: finalClear,
      );
      // Real pixels of the final framing inside the root (estimate from its
      // zoom; the tracked crop below measures the real region).
      final rootPx = root == null || _rootStillLong == null
          ? null
          : realRoiPx(
              stillLong: _rootStillLong!,
              label: root.zoomLabel,
              finalZoom: snap.zoom,
            );
      final tiny = rootPx != null && roiTooTiny(rootPx);
      // v11.60: the final region inside each clear reference comes from the
      // accumulated tracking (never the centre of a whole-frame guess).
      // No valid track → no candidates → fails closed when a source is
      // needed.
      final frac = finalFrac ?? _finalFrac(crop);
      TrackedCandidates? tc;
      final aspect = _track.rootAspect;
      if (!tiny &&
          trackAtShutter != null &&
          aspect != null &&
          frac != null &&
          ladderRefs.isNotEmpty) {
        try {
          tc = await trackedSourceCandidates(
            refs: ladderRefs,
            rootToCur: trackAtShutter,
            trackAspect: aspect,
            finalFrac: frac,
            shutterRot: trackRot,
            outDir: (await getTemporaryDirectory()).path,
          );
        } catch (e) {
          debugPrint('Tracked source failed: $e');
        }
      }
      final d = await pickZoomSource(
        finalAreaPath: crop.path,
        candidates: tc?.candidates ?? const [],
      );
      if (tc != null) deleteQuietly(tc.files);
      if (d.ok) zoomSource = File(d.path!);
      final trackTxt = trackAtShutter == null
          ? _track.debugText
          : 'tracked ${tc?.notes.join(', ') ?? 'none'}';
      final failClosed = zoomFailClosed(ok: d.ok, need: need, tiny: tiny);
      final sent = d.ok
          ? 'sent source + final (framing only)'
          : failClosed
          ? 'sent nothing (${tiny
                ? 'roi tiny'
                : root == null
                ? 'no root'
                : 'no sharp source'})'
          : 'sent final only (${finalClear ? 'final clear' : 'within clear limit'})';
      final gate =
          'clear ≤${formatZoom(clearLim)}x${rootPx == null ? '' : ' roi ${rootPx.round()}px'}${beyond ? ' beyond' : ''}';
      _zoomSendDbg =
          '${l?.refsLabelText() ?? 'refs none'} · $trackTxt · ${d.debugText} · $gate · $sent';
      debugPrint('Zoom source: $_zoomSendDbg');
      if (AiConfig.hasEmbeddedApiKey) {
        final sz = ladderSizesFor(
          d.ok ? d.path! : crop.path,
          d.ok ? [crop.path] : const [],
        );
        final dbg = '$_zoomSendDbg · $sz';
        captureNote = captureNote == null ? dbg : '$captureNote · $dbg';
      }
      if (failClosed) {
        if (mounted) {
          setState(() => _processingCapture = false);
          _snack(zoomFailMessage(tiny: tiny, hasRoot: root != null));
        }
        return;
      }
      if (beyond) zoomLabel = kBeyondClearLabel;
    }
    if (!mounted) return;
    ZoomInfoService.lastCaptureCalibration = _calibrationLine(
      selected: snap.zoom,
      digital: snap.digital,
      ratio: snap.ratio,
      crop: crop,
    );
    debugPrint('Zoom calibration: ${ZoomInfoService.lastCaptureCalibration}');
    setState(() {
      _lastShot = File(crop.path);
      _pendingLook = null; // consumed by this photo
    });
    // v11.54: a video style waiting for this photo → its confirm sheet.
    final pv = _pendingVideo;
    if (pv != null) {
      setState(() => _pendingVideo = null);
      unawaited(_startVideoStyle(pv, photo: File(crop.path)));
      return;
    }
    final mode = modeOverride ?? snap.mode;
    // The level is always the zoom's (no blur step-down). v11.13 Extreme:
    // a tighter crop (centre ~1/3, upscaled to 1024).
    // v11.19 Extreme: ONLY the zoomed crop goes to the image AI (no step
    // photos, no boxed frame) — they made it copy the whole object.
    final extreme = macroLevel?.isDeep ?? false; // Extreme + Ultra
    if (!mounted) return;
    final ai = mode == CaptureMode.pro;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => PreviewScreen(
          imageFile: File(crop.path),
          // v11.30: the 100x flows send no wide context photo.
          contextFile:
              crop.contextPath == null ||
                  !ai ||
                  extreme ||
                  zoomFlow != ZoomFlow.normal
              ? null
              : File(crop.contextPath!),
          captureZoom: snap.zoom,
          opticalLimit: snap.optical.opticalLimit,
          mode: mode,
          tier: snap.tier,
          night: ai && aiNight,
          nightNote: nightNote,
          pendingLook: snap.pending,
          initialAiFilter: ai ? snap.aiFilter : null,
          initialFilter: snap.premium,
          initialStrength: snap.strength,
          aiMode: ai ? aiModeId : 'photo',
          subject: subject,
          part: part,
          spotSource: spotSource,
          subjectSure: aiModeId == 'macro' && (subject ?? '').isNotEmpty,
          contextBoxed: crop.contextBoxed,
          stepFiles:
              extreme ||
                  zoomFlow == ZoomFlow.flagshipSingle ||
                  zoomFlow == ZoomFlow.ladder
              ? const []
              : [for (final p in crop.stepPaths) File(p)],
          // v11.59: the ladder sends the aligned sharp source (+ the final
          // as framing), never the final first with references after it.
          zoomLadder: false,
          zoomSourceFile: zoomSource,
          zoomLabel: zoomLabel,
          zoomClean: zoomFlow != ZoomFlow.normal,
          macroLevel: macroLevel,
          captureNote: captureNote,
        ),
      ),
    );
    _afterFrames = false;
    if (!mounted) return;
    if (result == 'flash_on') _setNightFlashOn();
    // v11.27: X on the result → fully fresh Macro start at 1x.
    if (result == kPreviewClosed && _macroActive) unawaited(_freshMacroStart());
    // Re-bind preview after returning from preview screen.
    if (_bokeh == null &&
        !_bokehBusy &&
        (_controller == null || !_controller!.value.isInitialized)) {
      unawaited(_setupCamera());
    }
  }

  void _setNightFlashOn() {
    setState(() => _nightFlash = FlashChoice.on);
    unawaited(_savePref(_kNightFlashKey, _nightFlash.name));
    _showToast('Night · Flash on');
  }

  /// v11.60 zoom burst: [kBurstMinFrames]–[kBurstMaxFrames] stills while
  /// they fit [kBurstBudgetMs] (a slow capture ends it), only the zoomed
  /// region (+ margin) decoded, merged in a cancellable isolate. Returns
  /// the merged REGION (frac = its share of the still) or, when not
  /// merged, the first full still (frac null). Temporary files removed.
  Future<({String path, String? note, (double, double)? frac})> _zoomBurst(
    CameraController c,
    _ShotSnap snap, {
    bool nativeZoom = false,
  }) async {
    final ourAf = await _preCapture();
    final paths = <String>[];
    final sw = Stopwatch()..start();
    var lastMs = 0;
    (int, int)? size;
    CropRect? rect;
    if (mounted) setState(() => _holdSteady = true);
    try {
      while (burstWantsMore(
        taken: paths.length,
        elapsedMs: sw.elapsedMilliseconds,
        lastCaptureMs: lastMs,
      )) {
        if (!mounted || !identical(c, _controller) || !c.value.isInitialized) {
          break;
        }
        final t0 = sw.elapsedMilliseconds;
        try {
          paths.add((await c.takePicture()).path);
        } catch (e) {
          if (paths.isEmpty) rethrow;
          break;
        }
        lastMs = sw.elapsedMilliseconds - t0;
        if (paths.length == 1) {
          final sz = await uprightSize(paths.first);
          size = sz;
          final r = computeCaptureCrop(
            iw: sz.$1,
            ih: sz.$2,
            portraitRatio: snap.ratio.portrait,
            digitalZoom: snap.digital,
          );
          rect = r;
          if (!shouldBurstZoom(
            lowEnd: true,
            digital: snap.digital,
            regionPixels: r.width * r.height,
            plainPhoto: true,
            nativeZoom: nativeZoom,
          )) {
            break; // region too large for a safe merge → single shot
          }
        }
      }
    } finally {
      unawaited(_focus.afterCapture(ourAf));
      if (mounted) {
        setState(() {
          _holdSteady = false;
          _afterFrames = true;
        });
      }
    }
    final ms = sw.elapsedMilliseconds;
    final sz = size, r = rect;
    if (paths.length < 2 || sz == null || r == null || !mounted) {
      _deletePaths(paths.skip(1).toList());
      return (path: paths.first, note: null, frac: null);
    }
    final (iw, ih) = sz;
    final mx = (r.width * kBurstMargin).round();
    final my = (r.height * kBurstMargin).round();
    final ox = math.max(0, r.x - mx), oy = math.max(0, r.y - my);
    final ow = math.min(iw, r.x + r.width + mx) - ox;
    final oh = math.min(ih, r.y + r.height + my) - oy;
    final dir = (await getTemporaryDirectory()).path;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final out = '$dir/zoomburst_$stamp.jpg';
    try {
      // Banded merge in a killable isolate (native region decode per band:
      // memory stays bounded for full 2x … native-max frames).
      final job = await BurstJob.start(
        paths: paths,
        region: (ox, oy, ow, oh),
        inner: (r.x - ox, r.y - oy, r.width, r.height),
        outJpeg: out,
      );
      _burstJob = job;
      final res = await job.result;
      _burstJob = null;
      if (res == null) throw StateError('merge cancelled / failed');
      if (!mounted) {
        deleteQuietly([out, ...paths]);
        return (path: paths.first, note: null, frac: null);
      }
      final n = paths.length;
      if (res.timedOut || !File(out).existsSync()) {
        // Over budget: the sharpest frame's own full photo (no half merge).
        final keep = paths[res.anchor];
        _deletePaths([for (final p in paths) if (p != keep) p]);
        deleteQuietly([out]);
        return (
          path: keep,
          note: AiConfig.hasEmbeddedApiKey
              ? 'Zoom burst $n frames ${ms}ms · merge over time → sharpest'
              : 'Sharpest of $n',
          frac: null,
        );
      }
      _deletePaths(paths);
      final note = AiConfig.hasEmbeddedApiKey
          ? 'Zoom burst $n frames ${ms}ms · ${res.debugText}'
          : res.used >= 2
          ? 'Merged ${res.used} of $n frames'
          : 'Sharpest of $n';
      debugPrint('Zoom burst: $note');
      return (path: out, note: note, frac: (r.width / iw, r.height / ih));
    } catch (e) {
      debugPrint('Zoom burst merge failed: $e');
      deleteQuietly([out]);
      _deletePaths(paths.skip(1).toList());
      return (path: paths.first, note: 'Single frame', frac: null);
    }
  }

  Future<String> _takeSingle(CameraController c) async {
    // AF must converge before the still (CameraX's default low-latency
    // capture does not trigger AF itself).
    final ourAf = await _preCapture();
    try {
      return (await c.takePicture()).path;
    } finally {
      unawaited(_focus.afterCapture(ourAf));
    }
  }

  // ---- Portrait (NORMAL): phone's own bokeh ---------------------------------

  Future<void> _captureBokeh() async {
    if (_processingCapture || _captureLock || _bokehBusy) return;
    final snap = _snap();
    _captureLock = true;
    setState(() => _processingCapture = true);
    String? path;
    try {
      path = await BokehBridge.capture((await getTemporaryDirectory()).path);
    } catch (e) {
      if (mounted) _snack('Capture failed: $e');
    } finally {
      _captureLock = false;
      if (mounted) setState(() => _processingCapture = false);
    }
    if (path == null || !mounted) return;
    await _openPreview(path, snap, captureNote: 'Portrait · phone bokeh');
  }

  /// Hands the camera to the native BOKEH session (Flutter camera closed:
  /// one CameraX provider per app).
  Future<void> _startBokeh() async {
    if (_bokehBusy || _bokeh != null) return;
    _bokehBusy = true;
    final front = _front;
    try {
      final c = _controller;
      setState(() {
        _controller = null;
        _initializing = true;
      });
      await _focus.attach(null);
      await _vision.attach(null);
      await c?.dispose();
      final st = await BokehBridge.start(front: front);
      if (!mounted) {
        await BokehBridge.stop();
        return;
      }
      if (_shootMode != ShootMode.portrait || _aiMode || _front != front) {
        // Mode changed while starting.
        await BokehBridge.stop();
        _bokehBusy = false;
        await _setupCamera();
        return;
      }
      setState(() {
        _bokeh = st;
        _initializing = false;
        _error = null;
        _zoom = 1;
        _cameraZoom = 1;
        _digitalZoom = 1;
      });
    } catch (e) {
      debugPrint('Bokeh start failed: $e');
      BokehBridge.markUnavailable(front: front);
      _bokehBusy = false;
      if (mounted) {
        await _setupCamera();
        if (mounted) setState(() {});
      }
    } finally {
      _bokehBusy = false;
    }
  }

  Future<void> _stopBokeh({bool reopen = true}) async {
    if (_bokeh == null) return;
    _bokehBusy = true;
    try {
      setState(() {
        _bokeh = null;
        _initializing = true;
      });
      await BokehBridge.stop();
    } finally {
      _bokehBusy = false;
    }
    if (reopen && mounted) await _setupCamera();
  }

  /// Native bokeh session ⇄ Flutter camera, macro zoom, after any change of
  /// mode / tab / lens.
  Future<void> _syncModeHardware() async {
    if (!_zoomModeActive && (_brightApplied || _zoom > _userZoomMax + 0.01)) {
      unawaited(_leaveZoomMode());
    }
    final wantBokeh = _shootMode == ShootMode.portrait && !_aiMode;
    if (wantBokeh) {
      final ok = await BokehBridge.available(front: _front);
      if (!mounted) return;
      setState(() {}); // note / route depend on the probe
      if (ok &&
          _bokeh == null &&
          _shootMode == ShootMode.portrait &&
          !_aiMode) {
        await _startBokeh();
      }
    } else if (_bokeh != null) {
      await _stopBokeh();
    }
    if (!mounted) return;
    if (_macroActive) {
      // v11.33: Macro always opens at 1x with no level.
      setState(_resetMacroFlow);
      await _animateZoom(1.0);
    }
  }

  // ---- Night ------------------------------------------------------------------

  Timer? _nightTicker;
  Completer<bool>? _nightWait;

  void _cancelNightCountdown() {
    _nightTicker?.cancel();
    _nightTicker = null;
    final w = _nightWait;
    _nightWait = null;
    if (w != null && !w.isCompleted) w.complete(false);
    if (_nightCountdown != null && mounted) {
      setState(() => _nightCountdown = null);
    }
  }

  /// "Hold still" 1–3 s on the live preview. false = cancelled.
  Future<bool> _runNightCountdown(int seconds) {
    if (seconds <= 0) return Future.value(true);
    final w = _nightWait = Completer<bool>();
    setState(() => _nightCountdown = seconds);
    _nightTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        if (!w.isCompleted) w.complete(false);
        return;
      }
      final next = (_nightCountdown ?? 1) - 1;
      if (next <= 0) {
        t.cancel();
        _nightTicker = null;
        setState(() => _nightCountdown = null);
        if (!w.isCompleted) w.complete(true);
      } else {
        HapticFeedback.selectionClick();
        setState(() => _nightCountdown = next);
      }
    });
    return w.future;
  }

  Future<void> _captureNight(CameraController c) async {
    final snap = _snap();
    final pro = snap.ai;
    final flash = _lens == CameraLensDirection.back
        ? _nightFlash
        : FlashChoice.off;
    final plan = planNight(
      luma: _liveLuma,
      mode: snap.mode,
      flash: flash,
      maxExposureOffset: _maxExposureOffset,
    );
    debugPrint('Night plan: $plan (luma ${_liveLuma.toStringAsFixed(3)})');
    String path;
    String note;
    setState(() => _processingCapture = true);
    try {
      await _waitZoomSettled();
      if (plan.useFlash) {
        await _vision.pause();
        path = await _flashShot(c);
        note = 'Night · flash';
      } else {
        final go = await _runNightCountdown(plan.countdownSeconds);
        if (!go || !mounted) return;
        await _vision.pause();
        setState(() {
          _holdSteady = true;
          _nightStage = 'Hold still';
        });
        (path, note) = await _nightBurst(c, plan);
      }
    } catch (e) {
      if (mounted) _snack('Night capture failed: $e');
      return;
    } finally {
      if (mounted) {
        setState(() {
          _processingCapture = false;
          _holdSteady = false;
          _nightStage = null;
          _nightCountdown = null;
        });
      }
    }
    if (!mounted) return;
    if (pro) {
      // Pro Night darkness gate: no AI, no charge on a near-black frame.
      NightSignal? sig;
      try {
        sig = await nightSignalOf(await File(path).readAsBytes());
        debugPrint('Pro Night signal: $sig');
      } catch (e) {
        debugPrint('Night signal failed: $e');
      }
      if (!mounted) return;
      if (sig != null && sig.tooDark) {
        final choice = await showTooDarkSheet(context);
        if (!mounted) return;
        if (choice == TooDarkChoice.flashOn) {
          _setNightFlashOn();
        } else if (choice == TooDarkChoice.normalNight) {
          await _setMode(CaptureMode.normal);
          setState(() => _processingCapture = true);
          File bright;
          try {
            bright = await retoneNightBright(
              File(path),
              outDir: File(path).parent.path,
            );
          } catch (e) {
            debugPrint('Night retone failed: $e');
            bright = File(path);
          } finally {
            if (mounted) setState(() => _processingCapture = false);
          }
          if (!mounted) return;
          await _openPreview(
            bright.path,
            snap,
            nightNote: '$note · Normal Night',
            modeOverride: CaptureMode.normal,
          );
        }
        return;
      }
    }
    await _openPreview(
      path,
      snap,
      nightNote: note,
      aiNight: pro,
      aiModeId: pro ? 'night' : 'photo',
    );
  }

  /// Flash night shot (Flash On, or Auto in a very dark scene).
  Future<String> _flashShot(CameraController c) async {
    final ourAf = await _preCapture();
    try {
      try {
        await c.setFlashMode(FlashMode.always);
      } catch (_) {}
      return (await c.takePicture()).path;
    } finally {
      try {
        await c.setFlashMode(FlashMode.off);
      } catch (_) {}
      unawaited(_focus.afterCapture(ourAf));
    }
  }

  String _nightNote(int used, {bool manual = false}) => used > 1
      ? 'Night · $used frames merged${manual ? ' · long exposure' : ''}'
      : 'Night';

  /// 8–15 frame burst: native Camera2 (manual exposure where supported) →
  /// streaming align + merge + tone map. Falls back to a plugin burst +
  /// native merge, then the Dart merge.
  Future<(String, String)> _nightBurst(
    CameraController c,
    NightPlan plan,
  ) async {
    final desc = _description;
    final dir = (await getTemporaryDirectory()).path;
    final zoomSel = _zoom;
    final camZoom = _cameraZoom;
    if (!kIsWeb && Platform.isAndroid && desc != null) {
      setState(() {
        _controller = null;
        _initializing = true;
      });
      await _focus.attach(null);
      await _vision.attach(null);
      await c.dispose();
      NightMergeResult? r;
      try {
        r = await NightBridge.capture(
          cameraId: desc.name,
          plan: plan,
          zoom: camZoom,
          outDir: dir,
        );
        debugPrint('Native night: $r');
      } catch (e) {
        debugPrint('Native night failed, plugin fallback: $e');
      }
      if (mounted) setState(() => _nightStage = 'Processing');
      try {
        await _openController(desc);
        if (zoomSel != 1.0) await _setZoom(zoomSel);
      } catch (e) {
        debugPrint('Camera reopen after night failed: $e');
        if (mounted) unawaited(_setupCamera());
      }
      if (r != null) return (r.path, _nightNote(r.used, manual: r.manual));
    }
    final c2 = _controller;
    if (c2 == null || !c2.value.isInitialized) {
      throw StateError('Camera not ready');
    }
    return _pluginNightBurst(c2, plan, dir);
  }

  Future<(String, String)> _pluginNightBurst(
    CameraController c,
    NightPlan plan,
    String dir,
  ) async {
    final ourAf = await _preCapture();
    final paths = <String>[];
    try {
      if (plan.fallbackEv > 0) {
        try {
          await c.setExposureOffset(plan.fallbackEv);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        } catch (_) {}
      }
      final n = plan.frames.clamp(1, 8);
      for (var i = 0; i < n; i++) {
        if (!identical(c, _controller) || !c.value.isInitialized) break;
        try {
          paths.add((await c.takePicture()).path);
        } catch (e) {
          debugPrint('Night frame $i failed: $e');
          if (paths.isEmpty) rethrow;
          break;
        }
      }
    } finally {
      unawaited(_focus.afterCapture(ourAf));
      unawaited(_applyNightExposure());
    }
    if (mounted) setState(() => _nightStage = 'Processing');
    if (paths.length == 1) return (paths.first, 'Night');
    try {
      final r = await NightBridge.mergeJpegs(
        paths: paths,
        out: '$dir/night_merge_${DateTime.now().microsecondsSinceEpoch}.jpg',
        tone: plan.tone,
      );
      return (r.path, _nightNote(r.used));
    } catch (e) {
      debugPrint('Native merge failed, Dart merge: $e');
    }
    try {
      final r = await mergeNightFrames(paths, dir);
      return (r.path, _nightNote(r.used));
    } catch (e) {
      debugPrint('Night merge failed, using first frame: $e');
      return (paths.first, 'Night');
    }
  }

  // ---- Macro (PRO AI) v11.33: level chips + centre box -----------------------

  bool get _macroActive => _shootMode == ShootMode.macro && _aiMode;

  /// Max zoom for the macro levels: min(10x, device max) (v11.41).
  double get _macroMaxZoom => macroLevelMaxZoom(_range.hardwareMax);

  /// Smooth automatic zoom (~1 s, eased; never jumps). A pinch or a new
  /// animation stops it.
  // ---- v11.42 stability ------------------------------------------------------

  /// Chip tap: short eased ramp (~200 ms) instead of a jump. The cheap-phone
  /// ladder walk keeps its own path.
  void _onZoomChip(double v) {
    if (_ladderMode || (v - _zoom).abs() < 0.01) {
      _setZoomUser(v);
      return;
    }
    final target = v.clamp(_range.minZoom, _userZoomMax).toDouble();
    if (crossedTicks(_zoom, target, _chips.lensValues).isNotEmpty) {
      unawaited(HapticFeedback.selectionClick());
    }
    unawaited(_animateZoomTo(target, kChipZoomRamp));
  }

  bool get _steadyOn =>
      steadyActive(zoom: _zoom, back: _lens == CameraLensDirection.back);

  /// v11.61: the gyro is live and reports the phone still.
  bool get _gyroStill => _gyroSub != null && _steady.steadyAt(DateTime.now());

  /// Gyro only while above 10x on the back camera. v11.61: also in the
  /// cheap-phone zoom ladder (steady root photo + tracking past blur); the
  /// "Hold steady" hint and shutter wait still apply above 10x only.
  void _syncGyro() {
    if (_steadyOn || _ladderMode) {
      _gyroSub ??=
          gyroscopeEventStream(
            samplingPeriod: SensorInterval.gameInterval,
          ).listen(
            (e) {
              _steady.add(gyroMagnitude(e.x, e.y, e.z), DateTime.now());
              if (_steady.moving != _steadyMoving && mounted) {
                setState(() => _steadyMoving = _steady.moving);
              }
            },
            onError: (Object e) {
              debugPrint('Gyro unavailable: $e');
              _gyroSub?.cancel();
              _gyroSub = null;
            },
          );
    } else if (_gyroSub != null) {
      _gyroSub?.cancel();
      _gyroSub = null;
      _steady.reset();
      if (_steadyMoving && mounted) setState(() => _steadyMoving = false);
    }
  }

  /// Wait until still ~0.3 s (max 1.5 s; never blocks for good).
  Future<void> _waitSteady() async {
    if (!_steadyOn || _gyroSub == null) return;
    final start = DateTime.now();
    while (mounted) {
      final now = DateTime.now();
      if (shutterMayFire(
        steady: _steady.steadyAt(now),
        waited: now.difference(start),
      )) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> _loadDebugOverlay() async {
    if (!AiConfig.hasEmbeddedApiKey) return;
    try {
      final p = await SharedPreferences.getInstance();
      final on = p.getBool(kDebugOverlayKey) ?? false;
      if (!mounted) return;
      setState(() => _debugOverlay = on);
      if (on) {
        _startFpsMeter();
      } else {
        _stopFpsMeter();
      }
    } catch (_) {}
  }

  void _onTimings(List<FrameTiming> t) => _fpsFrames += t.length;

  void _startFpsMeter() {
    if (_debugTicker != null) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _fpsSince = DateTime.now();
    _fpsFrames = 0;
    _debugTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final dt = now.difference(_fpsSince).inMilliseconds / 1000;
      if (dt > 0) _uiFps = _fpsFrames / dt;
      _fpsFrames = 0;
      _fpsSince = now;
      if (mounted) setState(() {});
    });
  }

  void _stopFpsMeter() {
    if (_debugTicker == null) return;
    _debugTicker?.cancel();
    _debugTicker = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  Future<void> _animateZoom(double target) async {
    final gen = ++_zoomAnimGen;
    final path = smoothZoomPath(_zoom, target);
    for (final z in path) {
      if (gen != _zoomAnimGen || !mounted) return;
      await _setZoom(z);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  void _stopZoomAnim() => _zoomAnimGen++;

  /// Level chip tap (null = 1x, exit the level). Microscope first takes a
  /// free 1x–2x hint photo, then the level's start zoom (animated).
  Future<void> _selectMacroLevel(MacroLevel? level) async {
    if (!_macroActive || _processingCapture) return;
    _detector.cancelInFlight();
    setState(() {
      _macroLevel = level;
      _boxCheck.reset();
      _boxDbg = null;
    });
    if (level == null) {
      _dropMicroHint(); // v11.49: 1x chip = no level, zoom stays
      return;
    }
    _showToast(
      '${kMacroChipNames[level]} · 🪙${macroCreditsFor(level.id, quality: _macroTier.id)}',
    );
    // v11.49: a level chip never moves the zoom (no hint-photo zoom-out,
    // no start zoom); step photos at the shutter give the wider view.
    _dropMicroHint();
    if (!mounted || _macroLevel != level) return;
    // Safety only: stay within the macro max (min(10x, phone max)).
    final keep = macroLevelPickZoom(_zoom, _range.hardwareMax);
    if ((keep - _zoom).abs() > 0.01) await _animateZoom(keep);
    unawaited(_refocusCentre());
    unawaited(_maybeMicroscopeTip(level));
  }

  void _dropMicroHint() {
    final old = _microHint?.path;
    _microHint = null;
    if (old != null) {
      unawaited(File(old).delete().then((_) {}, onError: (_) {}));
    }
  }

  /// Free on-device box check (every analysis frame while a level is on).
  void _updateBoxCheck(FrameStats s) {
    if (!_macroActive || _macroLevel == null || _processingCapture) return;
    final changed = _boxCheck.update(s);
    if (changed || AiConfig.hasEmbeddedApiKey) setState(() {});
  }

  // v11.59 F6: the old detect-only Microscope fallback was removed (it ran
  // an AI flow without a 1.5x lock / match); Microscope now fails closed.

  void _dropMicroLock() {
    final l = _microLock;
    _microLock = null;
    if (l != null) unawaited(File(l.path).delete().then((_) {}, onError: (_) {}));
  }

  /// v11.58: name + LOCK the object in the 1.5x photo. A recent lock is
  /// reused (no new call) while the 1.5x photo still shows the same thing.
  Future<String?> _lockMicroObject(ContextSnapshot half) async {
    final prev = _microLock;
    if (prev != null &&
        DateTime.now().difference(prev.at) < kMicroLockReuse &&
        File(prev.path).existsSync()) {
      try {
        final s = await checkpointMatch(prev.path, prev.cameraZoom, half.path, half.cameraZoom);
        if (isSameSubject(s)) return prev.name;
      } catch (_) {}
    }
    if (mounted) setState(() => _nightStage = 'Checking…');
    try {
      final name = await _detector.detectSubjectTimed(File(half.path));
      if (!isUsableLock(name)) return null;
      final copy = '${half.path}_lock.jpg';
      await File(half.path).copy(copy);
      _dropMicroLock();
      _microLock = MicroLock(
        name: name!,
        path: copy,
        cameraZoom: half.cameraZoom,
        at: DateTime.now(),
        others: _detector.lastOthers,
      );
      return name;
    } catch (e) {
      debugPrint('Microscope lock failed: $e');
      return null;
    } finally {
      if (mounted) setState(() => _nightStage = null);
    }
  }

  /// v11.58 coordinated Microscope / Extreme / Ultra detection: lock at
  /// 1.5x → part only at the high zoom → frames must match, otherwise
  /// "Hold steady" and retake (max [kMicroRetakes]). No lock / still no
  /// match → lock null (the older photo / box flow runs; never a wrong
  /// name).
  /// v11.59 F6: fails CLOSED — no 1.5x photo, no lock, a comparison error
  /// or still no match after the retakes → [fail] is set and the caller
  /// makes no AI call (nothing charged), never the old detect-only flow.
  Future<
    ({
      String path,
      String note,
      double crop,
      String? lock,
      String? part,
      String? fail,
    })
  >
  _coordinatedMicro(
    CameraController c,
    String path,
    String note,
    double crop,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final half = _microOneHalf;
      if (half == null || !File(half.path).existsSync()) {
        _boxDbg = 'lock - (no 1.5x photo)';
        return (
          path: path,
          note: note,
          crop: crop,
          lock: null,
          part: null,
          fail: kMicroNoLock,
        );
      }
      final lock = await _lockMicroObject(half);
      if (lock == null) {
        _boxDbg = 'lock - (${_detector.lastReason})';
        return (
          path: path,
          note: note,
          crop: crop,
          lock: null,
          part: null,
          fail: kMicroNoLock,
        );
      }
      var score = 0.0;
      var matchError = false;
      try {
        score = await checkpointMatch(
          half.path,
          half.cameraZoom,
          path,
          _macroShotCamera,
        );
      } catch (e) {
        matchError = true; // no evidence → mismatch (fail closed)
        debugPrint('Microscope match failed: $e');
      }
      PartResult? pr;
      String? boxed;
      if (mounted) setState(() => _nightStage = 'Checking…');
      try {
        boxed = await writeZoomBoxed(path, crop);
        pr = await _detector.detectPart(
          File(half.path),
          File(boxed),
          lock,
          others: _microLock?.others ?? const [],
        );
      } catch (e) {
        debugPrint('Microscope part check failed: $e');
      } finally {
        if (boxed != null && boxed != path) {
          unawaited(File(boxed).delete().then((_) {}, onError: (_) {}));
        }
        if (mounted) setState(() => _nightStage = null);
      }
      final mismatch =
          matchError ||
          microFrameMismatch(pixelScore: score, inScene: pr?.sameSubject);
      _boxDbg =
          'lock $lock · part ${pr?.part ?? '-'} · match ${score.toStringAsFixed(2)}'
          '${mismatch ? ' · retake ${attempt + 1}' : ''}';
      debugPrint('Microscope: $_boxDbg');
      if (!mismatch) {
        return (
          path: path,
          note: '$note · locked: $lock',
          crop: crop,
          lock: lock,
          part: microPartText(pr?.part, lock),
          fail: null,
        );
      }
      if (attempt >= kMicroRetakes || !mounted || !identical(c, _controller)) {
        return (
          path: path,
          note: '$note · frames did not match',
          crop: crop,
          lock: null,
          part: null,
          fail: kMicroNoMatch,
        );
      }
      // Frames do not match → "Hold steady" and retake.
      _showToast(kMicroHoldSteady);
      setState(() {
        _holdSteady = true;
        _nightStage = kMicroHoldSteady;
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      unawaited(File(path).delete().then((_) {}, onError: (_) {}));
      final r = await _takeMacro(c);
      path = r.$1;
      note = r.$2;
      crop = r.$3;
    }
  }

  /// v11.27: X on the result → fresh Macro start at 1x (no level).
  Future<void> _freshMacroStart() async {
    _resetMacroFlow();
    if (mounted) setState(() {});
    await _animateZoom(1.0);
  }

  void _resetMacroFlow() {
    _detector.cancelInFlight();
    _dropMicroLock();
    _macroLevel = null;
    _boxCheck.reset();
    _dropMicroHint();
    _dropMacroCtx();
  }

  void _dropMacroCtx() {
    final half = _microOneHalf;
    _microOneHalf = null;
    if (half != null) {
      unawaited(File(half.path).delete().then((_) {}, onError: (_) {}));
    }
    final old = _macroCtx;
    _macroCtx = const [];
    for (final s in old) {
      unawaited(File(s.path).delete().then((_) {}, onError: (_) {}));
    }
  }

  /// v11.40: up to 2 wider context photos below the shot zoom (widest
  /// first). Fail-safe: any error → fewer / no context photos.
  Future<List<ContextSnapshot>> _takeMacroContext(
    CameraController c,
    double shotZoom,
  ) async {
    final out = <ContextSnapshot>[];
    for (final z in macroContextZooms(shotZoom)) {
      if (!identical(c, _controller) || !c.value.isInitialized) break;
      try {
        final cam = planZoom(requested: z, range: _range).cameraZoom;
        await c.setZoomLevel(cam);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final shot = await c.takePicture();
        out.add(
          ContextSnapshot(path: shot.path, cameraZoom: cam, at: DateTime.now()),
        );
      } catch (e) {
        debugPrint('Macro step photo @${z}x skipped: $e');
        continue; // v11.46: skip a failed step, keep going
      }
    }
    return out;
  }

  // ---- v11.30 100x zoom ladder (cheap phones) --------------------------------

  /// AI photo mode on the back camera of a cheap phone.
  bool get _ladderMode =>
      _snapshotMode &&
      !_macroActive &&
      _lens == CameraLensDirection.back &&
      _zoomMode &&
      _macroLowEnd;

  void _resetLadder() {
    _ladderTimer?.cancel();
    final old = _ladder?.clear() ?? const <String>[];
    _ladder = null;
    _subjectChanged = false;
    // v11.59: no stale diagnostics from an old chain.
    _ladderDbg = null;
    _zoomSendDbg = null;
    // v11.60: a new chain starts from a fresh tracker.
    _resetTracking();
    _deletePaths(old);
  }

  void _deletePaths(List<String> paths) {
    for (final p in paths) {
      unawaited(File(p).delete().then((_) {}, onError: (_) {}));
    }
  }

  /// Every zoom change: drop photos above the zoom (zoomed back out). v11.60:
  /// no photo per checkpoint — a reference is taken only once the zoom has
  /// rested and the view is steady AND tracked ([_maybeCaptureRef]).
  void _onLadderZoom() {
    unawaited(_maybeLadderNote());
    if (!_ladderMode) {
      _ladderTimer?.cancel();
      return;
    }
    final l = _ladder ??= ZoomLadder(hardwareMax: _range.hardwareMax);
    _deletePaths(l.zoomedTo(_zoom));
    // No reference yet while already zoomed far: ask once to zoom slowly
    // (references need the zoom to rest briefly while steady).
    if (l.shots.isEmpty && _cameraZoom >= 3 && !_slowHintShown && mounted) {
      _slowHintShown = true;
      _showToast(kZoomSlowlyHint);
    }
    _ladderTimer?.cancel();
    _ladderTimer = Timer(
      kRefRest + const Duration(milliseconds: 50),
      _maybeCaptureRef,
    );
  }

  TrackSnapshot get _track => _trackWorker?.snapshot ?? TrackSnapshot.idle;

  /// The tracker's latest frame is recent (the chain describes NOW).
  bool get _trackFresh {
    final at = _track.curAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(milliseconds: 900);
  }

  /// Fresh chain: tracker reset, rotation / lens identity forgotten. After
  /// a rotation or lens switch the first root waits [kTrackSettle] and a
  /// steady phone (a clear new reference, not a mid-turn blur).
  void _resetTracking({bool settle = false}) {
    _trackWorker?.reset();
    _trackRebaseNext = false;
    _prevTrack = null;
    _trackMotion = 1;
    _trackRot = null;
    _trackOrient = null;
    _trackLensId = null;
    _trackSettleUntil = settle ? DateTime.now().add(kTrackSettle) : null;
  }

  void _invalidateTracking(String why) {
    final l = _ladder;
    if (l != null && l.shots.isNotEmpty) _dropTrackedRefs(why);
    _resetTracking(settle: true);
    _ladderDbg = 'track reset ($why)';
  }

  /// v11.60: every analysed frame (ladder mode) → tracker worker. A lost
  /// chain invalidates the references (a shot needing a sharp source then
  /// fails closed); with nothing to protect the tracker simply re-roots.
  /// Device rotation or a physical-lens switch → reset + fresh reference.
  void _feedTracker(FrameStats s) {
    final tl = s.trackLuma;
    if (!_ladderMode || tl == null || _processingCapture) return;
    final c = _controller;
    if (c == null) return;
    final w = _trackWorker;
    if (w == null) {
      if (!_trackWorkerStarting) {
        _trackWorkerStarting = true;
        TrackerWorker.start().then(
          (w) {
            if (!mounted) return w.dispose();
            w.onUpdate = _onTrackUpdate;
            _trackWorker = w;
          },
          onError: (Object e) {
            _trackWorkerStarting = false;
            debugPrint('Tracker worker failed: $e');
          },
        );
      }
      return;
    }
    final now = DateTime.now();
    final o = c.value.deviceOrientation;
    if (_trackOrient != null && o != _trackOrient) {
      _invalidateTracking('rotation');
    }
    _pollTrackLens(now);
    final settle = _trackSettleUntil;
    if (settle != null) {
      if (now.isBefore(settle) || _steady.moving) return;
      _trackSettleUntil = null;
    }
    _trackOrient ??= o;
    final g = GreyImage.fromBytes(s.trackWidth, s.trackHeight, tl);
    _lastTrackGrey = g;
    w.submit(
      TrackFrame(g, _cameraZoom, now, steady: _gyroStill),
      rebase: _trackRebaseNext,
    );
    _trackRebaseNext = false;
  }

  /// Worker reply (current epoch only).
  void _onTrackUpdate(TrackSnapshot t) {
    if (!mounted || !_ladderMode) return;
    if (t.state == TrackState.lost) {
      final l = _ladder;
      if (l != null && l.shots.any((e) => e.rootToRef != null)) {
        _dropTrackedRefs(t.lostReason ?? 'lost');
      }
      _trackRot = null;
      _trackRebaseNext = true;
      _prevTrack = null;
      _trackMotion = 1;
      return;
    }
    final cur = t.rootToCur;
    final prev = _prevTrack;
    _trackMotion = cur == null || prev == null ? 1 : transformDelta(prev, cur);
    _prevTrack = cur;
    _maybeCaptureRef();
  }

  /// Physical camera identity (~1 s): a switch → the chain is invalid.
  void _pollTrackLens(DateTime now) {
    final at = _lensPolledAt;
    if (_lensPollBusy ||
        (at != null && now.difference(at) < const Duration(seconds: 1))) {
      return;
    }
    _lensPollBusy = true;
    _lensPolledAt = now;
    CameraExtras.info()
        .then((info) {
          final id = info['activePhysicalId'] as String?;
          if (!mounted || !_ladderMode || id == null) return;
          final old = _trackLensId;
          if (old != null && id != old) {
            _invalidateTracking('lens switch');
          }
          _trackLensId = id;
        }, onError: (_) {})
        .whenComplete(() => _lensPollBusy = false);
  }

  /// The chain broke: references no longer map to the view (hint shown).
  void _dropTrackedRefs(String why) {
    final l = _ladder;
    if (l == null) return;
    _deletePaths(l.clear());
    _subjectChanged = true;
    _ladderDbg = 'refs dropped ($why)';
    debugPrint('Ladder: tracking lost ($why), references dropped');
    if (mounted) setState(() {});
  }

  void _maybeCaptureRef() {
    final c = _controller;
    final l = _ladder;
    if (c == null || l == null || !c.value.isInitialized || !mounted) return;
    if (!_ladderMode) return;
    final ok = shouldCaptureReference(
      cameraZoom: _cameraZoom,
      hardwareMax: _range.hardwareMax,
      refZooms: [for (final s in l.shots) s.cameraZoom],
      now: DateTime.now(),
      zoomChangedAt: _zoomChangedAt,
      gyroSteady: _gyroSub == null ? true : !_steady.moving,
      tracked: _track.rootToCur != null && _trackFresh,
      opticalLimit: _optical.opticalLimit,
      motion: _trackMotion,
      busy:
          _ladderBusy ||
          _ctxBusy ||
          _captureLock ||
          _processingCapture ||
          _zoomInFlight ||
          c.value.isTakingPicture,
      flashOff: c.value.flashMode == FlashMode.off,
    );
    if (ok) unawaited(_takeLadderShot());
  }

  /// One reference still, stamped with the tracked view at that moment.
  /// Discarded when the view moved / zoom changed during the still.
  Future<void> _takeLadderShot() async {
    final c = _controller;
    final l = _ladder;
    if (c == null || l == null || !c.value.isInitialized || !mounted) return;
    if (!_ladderMode || _ladderBusy) return;
    final before = _track.rootToCur;
    final ana = _lastTrackGrey;
    final orient = _trackOrient;
    if (before == null || ana == null || orient == null) return;
    final cam = _cameraZoom;
    final cp = (_zoom * 10).round() / 10;
    // v11.61: the first reference of a chain is the low-zoom ROOT; deep zoom
    // without one takes no reference (the shot fails closed instead).
    final isRoot = l.root == null;
    if (isRoot && !isRootZoom(cam, _optical.opticalLimit)) {
      _ladderDbg = 'no root yet (cam ${formatZoom(cam)}x > root max)';
      return;
    }
    final label = refZoomLabel(
      cam,
      lensFactors: _optical.usableFactors,
      sensorCrop: _optical.sensorCropFactor,
    );
    _ladderBusy = true;
    final epoch = _trackWorker?.epoch;
    try {
      final shot = await c.takePicture();
      final sharp = await photoSharpness(shot.path);
      // Which way the still is turned vs the analysis view: device
      // orientation (portrait / landscape) + image check, off the UI isolate.
      StillRotation? rot;
      try {
        final proxy = await stillProxy(shot.path);
        final landscape =
            orient == DeviceOrientation.landscapeLeft ||
            orient == DeviceOrientation.landscapeRight;
        rot = await Isolate.run(
          () => detectStillRotation(ana, proxy, landscape: landscape),
        );
      } catch (e) {
        debugPrint('Ref rotation check failed: $e');
      }
      final after = _track.rootToCur;
      final moved =
          after == null ||
          _trackWorker?.epoch != epoch ||
          transformDelta(before, after) > kRefMaxMotion * 2;
      final rotBad =
          rot == null || !rot.ok || (_trackRot != null && rot.k != _trackRot);
      if (!identical(l, _ladder) ||
          (_cameraZoom - cam).abs() > 0.01 ||
          moved ||
          rotBad ||
          _controller?.value.deviceOrientation != orient) {
        _deletePaths([shot.path]);
        _ladderDbg =
            'ref ${formatZoom(cp)} discarded (${moved
                ? 'moved / lost'
                : rotBad
                ? 'rotation unverified ${rot == null ? 'n/a' : '${rot.score.toStringAsFixed(2)}/${rot.margin.toStringAsFixed(2)}'}'
                : 'zoom / orientation changed'})';
      } else {
        _trackRot ??= rot.k;
        // A blurry reference is kept for the clear-limit record only (never
        // a source); the tracking chain is not affected by it. v11.61: the
        // ROOT is the sharpness baseline of the chain.
        final clear = isRoot || isClearPhoto(sharp, l.refSharpness);
        l.add(
          LadderShot(
            checkpoint: cp,
            path: shot.path,
            cameraZoom: cam,
            sharpness: sharp,
            rootToRef: before,
            stillRot: rot.k!,
            optical: label.optical,
            root: isRoot,
          ),
        );
        _noteClearLimit(l);
        if (isRoot) unawaited(_noteRootStill(shot.path, label));
        _ladderDbg =
            'ref ${isRoot ? 'root ' : ''}${formatZoom(cp)} ${label.text} ${clear ? 'clear' : 'blurry'} · ${_track.debugText}';
        if (mounted) setState(() {});
        debugPrint(
          'Ladder ref ${isRoot ? '(root) ' : ''}${cp}x @ cam ${cam.toStringAsFixed(2)}x '
          '(${label.text}) sharp ${sharp.toStringAsFixed(1)} ${clear ? 'clear' : 'blurry'}',
        );
      }
    } catch (e) {
      debugPrint('Ladder photo failed: $e');
    } finally {
      _ladderBusy = false;
    }
  }

  /// v11.34 remember where photos turn blurry on this phone.
  void _noteClearLimit(ZoomLadder l) {
    final obs = observedClearLimit([
      for (final s in l.shots) (s.checkpoint, l.isClear(s)),
    ]);
    if (obs == null || obs == _clearLimit) return;
    _clearLimit = obs;
    unawaited(_savePref(kClearLimitKey, obs.toString()));
  }

  Future<void> _loadClearLimit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = double.tryParse(prefs.getString(kClearLimitKey) ?? '');
      if (v != null && mounted) setState(() => _clearLimit = v);
      final r = int.tryParse(prefs.getString(kRootStillLongKey) ?? '');
      if (r != null && r > 0 && mounted) setState(() => _rootStillLong = r);
    } catch (_) {}
  }

  /// v11.61: long side + real zoom of the current ROOT still (real-pixel
  /// gate); the long side is remembered for the live label next time.
  Future<void> _noteRootStill(String path, RefZoomLabel label) async {
    try {
      final (w, h) = await uprightSize(path);
      final long = math.max(w, h);
      if (!mounted || long <= 0) return;
      setState(() {
        _rootStillLong = long;
        _rootLabel = label;
      });
      unawaited(_savePref(kRootStillLongKey, long.toString()));
    } catch (_) {}
  }

  /// v11.61 per-device clear limit from REAL pixels: the root's (or, before
  /// one exists, the last root still's / a default) long side × its optical
  /// part ÷ [kClearRoiPx]; never below the optical limit.
  double get _pixelClearLimit {
    final l = _ladder;
    final hasRoot = l?.root != null;
    return pixelClearLimit(
      stillLong: _rootStillLong ?? kDefaultStillLong,
      rootOptical: hasRoot ? (_rootLabel?.optical ?? 1.0) : 1.0,
      opticalLimit: _optical.opticalLimit,
    );
  }

  /// v11.61 live note while zooming (ladder): missing base photo, or
  /// "Beyond clear range, AI-enhanced". Capture is never blocked by it.
  String? get _liveZoomNote => _processingCapture || _clearLimitBusy
      ? null
      : liveZoomNote(
          ladderMode: _ladderMode && _zoomModeActive,
          zoom: _zoom,
          opticalLimit: _optical.opticalLimit,
          hasRoot: _ladder?.root != null,
          clearLimit: _pixelClearLimit,
        );

  bool get _showNewSubject =>
      _ladderMode &&
      !_clearLimitBusy &&
      !_processingCapture &&
      showNewSubjectHint(
        subjectChanged: _subjectChanged,
        zoom: _zoom,
        clearLimit: _clearLimit,
      );

  /// Tap on "New subject": zoom (~1 s) to the clear limit, take 1–2
  /// checkpoint photos, then back to the user's zoom. Only on tap.
  /// v11.61: without a ROOT the low-zoom base photo is taken first (the
  /// chain's root), at 1x (or the lowest zoom the camera allows).
  Future<void> _captureAtClearLimit() async {
    final needRoot = _ladder?.root == null;
    final lim = _clearLimit;
    if ((lim == null && !needRoot) || _clearLimitBusy) return;
    final back = _zoom;
    setState(() {
      _clearLimitBusy = true;
      _subjectChanged = false;
    });
    try {
      if (needRoot) {
        final rz = 1.0.clamp(_range.minZoom, _userZoomMax).toDouble();
        await _animateZoomTo(rz, kClearLimitAnim);
        await _waitZoomSettled();
        await Future<void>.delayed(kLadderStepPause);
        // A chain rooted deep in the zoom cannot hold the wide view: start a
        // fresh chain here and wait (≤ 1.5 s) for it before the base photo.
        if (_track.rootToCur == null || !_trackFresh) _resetTracking();
        for (var i = 0; i < 30 && mounted; i++) {
          if (_track.rootToCur != null && _trackFresh) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await _takeLadderShot();
        if (lim == null) {
          await _animateZoomTo(back, kClearLimitAnim);
          await _waitZoomSettled();
          return;
        }
      }
      await _animateZoomTo(lim!, kClearLimitAnim);
      await _waitZoomSettled();
      await Future<void>.delayed(kLadderStepPause);
      await _takeLadderShot();
      await _animateZoomTo(back, kClearLimitAnim);
      await _waitZoomSettled();
      await Future<void>.delayed(kLadderStepPause);
      await _takeLadderShot();
    } finally {
      if (mounted) setState(() => _clearLimitBusy = false);
    }
  }

  /// Smooth zoom over [d] (eased).
  Future<void> _animateZoomTo(double target, Duration d) async {
    final from = _zoom;
    final steps = math.max(1, d.inMilliseconds ~/ 50);
    for (var i = 1; i <= steps && mounted; i++) {
      final t = i / steps;
      final e = t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2;
      await _setZoom(from + (target - from) * e);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Shutter waits for a ladder photo in flight (≤1.5 s).
  Future<void> _awaitLadderShot() async {
    _ladderTimer?.cancel();
    for (var i = 0; i < 30 && _ladderBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// One-time note the first time AI zoom passes 10x (all phones).
  Future<void> _maybeLadderNote() async {
    if (_ladderNoteShown || !_snapshotMode || _macroActive || _zoom < 10) {
      return;
    }
    _ladderNoteShown = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kLadderNoteKey) ?? false) return;
      await prefs.setBool(kLadderNoteKey, true);
    } catch (_) {}
    if (mounted) _showToast(kLadderNote);
  }

  // ---- v11.9 context snapshot -----------------------------------------------

  // v11.12: Macro uses its own 2x / 3x / 4x step photos.
  bool get _snapshotMode => _aiMode && _shootMode == ShootMode.photo;

  /// After the zoom settles at ≤3x, silently keep a full-quality still.
  void _scheduleContextSnap({bool force = false}) {
    if (!_snapshotMode || !atSnapshotZoom(_zoom)) {
      _ctxTimer?.cancel();
      return;
    }
    if (!force && _ctxTimer?.isActive == true) return;
    _ctxTimer?.cancel();
    _ctxTimer = Timer(kSnapshotSettle, () => unawaited(_takeContextSnap()));
  }

  Future<void> _takeContextSnap() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || !mounted) return;
    if (!_snapshotMode || !atSnapshotZoom(_zoom)) return;
    if (_ctxBusy ||
        _captureLock ||
        _processingCapture ||
        c.value.isTakingPicture ||
        c.value.flashMode != FlashMode.off) {
      return; // never fire the flash / torch for a silent snapshot
    }
    final thumb = _lastStats?.thumb;
    if (!shouldTakeSnapshot(
      zoom: _zoom,
      existing: _ctxSnap,
      now: DateTime.now(),
      sceneChange: _ctxSnap?.thumb == null || thumb == null
          ? 0
          : frameDiff(_ctxSnap!.thumb, thumb),
    )) {
      return;
    }
    _ctxBusy = true;
    final cam = _cameraZoom;
    try {
      final shot = await c.takePicture();
      final old = _ctxSnap?.path;
      _ctxSnap = ContextSnapshot(
        path: shot.path,
        cameraZoom: cam,
        at: DateTime.now(),
        thumb: thumb,
      );
      debugPrint('Context snapshot @ ${cam.toStringAsFixed(2)}x');
      if (old != null && old != shot.path) {
        unawaited(File(old).delete().then((_) {}, onError: (_) {}));
      }
    } catch (e) {
      debugPrint('Context snapshot failed: $e');
    } finally {
      _ctxBusy = false;
    }
  }

  /// Shutter waits for a snapshot in flight (≤1.5 s).
  Future<void> _awaitContextSnap() async {
    _ctxTimer?.cancel();
    for (var i = 0; i < 30 && _ctxBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// AF pass at the frame centre (entering Macro / after a chip change).
  Future<void> _refocusCentre() async {
    final g = _geometry;
    if (g == null || !_macroActive) return;
    try {
      await _focus.focusAt(g.frameSize.center(Offset.zero), g);
    } catch (e) {
      debugPrint('Macro refocus failed: $e');
    }
  }

  /// v11.58: ONE phone class everywhere. The flows (zoom ladder, merge,
  /// zoom AF, macro burst) used the old preview-size heuristic while the
  /// debug overlay showed [classifyCamera] — a flagship with a <1600 px
  /// preview stream (e.g. S24 Ultra) was treated as a cheap phone.
  bool get _macroLowEnd => _cameraClass.lowEnd;

  /// v11.8 shutter: camera to the optical limit (real pixels) → settle →
  /// centre AF → sharpest of 4 (7 on low-end) → restore the preview zoom.
  /// Returns (path, note, crop factor still → user's region).
  Future<(String, String, double)> _takeMacro(CameraController c) async {
    final cap = macroCaptureZoom(
      chip: _zoom, // v11.33: the user's current zoom
      previewCamera: _cameraZoom,
      opticalCap: macroCameraCap(
        hardwareMax: _range.hardwareMax,
        opticalLimit: _optical.opticalLimit,
      ),
    );
    final previewCam = _cameraZoom;
    final moved = (cap.camera - previewCam).abs() > 0.01;
    if (moved) {
      try {
        await c.setZoomLevel(cap.camera);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (e) {
        debugPrint('Macro capture zoom failed: $e');
      }
    }
    final lowEnd = _macroLowEnd;
    final n = macroBurstCount(lowEnd: lowEnd);
    final crop = moved ? cap.crop : _digitalZoom;
    _macroShotCamera = moved ? cap.camera : previewCam;
    final ourAf = await _preCapture(); // centre AF unless tapped
    try {
      final (path, note) = await _burstSharpest(c, n, crop, merge: lowEnd);
      // v11.40: Macro / Close / Extreme / Ultra add wider context photos
      // (Microscope keeps its own hint photo).
      _dropMacroCtx();
      var ctxTaken = false;
      if (_macroLevel != null) {
        final steps = macroContextZooms(_zoom);
        if (steps.isNotEmpty) _showToast(macroStepHint(steps));
        try {
          _macroCtx = await _takeMacroContext(c, _zoom);
          ctxTaken = _macroCtx.isNotEmpty;
        } catch (e) {
          debugPrint('Macro context photos skipped: $e');
        }
        // v11.58: Microscope levels also take a 1.5x photo (object lock).
        if (_macroLevel!.isMicroscopic && identical(c, _controller)) {
          try {
            final cam = planZoom(requested: kMacroDetectZoom, range: _range).cameraZoom;
            await c.setZoomLevel(cam);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final shot = await c.takePicture();
            _microOneHalf = ContextSnapshot(path: shot.path, cameraZoom: cam, at: DateTime.now());
            ctxTaken = true;
          } catch (e) {
            debugPrint('Microscope 1.5x photo skipped: $e');
          }
        }
      }
      if (ctxTaken && !moved && identical(c, _controller)) {
        unawaited(c.setZoomLevel(previewCam).catchError((Object _) {}));
      }
      return (path, note, crop);
    } finally {
      unawaited(_focus.afterCapture(ourAf));
      if (moved && identical(c, _controller)) {
        unawaited(c.setZoomLevel(previewCam).catchError((Object _) {}));
      }
    }
  }

  /// Burst of [n] with a "Hold steady · N" countdown; scores the user's
  /// region (centre 1/[crop]); [merge] = align + average the sharpest 5
  /// (low-end), else the sharpest frame wins.
  Future<(String, String)> _burstSharpest(
    CameraController c,
    int n,
    double crop, {
    bool merge = false,
  }) async {
    final paths = <String>[];
    if (mounted) {
      setState(() {
        _holdSteady = true;
        _nightStage = holdSteadyCountdown(n);
      });
    }
    try {
      for (var i = 0; i < n; i++) {
        if (!identical(c, _controller) || !c.value.isInitialized) break;
        try {
          paths.add((await c.takePicture()).path);
        } catch (e) {
          if (paths.isEmpty) rethrow;
          break;
        }
        if (mounted) {
          setState(() => _nightStage = holdSteadyCountdown(n - i - 1));
        }
      }
    } finally {
      // v11.29: "Hold steady" only while the frames are captured.
      if (mounted) {
        setState(() {
          _nightStage = null;
          _holdSteady = false;
          _afterFrames = true;
        });
      }
    }
    if (paths.length == 1) return (paths.first, 'Single frame');
    final scores = <double>[];
    for (final p in paths) {
      try {
        final g = await grayProxy(
          await File(p).readAsBytes(),
          (360 * math.min(crop, 6)).round(),
        );
        scores.add(regionSharpness(g.values, g.width, g.height, crop));
      } catch (_) {
        scores.add(0);
      }
    }
    final order = sharpestFirst(scores);
    debugPrint('Burst sharpness: $scores → $order');
    if (merge && order.length >= 2) {
      try {
        final (out, used, errs) = await mergeZoomRegion(
          [for (final i in order) paths[i]],
          crop,
          (await getTemporaryDirectory()).path,
        );
        // v11.30 key builds: merge result + alignment error per frame.
        final dbg = mergeDebugText(used, paths.length, errs);
        debugPrint('Zoom merge: $dbg');
        if (used >= 2) {
          return (
            out,
            AiConfig.hasEmbeddedApiKey
                ? dbg
                : 'Merged $used of ${paths.length} frames',
          );
        }
        return (
          paths[order.first],
          AiConfig.hasEmbeddedApiKey ? dbg : 'Sharpest of ${paths.length}',
        );
      } catch (e) {
        debugPrint('Zoom merge failed: $e');
      }
    }
    return (paths[order.first], 'Sharpest of ${paths.length}');
  }

  void _showBlockedNote(ModeBlock b) {
    switch (b) {
      case ModeBlock.macroNeedsPro:
        _snack(
          kMacroNeedsProNote,
          action: SnackBarAction(
            label: 'Pro AI',
            onPressed: () => unawaited(_setMode(CaptureMode.pro)),
          ),
        );
      case ModeBlock.portraitUnsupported:
        _snack(
          kPortraitUnsupportedNote,
          action: SnackBarAction(
            label: 'Pro AI',
            onPressed: () => unawaited(_setMode(CaptureMode.pro)),
          ),
        );
      case ModeBlock.none:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // v10: shooting modes (all free, on-device — no credits, no cloud AI)
  // ---------------------------------------------------------------------------

  bool get _front => _lens == CameraLensDirection.front;

  /// What the live preview approximates for the selected AI filter / style
  /// (credits are only spent after the shutter + a successful AI result).
  LiveLook get _liveLook {
    final p = _pendingLook;
    if (p != null) {
      final s = p.style;
      if (s != null) return liveLookForStyle(s);
      final c = p.customPrompt;
      if (c != null && c.trim().isNotEmpty) return liveLookForCustom(c);
      return LiveLook.none;
    }
    final f = _aiMode ? _aiFilter : null;
    return f == null ? LiveLook.none : liveLookForFilter(f);
  }

  ModeRoute get _route => routeFor(
    _shootMode,
    features: _features,
    aiMode: _aiMode,
    bokehAvailable: BokehBridge.cached(_front),
  );

  Set<LiveAnalyzer> _wantedAnalyzers() {
    if (!_cameraReady || _bokeh != null) return const {};
    return _route.analyzers;
  }

  /// Auto-capture (smile) only while this screen is on top and idle.
  bool get _canAutoCapture =>
      _cameraReady &&
      !_processingCapture &&
      !_captureLock &&
      _countdown == null &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  Future<void> _setShootMode(ShootMode m) async {
    if (_processingCapture) return;
    if (m == ShootMode.document) {
      await _scanDocument();
      return;
    }
    if (m == _shootMode) return;
    final wasNight = _night;
    setState(() {
      _shootMode = m;
      _night = m == ShootMode.night;
      _tip = null;
      _resetMacroFlow(); // v11.33: Macro opens at 1x, no level
      if (m == ShootMode.macro) {
        _menuOpen = false; // v11.50: no menu in Macro
        _panel = _Panel.none; // v11.51: no filter row in Macro
      }
    });
    if (m != ShootMode.macro && _torchOn) unawaited(_setTorch(false));
    _showToast(_modeToast(m));
    if (m == ShootMode.pose) unawaited(_enterPose());
    if (wasNight != _night) {
      unawaited(_applyNightExposure());
      unawaited(_applyFlash());
    }
    if (_night) unawaited(_maybeShowNightTips());
    await _syncModeHardware();
  }

  String _modeToast(ShootMode m) => switch (m) {
    ShootMode.photo => 'Photo',
    ShootMode.portrait => _aiMode ? 'Portrait · AI bokeh' : 'Portrait',
    ShootMode.night => _aiMode ? 'Pro Night' : 'Night · hold still',
    ShootMode.macro => _aiMode ? kMacroTip : kMacroNeedsProNote,
    ShootMode.document => 'Document scan',
    ShootMode.hdr => 'Photo', // v11.49: HDR removed
    ShootMode.pose => 'Pose · pick a photo to copy',
  };

  Future<void> _openMoreModes() async {
    await showMoreModesSheet(
      context,
      features: _features,
      onFeatures: _setFeatures,
    );
  }

  void _setFeatures(CameraFeatures f) {
    setState(() {
      _features = f;
      if (!f.scanQr) _scan = null;
      if (!f.sceneTips) _tip = null;
    });
    if (!f.faceFocus) _focus.clearFace();
    _syncLevel();
    unawaited(_savePref(CameraFeatures.prefsKey, jsonEncode(f.toJson())));
  }

  /// Level line: accelerometer only while the toggle is on.
  void _syncLevel() {
    if (_features.level && _accelSub == null) {
      try {
        _accelSub =
            accelerometerEventStream(
              samplingPeriod: SensorInterval.uiInterval,
            ).listen((e) {
              if (!mounted) return;
              final r = smoothAngle(_roll, rollDegrees(e.x, e.y));
              final flat = isFlat(e.x, e.y, e.z);
              if ((r - _roll).abs() > 0.15 || flat != _flat) {
                setState(() {
                  _roll = r;
                  _flat = flat;
                });
              }
            }, onError: (Object _) {});
      } catch (e) {
        debugPrint('Accelerometer unavailable: $e');
      }
    } else if (!_features.level && _accelSub != null) {
      unawaited(_accelSub!.cancel());
      _accelSub = null;
    }
  }

  /// Upright analysis point (NOT mirrored) → displayed preview point.
  Offset _toDisplayPreview(Offset u) => _front ? Offset(1 - u.dx, u.dy) : u;

  /// Upright analysis point → frame pixels (cover-fit + digital zoom).
  Offset _toFramePx(Offset u) {
    final g = _geometry;
    if (g == null) return u;
    return previewPointToFrame(_toDisplayPreview(u), g);
  }

  /// Live-vision results → QR chip, scene tip, face focus, smile shot,
  /// pose score. Pure overlays (mask / boxes / skeleton) rebuild through a
  /// ValueListenableBuilder; this only setStates for chip changes.
  void _onVision() {
    if (!mounted) return;
    final v = _vision.value;
    final now = DateTime.now();
    var dirty = false;
    final stats = v.stats;
    if (stats != null) _lastStats = stats;
    _vision.trackFrames = _ladderMode;
    if (stats != null) _feedTracker(stats);
    if (_macroActive && stats != null) _updateBoxCheck(stats);
    if (stats != null) _updateBright(stats);
    if (stats?.thumb != null &&
        _snapshotMode &&
        atSnapshotZoom(_zoom) &&
        !_ctxBusy &&
        (_ctxSnap == null ||
            (_ctxSnap!.thumb != null &&
                frameDiff(_ctxSnap!.thumb, stats!.thumb!) >=
                    kSceneChangeDiff))) {
      _scheduleContextSnap();
    }

    // QR / barcode chip.
    if (_features.scanQr && v.barcodes.isNotEmpty) {
      final raw = v.barcodes.first;
      _scanSeenAt = now;
      if (raw != _scan?.raw && raw != _scanDismissed) {
        _scan = classifyScan(raw);
        dirty = true;
      }
    } else if (_scan != null &&
        (_scanSeenAt == null ||
            now.difference(_scanSeenAt!) > const Duration(seconds: 3))) {
      _scan = null;
      dirty = true;
    }

    // Faces: face-priority focus + smile shot.
    final faces = v.faces;
    if (_features.faceFocus && !_processingCapture && !_brightApplied) {
      final pt = _faceFocus.decide(
        faces,
        now,
        userFocusActive: _focus.isActive,
      );
      if (pt != null) unawaited(_focus.faceMeter(_toDisplayPreview(pt)));
      if (faces.isEmpty && _focus.facePoint != null) _focus.clearFace();
    }
    if (_features.smileShot &&
        faces.isNotEmpty &&
        _canAutoCapture &&
        _smile.update(faces, now)) {
      HapticFeedback.lightImpact();
      _showToast('Smile!');
      unawaited(_capture());
    }

    // Scene tips (image labeling) + pose category order.
    if (!identical(v.labels, _lastLabels)) {
      _lastLabels = v.labels;
      if (_features.sceneTips && _shootMode != ShootMode.pose) {
        final s = _tipGate.offer(
          suggestFor(v.labels, mode: _shootMode, faces: faces.length),
          now,
        );
        if (s != null) {
          _tip = s;
          dirty = true;
          _tipTimer?.cancel();
          _tipTimer = Timer(const Duration(seconds: 7), () {
            if (mounted) setState(() => _tip = null);
          });
        }
      }
      if (_shootMode == ShootMode.pose) {
        final order = orderPoseCategories(
          v.labels,
          faces: faces.length,
          front: _front,
        );
        if (!listEquals(order, _poseCategories)) {
          _poseCategories = order;
          dirty = true;
        }
      }
    }

    // Macro distance guide (hysteresis inside MacroGuide).
    if (_macroActive && stats != null && !identical(stats, _macroStatsSeen)) {
      _macroStatsSeen = stats;
      final t = stats.thumb;
      final m = frameDiff(_prevThumb, t);
      _prevThumb = t;
      final steadyBefore = showHoldSteady(zoom: _zoom, motion: _motion);
      final darkBefore = _macroDark;
      _motion = _motion * 0.5 + m * 0.5;
      _macroDark = macroTooDark(stats.luma, torchOn: _torchOn);
      if (steadyBefore != showHoldSteady(zoom: _zoom, motion: _motion) ||
          darkBefore != _macroDark) {
        dirty = true;
      }
    }

    if (dirty) setState(() {});
  }

  FrameStats? _macroStatsSeen;
  bool _macroDark = false;

  Future<void> _setTorch(bool on) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFlashMode(on ? FlashMode.torch : _previewFlashMode);
      if (mounted) {
        setState(() {
          _torchOn = on;
          if (on) _macroDark = false;
        });
      }
    } catch (e) {
      debugPrint('Torch failed: $e');
      if (mounted) _snack('Torch not available');
    }
  }

  Future<void> _maybeMicroscopeTip(MacroLevel level) async {
    final tip = macroFirstTipFor(level);
    if (tip == null || !_levelTipsShown.add(level)) return;
    final key = level.isDeep
        ? 'macro_extreme_tip_seen_v117'
        : 'macro_microscope_tip_seen_v111';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(key) ?? false) return;
      await prefs.setBool(key, true);
    } catch (_) {}
    if (mounted) _showToast(tip);
  }

  Future<void> _onScanTap() async {
    final a = _scan;
    if (a == null) return;
    final uri = a.uri;
    if (uri != null) {
      var ok = false;
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
      if (!ok && mounted) _snack('No app found to open this');
      return;
    }
    await Clipboard.setData(ClipboardData(text: a.raw));
    if (mounted) _snack('Copied');
  }

  void _dismissScan() {
    setState(() {
      _scanDismissed = _scan?.raw;
      _scan = null;
    });
  }

  Future<void> _onTipTap() async {
    final t = _tip;
    if (t == null) return;
    setState(() => _tip = null);
    await _setShootMode(t.mode);
  }

  void _dismissTip() {
    final t = _tip;
    if (t != null) _tipGate.dismiss(t.id);
    setState(() => _tip = null);
  }

  // ---- Pose mode -----------------------------------------------------------

  Future<void> _enterPose() async {
    final v = _vision.value;
    setState(() {
      _poseCategories = orderPoseCategories(
        v.labels,
        faces: v.faces.length,
        front: _front,
      );
      _poseCategory = _poseCategories.first;
    });
    try {
      await PoseCatalog.instance.ensureLoaded(); // + admin poses
    } catch (_) {}
  }

  void _selectPoseCategory(String c) {
    setState(() => _poseCategory = c);
  }

  void _selectPose(PosePhoto? t) {
    setState(() => _pose = t);
  }

  // ---- Capture helpers -----------------------------------------------------

  /// HDR: 3 frames at 0 / −s / +s EV, aligned + exposure-fused on device.
  Future<String> _takeHdr(
    CameraController c,
    void Function(String note) onNote,
  ) async {
    final ourAf = await _preCapture();
    var minEv = 0.0;
    var maxEv = 0.0;
    try {
      minEv = await c.getMinExposureOffset();
      maxEv = await c.getMaxExposureOffset();
    } catch (_) {}
    final plan = hdrBracketEv(minEv: minEv, maxEv: maxEv);
    final paths = <String>[];
    try {
      if (plan.isEmpty) {
        onNote('HDR not supported here · single photo');
        return (await c.takePicture()).path;
      }
      for (final ev in plan) {
        if (!identical(c, _controller) || !c.value.isInitialized) break;
        try {
          await c.setExposureOffset(ev);
          // Let AE settle on the new compensation.
          await Future<void>.delayed(const Duration(milliseconds: 150));
        } catch (_) {}
        try {
          paths.add((await c.takePicture()).path);
        } catch (e) {
          if (paths.isEmpty) rethrow;
          break;
        }
      }
    } finally {
      try {
        await c.setExposureOffset(0);
      } catch (_) {}
      unawaited(_focus.afterCapture(ourAf));
    }
    if (mounted) setState(() => _holdSteady = false);
    if (paths.length < 2) {
      onNote('HDR · single photo');
      return paths.first;
    }
    try {
      final r = await mergeHdrFiles(paths, File(paths.first).parent.path);
      debugPrint('HDR merge: ${r.used}/${paths.length}, shifts ${r.shifts}');
      onNote(
        r.used >= 2
            ? 'HDR · ${r.used} exposures merged'
            : 'HDR · single photo (camera moved)',
      );
      return r.path;
    } catch (e) {
      debugPrint('HDR merge failed: $e');
      onNote('HDR · single photo');
      return paths.first;
    }
  }

  /// Document: Google's on-device scanner (edge detect, crop, clean-up)
  /// → PDF + pages.
  Future<void> _scanDocument() async {
    if (_processingCapture || _captureLock) return;
    _captureLock = true;
    ScannedDocument? doc;
    Object? error;
    try {
      await _vision.pause();
      // Keep the camera across the scanner activity (smooth return).
      _externalActivity = true;
      doc = await DocumentScan.scan();
    } catch (e) {
      error = e;
    } finally {
      _externalActivity = false;
      _captureLock = false;
      if (mounted) unawaited(_vision.resume());
    }
    if (!mounted) return;
    if (error != null) {
      if (!'$error'.toLowerCase().contains('cancel')) {
        _snack('Document scanner unavailable (needs Google Play services)');
      }
      return;
    }
    if (doc == null) {
      _snack('Document scanner needs Google Play services');
      return;
    }
    if (doc.pageCount == 0 && doc.pages.isEmpty) return; // cancelled
    await showDocumentResultSheet(context, doc);
  }

  /// e.g. "100x = camera 10x × digital 10x · 4:3 · crop 400×300 of
  /// 4000×3000 · EXIF 6.3mm (35mm 230) dz 1.00".
  String _calibrationLine({
    required double selected,
    required double digital,
    required FrameRatio ratio,
    required CaptureCropResult crop,
  }) {
    final cam = digital > 0 ? selected / digital : selected;
    String n(double? v, [int d = 1]) => v == null ? '—' : v.toStringAsFixed(d);
    final c = crop.crop;
    return '${formatZoom(selected)}x = camera ${n(cam, 2)}x × digital '
        '${n(digital, 2)}x · ${ratio.label}'
        '${c == null ? '' : ' · crop ${c.width}×${c.height} of ${crop.sourceWidth}×${crop.sourceHeight}'}'
        ' · EXIF ${n(crop.exifFocalMm, 2)}mm (35mm ${n(crop.exifFocal35mm, 0)}) '
        'dz ${n(crop.exifDigitalZoom, 2)}';
  }

  Future<void> _pickFromGallery({
    ImageSource source = ImageSource.gallery,
  }) async {
    try {
      _externalActivity = true;
      XFile? xfile;
      try {
        xfile = await _picker.pickImage(
          source: source,
          imageQuality: 95,
          maxWidth: 3000,
        );
      } finally {
        _externalActivity = false;
      }
      final picked = xfile;
      if (picked == null || !mounted) return;
      final ai = _mode == CaptureMode.pro;
      final gallery = source == ImageSource.gallery;
      await _vision.pause();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PreviewScreen(
            imageFile: File(picked.path),
            mode: _mode,
            tier: _effTier,
            // v10: gallery photos get no enhance / AI filters — only
            // creative Styles + Describe a change.
            source: gallery ? PhotoSource.gallery : null,
            pendingLook: _pendingLook,
            initialAiFilter: ai && !gallery ? _aiFilter : null,
            initialFilter: _premium,
            initialStrength: _strength,
          ),
        ),
      );
      if (mounted) unawaited(_vision.resume());
      if (mounted &&
          _bokeh == null &&
          !_bokehBusy &&
          (_controller == null || !_controller!.value.isInitialized)) {
        unawaited(_setupCamera());
      }
    } catch (e) {
      if (!mounted) return;
      _snack('Picker failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  bool get _filterActive =>
      !_premium.isOriginal || (_aiMode && _aiFilter != null);

  bool get _styleActive => _pendingLook != null;

  @override
  Widget build(BuildContext context) {
    // Live analyzers follow mode / features / live look (idempotent).
    final wantAnalyzers = _wantedAnalyzers();
    if (!setEquals(wantAnalyzers, _vision.active)) {
      scheduleMicrotask(() {
        if (mounted) unawaited(_vision.setAnalyzers(_wantedAnalyzers()));
      });
    }
    final posePanel = _shootMode == ShootMode.pose;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Minimal top bar: PRO (left) · coin balance + quality (right).
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  const ProBadgeButton(),
                  const SizedBox(width: 8),
                  // v11.48: one Flash button for every mode (Macro too).
                  TopFlashButton(
                    flash: _night ? _nightFlash : _flash,
                    onTap:
                        _lens == CameraLensDirection.back && !_processingCapture
                        ? _cycleFlash
                        : null,
                  ),
                  const Spacer(),
                  const LiveCreditsPill(),
                  const SizedBox(width: 8),
                  _QualityChip(
                    tier: _effTier,
                    aiMode: _aiMode,
                    onTap: _processingCapture ? null : _pickQuality,
                  ),
                ],
              ),
            ),
            // Edge-to-edge viewfinder: full width, straight edges.
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  children: [
                    Positioned.fill(child: _buildViewfinderArea()),
                    // Blocked-mode notes (also when the camera is closed).
                    Positioned(
                      top: 48,
                      left: 12,
                      right: 12,
                      child: Center(child: _buildModeBlockNote()),
                    ),
                    // Brief toast for quick-menu changes.
                    Positioned(
                      top: 14,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: TransientNotice(
                          message: _toast,
                          token: _toastSeq,
                          duration: const Duration(milliseconds: 1400),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 10,
                      child: _buildBottomOverlay(),
                    ),
                    // v11.54 first-run tooltip above the four-dot button.
                    if (_stylesHint &&
                        !_menuOpen &&
                        quickMenuVisible(aiMode: _aiMode, mode: _shootMode))
                      // v11.59: anchored to the real four-dot button.
                      Positioned.fill(
                        child: AnchoredStylesHint(
                          anchorKey: _menuKey,
                          onTap: () => unawaited(_dismissStylesHint()),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Filter / style strip (opened from the quick menu).
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              child: posePanel
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildPosePanel(),
                    )
                  : _panel == _Panel.none
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildPanel(),
                    ),
            ),
            // v10 shooting modes (free, on-device) above the shutter.
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ModeStrip(
                mode: _shootMode,
                onMode: _processingCapture
                    ? null
                    : (m) => unawaited(_setShootMode(m)),
                onMore: _processingCapture ? null : _openMoreModes,
                proModes: const {ShootMode.macro},
                modes: ShootMode.stripFor(aiMode: _aiMode),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _GalleryThumb(
                    file: _lastShot,
                    onTap: () => _pickFromGallery(),
                  ),
                  _CaptureButton(
                    onTap: _onShutter,
                    ai: _aiMode,
                    countingDown: _countdown != null,
                  ),
                  _CircleButton(
                    key: const ValueKey('flip_camera'),
                    icon: Icons.cameraswitch_rounded,
                    tooltip: 'Switch camera',
                    onTap: _cameras.length > 1
                        ? _flipCamera
                        : () => _snack('Only one camera on this device'),
                  ),
                ],
              ),
            ),
            // Samsung-style mode tabs under the shutter.
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 10),
              child: _ModeTabs(
                mode: _mode,
                onChanged: _processingCapture ? null : _setMode,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeBlockNote() {
    switch (_route.block) {
      case ModeBlock.portraitUnsupported:
        return _ModeNote(
          key: const ValueKey('portrait_unsupported'),
          icon: Icons.portrait_rounded,
          text: kPortraitUnsupportedNote,
          action: 'Pro AI',
          onAction: () => unawaited(_setMode(CaptureMode.pro)),
        );
      case ModeBlock.macroNeedsPro:
        return _ModeNote(
          key: const ValueKey('macro_needs_pro'),
          icon: Icons.local_florist_outlined,
          text: kMacroNeedsProNote,
          action: 'Pro AI',
          onAction: () => unawaited(_setMode(CaptureMode.pro)),
        );
      case ModeBlock.none:
        return const SizedBox.shrink();
    }
  }

  Widget _buildPosePanel() {
    return ValueListenableBuilder<List<PosePhoto>>(
      valueListenable: PoseCatalog.instance.poses,
      builder: (context, all, _) => PoseStrip(
        categories: _poseCategories,
        category: _poseCategory,
        poses: posesIn(all, _poseCategory),
        selected: _pose,
        onCategory: _selectPoseCategory,
        onPose: _selectPose,
      ),
    );
  }

  /// v11.51: Styles → camera filter row (from the DB, cached) + View more.
  Widget _buildPanel() {
    return ValueListenableBuilder<List<AiStyle>>(
      valueListenable: FilterCatalog.instance.filters,
      builder: (context, list, _) {
        final sel = _pendingLook?.style?.isFilter == true
            ? _pendingLook!.style!.id
            : null;
        // v11.54: one row · PHOTO (filters + styles) · VIDEO · More ›.
        return StylesQuickPanel(
          filters: list,
          selectedId: sel,
          onPhoto: (s) => s.isFilter
              ? _onFilterSelect(s.id == sel ? null : s)
              : unawaited(_applyStyle(s)),
          onVideo: (s) => unawaited(_startVideoStyle(s)),
          onMore: () => unawaited(_openStyles()),
        );
      },
    );
  }

  /// Bottom of the viewfinder: active filter/style badges, a brief zoom
  /// notice, and the zoom pill ⇄ quick-menu bar.
  /// v11.33 Macro HUD above the level chips: level pill · guide line ·
  /// small notes (+ key-build debug lines).
  Widget _buildMacroHud() {
    final level = _macroLevel;
    const small = TextStyle(
      fontSize: 11,
      color: Colors.white70,
      shadows: [Shadow(blurRadius: 3, color: Colors.black)],
    );
    final band = level == null ? 1.0 : kMacroLevelBandZoom[level]!;
    final dbg = <Widget>[
      if (AiConfig.hasEmbeddedApiKey && level != null)
        Text(
          '${_boxCheck.debug} · zoom ${_zoom.toStringAsFixed(1)}/${_macroMaxZoom.toStringAsFixed(0)}',
          key: const ValueKey('macro_box_debug'),
          style: small.copyWith(color: Colors.orange.shade300),
        ),
      if (AiConfig.hasEmbeddedApiKey && _boxDbg != null)
        Text(
          _boxDbg!,
          key: const ValueKey('macro_detect_debug'),
          style: small.copyWith(color: Colors.orange.shade300),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 6,
            alignment: WrapAlignment.center,
            children: [
              if (level != null)
                _ModeNote(
                  key: ValueKey('macro_level_pill_${level.id}'),
                  icon: Icons.layers_rounded,
                  text: macroLevelCostLabel(
                    level.label,
                    level.id,
                    quality: _macroTier.id,
                  ),
                  color: AppColors.proGold,
                ),
              if (_macroDark || _torchOn)
                GestureDetector(
                  key: const ValueKey('macro_torch'),
                  onTap: () => unawaited(_setTorch(!_torchOn)),
                  child: _ModeNote(
                    icon: _torchOn
                        ? Icons.flashlight_off_rounded
                        : Icons.flashlight_on_rounded,
                    text: _torchOn ? 'Torch off' : kTurnOnTorchHint,
                    color: _torchOn ? null : Colors.amber.shade300,
                  ),
                ),
            ],
          ),
          Text(
            level == null ? kPickMacroLevel : _boxCheck.guide.text,
            key: const ValueKey('macro_tip'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small.copyWith(
              fontSize: 12,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          // v11.40 manual macro zoom: 1x · 2x · 3x · 5x · 10x (within the max).
          if (level != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                key: const ValueKey('macro_zoom_chips'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final z in macroZoomChips(_range.hardwareMax))
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: GestureDetector(
                        key: ValueKey('macro_zoom_${z.round()}'),
                        onTap: _processingCapture
                            ? null
                            : () {
                                _stopZoomAnim();
                                unawaited(_setZoom(z));
                              },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: (_zoom - z).abs() < 0.05
                                ? AppColors.proGold
                                : Colors.black45,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${z.round()}x',
                            style: small.copyWith(
                              color: (_zoom - z).abs() < 0.05
                                  ? Colors.black
                                  : Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if ((level != null && showMicroscopeDisclaimer(band)) ||
              dbg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (level != null && showMicroscopeDisclaimer(band))
                    Text(
                      macroDisclaimerFor(band)!,
                      key: const ValueKey('microscope_disclaimer'),
                      style: small,
                    ),
                  ...dbg,
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomOverlay() {
    final badges = <Widget>[
      if (_pendingLook != null)
        _ActiveBadge(
          key: const ValueKey('active_style_badge'),
          icon: Icons.auto_awesome,
          label: _pendingLook!.label,
          onClear: () => setState(() => _pendingLook = null),
        ),
      if (_pendingVideo != null)
        _ActiveBadge(
          key: const ValueKey('active_video_badge'),
          icon: Icons.play_circle_fill_rounded,
          label: _pendingVideo!.name,
          onClear: () => setState(() => _pendingVideo = null),
        ),
      if (_night)
        _ActiveBadge(
          key: const ValueKey('night_badge'),
          icon: Icons.nightlight_round,
          label: _aiMode ? 'Pro Night' : 'Night',
          onClear: _toggleNight,
        ),
    ];
    final macro = _macroActive && _cameraReady;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (badges.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(spacing: 6, children: badges),
          ),
        // v11.27: Macro HUD + chips sit low, near the shutter.
        if (macro && !_menuOpen && !_processingCapture)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _buildMacroHud(),
          ),
        if (macro && !_menuOpen)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: MacroLevelChips(
              selected: _macroLevel,
              quality: _macroTier.id,
              onSelected: _processingCapture
                  ? null
                  : (l) => unawaited(_selectMacroLevel(l)),
            ),
          ),
        ValueListenableBuilder<CreditState?>(
          valueListenable: _account.state,
          builder: (context, st, _) {
            final info = computeZoomBadge(
              aiMode: _aiMode && _cameraReady,
              zoom: _zoom,
              optical: _optical,
              tier: _effTier,
              state: st,
              now: _account.now,
            );
            final notice = zoomNotice(info);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TransientNotice(
                message: notice,
                color: info.locked
                    ? AppColors.proGold
                    : (info.warning != null
                          ? Colors.orange.shade300
                          : Colors.white),
              ),
            );
          },
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child:
              _menuOpen && quickMenuVisible(aiMode: _aiMode, mode: _shootMode)
              ? QuickMenuBar(
                  flash: _night ? _nightFlash : _flash,
                  timer: _timer,
                  ratio: _ratio,
                  tier: _effTier,
                  stylesOpen: _panel == _Panel.filters,
                  styleActive: _styleActive,
                  flashAvailable: _lens == CameraLensDirection.back,
                  night: _night,
                  onNight: _processingCapture ? null : _toggleNight,
                  onSettings: _openSettings,
                  onFlash: _cycleFlash,
                  onTimer: _cycleTimer,
                  onRatio: _processingCapture ? null : _cycleRatio,
                  onQuality: _processingCapture ? null : _pickQuality,
                  onStyles: () => _togglePanel(_Panel.filters),
                  onClose: () => _toggleMenu(false),
                )
              : _rulerOpen
              ? Padding(
                  key: const ValueKey('ruler_wrap'),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ZoomRuler(
                    scale: _rulerScale,
                    zoom: _zoom,
                    ticks: buildRulerTicks(
                      _rulerScale,
                      lensChips: _chips.lensValues,
                      shortcuts: _chips.shortcutValues,
                    ),
                    onChanged: _processingCapture ? (_) {} : _setZoomUser,
                    onInteraction: _bumpRuler,
                  ),
                )
              : ZoomPill(
                  chips: _chips,
                  zoom: _zoom,
                  showChips: _cameraReady && !_initializing && !macro,
                  menuDot: _filterActive || _styleActive || _night,
                  menuNew: _stylesHint,
                  menuKey: _menuKey,
                  onSelected: _processingCapture ? null : _onZoomChip,
                  onOpenMenu: () => _toggleMenu(true),
                  showMenu: quickMenuVisible(aiMode: _aiMode, mode: _shootMode),
                  onRulerOpen: _processingCapture ? null : _openRuler,
                  onRulerDragStart: _processingCapture
                      ? null
                      : _onPillDragStart,
                  onRulerDragUpdate: _processingCapture
                      ? null
                      : _onPillDragUpdate,
                ),
        ),
      ],
    );
  }

  Widget _buildViewfinderArea() {
    final c = _controller;
    final b = _bokeh;
    if (b != null) {
      return Align(alignment: Alignment.topCenter, child: _buildBokehFrame(b));
    }
    if (c != null && c.value.isInitialized) {
      return Align(alignment: Alignment.topCenter, child: _buildLiveFrame(c));
    }
    if (_initializing || _processingCapture || _bokehBusy || _setupLocked) {
      // Camera hand-over / re-open: last frame (blurred), never a black
      // "Opening camera…" screen.
      return Align(
        alignment: Alignment.topCenter,
        child: AspectRatio(
          aspectRatio: _ratio.portrait,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FreezeFrame(
                key: const ValueKey('freeze_frame'),
                stats: _lastStats,
                mirror: _front,
              ),
              if (_processingCapture && _holdSteady)
                _HoldSteadyOverlay(stage: _nightStage)
              else if (_processingCapture && _nightStage != null)
                _HoldSteadyOverlay(stage: _nightStage, done: true)
              else
                const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white70,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // Clear error / permission state — never a silent blank screen.
    return Padding(
      padding: const EdgeInsets.only(bottom: 60),
      child: _CameraErrorPane(
        message: _error ?? 'Camera is not available.',
        permissionDenied: _permissionDenied,
        onRetry: _setupCamera,
        onGallery: () => _pickFromGallery(),
      ),
    );
  }

  /// NORMAL Portrait: the vendor bokeh session's own preview texture.
  Widget _buildBokehFrame(BokehStart b) {
    final turns = b.handlesCropAndRotation ? 0 : (b.sensorOrientation ~/ 90);
    Widget tex = Texture(textureId: b.textureId);
    if (_front && !b.handlesCropAndRotation) {
      tex = Transform.scale(scaleY: -1, child: tex);
    }
    tex = turns.isOdd
        ? RotatedBox(
            quarterTurns: turns,
            child: AspectRatio(aspectRatio: 4 / 3, child: tex),
          )
        : RotatedBox(
            quarterTurns: turns,
            child: AspectRatio(aspectRatio: 3 / 4, child: tex),
          );
    final m = premiumPreviewMatrix(_premium, _strength);
    if (m != null) {
      tex = ColorFiltered(colorFilter: ColorFilter.matrix(m), child: tex);
    }
    return AspectRatio(
      aspectRatio: _ratio.portrait,
      child: LayoutBuilder(
        builder: (context, box) => GestureDetector(
          key: const ValueKey('bokeh_preview'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => unawaited(
            BokehBridge.focus(
              d.localPosition.dx / box.maxWidth,
              d.localPosition.dy / box.maxHeight,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(width: 300, height: 400, child: tex),
                ),
              ),
              IgnorePointer(
                child: GridLevelOverlay(
                  grid: _features.grid,
                  level: _features.level,
                  roll: _roll,
                  flat: _flat,
                ),
              ),
              const Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: _ModeNote(
                    key: ValueKey('bokeh_note'),
                    icon: Icons.portrait_rounded,
                    text: 'Portrait · phone bokeh',
                  ),
                ),
              ),
              if (_processingCapture)
                const ColoredBox(
                  color: Color(0x66000000),
                  child: Center(
                    child: CircularProgressIndicator(color: AppColors.accent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVisionLayer(LiveVision v) {
    final showBoxes =
        (_features.faceFocus || _features.smileShot) &&
        v.faces.isNotEmpty &&
        !_processingCapture;
    if (!showBoxes) return const SizedBox.shrink();
    final boxes = [
      for (final f in v.faces)
        Rect.fromPoints(
          _toFramePx(f.box.topLeft),
          _toFramePx(f.box.bottomRight),
        ),
    ];
    return FaceBoxesOverlay(boxes: boxes);
  }

  /// Frame at the selected output ratio. For 4:3 the native 4:3 preview fills
  /// it exactly (no cover zoom). For 9:16 / 1:1 the preview is center-cropped
  /// the same way the captured file is, so what you see is what you get.
  Widget _buildLiveFrame(CameraController c) {
    final sensorAspect = c.value.aspectRatio; // landscape w/h, ~4/3
    final previewPortrait = (sensorAspect.isFinite && sensorAspect > 0)
        ? 1 / sensorAspect
        : 3 / 4;
    final local = premiumPreviewMatrix(_premium, _strength);
    final look = _liveLook;
    final lookMatrix = look.matrix;
    // Premium filter (live LUT approximation) + AI-look colour grade.
    final matrix = local == null
        ? lookMatrix
        : (lookMatrix == null ? local : composeMatrices(lookMatrix, local));

    return AspectRatio(
      aspectRatio: _ratio.portrait,
      child: LayoutBuilder(
        builder: (context, box) {
          final fw = box.maxWidth;
          final fh = box.maxHeight;
          if (fw <= 0 || fh <= 0 || !fw.isFinite || !fh.isFinite) {
            return const SizedBox.shrink();
          }
          // Cover-fit the (portrait) preview into the frame. When ratios
          // match (4:3 default) this is an exact fit: pw == fw, ph == fh.
          double pw;
          double ph;
          if (fw / fh > previewPortrait) {
            pw = fw;
            ph = fw / previewPortrait;
          } else {
            ph = fh;
            pw = fh * previewPortrait;
          }

          Widget preview = AspectRatio(
            aspectRatio: previewPortrait,
            child: CameraPreview(c),
          );
          // Live approximation of the selected free filter.
          if (matrix != null) {
            preview = ColorFiltered(
              colorFilter: ColorFilter.matrix(matrix),
              child: preview,
            );
          }

          final geometry = PreviewGeometry(
            frameSize: Size(fw, fh),
            previewSize: Size(pw, ph),
            digitalZoom: _digitalZoom,
          );
          _geometry = geometry;

          // One detector: 1-finger tap = focus, long-press = AE/AF lock,
          // 2-finger pinch = zoom (the arena disambiguates; the scale
          // handler ignores single-pointer drags).
          return GestureDetector(
            key: const ValueKey('preview_gestures'),
            behavior: HitTestBehavior.opaque,
            onTapUp: _processingCapture
                ? null
                : (d) => _brightApplied
                      ? _latchTap(d.localPosition, geometry)
                      : unawaited(
                          _focus.focusAt(
                            d.localPosition,
                            geometry,
                            zoom: _zoom,
                          ),
                        ),
            onLongPressStart: _processingCapture
                ? null
                : (d) {
                    HapticFeedback.mediumImpact();
                    if (_brightApplied) {
                      _latchTap(d.localPosition, geometry);
                      return;
                    }
                    unawaited(
                      _focus.focusAt(
                        d.localPosition,
                        geometry,
                        lock: true,
                        zoom: _zoom,
                      ),
                    );
                  },
            onScaleStart: (_) => _pinchBaseZoom = _zoom,
            onScaleUpdate: (d) {
              if (d.pointerCount < 2) return;
              if (_macroActive) {
                // v11.41: pinch 1x–10x (device max); stops any animation.
                _stopZoomAnim();
                unawaited(
                  _setZoom(
                    (_pinchBaseZoom * d.scale)
                        .clamp(1.0, _macroMaxZoom)
                        .toDouble(),
                  ),
                );
                return;
              }
              // Pinch is continuous; the ruler shows the live value.
              if (!_rulerOpen) setState(() => _rulerOpen = true);
              _bumpRuler();
              _setZoomUser(_pinchBaseZoom * d.scale);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  // Digital zoom (beyond deviceMax): centred scale,
                  // matched by the centre crop applied to the capture.
                  child: Transform.scale(
                    scale: _digitalZoom,
                    alignment: Alignment.center,
                    // Smoother upscale when scaling past the hardware max.
                    filterQuality: _digitalZoom > 1.001
                        ? FilterQuality.medium
                        : null,
                    child: OverflowBox(
                      minWidth: pw,
                      maxWidth: pw,
                      minHeight: ph,
                      maxHeight: ph,
                      alignment: Alignment.center,
                      // Portrait ratio = 1 / sensor ratio -> never stretched.
                      child: preview,
                    ),
                  ),
                ),
                IgnorePointer(
                  child: GridLevelOverlay(
                    grid: _features.grid,
                    level: _features.level,
                    roll: _roll,
                    flat: _flat,
                  ),
                ),
                // Face boxes (rebuild with live vision only).
                IgnorePointer(
                  child: ValueListenableBuilder<LiveVision>(
                    valueListenable: _vision,
                    builder: (context, v, _) => _buildVisionLayer(v),
                  ),
                ),
                if (!look.isNone)
                  Positioned(
                    top: 10,
                    right: 10,
                    child: LiveLookBadge(
                      look: look,
                      title: _pendingLook?.label ?? _aiFilter?.label ?? 'AI',
                    ),
                  ),
                // v11.42: "Hold steady" while the phone moves above 10x.
                if (_steadyOn && _steadyMoving && !_processingCapture)
                  const Positioned(
                    top: 56,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        key: ValueKey('steady_hint'),
                        child: _ModeNote(
                          icon: Icons.back_hand_rounded,
                          text: kSteadyHint,
                          color: Colors.amber,
                        ),
                      ),
                    ),
                  ),
                // v11.42 test builds: debug overlay (Settings switch).
                if (_debugOverlay && AiConfig.hasEmbeddedApiKey)
                  Positioned(
                    bottom: 4,
                    left: 6,
                    right: 6,
                    child: IgnorePointer(
                      child: Text(
                        debugOverlayText(
                          uiFps: _uiFps,
                          analysedFps: _vision.analysedFps,
                          frameW: _vision.frameWidth,
                          frameH: _vision.frameHeight,
                          gyro: _steady.rate,
                          stabilization: _stabText,
                        ),
                        key: const ValueKey('debug_overlay'),
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.greenAccent.shade200,
                          shadows: const [
                            Shadow(blurRadius: 3, color: Colors.black),
                          ],
                        ),
                      ),
                    ),
                  ),
                // v11.33 centre box: the subject must fill it.
                if (_macroActive && _macroLevel != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: FractionallySizedBox(
                          widthFactor: kMacroBoxFraction,
                          heightFactor: kMacroBoxFraction,
                          child: DecoratedBox(
                            key: const ValueKey('macro_box'),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: _boxCheck.ready
                                    ? AppColors.proGold
                                    : Colors.white70,
                                width: 2,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 48,
                  left: 12,
                  right: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_showZoomModeChip)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _ZoomModeChip(
                                key: const ValueKey('zoom_mode_chip'),
                                label: kZoomModeLabel,
                                active: _zoomModeActive,
                                onTap: () => unawaited(_toggleZoomMode()),
                              ),
                              if (_brightApplied) ...[
                                const SizedBox(width: 8),
                                _ZoomModeChip(
                                  key: const ValueKey('auto_focus_chip'),
                                  label: kAutoFocusLabel,
                                  active: false,
                                  onTap: () => unawaited(_exitLatch()),
                                ),
                              ],
                            ],
                          ),
                        ),
                      // v11.61: no clear base photo yet while zoomed deep
                      // (tap: capture it, then back) / beyond the clear
                      // range (label only — capture is never blocked).
                      if (_liveZoomNote case final note?)
                        GestureDetector(
                          key: ValueKey(
                            note == kRootMissingHint
                                ? 'root_missing_hint'
                                : 'beyond_clear_label',
                          ),
                          onTap: note == kRootMissingHint
                              ? () => unawaited(_captureAtClearLimit())
                              : null,
                          child: _ModeNote(
                            icon: note == kRootMissingHint
                                ? Icons.center_focus_strong_rounded
                                : Icons.auto_awesome_rounded,
                            text: note,
                            color: AppColors.proGold,
                          ),
                        ),
                      if (_showNewSubject && _liveZoomNote != kRootMissingHint)
                        GestureDetector(
                          key: const ValueKey('new_subject_hint'),
                          onTap: () => unawaited(_captureAtClearLimit()),
                          child: _ModeNote(
                            icon: Icons.center_focus_strong_rounded,
                            text: kNewSubjectHint,
                            color: AppColors.proGold,
                          ),
                        ),
                      if (_scan != null && !_processingCapture)
                        ScanChip(
                          action: _scan!,
                          onTap: _onScanTap,
                          onDismiss: _dismissScan,
                        ),
                      if (_tip != null && !_processingCapture)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: SuggestionChip(
                            text: _tip!.text,
                            onTap: _onTipTap,
                            onDismiss: _dismissTip,
                          ),
                        ),
                    ],
                  ),
                ),
                if (AiConfig.hasEmbeddedApiKey && _cameraReady)
                  Positioned(top: 8, left: 8, child: _buildDebugOverlay()),
                // Tap-to-focus ring / AE-AF lock label.
                ListenableBuilder(
                  listenable: _focus,
                  builder: (context, _) {
                    final at = _focus.ringPosition;
                    if (at == null) return const SizedBox.shrink();
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        FocusRing(
                          key: ValueKey('focus_ring_${_focus.seq}'),
                          center: at,
                          diameter: focusRingDiameter(Size(fw, fh)),
                          locked: _focus.locked,
                          focused: _focus.focused,
                        ),
                      ],
                    );
                  },
                ),
                if (_night && !_processingCapture)
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Row(
                      children: [
                        if (_lens == CameraLensDirection.back)
                          _NightFlashChip(
                            flash: _nightFlash,
                            onTap: _cycleNightFlash,
                          ),
                        if (_aiMode)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _RoundIcon(
                              key: const ValueKey('night_info'),
                              icon: Icons.info_outline_rounded,
                              onTap: () => showProNightTips(context),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_shootMode == ShootMode.pose && _pose != null)
                  PoseReference(
                    key: ValueKey('pose_ref_${_pose!.id}'),
                    pose: _pose!,
                    onDismiss: () => setState(() => _pose = null),
                  ),
                if (_nightCountdown != null)
                  Center(
                    child: IgnorePointer(
                      child: _HoldStillCount(seconds: _nightCountdown!),
                    ),
                  ),
                if (_countdown != null)
                  Center(
                    child: IgnorePointer(
                      child: Text(
                        '$_countdown',
                        key: const ValueKey('countdown'),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 96,
                          fontWeight: FontWeight.w300,
                          shadows: [
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.6),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_processingCapture && _holdSteady)
                  _HoldSteadyOverlay(stage: _nightStage)
                else if (_processingCapture && _nightCountdown == null)
                  ColoredBox(
                    color: const Color(0x66000000),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: AppColors.accent,
                          ),
                          // v11.29: frames done → the user may move.
                          if (_afterFrames)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text(
                                kProcessingMoveNow,
                                key: ValueKey('processing_move_now'),
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Night burst in progress: "Hold still" (then "Processing").
class _HoldSteadyOverlay extends StatelessWidget {
  const _HoldSteadyOverlay({this.stage, this.done = false});

  final String? stage;
  final bool done;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey('hold_steady'),
      color: const Color(0x55000000),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.nightlight_round,
                color: AppColors.proGold,
                size: 28,
              ),
              const SizedBox(height: 6),
              Text(
                stage ?? 'Hold still',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const SizedBox(
                width: 120,
                child: LinearProgressIndicator(color: AppColors.proGold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Night "Hold still" countdown (before the burst).
class _HoldStillCount extends StatelessWidget {
  const _HoldStillCount({required this.seconds});
  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('night_countdown'),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Hold still',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          Text(
            '$seconds',
            style: const TextStyle(
              fontSize: 54,
              fontWeight: FontWeight.w300,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill note on the viewfinder (optional one-tap action).
class _ModeNote extends StatelessWidget {
  const _ModeNote({
    super.key,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
    this.color,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color ?? Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color ?? Colors.white),
          const SizedBox(width: 6),
          Flexible(
            child: CreditText(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color ?? Colors.white,
              ),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: onAction,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.proGold,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  action!,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ] else
            const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// Night flash chip: Off / Auto / On (tap cycles).
class _NightFlashChip extends StatelessWidget {
  const _NightFlashChip({required this.flash, required this.onTap});
  final FlashChoice flash;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = switch (flash) {
      FlashChoice.off => 'Off',
      FlashChoice.auto => 'Auto',
      FlashChoice.on => 'On',
    };
    return GestureDetector(
      key: const ValueKey('night_flash'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              flash.icon,
              size: 15,
              color: flash == FlashChoice.off
                  ? Colors.white70
                  : AppColors.proGold,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({super.key, required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 17, color: Colors.white),
    ),
  );
}

/// Shutter-time state snapshot.
class _ShotSnap {
  const _ShotSnap({
    required this.ratio,
    required this.digital,
    required this.zoom,
    required this.mode,
    required this.optical,
    required this.tier,
    required this.aiFilter,
    required this.pending,
    required this.premium,
    required this.strength,
  });
  final FrameRatio ratio;
  final double digital;
  final double zoom;
  final CaptureMode mode;
  final OpticalProfile optical;
  final QualityTier tier;
  final StylePreset? aiFilter;
  final PendingLook? pending;
  final PremiumFilter premium;
  final double strength;

  bool get ai => mode == CaptureMode.pro;

  _ShotSnap withDigital(double d) => _ShotSnap(
    ratio: ratio,
    digital: d,
    zoom: zoom,
    mode: mode,
    optical: optical,
    tier: tier,
    aiFilter: aiFilter,
    pending: pending,
    premium: premium,
    strength: strength,
  );
}

class _CameraErrorPane extends StatelessWidget {
  const _CameraErrorPane({
    required this.message,
    required this.onRetry,
    required this.onGallery,
    this.permissionDenied = false,
  });

  final String message;
  final bool permissionDenied;
  final VoidCallback onRetry;
  final VoidCallback onGallery;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            permissionDenied
                ? Icons.no_photography_outlined
                : Icons.videocam_off_outlined,
            size: 64,
            color: AppColors.accentSoft,
          ),
          const SizedBox(height: 16),
          Text(
            permissionDenied ? 'Camera permission' : 'Camera unavailable',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: Text(permissionDenied ? 'Allow Camera' : 'Retry'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: onGallery,
            child: const Text('Open Gallery instead'),
          ),
        ],
      ),
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({
    required this.tier,
    required this.aiMode,
    required this.onTap,
  });

  final QualityTier tier;
  final bool aiMode;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'AI quality ${tier.label}',
      child: GestureDetector(
        key: const ValueKey('quality_chip'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 40),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: aiMode ? AppColors.accentSoft : Colors.white54,
              width: 1.4,
            ),
          ),
          child: Text(
            tier.shortLabel,
            style: TextStyle(
              color: aiMode ? Colors.white : Colors.white70,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small "Warm ✕" style badge so the user knows a filter / style is active.
class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.onClear,
  });

  final IconData icon;
  final String label;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onClear,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 3, 5, 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.proGold.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: AppColors.proGold),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 3),
            const Icon(Icons.close_rounded, size: 12, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

/// Bottom-left round thumbnail of the last shot (opens the gallery picker).
class _GalleryThumb extends StatelessWidget {
  const _GalleryThumb({required this.file, required this.onTap});

  final File? file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = file;
    return Semantics(
      button: true,
      label: 'Gallery',
      child: GestureDetector(
        key: const ValueKey('gallery_button'),
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.card,
            border: Border.all(color: Colors.white24),
          ),
          clipBehavior: Clip.antiAlias,
          child: f == null
              ? const Icon(Icons.photo_library_outlined, color: Colors.white)
              : Image.file(
                  f,
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.photo_library_outlined,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.card,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(icon, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// Shutter: white like the stock camera in Normal, AI gradient in Pro AI.
/// While the self-timer counts down it shows a stop square (tap = cancel).
class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.onTap,
    required this.ai,
    required this.countingDown,
  });

  final VoidCallback onTap;
  final bool ai;
  final bool countingDown;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: countingDown ? 'Cancel timer' : 'Take photo',
      child: GestureDetector(
        key: const ValueKey('shutter'),
        onTap: onTap,
        child: Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3.5),
          ),
          padding: const EdgeInsets.all(4),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ai ? null : Colors.white,
              gradient: ai
                  ? const LinearGradient(
                      colors: [AppColors.accentSoft, AppColors.accent],
                    )
                  : null,
            ),
            child: countingDown
                ? const Center(
                    child: Icon(Icons.stop_rounded, color: Colors.black87),
                  )
                : (ai
                      ? const Center(
                          child: Icon(
                            Icons.auto_awesome,
                            color: Colors.white,
                            size: 22,
                          ),
                        )
                      : null),
          ),
        ),
      ),
    );
  }
}

/// Samsung-style text mode tabs under the shutter: NORMAL · PRO AI.
/// Normal = plain camera; Pro AI = auto AI enhance after capture.
class _ModeTabs extends StatelessWidget {
  const _ModeTabs({required this.mode, required this.onChanged});

  final CaptureMode mode;
  final ValueChanged<CaptureMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final m in CaptureMode.values)
          Semantics(
            button: true,
            selected: m == mode,
            label: '${m.label} mode',
            child: GestureDetector(
              key: ValueKey('mode_${m.name}'),
              behavior: HitTestBehavior.opaque,
              onTap: onChanged == null ? null : () => onChanged!(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m == CaptureMode.pro) ...[
                      Icon(
                        Icons.auto_awesome,
                        size: 12,
                        color: m == mode
                            ? AppColors.proGold
                            : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      m == CaptureMode.pro ? 'PRO AI' : 'NORMAL',
                      style: TextStyle(
                        color: m == mode
                            ? (m == CaptureMode.pro
                                  ? AppColors.proGold
                                  : Colors.white)
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: m == mode
                            ? FontWeight.w800
                            : FontWeight.w600,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// v11.36 Zoom mode / Auto focus chip (filled when active).
class _ZoomModeChip extends StatelessWidget {
  const _ZoomModeChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.proGold : Colors.black54,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? AppColors.proGold : Colors.white38,
          ),
        ),
        child: Text(
          active ? '$label · ON' : label,
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
