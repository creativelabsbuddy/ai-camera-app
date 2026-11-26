import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../config/features_v1170.dart';
import '../services/adjust_presets.dart';
import '../services/edit_render_v1170.dart';
import '../services/edit_v1170.dart';
import '../services/tone_proxy.dart';
import '../theme/app_theme.dart';
import 'editor_screen.dart' show CropOverlay, centeredCrop;

/// Result of a saved edit: the NEW edited copy (the original is kept).
class EditedPhoto {
  const EditedPhoto(this.file, {required this.savedToGallery});
  final File file;
  final bool savedToGallery;
}

/// Proxy pixels for the live preview.
typedef EditProxyPixels = ({Uint8List rgba, int width, int height});

/// v11.70 crop aspect presets (null = free; 0 = the photo's own ratio).
const kEditorAspects = <String, double?>{
  'Free': null,
  'Original': 0,
  '1:1': 1,
  '4:5': 4 / 5,
  '3:4': 3 / 4,
  '4:3': 4 / 3,
  '9:16': 9 / 16,
  '16:9': 16 / 9,
};

enum EditorTab {
  crop('Crop', Icons.crop_rotate_rounded),
  adjust('Adjust', Icons.tune_rounded),
  retouch('Retouch', Icons.face_retouching_natural_rounded),
  skin('Skin Tone', Icons.contrast_rounded);

  const EditorTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Retouch sliders (id, label).
const kRetouchSliders = <(String, String)>[
  ('smooth', 'Smooth skin'),
  ('faceLight', 'Brighten face'),
  ('eyes', 'Eyes'),
  ('teeth', 'Teeth whiten'),
  ('underEye', 'Under-eye'),
];

double retouchValue(RetouchParams r, String id) => switch (id) {
  'smooth' => r.smooth,
  'faceLight' => r.faceLight,
  'eyes' => r.eyes,
  'teeth' => r.teeth,
  'underEye' => r.underEye,
  _ => 0,
};

RetouchParams retouchWith(RetouchParams r, String id, double v) => switch (id) {
  'smooth' => r.copyWith(smooth: v),
  'faceLight' => r.copyWith(faceLight: v),
  'eyes' => r.copyWith(eyes: v),
  'teeth' => r.copyWith(teeth: v),
  'underEye' => r.copyWith(underEye: v),
  _ => r,
};

/// Displayed (rotated) normalised point → the upright original's point.
Offset unrotatePoint(Offset d, int quarterTurns) => switch (quarterTurns % 4) {
  1 => Offset(d.dy, 1 - d.dx),
  2 => Offset(1 - d.dx, 1 - d.dy),
  3 => Offset(1 - d.dy, d.dx),
  _ => d,
};

/// v11.70 free editor: Crop · Adjust · Retouch · Skin Tone. On device, no
/// AI, no credits. Save writes a NEW edited copy (gallery too) and keeps
/// the original. Pops an [EditedPhoto] (null = nothing saved).
class PhotoEditorScreen extends StatefulWidget {
  const PhotoEditorScreen({
    super.key,
    required this.file,
    this.saver,
    this.gallerySaver,
    this.faceDetector,
    this.proxyLoader,
  });

  final File file;

  /// Test hooks.
  final Future<File> Function(File, EditRecipe, List<FaceGeom>)? saver;
  final Future<bool> Function(File)? gallerySaver;
  final Future<List<FaceGeom>> Function(Uint8List, int, int)? faceDetector;
  final Future<EditProxyPixels?> Function(File)? proxyLoader;

  @override
  State<PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<PhotoEditorScreen> {
  EditRecipe _r = const EditRecipe();
  EditorTab _tab = EditorTab.adjust;
  String _aspect = 'Free';
  Size? _imageSize;
  bool _saving = false;

  EditProxyPixels? _proxy;
  List<FaceGeom>? _faces; // null = still looking
  ui.Image? _view;
  String? _viewKey;
  bool _rendering = false;
  bool _dirty = false;
  bool _hold = false;
  bool _heal = false;
  List<AdjustPreset> _userPresets = const [];

  List<EditorTab> get _tabs => [
    EditorTab.crop,
    EditorTab.adjust,
    if (kRetouch) EditorTab.retouch,
    if (kSkinTone) EditorTab.skin,
  ];

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
    unawaited(_loadProxy());
    unawaited(
      AdjustPresetStore.load().then((v) {
        if (mounted) setState(() => _userPresets = v);
      }),
    );
  }

  @override
  void dispose() {
    _view?.dispose();
    super.dispose();
  }

  Future<void> _loadProxy() async {
    EditProxyPixels? px;
    try {
      if (widget.proxyLoader != null) {
        px = await widget.proxyLoader!(widget.file);
      } else {
        final tp = await ToneProxy.load(widget.file, maxLong: 1080);
        if (tp != null) {
          px = (rgba: tp.rgba, width: tp.width, height: tp.height);
        }
      }
    } catch (e) {
      debugPrint('Editor proxy failed: $e');
    }
    if (!mounted) return;
    setState(() => _proxy = px);
    if (px == null) {
      setState(() => _faces = const []);
      return;
    }
    List<FaceGeom> faces = const [];
    try {
      faces = widget.faceDetector != null
          ? await widget.faceDetector!(px.rgba, px.width, px.height)
          : await detectFaceGeoms(
              px.rgba,
              px.width,
              px.height,
              tmpDir: (await getTemporaryDirectory()).path,
            );
    } catch (e) {
      debugPrint('Editor faces failed: $e');
    }
    if (!mounted) return;
    setState(() => _faces = faces);
    _render();
  }

  void _set(EditRecipe r) {
    setState(() => _r = r);
    _render();
  }

  Future<void> _render() async {
    final px = _proxy;
    if (px == null) return;
    if (_rendering) {
      _dirty = true;
      return;
    }
    _rendering = true;
    try {
      do {
        _dirty = false;
        final r = _r;
        if (!r.hasPixels) {
          final old = _view;
          setState(() {
            _view = null;
            _viewKey = null;
          });
          old?.dispose();
          continue;
        }
        final key = r.pixelKey;
        if (key == _viewKey) continue;
        final out = await renderEditProxy(
          px.rgba,
          px.width,
          px.height,
          r,
          _faces ?? const [],
        );
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          out,
          px.width,
          px.height,
          ui.PixelFormat.rgba8888,
          c.complete,
        );
        final im = await c.future;
        if (!mounted) {
          im.dispose();
          return;
        }
        final old = _view;
        setState(() {
          _view = im;
          _viewKey = key;
        });
        old?.dispose();
      } while (_dirty && mounted);
    } catch (e) {
      debugPrint('Editor preview failed: $e');
    } finally {
      _rendering = false;
    }
  }

  double get _rotatedAspect {
    final s = _imageSize ?? const Size(3, 4);
    return _r.quarterTurns.isOdd ? s.height / s.width : s.width / s.height;
  }

  double? _aspectValue(String name) {
    final a = kEditorAspects[name];
    if (a == 0) return _rotatedAspect;
    return a;
  }

  void _rotate() {
    var r = _r.copyWith(quarterTurns: (_r.quarterTurns + 1) % 4);
    // The crop turns with the image (same maths as the v10 editor).
    final c = _r.crop;
    r = r.copyWith(
      crop: Rect.fromLTWH(1 - c.top - c.height, c.left, c.height, c.width),
    );
    setState(() => _r = r);
    final a = _aspectValue(_aspect);
    if (a != null) {
      setState(() => _r = _r.copyWith(crop: centeredCrop(_rotatedAspect, a)));
    }
  }

  void _setAspect(String name) {
    setState(() {
      _aspect = name;
      _r = _r.copyWith(crop: centeredCrop(_rotatedAspect, _aspectValue(name)));
    });
  }

  void _reset() {
    setState(() {
      _aspect = 'Free';
      _heal = false;
    });
    _set(const EditRecipe());
  }

  Future<void> _save() async {
    if (_r.isIdentity) {
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    try {
      final faces = _faces ?? const <FaceGeom>[];
      final saver =
          widget.saver ??
          (File f, EditRecipe r, List<FaceGeom> fc) async => renderEditFile(
            f,
            r,
            fc,
            outDir: (await getTemporaryDirectory()).path,
          );
      final out = await saver(widget.file, _r, faces);
      var saved = false;
      try {
        saved = await (widget.gallerySaver ?? _toGallery)(out);
      } catch (e) {
        debugPrint('Edited copy not saved to gallery: $e');
      }
      if (mounted) {
        Navigator.pop(context, EditedPhoto(out, savedToGallery: saved));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Edit failed: $e')));
    }
  }

  static Future<bool> _toGallery(File f) async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      if (!await Gal.requestAccess(toAlbum: true)) return false;
    }
    await Gal.putImage(f.path, album: 'AI Camera');
    return true;
  }

  Future<void> _savePreset() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save as preset'),
        content: TextField(
          key: const ValueKey('preset_name'),
          controller: ctl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: 'Preset name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('preset_save'),
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final l = await AdjustPresetStore.add(name, _r.adjust);
    if (mounted) setState(() => _userPresets = l);
  }

  Future<void> _deletePreset(AdjustPreset p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${p.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final l = await AdjustPresetStore.remove(p.name);
    if (mounted) setState(() => _userPresets = l);
  }

  void _onCanvasTap(Offset local, Size size) {
    if (!(_tab == EditorTab.retouch && _heal)) return;
    final d = Offset(local.dx / size.width, local.dy / size.height);
    if (d.dx < 0 || d.dy < 0 || d.dx > 1 || d.dy > 1) return;
    final o = unrotatePoint(d, _r.quarterTurns);
    final s = _imageSize ?? const Size(3, 4);
    final r = blemishRadiusFor(_faces ?? const [], s.width / s.height);
    _set(
      _r.copyWith(
        retouch: _r.retouch.copyWith(
          spots: [..._r.retouch.spots, BlemishSpot(o.dx, o.dy, r)],
        ),
      ),
    );
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
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  key: const ValueKey('edit_reset'),
                  onPressed: _saving ? null : _reset,
                  child: const Text('Reset'),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton(
                    key: const ValueKey('edit_save'),
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: LayoutBuilder(builder: _buildCanvas),
              ),
            ),
            _tabBar(),
            SizedBox(height: 196, child: _panel()),
          ],
        ),
      ),
    );
  }

  Widget _tabBar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      children: [
        for (final t in _tabs)
          Expanded(
            child: InkWell(
              key: ValueKey('edit_tab_${t.name}'),
              borderRadius: BorderRadius.circular(10),
              onTap: _saving
                  ? null
                  : () => setState(() {
                      _tab = t;
                      if (t != EditorTab.retouch) _heal = false;
                    }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      t.icon,
                      size: 20,
                      color: t == _tab
                          ? AppColors.accentSoft
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: t == _tab
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: t == _tab
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _buildCanvas(BuildContext context, BoxConstraints box) {
    final a = _rotatedAspect;
    var w = box.maxWidth, h = w / a;
    if (h > box.maxHeight) {
      h = box.maxHeight;
      w = h * a;
    }
    final size = Size(w, h);
    final view = _view;
    final Widget image = view != null && !_hold
        ? RawImage(
            key: const ValueKey('edit_view'),
            image: view,
            fit: BoxFit.fill,
          )
        : Image.file(widget.file, fit: BoxFit.fill, gaplessPlayback: true);
    final aspect = _aspectValue(_aspect);
    return Center(
      child: GestureDetector(
        key: const ValueKey('edit_canvas'),
        onTapUp: (d) => _onCanvasTap(d.localPosition, size),
        onLongPressStart: (_) => setState(() => _hold = true),
        onLongPressEnd: (_) => setState(() => _hold = false),
        onLongPressCancel: () => setState(() => _hold = false),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RotatedBox(quarterTurns: _r.quarterTurns, child: image),
              if (_tab == EditorTab.crop || _r.hasGeometry)
                CropOverlay(
                  key: const ValueKey('crop_overlay'),
                  size: size,
                  crop: _r.crop,
                  interactive: _tab == EditorTab.crop,
                  aspect: aspect == null ? null : aspect / a,
                  onChanged: (c) => setState(() => _r = _r.copyWith(crop: c)),
                ),
              if (_hold)
                const Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(child: _Tag('Original')),
                ),
              if (_heal && _tab == EditorTab.retouch && !_hold)
                const Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(child: _Tag('Tap a spot to heal')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel() => switch (_tab) {
    EditorTab.crop => _cropPanel(),
    EditorTab.adjust => _adjustPanel(),
    EditorTab.retouch => _retouchPanel(),
    EditorTab.skin => _skinPanel(),
  };

  Widget _cropPanel() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    children: [
      Row(
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('edit_rotate'),
            onPressed: _rotate,
            icon: const Icon(Icons.rotate_90_degrees_cw_rounded),
            label: const Text('Rotate'),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Drag the corners to crop',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final n in kEditorAspects.keys)
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

  Widget _slider({
    required String key,
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    bool enabled = true,
  }) => Row(
    children: [
      SizedBox(
        width: 98,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: enabled ? null : AppColors.textSecondary,
          ),
        ),
      ),
      Expanded(
        child: Slider(
          key: ValueKey(key),
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: enabled ? onChanged : null,
        ),
      ),
      SizedBox(
        width: 34,
        child: Text(
          (value * 100).round().toString(),
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ),
    ],
  );

  Widget _adjustPanel() {
    final presets = [...kAdjustPresets, ..._userPresets];
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            key: const ValueKey('adjust_presets'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              for (final p in presets)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GestureDetector(
                    onLongPress: p.builtIn ? null : () => _deletePreset(p),
                    child: ChoiceChip(
                      key: ValueKey('preset_${p.name}'),
                      label: Text(p.name),
                      selected: _r.adjust == p.params,
                      onSelected: (_) => _set(_r.copyWith(adjust: p.params)),
                    ),
                  ),
                ),
              ActionChip(
                key: const ValueKey('adj_save_preset'),
                avatar: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Save as preset'),
                onPressed: _r.adjust.isNeutral ? null : _savePreset,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final s in kAdjustSliders)
                _slider(
                  key: 'adj_${s.id}',
                  label: s.label,
                  value: _r.adjust.value(s.id),
                  min: s.min,
                  max: s.max,
                  onChanged: (v) =>
                      _set(_r.copyWith(adjust: _r.adjust.withValue(s.id, v))),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _retouchPanel() {
    final faces = _faces;
    final hasFace = faces != null && faces.isNotEmpty;
    final rt = _r.retouch;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonalIcon(
              key: const ValueKey('retouch_auto'),
              onPressed: hasFace
                  ? () => _set(
                      _r.copyWith(
                        retouch: RetouchParams.auto.copyWith(spots: rt.spots),
                      ),
                    )
                  : null,
              icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
              label: const Text('Auto Retouch'),
            ),
            FilterChip(
              key: const ValueKey('retouch_heal'),
              label: const Text('Blemish · tap to heal'),
              selected: _heal,
              onSelected: (v) => setState(() => _heal = v),
            ),
            if (rt.spots.isNotEmpty)
              TextButton(
                key: const ValueKey('retouch_undo_spot'),
                onPressed: () => _set(
                  _r.copyWith(
                    retouch: rt.copyWith(
                      spots: rt.spots.sublist(0, rt.spots.length - 1),
                    ),
                  ),
                ),
                child: Text('Undo spot (${rt.spots.length})'),
              ),
          ],
        ),
        if (faces == null)
          const _Note('Finding faces…')
        else if (!hasFace)
          const _Note(
            'No face found. Smooth skin, eyes and teeth need a face; '
            'tap to heal still works.',
          ),
        for (final (id, label) in kRetouchSliders)
          _slider(
            key: 'retouch_$id',
            label: label,
            value: retouchValue(rt, id),
            min: 0,
            max: 1,
            enabled: hasFace,
            onChanged: (v) =>
                _set(_r.copyWith(retouch: retouchWith(rt, id, v))),
          ),
      ],
    );
  }

  Widget _skinPanel() {
    final faces = _faces;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      children: [
        _slider(
          key: 'skin_tone',
          label: 'Skin Tone',
          value: _r.skinTone,
          min: -1,
          max: 1,
          onChanged: (v) => _set(_r.copyWith(skinTone: v)),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              SizedBox(width: 98),
              Text(
                'Darker',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              Spacer(),
              Text(
                'Lighter',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
              SizedBox(width: 40),
            ],
          ),
        ),
        _Note(
          faces == null
              ? 'Finding faces…'
              : faces.isEmpty
              ? 'No face found: skin is detected by colour only, so the '
                    'change is gentler.'
              : 'Face, neck and arms are found automatically. Natural range, '
                    'about 1–2 shades; detail and shading are kept.',
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
