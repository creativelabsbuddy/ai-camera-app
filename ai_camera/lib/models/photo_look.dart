import '../config/ai_config.dart';
import '../config/features_v1169.dart';

/// v11.69 Pro Photo look (chip above the shutter). Credits are the same for
/// both; only the image model differs.
enum PhotoLook {
  /// GPT Image 2.5 Sunburst — keeps the photo as it is.
  natural('Natural', 'natural'),

  /// GPT Image 2.5 Flare — the v11.68 "picture perfect" enhance.
  studio('Studio', 'studio');

  const PhotoLook(this.label, this.id);
  final String label;

  /// Sent to the server as `photo_look`.
  final String id;

  static const PhotoLook defaultLook = PhotoLook.natural;
  static const prefsKey = 'pro_photo_look_v1169';
  static const tipSeenKey = 'pro_photo_look_tip_seen_v1169';

  static PhotoLook fromId(String? id) =>
      PhotoLook.values.firstWhere((l) => l.id == id, orElse: () => defaultLook);
}

/// First-time tip under the chip (shown once).
const kPhotoLookTip = 'Natural: as it is · Studio: picture perfect';

/// v11.69 image model for an enhance. Pure (unit tested).
///
/// - Zoom mode jobs → Sunburst ([kZoomSunburst]).
/// - Pro Photo (mode 'photo', not zoom) → the chosen look ([kProLookToggle]);
///   no look sent → Flare.
/// - Everything else (Portrait, Night, Macro, styles) → Flare, unchanged.
String enhanceModelFor({
  required String aiMode,
  required bool zoomJob,
  PhotoLook? look,
}) {
  if (aiMode == 'photo' && zoomJob) {
    return kZoomSunburst ? AiConfig.sunburstModel : AiConfig.model;
  }
  if (aiMode == 'photo' && kProLookToggle && look == PhotoLook.natural) {
    return AiConfig.sunburstModel;
  }
  return AiConfig.model;
}

/// Short label for status / debug lines.
String modelShortName(String model) => switch (model) {
  AiConfig.sunburstModel => 'Sunburst',
  AiConfig.model => 'Flare',
  _ => model.split('/').last,
};
