import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Recognised text (on-device ML Kit) with a "Copy text" action.
Future<void> showTextSheet(BuildContext context, String text) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Text in this photo',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.45,
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  key: const ValueKey('recognized_text'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('copy_text_button'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Text copied')));
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy text'),
            ),
          ],
        ),
      ),
    ),
  );
}
