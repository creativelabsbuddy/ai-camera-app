import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Saves [f] to the "AI Camera" album (falls back to app files). Returns a
/// short user-facing message. Never touches the original file.
Future<String> savePhotoToGallery(File f) async {
  try {
    var ok = await Gal.hasAccess(toAlbum: true);
    if (!ok) ok = await Gal.requestAccess(toAlbum: true);
    if (ok) {
      await Gal.putImage(f.path, album: 'AI Camera');
      return 'Saved to gallery · AI Camera album';
    }
  } catch (_) {}
  final docs = await getApplicationDocumentsDirectory();
  final ext = p.extension(f.path).isEmpty ? '.jpg' : p.extension(f.path);
  final dest = File(
    p.join(docs.path, 'AICamera_${DateTime.now().millisecondsSinceEpoch}$ext'),
  );
  await f.copy(dest.path);
  return 'Saved to app files:\n${dest.path}';
}
