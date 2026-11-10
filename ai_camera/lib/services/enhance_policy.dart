/// v10 rule: AI enhance happens ONLY at capture time (PRO AI mode). There
/// is no post-capture / gallery "Enhance".
enum PhotoSource { proCapture, normalCapture, gallery }

class PreviewActions {
  const PreviewActions({
    required this.autoEnhance,
    required this.aiFilters,
    required this.styles,
    required this.customDescribe,
    required this.captureTip,
  });

  /// Enhance (credits) right after capture.
  final bool autoEnhance;

  /// Post-capture AI filters (they re-run the capture-time enhance with a
  /// look) — only on PRO AI captures.
  final bool aiFilters;

  /// Creative AI styles + custom describe (credits, every source).
  final bool styles;
  final bool customDescribe;

  /// "Shoot in Pro AI for sharper, clearer photos" (normal captures).
  final bool captureTip;
}

PreviewActions previewActionsFor(PhotoSource source) {
  switch (source) {
    case PhotoSource.proCapture:
      return const PreviewActions(
        autoEnhance: true,
        aiFilters: true,
        styles: true,
        customDescribe: true,
        captureTip: false,
      );
    case PhotoSource.normalCapture:
      return const PreviewActions(
        autoEnhance: false,
        aiFilters: false,
        styles: true,
        customDescribe: true,
        captureTip: true,
      );
    case PhotoSource.gallery:
      return const PreviewActions(
        autoEnhance: false,
        aiFilters: false,
        styles: true,
        customDescribe: true,
        captureTip: false,
      );
  }
}

const kProCaptureTip = 'Shoot in Pro AI for sharper, clearer photos';

/// Shown (no AI call, no credits) when the custom describe text only asks
/// for a generic quality boost.
const kEnhanceOnlyTip =
    'Enhance happens at capture — shoot in Pro AI for sharper, clearer '
    'photos. No credits used.';

const _core = {
  'enhance',
  'enhanced',
  'enhancement',
  'enhancer',
  'clear',
  'clearer',
  'clarity',
  'hd',
  'fullhd',
  'uhd',
  'sharp',
  'sharper',
  'sharpen',
  'sharpness',
  'quality',
  'improve',
  'improved',
  'upscale',
  'upscaled',
  'upscaling',
  '4k',
  '8k',
  '2k',
  'deblur',
  'unblur',
  'crisp',
  'crisper',
  'resolution',
  'highres',
  'hq',
  'detail',
  'details',
  'detailed',
  'focus',
  'denoise',
  'retouch',
  'blurry',
  'blurred',
};

const _filler = {
  'make',
  'it',
  'the',
  'photo',
  'image',
  'picture',
  'pic',
  'pics',
  'more',
  'please',
  'pls',
  'plz',
  'this',
  'a',
  'an',
  'and',
  'look',
  'looks',
  'fix',
  'blur',
  'remove',
  'reduce',
  'noise',
  'better',
  'high',
  'higher',
  'definition',
  'super',
  'very',
  'ultra',
  'full',
  'in',
  'to',
  'of',
  'my',
  'me',
  'bit',
  'little',
  'lot',
  'add',
  'increase',
  'quality',
  'version',
  'best',
  'good',
  'nice',
  'clean',
  'cleaner',
  'up',
  'with',
  'less',
  'bright',
  'brighter',
  'brightness',
  'colors',
  'colours',
  'color',
  'colour',
  'pixel',
  'pixels',
  'convert',
  'into',
  'k',
  'x',
  'mode',
  'res',
};

/// True when [text] is just "enhance / clear / HD / sharp…" (no creative
/// change). Then the app shows [kEnhanceOnlyTip] instead of charging.
bool isEnhanceOnlyPrompt(String text) {
  final words = text
      .toLowerCase()
      .replaceAll(RegExp(r'full\s*hd'), 'fullhd')
      .replaceAll(RegExp(r'high[\s-]*res(olution)?'), 'highres')
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return false;
  var hasCore = false;
  for (final w in words) {
    if (_core.contains(w)) {
      hasCore = true;
    } else if (!_filler.contains(w)) {
      return false; // any creative word → a real custom edit
    }
  }
  return hasCore;
}
