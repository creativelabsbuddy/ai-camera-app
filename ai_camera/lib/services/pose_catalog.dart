import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/pose_photo.dart';
import 'enhance_settings.dart';

/// v11 pose photos = small bundled fallback set (one per category, works
/// offline) + admin-managed photos from the server (`GET /v1/poses`,
/// managed at /admin/poses). Free: no credits, no AI.
class PoseCatalog {
  PoseCatalog({http.Client? httpClient, Future<String> Function()? serverUrl})
    : _http = httpClient ?? http.Client(),
      _serverUrl = serverUrl ?? EnhanceSettings().getServerUrl;

  static PoseCatalog instance = PoseCatalog();

  @visibleForTesting
  static void resetForTest(PoseCatalog c) => instance = c;

  final http.Client _http;
  final Future<String> Function() _serverUrl;

  final ValueNotifier<List<PosePhoto>> poses = ValueNotifier(
    List.unmodifiable(kBundledPoses),
  );
  Future<void>? _loading;
  String? lastError;

  Future<void> ensureLoaded() => _loading ??= refresh();

  Future<void> refresh() async {
    final url = (await _serverUrl()).trim();
    if (url.isEmpty) return;
    try {
      final root = url.replaceAll(RegExp(r'/+$'), '');
      final r = await _http
          .get(Uri.parse('$root/v1/poses'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) {
        throw HttpException('poses HTTP ${r.statusCode}');
      }
      final remote = parsePoseList(jsonDecode(r.body), baseUrl: root);
      poses.value = List.unmodifiable(mergePoses(remote));
      lastError = null;
    } catch (e) {
      lastError = '$e';
      debugPrint('Pose catalog refresh failed: $e');
    }
  }
}

List<PosePhoto> parsePoseList(Object? json, {String? baseUrl}) {
  final list = json is Map ? json['poses'] : json;
  if (list is! List) return const [];
  final out = <PosePhoto>[];
  for (final j in list) {
    if (j is! Map) continue;
    final p = PosePhoto.fromServer(j.cast<String, Object?>(), baseUrl: baseUrl);
    if (p != null) out.add(p);
  }
  out.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return out;
}

/// Server photos first (admin order); a bundled photo is kept only for
/// categories the server has none of (offline / empty server).
List<PosePhoto> mergePoses(List<PosePhoto> remote) {
  final covered = {for (final p in remote) p.category};
  return [
    ...remote,
    for (final b in kBundledPoses)
      if (!covered.contains(b.category)) b,
  ];
}

/// Poses for a category, in catalog order.
List<PosePhoto> posesIn(List<PosePhoto> all, String category) => [
  for (final t in all)
    if (t.category == category) t,
];
