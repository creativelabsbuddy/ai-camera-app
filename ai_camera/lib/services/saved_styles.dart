import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_style.dart';

/// v11.56 "Save" (bookmark) on style cards. Saved styles go FIRST in their
/// group (Photo / Video) of the four-dot quick row, in the order they were
/// saved (each new save goes after the earlier ones). Stored locally by
/// style id; ids of styles that no longer exist are ignored.
class SavedStyles {
  SavedStyles();

  static SavedStyles instance = SavedStyles();
  static void resetForTest(SavedStyles s) => instance = s;

  static const photoKey = 'saved_styles_photo_v1156';
  static const videoKey = 'saved_styles_video_v1156';

  final ValueNotifier<List<String>> photo = ValueNotifier(const []);
  final ValueNotifier<List<String>> video = ValueNotifier(const []);
  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    photo.value = List.unmodifiable(p.getStringList(photoKey) ?? const []);
    video.value = List.unmodifiable(p.getStringList(videoKey) ?? const []);
  }

  ValueNotifier<List<String>> listFor({required bool video}) => video ? this.video : photo;

  bool isSaved(String id, {required bool video}) => listFor(video: video).value.contains(id);

  /// Saves (appended after earlier saves) or unsaves [id]. Returns the new state.
  Future<bool> toggle(String id, {required bool video}) async {
    await ensureLoaded();
    final n = listFor(video: video);
    final next = toggleSavedId(n.value, id);
    n.value = List.unmodifiable(next);
    final p = await SharedPreferences.getInstance();
    await p.setStringList(video ? videoKey : photoKey, next);
    return next.contains(id);
  }
}

/// Pure toggle: unsave removes [id]; save appends it at the end.
List<String> toggleSavedId(List<String> saved, String id) =>
    saved.contains(id) ? [for (final s in saved) if (s != id) s] : [...saved, id];

/// Quick-row order for one group: saved styles first (saved order, unknown
/// ids ignored), then the default list without duplicates. An unsaved
/// default style simply falls back to its default position.
List<AiStyle> orderWithSaved(List<String> saved, List<AiStyle> defaults, List<AiStyle> all) {
  final byId = {for (final s in all) s.id: s, for (final s in defaults) s.id: s};
  final out = <AiStyle>[];
  final seen = <String>{};
  for (final id in saved) {
    final s = byId[id];
    if (s != null && seen.add(id)) out.add(s);
  }
  for (final s in defaults) {
    if (seen.add(s.id)) out.add(s);
  }
  return out;
}
