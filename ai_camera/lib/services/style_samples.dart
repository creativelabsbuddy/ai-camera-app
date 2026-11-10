import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ai_config.dart';
import '../models/ai_style.dart';
import 'style_catalog.dart';

/// Real before/after sample of a style (v11.56). Photo styles: both; video
/// styles: after only.
class StyleSample {
  const StyleSample({this.before, this.after});
  final String? before;
  final String? after;
  bool get hasSlider => before != null && after != null;
}

/// Sample URLs from Supabase (`style_samples_public` view: id + URLs only,
/// never prompts), cached offline. The server list (`/v1/styles`) may also
/// carry them on [AiStyle]; those win.
class StyleSamples {
  StyleSamples({http.Client? client, String? url, String? key})
    : _http = client ?? http.Client(),
      _url = url ?? AiConfig.filtersSupabaseUrl,
      _key = key ?? AiConfig.filtersSupabaseKey;

  static StyleSamples instance = StyleSamples();
  static void resetForTest(StyleSamples s) => instance = s;

  final http.Client _http;
  final String _url;
  final String _key;
  static const _cacheKey = 'style_samples_cache_v1156';

  final ValueNotifier<Map<String, StyleSample>> samples = ValueNotifier(const {});
  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw != null) samples.value = parseSampleRows(jsonDecode(raw) as List);
    } catch (_) {}
    await refresh();
  }

  Future<void> refresh() async {
    if (_url.isEmpty || _key.isEmpty) return;
    try {
      final u = Uri.parse('${_url.replaceAll(RegExp(r'/+$'), '')}/rest/v1/style_samples_public')
          .replace(queryParameters: {'select': 'id,media_type,sample_before_url,sample_after_url'});
      final r = await _http.get(u, headers: {'apikey': _key}).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw HttpException('samples HTTP ${r.statusCode}');
      final rows = jsonDecode(r.body) as List;
      samples.value = parseSampleRows(rows);
      await (await SharedPreferences.getInstance()).setString(_cacheKey, jsonEncode(rows));
    } catch (e) {
      debugPrint('Style samples refresh failed: $e');
    }
  }

  /// Sample for [s] ([video]: after image only), or null.
  StyleSample? of(AiStyle s, {bool video = false}) {
    final m = samples.value[s.id];
    final before = video ? null : (s.sampleBeforeUrl ?? m?.before);
    final after = s.sampleAfterUrl ?? m?.after;
    if (before == null && after == null) return null;
    return StyleSample(before: before, after: after);
  }

  /// Disk-cached image for a sample URL (same cache as style thumbnails).
  Future<File?> file(String url) => StyleCatalog.instance.imageFile(url);
}

@visibleForTesting
Map<String, StyleSample> parseSampleRows(List rows) {
  String? u(Object? v) => v is String && v.startsWith('http') ? v : null;
  return {
    for (final r in rows.whereType<Map>())
      if (r['id'] is String)
        r['id'] as String: StyleSample(
          before: r['media_type'] == 'video' ? null : u(r['sample_before_url']),
          after: u(r['sample_after_url']),
        ),
  };
}
