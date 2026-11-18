import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ai_config.dart';
import '../models/ai_style.dart';

/// v11.63 video style presets (image-to-video · 9:16 · 5 s · MiniMax H3).
/// Read from Supabase with the publishable key (RLS: enabled
/// media_type='video' rows only) so admin-added presets appear without a
/// new APK; built-ins are the offline fallback.
const kBuiltinVideoStyles = <AiStyle>[
  AiStyle(
    id: 'video_slow_zoom',
    uiCategory: 'zoom',
    name: 'Slow zoom',
    category: 'Video',
    creditCost: 0,
    sortOrder: 200,
    imageAsset: 'assets/styles/samples/swiss_alps.jpg',
    needsPerson: false,
    prompt:
        'A slow, smooth cinematic camera push-in on the scene, gentle natural motion, '
        'steady camera, realistic lighting. Keep everything in the photo as it is.',
  ),
  AiStyle(
    id: 'video_gentle_motion',
    uiCategory: 'motion',
    name: 'Gentle motion',
    category: 'Video',
    creditCost: 0,
    sortOrder: 201,
    imageAsset: 'assets/styles/samples/santorini.jpg',
    needsPerson: false,
    prompt:
        'Bring the photo gently to life: subtle natural movement in the scene such as soft '
        'breeze, light and shadows, steady camera, realistic. Keep everything in the photo as it is.',
  ),
  AiStyle(
    id: 'video_cinematic_pan',
    uiCategory: 'cinematic',
    name: 'Cinematic pan',
    category: 'Video',
    creditCost: 0,
    sortOrder: 202,
    imageAsset: 'assets/styles/samples/dubai_skyline.jpg',
    needsPerson: false,
    prompt:
        'A slow cinematic camera pan across the scene with soft depth of field and natural '
        'light, smooth and steady. Keep everything in the photo as it is.',
  ),
];

class VideoStyleCatalog {
  VideoStyleCatalog({http.Client? client, String? url, String? key, String? media})
    : _http = client ?? http.Client(),
      _url = url ?? AiConfig.filtersSupabaseUrl,
      _key = key ?? AiConfig.filtersSupabaseKey,
      _media = media ?? AiConfig.filtersMediaBase;

  static VideoStyleCatalog instance = VideoStyleCatalog();
  static void resetForTest(VideoStyleCatalog c) => instance = c;

  final http.Client _http;
  final String _url;
  final String _key;
  final String _media;
  static const _cacheKey = 'video_styles_cache_v1';

  final ValueNotifier<List<AiStyle>> styles = ValueNotifier(kBuiltinVideoStyles);
  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw != null) styles.value = parseRows(jsonDecode(raw) as List);
    } catch (_) {}
    await refresh();
  }

  @visibleForTesting
  List<AiStyle> parseRows(List rows) {
    final out = <AiStyle>[];
    for (final r in rows.whereType<Map>()) {
      final m = r.cast<String, Object?>();
      final img = m['display_image'];
      String? asset;
      String? cat;
      for (final b in kBuiltinVideoStyles) {
        if (b.id == m['id']) {
          asset = b.imageAsset;
          cat = b.uiCategory;
        }
      }
      out.add(
        AiStyle.fromJson({
          ...m,
          'needs_person': false,
          'image_asset': asset,
          'ui_category': m['ui_category'] ?? cat,
          'image_url': img is String && img.isNotEmpty
              ? '${_media.replaceAll(RegExp(r'/+$'), '')}/$img'
              : null,
        }),
      );
    }
    out.sort((a, b) => a.sortOrder != b.sortOrder
        ? a.sortOrder.compareTo(b.sortOrder)
        : a.name.compareTo(b.name));
    return out;
  }

  Future<void> refresh() async {
    if (_url.isEmpty || _key.isEmpty) return;
    try {
      final u = Uri.parse('${_url.replaceAll(RegExp(r'/+$'), '')}/rest/v1/styles').replace(
        queryParameters: {
          'select': 'id,name,category,ui_category,prompt,sort_order,display_image,credit_cost,'
              'sample_before_url,sample_after_url',
          'media_type': 'eq.video',
          'enabled': 'eq.true',
          'order': 'sort_order.asc,name.asc',
        },
      );
      final r = await _http.get(u, headers: {'apikey': _key}).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('video styles HTTP ${r.statusCode}');
      final rows = jsonDecode(r.body) as List;
      styles.value = parseRows(rows);
      await (await SharedPreferences.getInstance()).setString(_cacheKey, jsonEncode(rows));
    } catch (e) {
      debugPrint('Video styles refresh failed: $e');
    }
  }

  String? promptFor(String id) {
    for (final s in styles.value) {
      if (s.id == id) return s.prompt;
    }
    return null;
  }
}
