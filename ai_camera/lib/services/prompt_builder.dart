import 'dart:math' as math;

import '../models/quality_tier.dart';
import 'entitlements.dart' show kMaxCustomPromptChars;
import 'mode_prompts.dart' show kColorFilterTail;
import 'zoom_range.dart' show formatZoom;

/// v11.39 enhance prompt (short, positive, faithful; approved by Ankush). Everything
/// else is appended as separate sentences. Mirrored verbatim in
/// enhance-server/prompts.py.
const String kLockedEnhancePrompt =
    'Enhance this real photo and keep it the same photo: same framing, same people and faces, same objects and same scene, with nothing added. Make it clean and naturally sharp, with balanced light, true natural colours and real skin and surface texture.';

/// Sent when a second (context) image is attached.
const String kContextBoxedSentence =
    'The second image is a sharp, lower-zoom photo of the same '
    'scene taken just before; the red box marks exactly where the '
    'first image is. Use it only to understand what the subject '
    'really is; enhance and upscale only the first image, do not '
    'draw the box and do not invent new content.';

const String kHighZoomClarity =
    'Make what is already visible clear and clean, keeping every shape, letter and detail exactly as it is; leave parts that cannot be read as they are.';

/// v11.30 100x zoom ladder (cheap phones): boxed lower-zoom references
/// first, the photo to enhance last. Mirrors the server's hidden prompt
/// (key builds only).
/// v11.34 high zoom (2x+, all phones): keep the photo, raise its detail.
const String kZoomCleanPrompt =
    'Keep this zoomed photo exactly as it is: same subject, shapes, framing, colours and light. Make the detail that is already there clearer, gently clean light noise, and keep natural fine texture and a real camera-photo look.';
const String kZoomLadderRefsLine =
    'The other images are clearer close-up views of the same area; use them '
    'for detail.';
const String kZoomLadderPrompt = '$kZoomCleanPrompt $kZoomLadderRefsLine';

const String kContextImageSentence =
    'Use the second image only to understand the scene; enhance and upscale '
    'only the first image, do not invent new content.';

/// Pro AI night mode: appended right after [kLockedEnhancePrompt] (exact
/// wording approved by Ankush). Mirrored in enhance-server/prompts.py.
// v11.48: general night prompt.
const String kNightPrompt =
    'A natural night photograph of the last image: gently reduce noise, recover shadow detail and keep the real lighting and mood. Keep every object, light and colour as in the photo and do not add anything new. Photorealistic.';

/// AI style / custom "Prompt" wrapper (looks are NOT enhances: the
/// locked enhance prompt forbids changing clothes/background, so looks use
/// this identity-preserving wrapper instead). Mirrored in prompts.py.
const String kLookIdentityPrompt =
    'Edit this real photo of the person or people in the first image. '
    'Keep every person\'s face, identity, facial features, skin tone, '
    'age, body shape, hair and expression exactly the same; the result '
    'must clearly be the same real people, photorealistic, never a '
    'cartoon, painting or different person.';

/// Added when the style carries reference image(s).
const String kLookReferenceSentence =
    'Use the additional reference image(s) only as a guide for the '
    'requested look (outfit, place, style); never copy faces or '
    'identity from them.';

/// Always last in a look prompt.
const String kLookTailSentence =
    'Change only what the request asks for, match lighting and '
    'perspective so the result looks like a real photo, and keep hands '
    'and body natural.';

/// Detail-recovery emphasis level for zoom ratio over optical.
/// 0 = at/below optical (no sentence), 1 = ≤2x over, 2 = ≤4x over, 3 = more.
int zoomEmphasisLevel(double overOptical) {
  if (!overOptical.isFinite || overOptical <= 1.05) return 0;
  if (overOptical <= 2.0) return 1;
  if (overOptical <= 4.0) return 2;
  return 3;
}

String zoomSentence({required double zoom, required double opticalLimit}) {
  final limit = math.max(1.0, opticalLimit);
  final over = zoom.isFinite && zoom > 0 ? zoom / limit : 1.0;
  final z = formatZoom(zoom);
  final o = formatZoom(over);
  switch (zoomEmphasisLevel(over)) {
    case 0:
      return '';
    case 1:
      return 'The first image is a ${z}x zoom, about ${o}x beyond the phone\'s '
          'optical lens; gently recover fine detail softened by digital zoom.';
    case 2:
      return 'The first image is a ${z}x zoom, about ${o}x beyond the phone\'s '
          'optical lens; carefully recover fine detail, edges and textures '
          'lost to digital zoom while staying faithful to what is visible.';
    default:
      return 'The first image is a heavy ${z}x digital zoom, about ${o}x '
          'beyond the phone\'s optical lens; recover as much real detail as '
          'possible (edges, textures, text) strictly from what is visible, '
          'and prefer a clean natural result over invented detail.';
  }
}

String qualitySentence(QualityTier tier) {
  switch (tier) {
    case QualityTier.hd:
      return '';
    case QualityTier.fullHd:
      return 'Target a crisp Full HD result with clean fine detail.';
    case QualityTier.ultraHd:
      return 'Target a very detailed Ultra HD result with crisp fine texture.';
    case QualityTier.k4:
      return 'Target a maximum-detail 4K result with crisp fine texture '
          'throughout.';
  }
}

String sanitizeCustomPrompt(String raw) {
  final s = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > kMaxCustomPromptChars
      ? s.substring(0, kMaxCustomPromptChars)
      : s;
}

/// Full prompt = locked base + optional sentences, in a fixed order:
/// mode (night / portrait / macro), context-image rule, zoom emphasis,
/// quality, style, color look, user prompt. Same order as
/// prompts.build_prompt on the server.
String buildEnhancePrompt({
  bool hasContextImage = false,
  double zoom = 1.0,
  double opticalLimit = 1.0,
  QualityTier tier = QualityTier.hd,
  String? stylePrompt,
  String? customPrompt,
  bool night = false,
  String? modePrompt,
  String? colorPrompt,
  bool contextBoxed = false,
}) {
  final parts = <String>[kLockedEnhancePrompt];
  final mp = modePrompt?.trim() ?? '';
  if (mp.isNotEmpty) {
    parts.add(mp);
  } else if (night) {
    parts.add(kNightPrompt);
  }
  if (hasContextImage) {
    parts.add(contextBoxed ? kContextBoxedSentence : kContextImageSentence);
  }
  final zs = zoomSentence(zoom: zoom, opticalLimit: opticalLimit);
  if (zs.isNotEmpty) parts.add(zs);
  if (highZoomClarity(zoom, opticalLimit)) parts.add(kHighZoomClarity);
  final qs = qualitySentence(tier);
  if (qs.isNotEmpty) parts.add(qs);
  final st = stylePrompt?.trim() ?? '';
  if (st.isNotEmpty) parts.add('Style: $st');
  final cl = colorPrompt?.trim() ?? '';
  if (cl.isNotEmpty) parts.add('Color look: $cl $kColorFilterTail');
  final cp = sanitizeCustomPrompt(customPrompt ?? '');
  if (cp.isNotEmpty) {
    parts.add(
      'Additional user request (apply only while keeping every face, '
      'identity and the real scene intact): $cp',
    );
  }
  return parts.join(' ');
}

/// Prompt for a style apply (hidden style prompt) or a custom change.
/// Same order as prompts.build_look_prompt on the server.
String buildLookPrompt({
  String? stylePrompt,
  String? customPrompt,
  bool hasReferences = false,
}) {
  final parts = <String>[kLookIdentityPrompt];
  if (hasReferences) parts.add(kLookReferenceSentence);
  final st = stylePrompt?.trim() ?? '';
  if (st.isNotEmpty) parts.add('Requested look: $st');
  final cp = sanitizeCustomPrompt(customPrompt ?? '');
  if (cp.isNotEmpty) parts.add('Requested change: $cp');
  parts.add(kLookTailSentence);
  return parts.join(' ');
}

/// v11.9 clarity rule from >2x beyond the optical lens (same as server).
bool highZoomClarity(double zoom, double opticalLimit) {
  final limit = opticalLimit < 1 ? 1.0 : opticalLimit;
  final over = zoom.isFinite && zoom > 0 ? zoom / limit : 1.0;
  return zoomEmphasisLevel(over) >= 2;
}
