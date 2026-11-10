import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/document_scan.dart';
import '../services/photo_saver.dart';
import '../theme/app_theme.dart';

/// Test hooks for the document result sheet.
class DocumentSheetDeps {
  static Future<void> Function(String pdfPath) sharePdf = _sharePdf;
  static Future<String> Function(File) savePage = savePhotoToGallery;

  static void reset() {
    sharePdf = _sharePdf;
    savePage = savePhotoToGallery;
  }

  static Future<void> _sharePdf(String pdfPath) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(pdfPath)], subject: 'Scanned document'),
    );
  }
}

/// After a document scan: page thumbnails, "Share PDF", "Save pages".
Future<void> showDocumentResultSheet(
  BuildContext context,
  ScannedDocument doc,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (ctx) => _DocumentSheet(doc: doc),
  );
}

class _DocumentSheet extends StatefulWidget {
  const _DocumentSheet({required this.doc});
  final ScannedDocument doc;

  @override
  State<_DocumentSheet> createState() => _DocumentSheetState();
}

class _DocumentSheetState extends State<_DocumentSheet> {
  bool _busy = false;
  String? _note;

  Future<void> _savePages() async {
    setState(() => _busy = true);
    var saved = 0;
    for (final p in widget.doc.pages) {
      try {
        await DocumentSheetDeps.savePage(
          File(Uri.tryParse(p)?.toFilePath() ?? p),
        );
        saved++;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = saved == 0
          ? 'Could not save pages'
          : 'Saved $saved page${saved == 1 ? '' : 's'} to Gallery';
    });
  }

  Future<void> _share() async {
    final pdf = widget.doc.pdfPath;
    if (pdf == null) return;
    try {
      await DocumentSheetDeps.sharePdf(pdf);
    } catch (_) {
      if (mounted) setState(() => _note = 'Could not open the share sheet');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.doc;
    final pdf = d.pdfPath;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Scanned ${d.pageCount} page${d.pageCount == 1 ? '' : 's'}',
              key: const ValueKey('doc_title'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            if (pdf != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'PDF saved in the app: Scans/${pdf.split('/').last}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            if (d.pages.isNotEmpty)
              SizedBox(
                height: 110,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  scrollDirection: Axis.horizontal,
                  itemCount: d.pages.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final p = d.pages[i];
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(
                        File(Uri.tryParse(p)?.toFilePath() ?? p),
                        fit: BoxFit.cover,
                        width: 66,
                        errorBuilder: (_, _, _) => const SizedBox(
                          width: 66,
                          child: Icon(Icons.description_outlined),
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_note!, key: const ValueKey('doc_note')),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('doc_save_pages'),
                    onPressed: _busy || d.pages.isEmpty ? null : _savePages,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Save pages'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('doc_share_pdf'),
                    onPressed: _busy || pdf == null ? null : _share,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                    label: const Text('Share PDF'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
