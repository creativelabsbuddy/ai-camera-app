/// v11.70 feature switches. Every v11.70 change can be undone by flipping
/// one constant here and rebuilding (no data migration needed).
library;

/// Preview after capture: big edge-to-edge photo (tap = fullscreen with
/// pinch zoom), slim Styles row with "See all", small info text overlaid
/// on the photo, compact bottom buttons. False → the v11.69 layout.
const bool kPreviewV1170 = true;

/// No "Filters" button / free on-device filters panel on the preview. The
/// credit AI filters (Pro AI captures) are cards in the Styles row instead
/// (same prompts, same credits). False → the v11.69 Filters panel.
const bool kNoFiltersPanel = true;

/// No free Tone preset chips (Auto / Vivid / Natural / Warm / Cool / Food …)
/// on the live camera or after capture. Auto Tone, Adjust and Reset after a
/// Normal capture stay. False → the v11.69 chips.
const bool kNoToneChips = true;

/// New free editor (Crop · Adjust · Retouch · Skin Tone), on-device, no
/// credits, saves a new edited copy. False → the v11.69 Crop / Adjust editor.
const bool kEditorV1170 = true;

/// Editor "Retouch" tab (ML Kit face contours, on device). False → tab hidden.
const bool kRetouch = true;

/// Editor "Skin Tone" tab. False → tab hidden.
const bool kSkinTone = true;

/// One Pro AI enhance tier: Flare quality low, 1 credit, no upscale (no
/// Real-ESRGAN / resize), the Ultra HD detail line added to the prompt. The
/// HD / Full HD / Ultra HD chip is hidden. Zoom mode keeps Sunburst.
/// False → the v11.69 tiers and chip. Server: env SINGLE_TIER.
const bool kSingleEnhanceTier = true;
