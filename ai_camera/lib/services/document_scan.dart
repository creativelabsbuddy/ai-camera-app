import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Result of the free ML Kit document scanner (Google Play services UI:
/// edge detection, crop, clean-up filters; PDF + page JPEGs).
class ScannedDocument {
  const ScannedDocument({
    required this.pages,
    this.pdfPath,
    this.pageCount = 0,
  });
  final List<String> pages;
  final String? pdfPath;
  final int pageCount;
  bool get isEmpty => pages.isEmpty && pdfPath == null;
}

class DocumentScan {
  /// Test hook.
  static Future<ScannedDocument?> Function() scanner = _scan;
  static void reset() => scanner = _scan;

  static Future<ScannedDocument?> scan() => scanner();

  static Future<ScannedDocument?> _scan() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    final s = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.pdf, DocumentFormat.jpeg},
        pageLimit: 20,
        mode: ScannerMode.full,
        isGalleryImport: true,
      ),
    );
    try {
      final r = await s.scanDocument();
      final pdf = r.pdf;
      String? pdfPath;
      if (pdf != null) pdfPath = await _keepPdf(pdf.uri);
      return ScannedDocument(
        pages: r.images ?? const [],
        pdfPath: pdfPath,
        pageCount: pdf?.pageCount ?? (r.images?.length ?? 0),
      );
    } finally {
      await s.close();
    }
  }

  /// Copies the scanner's PDF (cache, may be cleared) to app documents.
  static Future<String?> _keepPdf(String uri) async {
    try {
      final src = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
      final f = File(src);
      if (!await f.exists()) return src;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Scans'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final dest = p.join(dir.path, scanFileName(DateTime.now()));
      await f.copy(dest);
      return dest;
    } catch (e) {
      debugPrint('Keep PDF failed: $e');
      return null;
    }
  }
}

/// "Scan_2026-10-08_13-45-02.pdf"
String scanFileName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Scan_${t.year}-${two(t.month)}-${two(t.day)}_'
      '${two(t.hour)}-${two(t.minute)}-${two(t.second)}.pdf';
}
