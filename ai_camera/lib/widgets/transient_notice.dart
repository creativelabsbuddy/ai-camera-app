import 'dart:async';

import 'package:flutter/material.dart';
import 'credit_icon.dart';

/// Small pill that briefly shows [message] whenever it changes (to a
/// non-null value), then fades out. Never a persistent banner.
class TransientNotice extends StatefulWidget {
  const TransientNotice({
    super.key,
    required this.message,
    this.token = 0,
    this.color = Colors.white,
    this.duration = const Duration(milliseconds: 2400),
  });

  final String? message;

  /// Bump to re-show the same message again.
  final int token;
  final Color color;
  final Duration duration;

  @override
  State<TransientNotice> createState() => _TransientNoticeState();
}

class _TransientNoticeState extends State<TransientNotice> {
  String? _shown;
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _show(widget.message);
  }

  @override
  void didUpdateWidget(TransientNotice old) {
    super.didUpdateWidget(old);
    if (widget.message != old.message || widget.token != old.token) {
      _show(widget.message);
    }
  }

  void _show(String? m) {
    _timer?.cancel();
    if (m == null) {
      if (_visible) setState(() => _visible = false);
      return;
    }
    _shown = m;
    _visible = true;
    _timer = Timer(widget.duration, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        child: _shown == null
            ? const SizedBox.shrink()
            : Container(
                key: const ValueKey('transient_notice'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: CreditText(
                  _shown!,
                  style: TextStyle(
                    color: widget.color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
      ),
    );
  }
}
