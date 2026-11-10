import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_style.dart';
import 'enhance_settings.dart';

/// Loads the AI style library.
///
/// Order: cached server list (instant) → bundled seed list (first run /
/// offline) → fresh `/v1/styles` from the server in the background. Display
/// images are cached on disk so the strip stays fast and works offline.
class StyleCatalog {
  StyleCatalog({
    http.Client? httpClient,
    Future<String> Function()? serverUrl,
    Future<String> Function(String asset)? loadAsset,
    Future<Directory> Function()? cacheDir,
  }) : _http = httpClient ?? http.Client(),
       _serverUrl = serverUrl ?? EnhanceSettings().getServerUrl,
       _loadAsset = loadAsset ?? rootBundle.loadString,
       _cacheDir = cacheDir ?? getApplicationSupportDirectory;

  static StyleCatalog instance = StyleCatalog();

  @visibleForTesting
  static void resetForTest(StyleCatalog c) => instance = c;

  static const seedAsset = 'assets/styles/seed_styles.json';
  static const _cacheKey = 'style_catalog_v9';

  final http.Client _http;
  final Future<String> Function() _serverUrl;
  final Future<String> Function(String asset) _loadAsset;
  final Future<Directory> Function() _cacheDir;

  final ValueNotifier<List<AiStyle>> styles = ValueNotifier(const []);

  /// "server", "cache" or "seed" — shown in Settings.
  String source = 'seed';
  String? lastError;
  Future<void>? _loading;
  Map<String, String> _seedAssets = const {};

  /// Idempotent: first call loads cache/seed and starts a server refresh.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final seed = await _loadSeed();
    _seedAssets = {
      for (final s in seed)
        if (s.imageAsset != null) s.id: s.imageAsset!,
    };
    final cached = await _loadCache();
    if (cached.isNotEmpty) {
      styles.value = _withSeedAssets(cached);
      source = 'cache';
    } else {
      styles.value = seed;
      source = 'seed';
    }
    await refresh();
  }

  /// Fetches the live list from the server (no-op without a server URL).
  Future<void> refresh() async {
    final url = (await _serverUrl()).trim();
    if (url.isEmpty) {
      // No server (test key build / offline): bundled seed list.
      if (source == 'cache') {
        styles.value = await _loadSeed();
        source = 'seed';
      }
      return;
    }
    try {
      final root = url.replaceAll(RegExp(r'/+$'), '');
      final r = await _http
          .get(Uri.parse('$root/v1/styles'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        throw HttpException('styles HTTP ${r.statusCode}');
      }
      // v11.51: camera filters live in their own row (FilterCatalog).
      final list = parseStyleList(
        jsonDecode(r.body),
        baseUrl: root,
      ).where((s) => !s.isFilter).toList();
      styles.value = _withSeedAssets(list);
      source = 'server';
      lastError = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'styles': [for (final s in list) s.toJson()],
        }),
      );
    } catch (e) {
      lastError = '$e';
      debugPrint(
        'Style catalog refresh failed (keeping ${styles.value.length}): $e',
      );
    }
  }

  AiStyle? byId(String id) {
    for (final s in styles.value) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Seed styles that still exist on the server keep their bundled sample
  /// as a placeholder while the server image downloads.
  List<AiStyle> _withSeedAssets(List<AiStyle> list) => [
    for (final s in list)
      s.imageAsset == null && _seedAssets.containsKey(s.id)
          ? s.withAsset(_seedAssets[s.id])
          : s,
  ];

  Future<List<AiStyle>> _loadSeed() async {
    try {
      return parseStyleList(jsonDecode(await _loadAsset(seedAsset)));
    } catch (e) {
      debugPrint('Seed styles unavailable: $e');
      return const [];
    }
  }

  Future<List<AiStyle>> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return const [];
      return parseStyleList(jsonDecode(raw));
    } catch (_) {
      return const [];
    }
  }

  final Map<String, Future<File?>> _thumbs = {};

  /// Disk-cached display image for [s] (null → use the bundled asset or a
  /// placeholder). Downloads once per URL.
  Future<File?> thumbnail(AiStyle s) {
    final url = s.imageUrl;
    if (url == null) return Future.value(null);
    return _thumbs[url] ??= _fetchThumb(url);
  }

  /// Any style image URL (v11.56 before/after samples), disk-cached.
  Future<File?> imageFile(String url) => _thumbs[url] ??= _fetchThumb(url);

  Future<File?> _fetchThumb(String url) async {
    try {
      final dir = Directory(p.join((await _cacheDir()).path, 'style_thumbs'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final name = '${stableUrlHash(url)}.jpg';
      final f = File(p.join(dir.path, name));
      if (await f.exists() && await f.length() > 0) return f;
      final r = await _http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      await f.writeAsBytes(r.bodyBytes, flush: true);
      return f;
    } catch (e) {
      debugPrint('Style thumbnail failed: $e');
      _thumbs.remove(url);
      return null;
    }
  }
}

/// Stable FNV-1a (32-bit) hex of [s] + length — cache file names.
String stableUrlHash(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return '${h.toRadixString(16).padLeft(8, '0')}_${s.length}';
}
