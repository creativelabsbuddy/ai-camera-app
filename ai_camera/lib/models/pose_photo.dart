/// v11 Pose mode: REAL reference photos (no outline overlay). The picked
/// photo floats on the camera as a small draggable thumbnail to copy.
library;

/// Pose categories (scene-ordered at runtime). Same list as the server.
const kPoseCategories = [
  'Standing',
  'Sitting',
  'Couple',
  'Group',
  'Selfie',
  'Travel',
  'Casual',
];

class PosePhoto {
  const PosePhoto({
    required this.id,
    required this.name,
    required this.category,
    this.asset,
    this.url,
    this.credit = '',
    this.sortOrder = 0,
  });

  final String id;
  final String name;
  final String category;

  /// Bundled fallback photo (offline).
  final String? asset;

  /// Server photo (`/media/poses/<file>`, admin-managed).
  final String? url;
  final String credit;
  final int sortOrder;

  bool get bundled => asset != null;

  /// Server JSON (`GET /v1/poses`).
  static PosePhoto? fromServer(Map<String, Object?> j, {String? baseUrl}) {
    final cat = '${j['category'] ?? ''}';
    final raw = '${j['photo_url'] ?? ''}';
    if (raw.isEmpty || !kPoseCategories.contains(cat)) return null;
    final url = raw.startsWith('http')
        ? raw
        : '${(baseUrl ?? '').replaceAll(RegExp(r'/+$'), '')}$raw';
    return PosePhoto(
      id: '${j['id']}',
      name: '${j['name'] ?? 'Pose'}',
      category: cat,
      url: url,
      credit: '${j['credit'] ?? ''}',
      sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
    );
  }

  /// Bundled `assets/poses/poses.json` entry.
  static PosePhoto? fromAsset(Map<String, Object?> j) {
    final cat = '${j['category'] ?? ''}';
    final asset = '${j['asset'] ?? ''}';
    if (asset.isEmpty || !kPoseCategories.contains(cat)) return null;
    return PosePhoto(
      id: '${j['id']}',
      name: '${j['name'] ?? 'Pose'}',
      category: cat,
      asset: asset,
      credit: '${j['credit'] ?? ''}',
      sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Bundled fallback: the full seed set (30 Pexels photos, 640 px) so the
/// gallery works offline / without a server. Mirrors assets/poses/poses.json.
const kBundledPoses = <PosePhoto>[
  PosePhoto(
    id: 'local_standing_17514227',
    name: 'Confident stance',
    category: 'Standing',
    asset: 'assets/poses/pose_standing_17514227.jpg',
    credit: 'Photo: Myco Libot / Pexels',
    sortOrder: 0,
  ),
  PosePhoto(
    id: 'local_standing_13515052',
    name: 'Sidewalk step',
    category: 'Standing',
    asset: 'assets/poses/pose_standing_13515052.jpg',
    credit: 'Photo: Brian Jiz / Pexels',
    sortOrder: 1,
  ),
  PosePhoto(
    id: 'local_standing_6311576',
    name: 'Relaxed studio',
    category: 'Standing',
    asset: 'assets/poses/pose_standing_6311576.jpg',
    credit: 'Photo: Monstera Production / Pexels',
    sortOrder: 2,
  ),
  PosePhoto(
    id: 'local_standing_7755193',
    name: 'Hands in pockets',
    category: 'Standing',
    asset: 'assets/poses/pose_standing_7755193.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 3,
  ),
  PosePhoto(
    id: 'local_standing_20337701',
    name: 'Coat & pockets',
    category: 'Standing',
    asset: 'assets/poses/pose_standing_20337701.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 4,
  ),
  PosePhoto(
    id: 'local_sitting_14359323',
    name: 'Spiral stairs',
    category: 'Sitting',
    asset: 'assets/poses/pose_sitting_14359323.jpg',
    credit: 'Photo: Liza Bakay / Pexels',
    sortOrder: 5,
  ),
  PosePhoto(
    id: 'local_sitting_20598318',
    name: 'Stairs lean',
    category: 'Sitting',
    asset: 'assets/poses/pose_sitting_20598318.jpg',
    credit: 'Photo: UMUT RAW / Pexels',
    sortOrder: 6,
  ),
  PosePhoto(
    id: 'local_sitting_27196698',
    name: 'City steps',
    category: 'Sitting',
    asset: 'assets/poses/pose_sitting_27196698.jpg',
    credit: 'Photo: foad shariyati / Pexels',
    sortOrder: 7,
  ),
  PosePhoto(
    id: 'local_sitting_16177597',
    name: 'Bench cozy',
    category: 'Sitting',
    asset: 'assets/poses/pose_sitting_16177597.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 8,
  ),
  PosePhoto(
    id: 'local_sitting_34974311',
    name: 'Bench smile',
    category: 'Sitting',
    asset: 'assets/poses/pose_sitting_34974311.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 9,
  ),
  PosePhoto(
    id: 'local_couple_37339715',
    name: 'Lakeside hug',
    category: 'Couple',
    asset: 'assets/poses/pose_couple_37339715.jpg',
    credit: 'Photo: Ismail Suleiman / Pexels',
    sortOrder: 10,
  ),
  PosePhoto(
    id: 'local_couple_36396113',
    name: 'Side by side',
    category: 'Couple',
    asset: 'assets/poses/pose_couple_36396113.jpg',
    credit: 'Photo: king caplis / Pexels',
    sortOrder: 11,
  ),
  PosePhoto(
    id: 'local_couple_34572487',
    name: 'Laughing walk',
    category: 'Couple',
    asset: 'assets/poses/pose_couple_34572487.jpg',
    credit: 'Photo: Alexander Mass / Pexels',
    sortOrder: 12,
  ),
  PosePhoto(
    id: 'local_couple_34837459',
    name: 'Traditional duo',
    category: 'Couple',
    asset: 'assets/poses/pose_couple_34837459.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 13,
  ),
  PosePhoto(
    id: 'local_couple_35036650',
    name: 'Festive pair',
    category: 'Couple',
    asset: 'assets/poses/pose_couple_35036650.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 14,
  ),
  PosePhoto(
    id: 'local_group_31517419',
    name: 'Three friends',
    category: 'Group',
    asset: 'assets/poses/pose_group_31517419.jpg',
    credit: 'Photo: César O\'neill / Pexels',
    sortOrder: 15,
  ),
  PosePhoto(
    id: 'local_group_33827653',
    name: 'Studio squad',
    category: 'Group',
    asset: 'assets/poses/pose_group_33827653.jpg',
    credit: 'Photo: Matheus Bertelli / Pexels',
    sortOrder: 16,
  ),
  PosePhoto(
    id: 'local_group_16751480',
    name: 'Team line-up',
    category: 'Group',
    asset: 'assets/poses/pose_group_16751480.jpg',
    credit: 'Photo: Gene Samit / Pexels',
    sortOrder: 17,
  ),
  PosePhoto(
    id: 'local_selfie_27177182',
    name: 'Park selfie',
    category: 'Selfie',
    asset: 'assets/poses/pose_selfie_27177182.jpg',
    credit: 'Photo: Helena Lopes / Pexels',
    sortOrder: 18,
  ),
  PosePhoto(
    id: 'local_selfie_7243117',
    name: 'Street selfie',
    category: 'Selfie',
    asset: 'assets/poses/pose_selfie_7243117.jpg',
    credit: 'Photo: Blue Bird / Pexels',
    sortOrder: 19,
  ),
  PosePhoto(
    id: 'local_selfie_36729905',
    name: 'Group selfie',
    category: 'Selfie',
    asset: 'assets/poses/pose_selfie_36729905.jpg',
    credit: 'Photo: Vitaly Gariev / Pexels',
    sortOrder: 20,
  ),
  PosePhoto(
    id: 'local_selfie_32064453',
    name: 'Arm-length selfie',
    category: 'Selfie',
    asset: 'assets/poses/pose_selfie_32064453.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 21,
  ),
  PosePhoto(
    id: 'local_travel_30674349',
    name: 'Landmark portrait',
    category: 'Travel',
    asset: 'assets/poses/pose_travel_30674349.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 22,
  ),
  PosePhoto(
    id: 'local_travel_33793239',
    name: 'Railing lean',
    category: 'Travel',
    asset: 'assets/poses/pose_travel_33793239.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 23,
  ),
  PosePhoto(
    id: 'local_travel_14642269',
    name: 'Valley view',
    category: 'Travel',
    asset: 'assets/poses/pose_travel_14642269.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 24,
  ),
  PosePhoto(
    id: 'local_travel_5636603',
    name: 'Mountain top',
    category: 'Travel',
    asset: 'assets/poses/pose_travel_5636603.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 25,
  ),
  PosePhoto(
    id: 'local_casual_31742300',
    name: 'Wall lean',
    category: 'Casual',
    asset: 'assets/poses/pose_casual_31742300.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 26,
  ),
  PosePhoto(
    id: 'local_casual_28279189',
    name: 'Graffiti wall',
    category: 'Casual',
    asset: 'assets/poses/pose_casual_28279189.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 27,
  ),
  PosePhoto(
    id: 'local_casual_34340561',
    name: 'Rustic wall',
    category: 'Casual',
    asset: 'assets/poses/pose_casual_34340561.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 28,
  ),
  PosePhoto(
    id: 'local_casual_33706502',
    name: 'Brick corner',
    category: 'Casual',
    asset: 'assets/poses/pose_casual_33706502.jpg',
    credit: 'Photo: Pexels contributor / Pexels',
    sortOrder: 29,
  ),
];
