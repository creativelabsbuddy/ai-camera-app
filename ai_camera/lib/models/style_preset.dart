import 'package:flutter/material.dart';

/// AI filters on the preview screen (Pro, or one starter trial). Prompts are
/// hidden from users; mirrored in enhance-server/prompts.py (FILTER_PROMPTS).
enum StyleKind { studio, cinematic, wedding, linkedIn, night, softBeauty }

class StylePreset {
  const StylePreset({
    required this.id,
    required this.label,
    required this.icon,
    required this.kind,
    required this.prompt,
  });

  /// Wire id (server `filter_id`).
  final String id;
  final String label;
  final IconData icon;
  final StyleKind kind;
  final String prompt;
}

const List<StylePreset> kStylePresets = [
  StylePreset(
    id: 'studio',
    label: 'Studio',
    icon: Icons.apartment_rounded,
    kind: StyleKind.studio,
    prompt:
        'Apply a clean professional studio portrait look: even soft lighting, '
        'neutral color grade, crisp detail, subtle contrast.',
  ),
  StylePreset(
    id: 'cinematic',
    label: 'Cinematic',
    icon: Icons.movie_filter_rounded,
    kind: StyleKind.cinematic,
    prompt:
        'Apply a cinematic color grade: slight teal-orange tone, deeper '
        'contrast, subtle filmic vignette feel, dramatic but natural.',
  ),
  StylePreset(
    id: 'wedding',
    label: 'Wedding',
    icon: Icons.favorite_rounded,
    kind: StyleKind.wedding,
    prompt:
        'Apply a warm romantic wedding look: soft highlights, gentle warm '
        'tones, flattering skin, elegant soft glow without changing faces.',
  ),
  StylePreset(
    id: 'linkedin',
    label: 'LinkedIn',
    icon: Icons.work_rounded,
    kind: StyleKind.linkedIn,
    prompt:
        'Apply a polished LinkedIn headshot look: clean professional '
        'lighting, natural skin, moderate contrast, trustworthy corporate '
        'finish.',
  ),
  StylePreset(
    id: 'night',
    label: 'Night',
    icon: Icons.nights_stay_rounded,
    kind: StyleKind.night,
    prompt:
        'Apply night/low-light recovery: lift shadows carefully, reduce '
        'noise, keep natural colors, slight cool ambient balance.',
  ),
  StylePreset(
    id: 'soft_beauty',
    label: 'Soft Beauty',
    icon: Icons.spa_rounded,
    kind: StyleKind.softBeauty,
    prompt:
        'Apply soft beauty polish: gentle skin smoothing that keeps '
        'pores/texture, soft light, slight brightness, natural colors — do '
        'not reshape face.',
  ),
];
