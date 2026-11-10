import 'package:flutter/material.dart';

import 'ai_style.dart';

/// v11.54 Snapchat-style browse categories in the full Styles sheet.
/// Ids match the admin panel / Supabase `styles.ui_category` values.
class StyleCategory {
  const StyleCategory(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;
}

const kCategoryNew = 'new';

const kPhotoCategories = <StyleCategory>[
  StyleCategory('new', 'New', Icons.fiber_new_rounded),
  StyleCategory('trending', 'Trending', Icons.local_fire_department_rounded),
  StyleCategory('appearance', 'Appearance', Icons.face_retouching_natural_rounded),
  StyleCategory('cities', 'Cities', Icons.location_city_rounded),
  StyleCategory('bw', 'Black & White', Icons.contrast_rounded),
  StyleCategory('cinematic', 'Cinematic', Icons.movie_filter_rounded),
  StyleCategory('ai_photo', 'AI for Photo', Icons.auto_awesome_rounded),
];

const kVideoCategories = <StyleCategory>[
  StyleCategory('new', 'New', Icons.fiber_new_rounded),
  StyleCategory('trending', 'Trending', Icons.local_fire_department_rounded),
  StyleCategory('motion', 'Motion', Icons.animation_rounded),
  StyleCategory('cinematic', 'Cinematic', Icons.movie_filter_rounded),
  StyleCategory('zoom', 'Zoom', Icons.zoom_in_rounded),
];

List<StyleCategory> categoriesFor({required bool video}) =>
    video ? kVideoCategories : kPhotoCategories;

/// The style's category id; missing or unknown → New.
String categoryOf(AiStyle s, {required bool video}) {
  final c = s.uiCategory;
  if (c == null) return kCategoryNew;
  return categoriesFor(video: video).any((k) => k.id == c) ? c : kCategoryNew;
}

/// Styles shown under [category]. New also holds styles without a (known)
/// category; if New would be empty it shows everything (graceful fallback).
List<AiStyle> stylesInCategory(
  List<AiStyle> all,
  String category, {
  required bool video,
}) {
  final hit = [for (final s in all) if (categoryOf(s, video: video) == category) s];
  if (category == kCategoryNew && hit.isEmpty) return all;
  return hit;
}
