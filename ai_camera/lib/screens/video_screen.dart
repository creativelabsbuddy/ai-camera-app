import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../config/ai_config.dart';
import '../models/ai_style.dart';
import '../services/video_service.dart';
import '../services/video_style_catalog.dart';
import '../theme/app_theme.dart';
import '../widgets/style_thumb.dart';
import '../widgets/video_style_flow.dart';
import 'look_screen.dart' show LookFlowDeps;
import '../widgets/credit_icon.dart';
import '../widgets/custom_photo_panel.dart';
import '../widgets/save_style_button.dart';
import '../models/quality_tier.dart';

/// Test hooks.
class VideoDeps {
  static Future<void> Function(File f) saveVideo = (f) => Gal.putVideo(f.path);
  static Future<void> Function(File f) share = (f) => SharePlus.instance
      .share(ShareParams(files: [XFile(f.path, mimeType: 'video/mp4')]));
  static bool showPlayer = true;

  /// v11.54: "Take photo" inside the AI Video screen (system camera).
  static Future<File?> Function() cameraPicker = () async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 95, maxWidth: 3000);
    return x == null ? null : File(x.path);
  };
}

/// Long side ≤1280 px JPEG (keeps uploads small; providers resize anyway).
/// v11.58: an upright JPEG that already fits is sent as is; otherwise q100
/// (no lossy q90 re-encode).
Future<File> prepareVideoImage(File f) async {
  try {
    final out = await compute(_shrink, await f.readAsBytes());
    if (out == null) return f;
    final dir = await getTemporaryDirectory();
    final o = File('${dir.path}/video_in_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await o.writeAsBytes(out, flush: true);
    return o;
  } catch (_) {
    return f;
  }
}

Uint8List? _shrink(Uint8List b) {
  final d = img.decodeImage(b);
  if (d == null) return null;
  final rotated = d.exif.imageIfd.hasOrientation && (d.exif.imageIfd.orientation ?? 1) != 1;
  final jpeg = b.length > 2 && b[0] == 0xFF && b[1] == 0xD8;
  if (jpeg && !rotated && (d.width > d.height ? d.width : d.height) <= 1280) return null;
  final o = img.bakeOrientation(d);
  final long = o.width > o.height ? o.width : o.height;
  final r = long > 1280
      ? img.copyResize(o,
          width: o.width >= o.height ? 1280 : null,
          height: o.height > o.width ? 1280 : null)
      : o;
  return Uint8List.fromList(img.encodeJpg(r, quality: 100));
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({
    super.key,
    this.preset,
    this.photo,
    this.resolution,
    this.startCustom = false,
    this.custom = false,
    this.customPhotoFirst = false,
    this.lookPhoto,
    this.tier = QualityTier.hd,
    this.onTakePhoto,
  });

  /// v11.56 Custom window: two sections at the top, "AI Photo" and
  /// "AI Video" (no Styles section). [customPhotoFirst] selects AI Photo.
  final bool custom;
  final bool customPhotoFirst;

  /// AI Photo section: the photo to edit (null → camera / gallery).
  final File? lookPhoto;
  final QualityTier tier;
  final void Function(String prompt, QualityTier tier)? onTakePhoto;

  /// v11.54: resolution already confirmed (photo + confirm sheet done
  /// before opening) → the video starts right away.
  final String? resolution;

  /// Custom → Video: opens the Custom window on AI Video (same as
  /// [custom] with [customPhotoFirst] false).
  final bool startCustom;

  bool get isCustomWindow => custom || startCustom;

  /// Opened from a video style card: preset tab with that style selected.
  final AiStyle? preset;

  /// Optional photo (e.g. the last shot) to animate.
  final File? photo;

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  /// v11.56 Custom window section: true = AI Photo, false = AI Video.
  late bool _aiPhoto = widget.custom && !widget.startCustom && widget.customPhotoFirst;
  final _svc = VideoService.instance;
  final _prompt = TextEditingController();

  File? _photo;
  // Custom options.
  VideoKind _kind = VideoKind.i2v;
  String _aspect = '9:16';
  int _seconds = 5;
  String _res = '480p';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this, initialIndex: widget.startCustom ? 1 : 0);
    _photo = widget.photo;
    unawaited(VideoStyleCatalog.instance.ensureLoaded());
    unawaited(_svc.refreshOptions());
    unawaited(_svc.resumePending());
    if (widget.preset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _svc.job.value?.active == true) return;
        final res = widget.resolution;
        if (res != null && _photo != null) {
          unawaited(_startPreset(widget.preset!, _photo!, res));
        } else {
          unawaited(_onPreset(widget.preset!));
        }
      });
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(m)));

  Future<File?> _ensurePhoto() async {
    if (_photo != null) {
      final p = await prepareVideoImage(_photo!);
      _photo = p;
      return p;
    }
    final f = await _pickPhoto(title: 'Choose a photo');
    if (f == null) return null;
    final p = await prepareVideoImage(f);
    if (mounted) setState(() => _photo = p);
    return p;
  }

  /// v11.54: gallery or camera.
  Future<File?> _pickPhoto({required String title}) async {
    final src = await showVideoPhotoSourceSheet(context, title: title);
    if (src == null || !mounted) return null;
    return src == VideoPhotoSource.camera ? VideoDeps.cameraPicker() : LookFlowDeps.galleryPicker();
  }

  Future<void> _changePhoto() async {
    final f = await _pickPhoto(title: 'Choose a photo');
    if (f == null) return;
    final p = await prepareVideoImage(f);
    if (mounted) setState(() => _photo = p);
  }

  // -- presets -------------------------------------------------------------
  Future<void> _onPreset(AiStyle s) async {
    final photo = await _ensurePhoto();
    if (photo == null || !mounted) return;
    final res = await showVideoConfirmSheet(context, style: s, photo: photo, svc: _svc);
    if (res == null || !mounted) return;
    await _startPreset(s, photo, res);
  }

  Future<void> _startPreset(AiStyle s, File photo, String res) async {
    final p = photo.path.contains('video_in_') ? photo : await prepareVideoImage(photo);
    if (!mounted) return;
    await _go(VideoRequest(
      kind: VideoKind.i2v,
      prompt: s.prompt ?? VideoStyleCatalog.instance.promptFor(s.id) ?? s.name,
      seconds: kPresetVideoSeconds,
      resolution: res,
      aspect: '9:16',
      image: p,
      styleId: s.id,
    ));
  }

  // -- custom --------------------------------------------------------------
  VideoRequest get _custom => VideoRequest(
    kind: _kind,
    prompt: _prompt.text.trim(),
    seconds: _seconds,
    resolution: _res,
    aspect: _aspect,
    image: _kind == VideoKind.i2v ? _photo : null,
  );

  Future<void> _go(VideoRequest r) async {
    final bad = r.validate();
    if (bad != null) return _snack(bad);
    final deny = await _svc.precheck(r);
    if (deny != null) return _snack(deny);
    try {
      await _svc.start(r);
    } on VideoException catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isCustomWindow) return _customWindow();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('AI Video'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(key: ValueKey('video_tab_presets'), text: 'Styles'), Tab(key: ValueKey('video_tab_custom'), text: 'Custom')],
        ),
      ),
      body: ValueListenableBuilder<VideoJob?>(
        valueListenable: _svc.job,
        builder: (context, job, _) {
          if (job != null) return _JobView(job: job, svc: _svc, onLeave: () => Navigator.maybePop(context));
          return TabBarView(controller: _tabs, children: [_presets(), _customView()]);
        },
      ),
    );
  }

  /// v11.56 Custom window: AI Photo | AI Video segments at the top.
  Widget _customWindow() => Scaffold(
    backgroundColor: AppColors.bg,
    appBar: AppBar(title: const Text('Custom')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              key: const ValueKey('custom_segments'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('AI Photo', key: ValueKey('custom_seg_photo')),
                    icon: Icon(Icons.photo_outlined)),
                ButtonSegment(value: false, label: Text('AI Video', key: ValueKey('custom_seg_video')),
                    icon: Icon(Icons.movie_creation_outlined)),
              ],
              selected: {_aiPhoto},
              onSelectionChanged: (v) => setState(() => _aiPhoto = v.first),
            ),
          ),
        ),
        Expanded(
          child: _aiPhoto
              ? CustomPhotoPanel(
                  photo: widget.lookPhoto ?? widget.photo,
                  tier: widget.tier,
                  onTakePhoto: widget.onTakePhoto,
                )
              : ValueListenableBuilder<VideoJob?>(
                  valueListenable: _svc.job,
                  builder: (context, job, _) => job != null
                      ? _JobView(job: job, svc: _svc, onLeave: () => Navigator.maybePop(context))
                      : _customView(),
                ),
        ),
      ],
    ),
  );

  Widget _photoRow() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 44,
            height: 58,
            child: _photo == null
                ? const ColoredBox(color: AppColors.card, child: Icon(Icons.photo_outlined))
                : Image.file(_photo!, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(_photo == null ? 'No photo yet — you will pick one' : 'Your photo',
              style: const TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          key: const ValueKey('video_pick_photo'),
          onPressed: _changePhoto,
          child: Text(_photo == null ? 'Choose photo' : 'Change'),
        ),
      ],
    ),
  );

  Widget _presets() => ValueListenableBuilder<List<AiStyle>>(
    valueListenable: VideoStyleCatalog.instance.styles,
    builder: (context, list, _) => ListView(
      children: [
        _photoRow(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text('Photo → 5 s video · 9:16', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 9 / 16,
            children: [
              for (final s in list)
                GestureDetector(
                  key: ValueKey('video_style_${s.id}'),
                  onTap: () => unawaited(_onPreset(s)),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        StyleThumb(style: s),
                        const Positioned(top: 8, left: 8, child: Icon(Icons.play_circle_fill_rounded, color: Colors.white)),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: _FromChip(credits: videoFromCredits(_svc)),
                        ),
                        Positioned(
                          top: 38,
                          left: 6,
                          child: SaveStyleButton(styleId: s.id, video: true, size: 20),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            color: Colors.black54,
                            child: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _chips<T>(String keyPrefix, List<T> values, T sel, String Function(T) label, void Function(T) on) =>
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final v in values)
            ChoiceChip(
              key: ValueKey('${keyPrefix}_$v'),
              label: CreditText(label(v)),
              selected: v == sel,
              onSelected: (_) => setState(() => on(v)),
            ),
        ],
      );

  Widget _h(String t) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)),
  );

  Widget _customView() {
    final lengths = AiConfig.minimaxEnabled ? kVideoLengths : const [5];
    final r = _custom;
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: _svc.credits,
      builder: (context, _, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _h('Video type'),
          _chips<VideoKind>('video_kind', VideoKind.values, _kind,
              (k) => k == VideoKind.i2v ? 'Image → video' : 'Text → video', (k) => _kind = k),
          if (_kind == VideoKind.i2v) _photoRow(),
          _h('Describe the video'),
          TextField(
            key: const ValueKey('video_prompt'),
            controller: _prompt,
            maxLines: 3,
            maxLength: 1500,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'e.g. waves rolling onto the beach at sunset', border: OutlineInputBorder()),
          ),
          _h('Aspect ratio'),
          _chips<String>('video_aspect', kVideoAspects, _aspect, (a) => a, (a) => _aspect = a),
          _h('Length'),
          _chips<int>('video_len', lengths, _seconds, (s) => '$s s', (s) {
            _seconds = s;
            if (!resolutionsFor(s).contains(_res)) _res = '480p';
          }),
          _h('Quality'),
          _chips<String>('video_res', resolutionsFor(_seconds), _res,
              (x) => '$x · 🪙${_svc.creditsForKey(_seconds, x)}', (x) => _res = x),
          if (r.isMiniMax)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(kLongVideoWaitNote, key: ValueKey('video_wait_note'),
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('video_generate'),
            onPressed: () => unawaited(_go(_custom)),
            icon: const Icon(Icons.movie_creation_outlined),
            label: CreditText('Make video · 🪙${_svc.creditsFor(r)}'),
          ),
          const SizedBox(height: 6),
          const Text('Credits are used only when your video is ready.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

/// v11.58: "AI-generated" chip on every AI video (replaces the model chip).
class AiGeneratedLabel extends StatelessWidget {
  const AiGeneratedLabel({super.key});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      key: const ValueKey('ai_generated_label'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
      child: const Text(kAiGeneratedLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
    ),
  );
}

class _FromChip extends StatelessWidget {
  const _FromChip({required this.credits});
  final int credits;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.62), borderRadius: BorderRadius.circular(99)),
    child: CreditText(videoFromLabel(credits), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
  );
}

String _elapsed(Duration d) =>
    d.inMinutes >= 1 ? '${d.inMinutes} min ${d.inSeconds % 60} s' : '${d.inSeconds} s';

class _JobView extends StatelessWidget {
  const _JobView({required this.job, required this.svc, required this.onLeave});
  final VideoJob job;
  final VideoService svc;
  final VoidCallback onLeave;

  String get _phaseText => switch (job.phase) {
    VideoPhase.submitting => 'Sending…',
    VideoPhase.queued => 'Waiting in line…',
    VideoPhase.running => 'Making your video…',
    VideoPhase.downloading => 'Almost done…',
    VideoPhase.done => 'Ready',
    VideoPhase.failed => 'Video failed',
    VideoPhase.cancelled => 'Cancelled',
  };

  @override
  Widget build(BuildContext context) {
    if (job.phase == VideoPhase.done && job.file != null) {
      return _ResultView(job: job, svc: svc);
    }
    final r = job.request;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (job.active) const Center(child: CircularProgressIndicator(key: ValueKey('video_progress'))),
          if (!job.active)
            Icon(job.phase == VideoPhase.failed ? Icons.error_outline : Icons.cancel_outlined,
                size: 48, color: AppColors.textSecondary),
          const SizedBox(height: 16),
          Text(_phaseText, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('${r.seconds} s · ${r.resolution} · ${r.aspect}',
              textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
          if (job.active) ...[
            const SizedBox(height: 4),
            StreamBuilder<int>(
              stream: Stream.periodic(const Duration(seconds: 1), (i) => i),
              builder: (_, _) => Text(
                '${_elapsed(DateTime.now().difference(job.started))} · '
                '${r.isMiniMax ? kLongVideoWaitNote : 'Usually ready in 1–3 min'}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
          ],
          if (job.active) ...[
            const SizedBox(height: 8),
            const Text(
              "You can leave this screen. We'll send a notification when your video is ready. "
              'If it is not ready in 30 min, your credits are refunded.',
              key: ValueKey('video_background_note'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
          if (job.error != null) ...[
            const SizedBox(height: 10),
            Text(job.error!, key: const ValueKey('video_error'), textAlign: TextAlign.center),
            if (job.error != kVideoTimeoutMessage)
              const Text('No credits were used.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.success)),
          ],
          const SizedBox(height: 24),
          if (job.active) ...[
            FilledButton.tonal(
              key: const ValueKey('video_leave'),
              onPressed: onLeave,
              child: const Text('Keep making in background'),
            ),
            TextButton(
              key: const ValueKey('video_cancel'),
              onPressed: () => unawaited(svc.cancel()),
              child: const Text('Cancel (no credits used)'),
            ),
          ] else
            FilledButton(
              key: const ValueKey('video_again'),
              onPressed: svc.dismiss,
              child: const Text('OK'),
            ),
        ],
      ),
    );
  }
}

class _ResultView extends StatefulWidget {
  const _ResultView({required this.job, required this.svc});
  final VideoJob job;
  final VideoService svc;
  @override
  State<_ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<_ResultView> {
  VideoPlayerController? _c;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    if (VideoDeps.showPlayer) {
      _c = VideoPlayerController.file(widget.job.file!)
        ..setLooping(true)
        ..initialize().then((_) {
          if (mounted) {
            setState(() {});
            _c!.play();
          }
        });
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await VideoDeps.saveVideo(widget.job.file!);
      if (mounted) setState(() => _saved = true);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to gallery')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save the video')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final j = widget.job;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Stack(
              children: [
                if (c != null && c.value.isInitialized)
                  GestureDetector(
                    onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
                    child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
                  )
                else
                  const SizedBox(key: ValueKey('video_result'), width: 120, height: 120, child: Icon(Icons.movie, size: 64)),
                const Positioned(right: 8, bottom: 8, child: AiGeneratedLabel()),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: CreditText(
            j.creditsCharged > 0 ? '🪙${j.creditsCharged} used' : 'Ready',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('video_save'),
                    onPressed: _saved ? null : _save,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(_saved ? 'Saved' : 'Save'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('video_share'),
                    onPressed: () => unawaited(VideoDeps.share(j.file!)),
                    icon: const Icon(Icons.share_rounded),
                    label: const Text('Share'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('video_new'),
                  tooltip: 'New video',
                  onPressed: widget.svc.dismiss,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
