import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/burst_shot.dart';
import '../services/capture_crop.dart';
import '../services/photo_saver.dart';
import '../theme/app_theme.dart';

/// What the burst review returns to the camera.
class BurstResult {
  const BurstResult({required this.saved, required this.deleted});

  /// Prepared (cropped) files that were saved to the gallery.
  final List<File> saved;
  final int deleted;
}

/// v11.69 Burst review (Normal Photo): all frames in a strip, the auto-picked
/// best marked "Best", one tap "Keep best, delete rest" (with confirm) or
/// "Keep all". Nothing is put in the gallery until the user chooses.
class BurstReviewScreen extends StatefulWidget {
  const BurstReviewScreen({
    super.key,
    required this.frames,
    required this.portraitRatio,
    this.digitalZoom = 1.0,
    this.prepare,
    this.save,
  });

  /// Raw stills from the camera (temporary files).
  final List<String> frames;

  /// The on-screen frame ratio / digital zoom (the saved photo is cropped
  /// exactly like a single shot).
  final double portraitRatio;
  final double digitalZoom;

  /// Raw still → final file (default: the single-shot crop).
  final Future<String> Function(String raw)? prepare;

  /// Saves a final file (default: gallery "AI Camera" album).
  final Future<String> Function(File f)? save;

  @override
  State<BurstReviewScreen> createState() => _BurstReviewScreenState();
}

class _BurstReviewScreenState extends State<BurstReviewScreen> {
  late final List<BurstScore?> _scores = List.filled(
    widget.frames.length,
    null,
  );
  late final List<(int, int)?> _sizes = List.filled(widget.frames.length, null);
  int _selected = 0;
  int? _best;
  bool _analysing = true;
  bool _saving = false;
  String? _progress;

  @override
  void initState() {
    super.initState();
    unawaited(_analyse());
  }

  @override
  void dispose() {
    unawaited(BurstAnalyzer.close());
    super.dispose();
  }

  Future<void> _analyse() async {
    final n = widget.frames.length;
    final sharp = List<double>.filled(n, 0);
    // 1. Sharpness of every frame (small native decode).
    for (var i = 0; i < n; i++) {
      final path = widget.frames[i];
      try {
        final px = await BurstAnalyzer.decode(path);
        if (px != null) {
          _sizes[i] = (px.$2, px.$3);
          sharp[i] = laplacianVariance(px.$1, px.$2, px.$3);
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() => _progress = 'Picking best ${i + 1}/$n');
    }
    // 2. Faces: check the sharpest frame first; eyes only matter with faces.
    var top = 0;
    for (var i = 1; i < n; i++) {
      if (sharp[i] > sharp[top]) top = i;
    }
    final probe = await BurstAnalyzer.eyesOf(widget.frames[top]);
    final eyes = List<List<double>?>.filled(n, null);
    eyes[top] = probe;
    if (probe != null && probe.isNotEmpty) {
      for (var i = 0; i < n; i++) {
        if (i == top) continue;
        eyes[i] = await BurstAnalyzer.eyesOf(widget.frames[i]);
        if (!mounted) return;
        setState(() => _progress = 'Checking eyes ${i + 1}/$n');
      }
    }
    final scores = [
      for (var i = 0; i < n; i++)
        BurstScore(
          sharpness: sharp[i],
          eyes: probe == null || probe.isEmpty ? null : eyes[i],
        ),
    ];
    final best = pickBestFrame(scores);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < n; i++) {
        _scores[i] = scores[i];
      }
      _best = best < 0 ? 0 : best;
      _selected = _best!;
      _analysing = false;
      _progress = scores.isEmpty ? null : bestReason(scores);
    });
  }

  Future<bool> _confirm(String title, String body, String ok) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const ValueKey('burst_confirm_cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('burst_confirm_ok'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  Future<String> _prepare(String raw) async {
    final f = widget.prepare;
    if (f != null) return f(raw);
    final r = await processCapture(
      raw,
      portraitRatio: widget.portraitRatio,
      label: 'burst',
      digitalZoom: widget.digitalZoom,
      writeContext: false,
    );
    return r.path;
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<void> _keep(List<int> keep) async {
    if (_saving) return;
    setState(() => _saving = true);
    final saved = <File>[];
    final save = widget.save ?? savePhotoToGallery;
    String? msg;
    try {
      for (final (k, i) in keep.indexed) {
        if (!mounted) return;
        setState(() => _progress = 'Saving ${k + 1}/${keep.length}');
        final raw = widget.frames[i];
        final out = await _prepare(raw);
        msg = await save(File(out));
        saved.add(File(out));
        if (out != raw) unawaited(_deleteQuietly(raw));
      }
      for (var i = 0; i < widget.frames.length; i++) {
        if (!keep.contains(i)) unawaited(_deleteQuietly(widget.frames[i]));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _progress = 'Save failed: $e';
        });
      }
      return;
    }
    if (!mounted) return;
    final deleted = widget.frames.length - keep.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          keep.length == 1
              ? 'Kept 1 photo · $deleted deleted${msg == null ? '' : '\n$msg'}'
              : 'Kept ${keep.length} photos${msg == null ? '' : '\n$msg'}',
        ),
      ),
    );
    Navigator.pop(context, BurstResult(saved: saved, deleted: deleted));
  }

  Future<void> _keepOne() async {
    final i = _selected;
    final rest = widget.frames.length - 1;
    final isBest = i == _best;
    final ok = await _confirm(
      isBest ? 'Keep best photo?' : 'Keep this photo?',
      'The other $rest photo${rest == 1 ? '' : 's'} will be deleted.',
      'Keep & delete',
    );
    if (ok) await _keep([i]);
  }

  Future<void> _keepAll() =>
      _keep([for (var i = 0; i < widget.frames.length; i++) i]);

  Future<void> _discard() async {
    final ok = await _confirm(
      'Discard burst?',
      'All ${widget.frames.length} photos will be deleted.',
      'Discard',
    );
    if (!ok || !mounted) return;
    for (final f in widget.frames) {
      unawaited(_deleteQuietly(f));
    }
    Navigator.pop(
      context,
      BurstResult(saved: const [], deleted: widget.frames.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.frames.length;
    final busy = _analysing || _saving;
    final isBest = _selected == _best;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) unawaited(_discard());
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('burst_close'),
                      onPressed: _saving ? null : _discard,
                      icon: const Icon(Icons.close),
                    ),
                    Expanded(
                      child: Text(
                        'Burst · $n photos',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _CroppedFrame(
                        key: ValueKey('burst_main_$_selected'),
                        path: widget.frames[_selected],
                        size: _sizes[_selected],
                        portraitRatio: widget.portraitRatio,
                        digitalZoom: widget.digitalZoom,
                        cacheWidth: 1080,
                      ),
                      if (isBest && !_analysing)
                        const Positioned(
                          top: 10,
                          left: 10,
                          child: _BestBadge(large: true),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        _progress ?? '',
                        key: const ValueKey('burst_status'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 78,
                child: ListView.separated(
                  key: const ValueKey('burst_strip'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: n,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) => GestureDetector(
                    key: ValueKey('burst_thumb_$i'),
                    onTap: _saving ? null : () => setState(() => _selected = i),
                    child: Container(
                      width: 62,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: i == _selected
                              ? Colors.white
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _CroppedFrame(
                              path: widget.frames[i],
                              size: _sizes[i],
                              portraitRatio: widget.portraitRatio,
                              digitalZoom: widget.digitalZoom,
                              cacheWidth: 180,
                              cover: true,
                            ),
                            if (i == _best && !_analysing)
                              const Positioned(
                                left: 3,
                                bottom: 3,
                                child: _BestBadge(),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: FilledButton.icon(
                        key: const ValueKey('burst_keep_best'),
                        onPressed: busy ? null : _keepOne,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.check_rounded, size: 20),
                        label: Text(
                          isBest || _analysing
                              ? 'Keep best, delete rest'
                              : 'Keep this, delete rest',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        key: const ValueKey('burst_keep_all'),
                        onPressed: busy ? null : _keepAll,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          'Keep all',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BestBadge extends StatelessWidget {
  const _BestBadge({this.large = false});

  final bool large;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('burst_best_badge'),
    padding: EdgeInsets.symmetric(
      horizontal: large ? 10 : 5,
      vertical: large ? 4 : 2,
    ),
    decoration: BoxDecoration(
      color: AppColors.proGold,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: large ? 14 : 10, color: Colors.black),
        SizedBox(width: large ? 3 : 1),
        Text(
          'Best',
          style: TextStyle(
            color: Colors.black,
            fontSize: large ? 12 : 9,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

/// A raw frame shown with the same centre crop the saved photo will get.
class _CroppedFrame extends StatelessWidget {
  const _CroppedFrame({
    super.key,
    required this.path,
    required this.size,
    required this.portraitRatio,
    required this.digitalZoom,
    required this.cacheWidth,
    this.cover = false,
  });

  final String path;

  /// Decoded (upright) size, any scale; null = not known yet → full frame.
  final (int, int)? size;
  final double portraitRatio;
  final double digitalZoom;
  final int cacheWidth;
  final bool cover;

  @override
  Widget build(BuildContext context) {
    final image = Image.file(
      File(path),
      cacheWidth: cacheWidth,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
    );
    final sz = size;
    if (sz == null) {
      return Image.file(
        File(path),
        cacheWidth: cacheWidth,
        fit: cover ? BoxFit.cover : BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
      );
    }
    final (w, h) = sz;
    final r = computeCaptureCrop(
      iw: w,
      ih: h,
      portraitRatio: portraitRatio,
      digitalZoom: digitalZoom,
    );
    return FittedBox(
      fit: cover ? BoxFit.cover : BoxFit.contain,
      clipBehavior: Clip.hardEdge,
      child: ClipRect(
        child: SizedBox(
          width: r.width.toDouble(),
          height: r.height.toDouble(),
          child: OverflowBox(
            minWidth: w.toDouble(),
            maxWidth: w.toDouble(),
            minHeight: h.toDouble(),
            maxHeight: h.toDouble(),
            child: SizedBox(
              width: w.toDouble(),
              height: h.toDouble(),
              child: image,
            ),
          ),
        ),
      ),
    );
  }
}
