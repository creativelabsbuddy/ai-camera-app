import 'package:flutter/material.dart';

import '../services/macro.dart';

/// v11.25 drift overlay: high-contrast card centred on the preview while
/// the return window runs ("Moved off subject — return to {subject}",
/// 5-4-3-2-1 countdown, "New subject" resets immediately).
class DriftPopup extends StatelessWidget {
  const DriftPopup({
    super.key = const ValueKey('macro_drift_popup'),
    required this.subject,
    required this.secondsLeft,
    required this.onNewSubject,
  });

  final String? subject;
  final int secondsLeft;
  final VoidCallback onNewSubject;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Material(
          color: Colors.black.withValues(alpha: 0.88),
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Colors.amber, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.center_focus_weak_rounded,
                  color: Colors.amber,
                  size: 32,
                ),
                const SizedBox(height: 8),
                Text(
                  guideDriftBack(subject),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$secondsLeft',
                  key: const ValueKey('macro_drift_countdown'),
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                TextButton(
                  key: const ValueKey('macro_drift_new_subject'),
                  onPressed: onNewSubject,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text(kDriftNewSubjectLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
