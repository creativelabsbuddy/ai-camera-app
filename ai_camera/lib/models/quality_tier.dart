/// Output quality the user pre-selects (persistent top badge). Cost depends
/// ONLY on the tier — zoom never forces a higher tier or extra credits.
///
/// Mapping to OpenRouter Flare params:
/// | tier     | credits | quality | resolution | target long side |
/// |----------|---------|---------|------------|------------------|
/// | HD       | 1       | low     | 1K         | ~1K  (≥1024)     |
/// | Full HD  | 2       | medium  | 1.5K       | ~2K  (≥1920)     |
/// | Ultra HD | 4       | high    | 2K         | ~2.5K (≥2560)    |
/// | 4K       | 8       | high    | 4K         | ~4K  (≥3840)     |
///
/// If the model returns fewer pixels than the target, the result is
/// resampled up to [minLongSide] so the label is honest.
enum QualityTier {
  hd('hd', 'HD', 1, 'low', '1K', 1024, '~1K', 'HD'),
  fullHd('full_hd', 'Full HD', 2, 'medium', '1.5K', 1920, '~2K', 'FHD'),
  ultraHd('ultra_hd', 'Ultra HD', 4, 'high', '2K', 2560, '~2.5K', 'UHD'),
  k4('4k', '4K', 8, 'high', '4K', 3840, '~4K', '4K');

  const QualityTier(
    this.id,
    this.label,
    this.credits,
    this.flareQuality,
    this.flareResolution,
    this.minLongSide,
    this.targetLabel,
    this.shortLabel,
  );

  /// Stable wire / prefs id (shared with enhance-server).
  final String id;

  /// User-facing name (kept in English: HD, Full HD, Ultra HD, 4K).
  final String label;
  final int credits;
  final String flareQuality;
  final String flareResolution;
  final int minLongSide;
  final String targetLabel;

  /// Compact top-right chip text (Samsung "12M" style): HD / FHD / UHD / 4K.
  final String shortLabel;

  /// Ultra HD / 4K — covered by the one-time "premium quality" starter trial.
  bool get isPremium => this == ultraHd || this == k4;

  static const prefsKey = 'quality_tier';

  /// v11.39 main picker: HD / Full HD / Ultra HD; 4K is gone (a locked
  /// "2K · Coming soon" row is shown instead and can't be picked).
  static const picker = [hd, fullHd, ultraHd];

  /// Saved / old ids → a pickable tier (old "4k" → Ultra HD).
  static QualityTier pickable(String? id) {
    final t = fromId(id);
    return t == k4 ? ultraHd : t;
  }

  static QualityTier fromId(String? id) => QualityTier.values.firstWhere(
    (t) => t.id == id,
    orElse: () => QualityTier.hd,
  );
}
