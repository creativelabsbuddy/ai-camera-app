import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'edit_v1170.dart';

/// v11.70 user Adjust presets ("Save as preset"), stored on this phone.
class AdjustPresetStore {
  AdjustPresetStore._();

  static const prefsKey = 'adjust_presets_v1170';
  static const maxPresets = 12;

  static Future<List<AdjustPreset>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return const [];
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return [for (final e in j) ?AdjustPreset.fromJson(e)];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<AdjustPreset> l) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      prefsKey,
      jsonEncode([for (final p in l) p.toJson()]),
    );
  }

  /// Adds (or replaces a preset with the same name). Newest first.
  static Future<List<AdjustPreset>> add(String name, AdjustParams p) async {
    final n = name.trim();
    if (n.isEmpty) return load();
    final cur = await load();
    final next = [
      AdjustPreset(n, p),
      for (final e in cur)
        if (e.name.toLowerCase() != n.toLowerCase()) e,
    ].take(maxPresets).toList();
    await _save(next);
    return next;
  }

  static Future<List<AdjustPreset>> remove(String name) async {
    final cur = await load();
    final next = [
      for (final e in cur)
        if (e.name != name) e,
    ];
    await _save(next);
    return next;
  }
}
