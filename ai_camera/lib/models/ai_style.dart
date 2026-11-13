/// v11.58 per-style image model (admin "Model" select, mirrors the server):
/// `klein` FLUX Klein (OpenRouter, photo only), `runware_klein4b` FLUX.2
/// Klein 4B on Runware (violent / bloody looks), `custom` = the Custom
/// change model (Flare). Unknown → `custom` (fallback to Custom).
const kStyleModelKlein = 'klein';
const kStyleModelRunware = 'runware_klein4b';
const kStyleModelCustom = 'custom';
const kStyleModels = [kStyleModelKlein, kStyleModelRunware, kStyleModelCustom];

String normalizeStyleModel(Object? v) {
  final s = '${v ?? ''}'.trim().toLowerCase();
  return kStyleModels.contains(s) ? s : kStyleModelCustom;
}

/// One AI look in the style library (v9). The hidden prompt and reference
/// images live on the server (admin panel) and are never sent to the app;
/// the app only knows how to show the style and what it costs.
class AiStyle {
  const AiStyle({
    required this.id,
    required this.name,
    required this.category,
    required this.creditCost,
    this.proOnly = false,
    this.sortOrder = 0,
    this.imageUrl,
    this.imageAsset,
    this.hasReference = false,
    this.needsPerson = true,
    this.kind = 'style',
    this.prompt,
    this.uiCategory,
    this.sampleBeforeUrl,
    this.sampleAfterUrl,
    this.model = kStyleModelKlein,
  });

  /// Parses a server `/v1/styles` entry (relative `image_url` resolved
  /// against [baseUrl]) or a bundled seed entry (`image_asset`).
  factory AiStyle.fromJson(Map<String, Object?> j, {String? baseUrl}) {
    int i(Object? v, int d) => v is num ? v.toInt() : int.tryParse('$v') ?? d;
    var url = j['image_url'] as String?;
    if (url != null && url.isNotEmpty && !url.startsWith('http')) {
      final root = (baseUrl ?? '').replaceAll(RegExp(r'/+$'), '');
      url = root.isEmpty ? null : '$root${url.startsWith('/') ? '' : '/'}$url';
    }
    String? abs(Object? v) {
      if (v is! String || v.isEmpty) return null;
      if (v.startsWith('http')) return v;
      final root = (baseUrl ?? '').replaceAll(RegExp(r'/+$'), '');
      return root.isEmpty ? null : '$root${v.startsWith('/') ? '' : '/'}$v';
    }
    return AiStyle(
      id: '${j['id']}',
      name: '${j['name'] ?? j['id']}',
      category: '${j['category'] ?? 'Styles'}',
      creditCost: i(j['credit_cost'], 2).clamp(0, 100),
      proOnly: j['pro_only'] == true,
      sortOrder: i(j['sort_order'], 0),
      imageUrl: (url == null || url.isEmpty) ? null : url,
      imageAsset: j['image_asset'] as String?,
      hasReference: j['has_reference'] == true,
      // Older servers / seeds without the field: person looks (default).
      needsPerson: j['needs_person'] != false,
      kind: j['kind'] == 'filter' ? 'filter' : 'style',
      prompt: j['prompt'] is String ? j['prompt'] as String : null,
      uiCategory: j['ui_category'] is String && (j['ui_category'] as String).trim().isNotEmpty
          ? (j['ui_category'] as String).trim().toLowerCase()
          : null,
      sampleBeforeUrl: abs(j['sample_before_url']),
      sampleAfterUrl: abs(j['sample_after_url']),
      // v11.58: missing (seed / older server) → Klein default; unknown → Custom.
      model: j.containsKey('model') && j['model'] != null
          ? normalizeStyleModel(j['model'])
          : (j['kind'] == 'filter' ? kStyleModelCustom : kStyleModelKlein),
    );
  }

  final String id;
  final String name;
  final String category;

  /// Credits per generated image.
  final int creditCost;
  final bool proOnly;
  final int sortOrder;

  /// Server display image (cached on disk by StyleCatalog).
  final String? imageUrl;

  /// Bundled sample image (seed styles / offline fallback).
  final String? imageAsset;
  final bool hasReference;

  /// Made for photos of people (outfits, portraits, travel selfies): the app
  /// warns before spending credits when no face is found in the photo.
  final bool needsPerson;

  /// v11.51: 'filter' = camera filter row (Styles carousel), 'style' = the
  /// Styles library. Same prompt / credit / apply path.
  final String kind;
  bool get isFilter => kind == 'filter';

  /// Public prompt (camera filters only; library style prompts stay hidden
  /// on the server). Used by the key test build's local look path.
  final String? prompt;

  /// v11.54 browse category id for the Styles sheet chips (admin-set,
  /// e.g. 'new', 'trending', 'cities'); null = shown under New.
  final String? uiCategory;

  /// v11.56 real before/after sample (card thumbnail = after; the apply
  /// sheet shows a before/after slider). Null → placeholder as before.
  final String? sampleBeforeUrl;
  final String? sampleAfterUrl;

  /// v11.58: which image model renders this style (see [kStyleModels]).
  final String model;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'credit_cost': creditCost,
    'pro_only': proOnly,
    'sort_order': sortOrder,
    if (imageUrl != null) 'image_url': imageUrl,
    if (imageAsset != null) 'image_asset': imageAsset,
    'has_reference': hasReference,
    'needs_person': needsPerson,
    'kind': kind,
    if (prompt != null) 'prompt': prompt,
    if (uiCategory != null) 'ui_category': uiCategory,
    if (sampleBeforeUrl != null) 'sample_before_url': sampleBeforeUrl,
    if (sampleAfterUrl != null) 'sample_after_url': sampleAfterUrl,
    'model': model,
  };

  AiStyle withAsset(String? asset) => AiStyle(
    id: id,
    name: name,
    category: category,
    creditCost: creditCost,
    proOnly: proOnly,
    sortOrder: sortOrder,
    imageUrl: imageUrl,
    imageAsset: asset,
    hasReference: hasReference,
    needsPerson: needsPerson,
    kind: kind,
    prompt: prompt,
    uiCategory: uiCategory,
    sampleBeforeUrl: sampleBeforeUrl,
    sampleAfterUrl: sampleAfterUrl,
    model: model,
  );

  @override
  String toString() => 'AiStyle($id, 🪙$creditCost${proOnly ? ', pro' : ''})';
}

/// Sorted by admin sort order, then name.
List<AiStyle> sortStyles(Iterable<AiStyle> styles) =>
    styles.toList()..sort((a, b) {
      final c = a.sortOrder.compareTo(b.sortOrder);
      return c != 0 ? c : a.name.compareTo(b.name);
    });

/// Parses a style list payload (`{"version":…, "styles":[…]}`).
List<AiStyle> parseStyleList(Object? json, {String? baseUrl}) {
  if (json is! Map) return const [];
  final list = json['styles'];
  if (list is! List) return const [];
  return sortStyles(
    list.whereType<Map>().map(
      (e) => AiStyle.fromJson(e.cast<String, Object?>(), baseUrl: baseUrl),
    ),
  );
}
