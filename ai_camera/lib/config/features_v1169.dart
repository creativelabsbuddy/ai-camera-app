/// v11.69 feature switches. Every v11.69 change can be undone by flipping
/// one constant here and rebuilding (no data migration needed).
library;

/// Zoom mode AI enhance uses GPT Image 2.5 Sunburst (false → Flare again).
const bool kZoomSunburst = true;

/// Pro Photo "Natural | Studio" chip above the shutter (false → chip hidden,
/// every Pro Photo uses Flare like v11.68).
const bool kProLookToggle = true;

/// Normal Photo burst: long-press the shutter (false → long-press does
/// nothing, single shots only).
const bool kBurstShot = true;

/// Free on-device Auto Tone after a Normal capture (false → photo shown
/// as captured, no tone bar).
const bool kAutoTone = true;

/// Free on-device Tone presets (camera strip + after capture). False →
/// strip hidden, no live tone preview.
const bool kTonePresets = true;
