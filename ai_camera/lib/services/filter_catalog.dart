import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/ai_config.dart';
import '../models/ai_style.dart';

/// v11.51 built-in fallback filter (works offline / when the DB is down).
const String kVividFilterPrompt =
    'Make this photo look vivid and social-media ready like a flagship '
    'phone camera: rich but natural colours, clean bright whites, deeper '
    'contrast, crisp local detail, smooth tonal balance. Keep every person, '
    'object, pose, shape, text and the composition exactly as in the photo; '
    'do not add or remove anything. Photorealistic.';

const AiStyle kVividFilter = AiStyle(
  id: 'vivid',
  name: 'Vivid',
  category: 'Filter',
  creditCost: 2,
  sortOrder: 100,
  imageAsset: 'assets/styles/samples/vivid_filter.jpg',
  needsPerson: false,
  kind: 'filter',
  model: kStyleModelCustom,
  prompt: kVividFilterPrompt,
);

/// Camera filters = styles with `kind='filter'` (Supabase `public.styles`).
/// Order: cached list → built-in Vivid → fresh list from Supabase.
class FilterCatalog {
  FilterCatalog({
    http.Client? httpClient,
    String? supabaseUrl,
    String? supabaseKey,
    String? mediaBase,
  }) : _http = httpClient ?? http.Client(),
       _url = supabaseUrl ?? AiConfig.filtersSupabaseUrl,
       _key = supabaseKey ?? AiConfig.filtersSupabaseKey,
       _media = mediaBase ?? AiConfig.filtersMediaBase;

  static FilterCatalog instance = FilterCatalog();

  @visibleForTesting
  static void resetForTest(FilterCatalog c) => instance = c;

  static const _cacheKey = 'filter_catalog_v1151';

  final http.Client _http;
  final String _url;
  final String _key;
  final String _media;

  final ValueNotifier<List<AiStyle>> filters = ValueNotifier(const [
    kVividFilter,
  ]);
  String source = 'builtin';
  Future<void>? _loading;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw != null && raw.isNotEmpty) {
        final l = withBuiltins(parseStyleList(jsonDecode(raw)));
        if (l.isNotEmpty) {
          filters.value = l;
          source = 'cache';
        }
      }
    } catch (_) {}
    await refresh();
  }

  /// Rows → filters (media names resolved against the public bucket).
  @visibleForTesting
  List<AiStyle> parseRows(List rows) {
    final out = <AiStyle>[];
    for (final r in rows.whereType<Map>()) {
      final m = r.cast<String, Object?>();
      final img = m['display_image'];
      out.add(
        AiStyle.fromJson({
          ...m,
          'kind': 'filter',
          // v11.58: filters keep the Custom (Flare) model unless the DB says otherwise.
          'model': m['model'] ?? kStyleModelCustom,
          'image_url': img is String && img.isNotEmpty
              ? '${_media.replaceAll(RegExp(r'/+$'), '')}/$img'
              : null,
        }),
      );
    }
    return sortStyles(out);
  }

  Future<void> refresh() async {
    if (_url.isEmpty || _key.isEmpty) return;
    try {
      final u =
          Uri.parse(
            '${_url.replaceAll(RegExp(r'/+$'), '')}/rest/v1/styles',
          ).replace(
            queryParameters: {
              'select':
                  'id,name,category,prompt,credit_cost,pro_only,sort_order,'
                  'display_image,needs_person,kind,model',
              'kind': 'eq.filter',
              'enabled': 'eq.true',
              'order': 'sort_order.asc,name.asc',
            },
          );
      final r = await _http
          .get(u, headers: {'apikey': _key})
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('filters HTTP ${r.statusCode}');
      final list = withBuiltins(parseRows(jsonDecode(r.body) as List));
      filters.value = list;
      source = 'db';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'styles': [for (final s in list) s.toJson()],
        }),
      );
    } catch (e) {
      debugPrint('Filter catalog refresh failed (keeping $source): $e');
    }
  }

  /// DB rows keep the bundled Vivid preview as placeholder; an empty DB
  /// list (all disabled) is respected.
  @visibleForTesting
  static List<AiStyle> withBuiltins(List<AiStyle> list) => [
    for (final s in list)
      s.id == kVividFilter.id && s.imageAsset == null
          ? s.withAsset(kVividFilter.imageAsset)
          : s,
  ];

  AiStyle? byId(String id) {
    for (final s in filters.value) {
      if (s.id == id) return s;
    }
    return id == kVividFilter.id ? kVividFilter : null;
  }

  /// Prompt for the local (key test build) look path.
  String? promptFor(String id) {
    final p = byId(id)?.prompt;
    return (p == null || p.trim().isEmpty) ? null : p;
  }
}
