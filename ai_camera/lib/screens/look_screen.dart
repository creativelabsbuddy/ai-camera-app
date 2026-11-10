import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/ai_style.dart';
import '../models/quality_tier.dart';
import '../services/account_service.dart';
import '../services/ai_call.dart';
import '../services/entitlements.dart';
import '../services/look_service.dart';
import '../services/person_check.dart';
import '../services/photo_saver.dart';
import '../services/style_catalog.dart';
import '../theme/app_theme.dart';
import '../widgets/ai_working_frame.dart';
import '../widgets/compare_slider.dart';
import '../widgets/look_sheet.dart';
import '../widgets/pro_upgrade_sheet.dart';
import '../widgets/style_card_strip.dart';
import '../widgets/credit_icon.dart';

typedef GalleryPicker = Future<File?> Function();

/// Default gallery source (image_picker).
Future<File?> pickPhotoFromGallery() async {
  final x = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    imageQuality: 95,
    maxWidth: 3000,
  );
  return x == null ? null : File(x.path);
}

/// Look picked before the photo exists (camera quick menu → Take photo).
class PendingLook {
  const PendingLook({
    this.style,
    this.customPrompt,
    this.tier = QualityTier.hd,
  });

  final AiStyle? style;
  final String? customPrompt;
  final QualityTier tier;

  String get label => style?.name ?? 'Your change';
}

/// Test hooks (fake look service / gallery / saver).
class LookFlowDeps {
  static LookService Function() service = LookService.new;
  static GalleryPicker galleryPicker = pickPhotoFromGallery;
  static Future<String> Function(File) saver = savePhotoToGallery;

  static void reset() {
    service = LookService.new;
    galleryPicker = pickPhotoFromGallery;
    saver = savePhotoToGallery;
  }
}

/// Look sheet for [photo] → on Apply, the look screen (runs the AI).
Future<void> startLook(
  BuildContext context, {
  required File photo,
  AiStyle? style,
  QualityTier tier = QualityTier.hd,
  String? initialPrompt,
}) async {
  final r = await showLookSheet(
    context,
    style: style,
    photo: photo,
    tier: tier,
    initialPrompt: initialPrompt,
  );
  if (r == null || r.action != LookSheetAction.apply || !context.mounted) {
    return;
  }
  final job = LookJob(
    image: photo,
    style: style,
    customPrompt: r.customPrompt,
    tier: r.tier,
  );
  if (!await confirmPersonForLook(context, job) || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LookScreen(original: photo, job: job),
    ),
  );
}

/// Person library styles only: quick on-device face check before spending
/// credits. No face → "No person found in this photo" with Apply anyway.
/// Custom changes and non-person styles are never checked.
Future<bool> confirmPersonForLook(BuildContext context, LookJob job) async {
  if (!job.needsPerson) return true;
  final has = await PersonCheck.hasPerson(job.image);
  if (has != false || !context.mounted) return true;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('person_warning'),
      title: const Text('No person found in this photo'),
      content: Text(
        '"${job.label}" is made for photos of people. With no person in '
        'the photo the AI may fail or invent someone. Credits are only used '
        'if the AI photo is ready.',
      ),
      actions: [
        TextButton(
          key: const ValueKey('person_warning_cancel'),
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Choose another photo'),
        ),
        FilledButton(
          key: const ValueKey('person_warning_apply'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Apply anyway'),
        ),
      ],
    ),
  );
  return go ?? false;
}

/// Style picked without a photo (camera quick menu): "Take photo" calls
/// [onTakePhoto]; "Choose from gallery" picks one and continues.
Future<void> startLookWithoutPhoto(
  BuildContext context, {
  AiStyle? style,
  QualityTier tier = QualityTier.hd,
  required void Function(LookSheetResult r) onTakePhoto,
}) async {
  final r = await showLookSheet(context, style: style, tier: tier);
  if (r == null || !context.mounted) return;
  switch (r.action) {
    case LookSheetAction.takePhoto:
      onTakePhoto(r);
    case LookSheetAction.pickGallery:
      final f = await LookFlowDeps.galleryPicker();
      if (f == null || !context.mounted) return;
      await startLook(
        context,
        photo: f,
        style: style,
        tier: r.tier,
        initialPrompt: r.customPrompt,
      );
    case LookSheetAction.apply:
      break;
  }
}

/// Runs a look (AI wave overlay over the photo), then shows the result:
/// before/after compare slider, variation picker, Save, Try another style,
/// Retry. The original photo is never modified.
class LookScreen extends StatefulWidget {
  const LookScreen({super.key, required this.original, required this.job});

  /// Belt-and-braces: even if something below never completes, the screen
  /// leaves the loading state (each AI request already times out at 90 s;
  /// parallel variation top-ups add at most one more slot).
  static const Duration watchdog = Duration(seconds: 240);

  final File original;
  final LookJob job;

  @override
  State<LookScreen> createState() => _LookScreenState();
}

class _LookScreenState extends State<LookScreen> {
  late final LookService _service = LookFlowDeps.service();
  late LookJob _job = widget.job;
  bool _running = false;
  List<File> _results = const [];
  int _selected = 0;
  String? _status;
  bool _showStrip = false;
  bool _saving = false;
  AiCancelToken? _cancel;
  int _runId = 0;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  void _cancelRun() {
    _cancel?.cancel();
    _runId++;
    setState(() {
      _running = false;
      _status = aiFailureMessage(AiFailureKind.cancelled);
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(StyleCatalog.instance.ensureLoaded());
    WidgetsBinding.instance.addPostFrameCallback((_) => _run(_job));
  }

  Future<void> _run(LookJob job) async {
    _cancel?.cancel();
    final token = _cancel = AiCancelToken();
    final id = ++_runId;
    setState(() {
      _job = job;
      _running = true;
      _status = null;
      _showStrip = false;
    });
    LookResult r;
    try {
      r = await _service.apply(job, cancel: token).timeout(LookScreen.watchdog);
    } on TimeoutException catch (e) {
      token.cancel();
      r = LookResult(error: '$e', failure: AiFailureKind.timeout);
    } catch (e) {
      r = LookResult(error: '$e', failure: classifyAiError(e));
    }
    // Cancelled / superseded: the cancel handler already updated the UI.
    if (!mounted || id != _runId) return;
    setState(() => _running = false);
    if (r.denied != null) {
      final msg = denyMessage(r.denied!);
      setState(() => _status = msg);
      unawaited(showProUpgradeSheet(context, reason: msg));
      return;
    }
    if (r.unavailable) {
      setState(
        () => _status =
            'AI styles need the AI server — add a server URL in Settings',
      );
      return;
    }
    if (!r.ok) {
      // Status line only (a snackbar would cover the Retry button).
      debugPrint('AI style failed (nothing charged): ${r.error}');
      setState(() {
        _status = aiFailureMessage(
          r.failure ?? AiFailureKind.other,
          isStyle: job.isStyle,
        );
      });
      return;
    }
    final paid = r.trialsUsed.isNotEmpty
        ? 'Starter trial · free'
        : '🪙${r.creditsCharged} used';
    setState(() {
      _results = r.files;
      _selected = 0;
      _status = '${job.label} · $paid';
    });
  }

  Future<void> _save() async {
    if (_results.isEmpty) return;
    setState(() => _saving = true);
    try {
      final msg = await LookFlowDeps.saver(_results[_selected]);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _another({AiStyle? style}) async {
    final r = await showLookSheet(
      context,
      style: style,
      photo: widget.original,
      tier: _job.tier,
    );
    if (r == null || r.action != LookSheetAction.apply || !mounted) return;
    final job = LookJob(
      image: widget.original,
      style: style,
      customPrompt: r.customPrompt,
      tier: r.tier,
    );
    if (!await confirmPersonForLook(context, job) || !mounted) return;
    await _run(job);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _running || _saving;
    final account = AccountService.instance;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('look_close'),
                    // Closing while the AI works cancels it (nothing charged).
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                  Expanded(
                    child: Text(
                      _job.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const LiveCreditsPill(),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: AiWorkingFrame(
                  active: _running,
                  label: 'AI · ${_job.label}',
                  showElapsed: true,
                  onCancel: _cancelRun,
                  child: _results.isEmpty
                      ? Image.file(widget.original, fit: BoxFit.contain)
                      : CompareSlider(
                          key: ValueKey(_results[_selected].path),
                          before: widget.original,
                          after: _results[_selected],
                        ),
                ),
              ),
            ),
            if (_results.length > 1)
              SizedBox(
                height: 66,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  scrollDirection: Axis.horizontal,
                  itemCount: _results.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => GestureDetector(
                    key: ValueKey('variation_$i'),
                    onTap: () => setState(() => _selected = i),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          width: 2,
                          color: i == _selected
                              ? AppColors.accent
                              : Colors.transparent,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(7),
                        child: Image.file(
                          _results[i],
                          width: 33,
                          height: 58.7,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_status != null && !_running)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: CreditText(
                  _status!,
                  key: const ValueKey('look_status'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            if (_showStrip)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: ValueListenableBuilder<List<AiStyle>>(
                  valueListenable: StyleCatalog.instance.styles,
                  builder: (context, styles, _) =>
                      ValueListenableBuilder<CreditState?>(
                        valueListenable: account.state,
                        builder: (context, st, _) => StyleCardStrip(
                          styles: styles,
                          isPro: st?.isPro(account.now) ?? false,
                          trialAvailable:
                              st?.trialAvailable(StarterTrial.libraryStyle) ??
                              true,
                          enabled: !busy,
                          onStyle: (s) => _another(style: s),
                          onCustom: () => _another(),
                        ),
                      ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
              child: Row(
                children: [
                  Expanded(
                    child: _Btn(
                      key: const ValueKey('look_save'),
                      icon: Icons.save_alt_rounded,
                      label: 'Save',
                      filled: true,
                      onPressed: busy || _results.isEmpty ? null : _save,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Btn(
                      key: const ValueKey('look_try_another'),
                      icon: Icons.style_outlined,
                      label: 'Try another',
                      onPressed: busy
                          ? null
                          : () => setState(() => _showStrip = !_showStrip),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Btn(
                      key: const ValueKey('look_retry'),
                      icon: Icons.refresh_rounded,
                      label: 'Retry',
                      onPressed: busy ? null : () => _run(_job),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({
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
    final child = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    const pad = EdgeInsets.symmetric(vertical: 14);
    return filled
        ? FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: pad,
              shape: shape,
            ),
            child: child,
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              padding: pad,
              shape: shape,
            ),
            child: child,
          );
  }
}
