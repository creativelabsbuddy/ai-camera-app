import 'package:flutter/material.dart';

import '../models/pose_photo.dart';
import '../theme/app_theme.dart';
import 'pose_strip.dart';

/// Floating reference thumbnail: drag anywhere, tap to enlarge, tap the
/// chevron to collapse to a small tab, tap × to dismiss.
class PoseReference extends StatefulWidget {
  const PoseReference({super.key, required this.pose, required this.onDismiss});

  final PosePhoto pose;
  final VoidCallback onDismiss;

  @override
  State<PoseReference> createState() => _PoseReferenceState();
}

class _PoseReferenceState extends State<PoseReference> {
  Offset _pos = const Offset(12, 84);
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final w = _collapsed ? 44.0 : 108.0;
    final h = _collapsed ? 44.0 : 148.0;
    final size = MediaQuery.sizeOf(context);
    return Positioned(
      left: _pos.dx.clamp(0, size.width - w),
      top: _pos.dy.clamp(0, size.height - h),
      child: GestureDetector(
        key: const ValueKey('pose_reference'),
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => setState(() => _pos += d.delta),
        onTap: () {
          if (_collapsed) {
            setState(() => _collapsed = false);
          } else {
            showPoseLarge(context, widget.pose);
          }
        },
        child: Material(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
          elevation: 6,
          child: SizedBox(
            width: w,
            height: h,
            child: _collapsed
                ? const Icon(
                    Icons.photo_rounded,
                    color: AppColors.proGold,
                    size: 20,
                  )
                : Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: PoseImage(pose: widget.pose, fit: BoxFit.cover),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.vertical(
                              bottom: Radius.circular(12),
                            ),
                          ),
                          child: Text(
                            widget.pose.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          key: const ValueKey('pose_reference_close'),
                          onTap: widget.onDismiss,
                          child: const CircleAvatar(
                            radius: 9,
                            backgroundColor: Colors.black54,
                            child: Icon(Icons.close, size: 12),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        left: 2,
                        child: GestureDetector(
                          key: const ValueKey('pose_reference_collapse'),
                          onTap: () => setState(() => _collapsed = true),
                          child: const CircleAvatar(
                            radius: 9,
                            backgroundColor: Colors.black54,
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 14,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
