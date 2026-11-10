import 'dart:async';

import 'package:flutter/material.dart';

import '../models/shoot_mode.dart';
import '../theme/app_theme.dart';

/// Scroll offset that centres item [index] in a [viewport]-wide strip whose
/// content is padded by viewport / 2 on both sides (so the first and last
/// items can reach the centre). Pure → unit tested.
double modeStripOffset(List<double> widths, int index, double viewport) {
  if (widths.isEmpty) return 0;
  final i = index.clamp(0, widths.length - 1);
  var prefix = 0.0;
  for (var k = 0; k < i; k++) {
    prefix += widths[k];
  }
  return prefix + widths[i] / 2;
}

/// Item whose centre is nearest the viewport centre at scroll [offset].
int nearestModeIndex(List<double> widths, double offset) {
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < widths.length; i++) {
    final d = (modeStripOffset(widths, i, 0) - offset).abs();
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

const double _kItemPad = 13;
const TextStyle _kItemStyle = TextStyle(
  fontSize: 12.5,
  fontWeight: FontWeight.w800,
  letterSpacing: 0.5,
);

/// Label widths (bold, upper-case) + padding → stable item widths.
List<double> modeStripItemWidths(List<String> labels, {double textScale = 1}) {
  return [
    for (final l in labels)
      (TextPainter(
            text: TextSpan(text: l.toUpperCase(), style: _kItemStyle),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.linear(textScale),
          )..layout()).width +
          2 * _kItemPad,
  ];
}

/// Samsung-style mode carousel: the selected mode is ALWAYS centred over
/// the shutter (NORMAL and PRO AI); others sit left / right. Swipe and it
/// snaps to the nearest mode, or tap one and it animates to the centre.
/// Order: NIGHT · PORTRAIT · PHOTO · MACRO · POSE · HDR · DOCUMENT · MORE.
class ModeStrip extends StatefulWidget {
  const ModeStrip({
    super.key,
    required this.mode,
    required this.onMode,
    required this.onMore,
    this.proModes = const {},
    this.modes = ShootMode.strip,
  });

  /// v11.48: the modes shown (Normal has no Macro, Pro AI has no HDR).
  final List<ShootMode> modes;

  final ShootMode mode;

  /// Picked a mode (tap or swipe). The parent decides: it may keep the
  /// current mode (Document launches the scanner, a blocked mode shows a
  /// note) — the strip then glides back to [mode].
  final ValueChanged<ShootMode>? onMode;
  final VoidCallback? onMore;

  /// Modes drawn with a small Pro AI sparkle (e.g. Macro).
  final Set<ShootMode> proModes;

  @override
  State<ModeStrip> createState() => _ModeStripState();
}

class _ModeStripState extends State<ModeStrip> {
  final _scroll = ScrollController();
  List<double> _widths = const [];
  double _viewport = 0;
  bool _userScroll = false;
  bool _positioned = false;

  List<ShootMode> get _modes => widget.modes;

  List<String> get _labels => [for (final m in _modes) m.label, 'More'];

  int get _moreIndex => _modes.length;

  int _indexOf(ShootMode m) => _modes.indexOf(m);

  @override
  void didUpdateWidget(ModeStrip old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode || old.modes.length != widget.modes.length) {
      _centre(widget.mode, animate: true);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _centre(ShootMode m, {required bool animate}) {
    _centreIndex(_indexOf(m), animate: animate);
  }

  void _centreIndex(int i, {required bool animate}) {
    if (!_scroll.hasClients || _widths.isEmpty) return;
    final target = modeStripOffset(
      _widths,
      i,
      _viewport,
    ).clamp(0.0, _scroll.position.maxScrollExtent);
    if ((_scroll.offset - target).abs() < 0.5) return;
    if (animate) {
      unawaited(
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  void _pick(int i) {
    if (i == _moreIndex) {
      widget.onMore?.call();
      _centre(widget.mode, animate: true);
      return;
    }
    final m = _modes[i];
    _centreIndex(i, animate: true);
    widget.onMode?.call(m);
    // Parent kept the old mode (scanner / blocked note) → glide back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.mode != m) {
        Future<void>.delayed(const Duration(milliseconds: 280), () {
          if (mounted && !_userScroll) _centre(widget.mode, animate: true);
        });
      }
    });
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userScroll = true;
    } else if (n is ScrollEndNotification && _userScroll) {
      _userScroll = false;
      final i = nearestModeIndex(_widths, _scroll.offset);
      final enabled = widget.onMode != null;
      if (!enabled) {
        _centre(widget.mode, animate: true);
      } else if (i == _indexOf(widget.mode)) {
        _centreIndex(i, animate: true);
      } else {
        _pick(i);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.3);
    return LayoutBuilder(
      builder: (context, box) {
        final viewport = box.maxWidth.isFinite
            ? box.maxWidth
            : MediaQuery.of(context).size.width;
        final widths = modeStripItemWidths(_labels, textScale: scale);
        final changed =
            viewport != _viewport || widths.length != _widths.length;
        _viewport = viewport;
        _widths = widths;
        if (changed || !_positioned) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _positioned = true;
            _centre(widget.mode, animate: false);
          });
        }
        return SizedBox(
          height: 34,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: ShaderMask(
              shaderCallback: (r) => const LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0, 0.12, 0.88, 1],
              ).createShader(r),
              blendMode: BlendMode.dstIn,
              child: ListView(
                key: const ValueKey('mode_strip_list'),
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.symmetric(horizontal: viewport / 2),
                children: [
                  for (var i = 0; i < _labels.length; i++) _item(i, widths[i]),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _item(int i, double width) {
    final more = i == _moreIndex;
    final m = more ? null : _modes[i];
    final selected = m == widget.mode;
    final enabled = more ? widget.onMore != null : widget.onMode != null;
    final label = _labels[i];
    return Semantics(
      button: true,
      selected: selected,
      label: '$label mode',
      child: GestureDetector(
        key: ValueKey(more ? 'shoot_more' : 'shoot_${m!.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => _pick(i) : null,
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      label.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      softWrap: false,
                      style: _kItemStyle.copyWith(
                        color: selected
                            ? Colors.white
                            : AppColors.textSecondary,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (m != null && widget.proModes.contains(m))
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 9,
                        color: AppColors.proGold.withValues(alpha: 0.8),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: selected ? 1 : 0,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: AppColors.proGold,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "More" sheet: free camera toggles (all modes are in the carousel).
Future<void> showMoreModesSheet(
  BuildContext context, {
  required CameraFeatures features,
  required ValueChanged<CameraFeatures> onFeatures,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      var f = features;
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          void set(CameraFeatures n) {
            setSheet(() => f = n);
            onFeatures(n);
          }

          Widget toggle(
            String key,
            IconData icon,
            String title,
            String subtitle,
            bool value,
            CameraFeatures Function(bool) next,
          ) => SwitchListTile(
            key: ValueKey(key),
            secondary: Icon(icon),
            title: Text(title),
            subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
            value: value,
            onChanged: (v) => set(next(v)),
          );

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text(
                      'Camera options',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  toggle(
                    'feat_qr',
                    Icons.qr_code_scanner_rounded,
                    'Scan QR codes',
                    'Show a chip for links and text',
                    f.scanQr,
                    (v) => f.copyWith(scanQr: v),
                  ),
                  toggle(
                    'feat_smile',
                    Icons.sentiment_satisfied_alt_rounded,
                    'Smile shot',
                    'Take the photo automatically on a smile',
                    f.smileShot,
                    (v) => f.copyWith(smileShot: v),
                  ),
                  toggle(
                    'feat_face_focus',
                    Icons.face_retouching_natural_rounded,
                    'Face-priority focus',
                    'Focus and expose for faces',
                    f.faceFocus,
                    (v) => f.copyWith(faceFocus: v),
                  ),
                  toggle(
                    'feat_tips',
                    Icons.lightbulb_outline_rounded,
                    'Scene tips',
                    'Suggest a mode for food, people, documents…',
                    f.sceneTips,
                    (v) => f.copyWith(sceneTips: v),
                  ),
                  toggle(
                    'feat_grid',
                    Icons.grid_3x3_rounded,
                    'Grid lines',
                    'Rule-of-thirds grid',
                    f.grid,
                    (v) => f.copyWith(grid: v),
                  ),
                  toggle(
                    'feat_level',
                    Icons.horizontal_rule_rounded,
                    'Level',
                    'Horizon line turns green when straight',
                    f.level,
                    (v) => f.copyWith(level: v),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
