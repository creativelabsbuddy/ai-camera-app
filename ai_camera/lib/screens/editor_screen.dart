import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/photo_edit.dart';
import '../theme/app_theme.dart';

/// Free basic editor (no AI, no credits): crop, rotate, brightness,
/// contrast, saturation, sharpness. Returns the edited file (or null).
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.file, this.saver});

  final File file;

  /// Test hook (defaults to [applyEditsToFile] in a background isolate).
  final Future<File> Function(File, EditParams)? saver;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

enum _Tab { crop, adjust }

/// Aspect presets for the crop box (null = free).
const kCropAspects = <String, double?>{
  'Free': null,
  '1:1': 1,
  '3:4': 3 / 4,
  '4:3': 4 / 3,
  '9:16': 9 / 16,
};

/// Largest centred crop (normalised) with [aspect] (w/h, pixels) inside an
/// image of [imageAspect] (w/h).
Rect centeredCrop(double imageAspect, double? aspect) {
  if (aspect == null) return const Rect.fromLTWH(0, 0, 1, 1);
  final rel = aspect / imageAspect; // normalised w / normalised h
  final w = rel >= 1 ? 1.0 : rel;
  final h = rel >= 1 ? 1 / rel : 1.0;
  return Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
}

class _EditorScreenState extends State<EditorScreen> {
  EditParams _p = const EditParams();
  _Tab _tab = _Tab.crop;
  String _aspect = 'Free';
  Size? _imageSize; // oriented pixels of the source
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final stream = FileImage(widget.file).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (mounted) {
        setState(
          () => _imageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          ),
        );
      }
      stream.removeListener(l);
    }, onError: (_, _) => stream.removeListener(l));
    stream.addListener(l);
  }

  double get _rotatedAspect {
    final s = _imageSize ?? const Size(3, 4);
    return _p.quarterTurns.isOdd ? s.height / s.width : s.width / s.height;
  }

  void _rotate() {
    setState(() {
      _p = _p.rotatedClockwise();
      final a = kCropAspects[_aspect];
      if (a != null) _p = _p.copyWith(crop: centeredCrop(_rotatedAspect, a));
    });
  }

  void _setAspect(String name) {
    setState(() {
      _aspect = name;
      _p = _p.copyWith(crop: centeredCrop(_rotatedAspect, kCropAspects[name]));
    });
  }

  Future<void> _save() async {
    if (_p.isIdentity) {
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    try {
      final saver =
          widget.saver ??
          (File f, EditParams p) async =>
              applyEditsToFile(f, p, (await getTemporaryDirectory()).path);
      final out = await saver(widget.file, _p);
      if (mounted) Navigator.pop(context, out);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Edit failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  key: const ValueKey('edit_close'),
                  icon: const Icon(Icons.close),
                  onPressed: _saving ? null : () => Navigator.pop(context),
                ),
                const Expanded(
                  child: Text(
                    'Edit · free',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  key: const ValueKey('edit_reset'),
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _p = const EditParams();
                          _aspect = 'Free';
                        }),
                  child: const Text('Reset'),
                ),
                IconButton(
                  key: const ValueKey('edit_save'),
                  icon: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  onPressed: _saving ? null : _save,
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(builder: _buildCanvas),
              ),
            ),
            SegmentedButton<_Tab>(
              segments: const [
                ButtonSegment(
                  value: _Tab.crop,
                  icon: Icon(Icons.crop_rotate_rounded),
                  label: Text('Crop & rotate'),
                ),
                ButtonSegment(
                  value: _Tab.adjust,
                  icon: Icon(Icons.tune_rounded),
                  label: Text('Adjust'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 190,
              child: _tab == _Tab.crop ? _cropControls() : _adjustControls(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCanvas(BuildContext context, BoxConstraints box) {
    final a = _rotatedAspect;
    var w = box.maxWidth, h = w / a;
    if (h > box.maxHeight) {
      h = box.maxHeight;
      w = h * a;
    }
    final size = Size(w, h);
    Widget image = Image.file(
      widget.file,
      fit: BoxFit.fill,
      gaplessPlayback: true,
    );
    if (_p.hasColor) {
      image = ColorFiltered(
        colorFilter: ColorFilter.matrix(adjustMatrix(_p)),
        child: image,
      );
    }
    return Center(
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RotatedBox(quarterTurns: _p.quarterTurns, child: image),
            _CropOverlay(
              key: const ValueKey('crop_overlay'),
              size: size,
              crop: _p.crop,
              interactive: _tab == _Tab.crop,
              aspect: kCropAspects[_aspect] == null
                  ? null
                  : kCropAspects[_aspect]! / a,
              onChanged: (r) => setState(() => _p = _p.copyWith(crop: r)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cropControls() => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    children: [
      Row(
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('edit_rotate'),
            onPressed: _rotate,
            icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
            label: const Text('Rotate'),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        children: [
          for (final n in kCropAspects.keys)
            ChoiceChip(
              key: ValueKey('crop_$n'),
              label: Text(n),
              selected: n == _aspect,
              onSelected: (_) => _setAspect(n),
            ),
        ],
      ),
    ],
  );

  Widget _adjustControls() {
    Widget slider(
      String key,
      String label,
      double value,
      double min,
      double max,
      ValueChanged<double> onChanged,
    ) => Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            key: ValueKey(key),
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            (value * 100).round().toString(),
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        slider(
          'adj_brightness',
          'Brightness',
          _p.brightness,
          -1,
          1,
          (v) => setState(() => _p = _p.copyWith(brightness: v)),
        ),
        slider(
          'adj_contrast',
          'Contrast',
          _p.contrast,
          -1,
          1,
          (v) => setState(() => _p = _p.copyWith(contrast: v)),
        ),
        slider(
          'adj_saturation',
          'Saturation',
          _p.saturation,
          -1,
          1,
          (v) => setState(() => _p = _p.copyWith(saturation: v)),
        ),
        slider(
          'adj_sharpness',
          'Sharpness',
          _p.sharpness,
          0,
          1,
          (v) => setState(() => _p = _p.copyWith(sharpness: v)),
        ),
      ],
    );
  }
}

/// Crop box with corner handles; drag inside to move. [aspect] = locked
/// normalised w/h ratio (null = free).
class _CropOverlay extends StatefulWidget {
  const _CropOverlay({
    super.key,
    required this.size,
    required this.crop,
    required this.interactive,
    required this.aspect,
    required this.onChanged,
  });

  final Size size;
  final Rect crop;
  final bool interactive;
  final double? aspect;
  final ValueChanged<Rect> onChanged;

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<_CropOverlay> {
  int? _corner; // 0 tl, 1 tr, 2 br, 3 bl, null = move
  Rect _start = Rect.zero;
  Offset _origin = Offset.zero;

  Rect get _px => Rect.fromLTWH(
    widget.crop.left * widget.size.width,
    widget.crop.top * widget.size.height,
    widget.crop.width * widget.size.width,
    widget.crop.height * widget.size.height,
  );

  void _onStart(DragStartDetails d) {
    final r = _px;
    final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    _corner = null;
    var best = 36.0;
    for (var i = 0; i < 4; i++) {
      final dist = (corners[i] - d.localPosition).distance;
      if (dist < best) {
        best = dist;
        _corner = i;
      }
    }
    _start = widget.crop;
    _origin = d.localPosition;
  }

  void _onUpdate(DragUpdateDetails d) {
    final dx = (d.localPosition.dx - _origin.dx) / widget.size.width;
    final dy = (d.localPosition.dy - _origin.dy) / widget.size.height;
    final s = _start;
    Rect r;
    if (_corner == null) {
      final l = (s.left + dx).clamp(0.0, 1 - s.width);
      final t = (s.top + dy).clamp(0.0, 1 - s.height);
      r = Rect.fromLTWH(l, t, s.width, s.height);
    } else {
      var l = s.left, t = s.top, rr = s.right, b = s.bottom;
      if (_corner == 0 || _corner == 3) l += dx;
      if (_corner == 1 || _corner == 2) rr += dx;
      if (_corner == 0 || _corner == 1) t += dy;
      if (_corner == 2 || _corner == 3) b += dy;
      l = l.clamp(0.0, rr - 0.05);
      rr = rr.clamp(l + 0.05, 1.0);
      t = t.clamp(0.0, b - 0.05);
      b = b.clamp(t + 0.05, 1.0);
      r = Rect.fromLTRB(l, t, rr, b);
      final a = widget.aspect;
      if (a != null) {
        // Keep the ratio: height follows width, anchored at the far corner.
        var w = r.width, h = w / a;
        if (h > 1) {
          h = 1;
          w = h * a;
        }
        final top = (_corner == 0 || _corner == 1) ? r.bottom - h : r.top;
        final left = (_corner == 0 || _corner == 3) ? r.right - w : r.left;
        r = Rect.fromLTWH(left.clamp(0.0, 1 - w), top.clamp(0.0, 1 - h), w, h);
      }
    }
    widget.onChanged(clampCrop(r));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: widget.interactive ? _onStart : null,
      onPanUpdate: widget.interactive ? _onUpdate : null,
      child: CustomPaint(
        painter: _CropPainter(_px, widget.interactive),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.r, this.handles);
  final Rect r;
  final bool handles;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final full = Offset.zero & size;
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(full),
        Path()..addRect(r),
      ),
      dim,
    );
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    if (!handles) return;
    final h = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final l = math.min(22.0, math.min(r.width, r.height) / 3);
    for (final (c, sx, sy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomRight, -1.0, -1.0),
      (r.bottomLeft, 1.0, -1.0),
    ]) {
      canvas.drawLine(c, c + Offset(l * sx, 0), h);
      canvas.drawLine(c, c + Offset(0, l * sy), h);
    }
    final g = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3, y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), g);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), g);
    }
  }

  @override
  bool shouldRepaint(_CropPainter o) => o.r != r || o.handles != handles;
}
