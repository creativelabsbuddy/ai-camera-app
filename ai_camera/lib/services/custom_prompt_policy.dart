/// "Describe a change…" rules (v9.1). Users may type anything — it's their
/// credits — so there is NO relevance check. Only a length limit and a tiny
/// safety keyword list; the model's own refusals cover the rest (refused /
/// no image → clear message, no credits charged). The server applies the
/// same list (prompts.py `blocked_custom_reason`) — keep them in sync.
library;

import 'entitlements.dart' show kMaxCustomPromptChars;

/// 200 characters (shared with prompt_builder / server).
const int kCustomPromptMaxChars = kMaxCustomPromptChars;

/// Rotating English placeholder examples for the text box.
const List<String> kCustomPromptExamples = [
  'e.g. Put me in a black suit',
  'e.g. Make it a sunset at the beach',
  'e.g. Add a red saree with gold border',
  'e.g. Turn this into a winter scene with snow',
  'e.g. Give me a neat short haircut',
];

/// Basic safety block (nudity / undressing, sexual content incl. minors,
/// face-swapping another real person, graphic violence).
final List<RegExp> kBlockedCustomPatterns = [
  RegExp(
    r'\b(nude|nudes|naked|nudity|topless|bottomless|undress\w*|unclothed|strip(ped|ping)?\s+(off|naked|down))\b',
  ),
  RegExp(
    r'\b(without|no|remove|take off|taking off)\s+(her |his |my |the |their )?(clothes|clothing|dress|shirt|top|bra|underwear)\b',
  ),
  RegExp(
    r'\b(sex|sexual|sexy|porn\w*|nsfw|erotic|explicit|lingerie|seductive)\b',
  ),
  RegExp(
    r'\b(face\s*-?\s*swap\w*|swap\w*\s+(my |his |her |the |their )?faces?|deep\s*-?\s*fake\w*|replace\s+(my |his |her |the |their )?face)\b',
  ),
  RegExp(
    r'\b(gore|gory|decapitat\w*|behead\w*|dismember\w*|mutilat\w*|corpse|dead body|blood\s*(splatter|soaked|bath)|bloody wound)\b',
  ),
];

/// Non-null (user message) when [prompt] hits the safety list.
String? blockedCustomPromptReason(String prompt) {
  final p = prompt.toLowerCase();
  for (final r in kBlockedCustomPatterns) {
    if (r.hasMatch(p)) {
      return "This change isn't allowed. Try something else — "
          'no credits used.';
    }
  }
  return null;
}

/// Trimmed and clipped to [kCustomPromptMaxChars].
String normalizeCustomPrompt(String prompt) {
  final t = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length > kCustomPromptMaxChars
      ? t.substring(0, kCustomPromptMaxChars)
      : t;
}
