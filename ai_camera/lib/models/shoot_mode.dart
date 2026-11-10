import 'package:flutter/material.dart';

/// Shooting modes in the Samsung-style carousel above the shutter
/// (v11 order). The selected mode is always centred over the shutter.
enum ShootMode {
  night('Night', Icons.nightlight_round),
  portrait('Portrait', Icons.portrait_rounded),
  photo('Photo', Icons.photo_camera_outlined),
  macro('Macro', Icons.local_florist_outlined),
  pose('Pose', Icons.accessibility_new_rounded),
  hdr('HDR', Icons.hdr_on_rounded),
  document('Document', Icons.document_scanner_outlined);

  const ShootMode(this.label, this.icon);
  final String label;
  final IconData icon;

  /// Carousel order (MORE = toggles sheet comes after these).
  /// v11.49: HDR removed from the app (Night keeps its merge).
  static const strip = [night, portrait, photo, macro, pose, document];

  /// v11.48: Normal has no Macro (Pro AI only); Pro AI has no HDR bracket.
  static List<ShootMode> stripFor({required bool aiMode}) => [
    for (final m in strip)
      if (!(aiMode ? m == hdr : m == macro)) m,
  ];

  static const prefsKey = 'shoot_mode';

  static ShootMode fromName(String? n) => n == 'hdr'
      ? ShootMode
            .photo // v11.49: HDR removed → Photo
      : ShootMode.values.firstWhere(
          (m) => m.name == n,
          orElse: () => ShootMode.photo,
        );

  /// Server / prompt id of the Pro AI mode add-on (hidden server prompt).
  String get aiModeId => switch (this) {
    ShootMode.portrait => 'portrait',
    ShootMode.night => 'night',
    ShootMode.macro => 'macro',
    _ => 'photo',
  };
}

/// v11.50: the four-dot quick menu shows in every mode except Pro AI Macro.
bool quickMenuVisible({required bool aiMode, required ShootMode mode}) =>
    !(aiMode && mode == ShootMode.macro);

/// Live on-device analyzers a mode / toggle can need. v11 removed live
/// selfie segmentation (flicker) and pose detection (no outline overlay).
enum LiveAnalyzer {
  faces,
  barcodes,
  labels,

  /// Cheap luma mean + centre sharpness + tiny thumbnail (Night planning,
  /// Macro distance guide, freeze frame for camera hand-overs).
  frameStats,
}

/// User toggles (More sheet), persisted. Samsung-like defaults.
class CameraFeatures {
  const CameraFeatures({
    this.scanQr = true,
    this.smileShot = false,
    this.faceFocus = true,
    this.sceneTips = true,
    this.grid = true,
    this.level = false,
  });

  final bool scanQr;
  final bool smileShot;
  final bool faceFocus;
  final bool sceneTips;
  final bool grid;
  final bool level;

  static const prefsKey = 'camera_features_v10';

  CameraFeatures copyWith({
    bool? scanQr,
    bool? smileShot,
    bool? faceFocus,
    bool? sceneTips,
    bool? grid,
    bool? level,
  }) => CameraFeatures(
    scanQr: scanQr ?? this.scanQr,
    smileShot: smileShot ?? this.smileShot,
    faceFocus: faceFocus ?? this.faceFocus,
    sceneTips: sceneTips ?? this.sceneTips,
    grid: grid ?? this.grid,
    level: level ?? this.level,
  );

  Map<String, Object?> toJson() => {
    'scan_qr': scanQr,
    'smile_shot': smileShot,
    'face_focus': faceFocus,
    'scene_tips': sceneTips,
    'grid': grid,
    'level': level,
  };

  factory CameraFeatures.fromJson(Map<String, Object?>? j) {
    const d = CameraFeatures();
    if (j == null) return d;
    bool b(String k, bool def) => j[k] is bool ? j[k]! as bool : def;
    return CameraFeatures(
      scanQr: b('scan_qr', d.scanQr),
      smileShot: b('smile_shot', d.smileShot),
      faceFocus: b('face_focus', d.faceFocus),
      sceneTips: b('scene_tips', d.sceneTips),
      grid: b('grid', d.grid),
      level: b('level', d.level),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CameraFeatures &&
      other.toJson().toString() == toJson().toString();

  @override
  int get hashCode => toJson().toString().hashCode;
}

/// What the shutter does in a mode.
enum CaptureKind {
  /// One still.
  single,

  /// v11 Night: hold-still countdown + 8–15 frame burst + merge.
  nightBurst,

  /// 3-frame exposure bracket → on-device HDR merge.
  hdrBracket,

  /// v11 Portrait in Normal: the phone's own BOKEH (CameraX extension).
  nativeBokeh,

  /// v11 Macro (Pro AI): 3–5 frames, sharpest one goes to the AI.
  macroBurst,

  /// Hands over to the ML Kit document scanner (no camera still).
  documentScanner,
}

/// Why a mode can't run as asked (the strip shows a note instead).
enum ModeBlock {
  none,

  /// Macro is Pro AI only.
  macroNeedsPro,

  /// Portrait in Normal needs the vendor bokeh extension.
  portraitUnsupported,
}

/// Mode routing: everything the camera screen needs to know for a mode.
class ModeRoute {
  const ModeRoute({
    required this.mode,
    required this.capture,
    required this.analyzers,
    this.night = false,
    this.aiMode = 'photo',
    this.block = ModeBlock.none,
  });

  final ShootMode mode;
  final CaptureKind capture;

  /// Live analyzers to run on the preview stream (empty → stream off).
  final Set<LiveAnalyzer> analyzers;

  /// Night burst pipeline.
  final bool night;

  /// Pro AI add-on prompt id sent with the enhance ('photo' = none).
  final String aiMode;
  final ModeBlock block;

  bool get blocked => block != ModeBlock.none;
}

/// Short notes for blocked modes (English, short).
const kMacroNeedsProNote = 'Macro works in Pro AI';
const kPortraitUnsupportedNote =
    "Portrait isn't supported on this phone in Normal. Try Pro AI.";

/// Pure mode router (unit-tested).
///
/// [aiMode] = PRO AI tab selected. [bokehAvailable] = the vendor BOKEH
/// extension is available for the current lens (null = not probed yet →
/// treated as unavailable; never a fake blur).
ModeRoute routeFor(
  ShootMode mode, {
  CameraFeatures features = const CameraFeatures(),
  bool aiMode = false,
  bool? bokehAvailable,
}) {
  final base = <LiveAnalyzer>{
    if (features.faceFocus || features.smileShot) LiveAnalyzer.faces,
    if (features.scanQr) LiveAnalyzer.barcodes,
    if (features.sceneTips) LiveAnalyzer.labels,
    LiveAnalyzer.frameStats,
  };
  switch (mode) {
    case ShootMode.photo:
      return ModeRoute(
        mode: mode,
        capture: CaptureKind.single,
        analyzers: base,
      );
    case ShootMode.portrait:
      if (aiMode) {
        // Normal capture, then AI DSLR-like bokeh (hidden server prompt).
        return ModeRoute(
          mode: mode,
          capture: CaptureKind.single,
          aiMode: 'portrait',
          analyzers: base.difference({LiveAnalyzer.barcodes}),
        );
      }
      if (bokehAvailable == true) {
        // Native session owns the camera: no Flutter analysis stream.
        return const ModeRoute(
          mode: ShootMode.portrait,
          capture: CaptureKind.nativeBokeh,
          analyzers: {},
        );
      }
      return ModeRoute(
        mode: mode,
        capture: CaptureKind.single,
        analyzers: base,
        block: ModeBlock.portraitUnsupported,
      );
    case ShootMode.night:
      // Keep the stream light in low light: QR + frame stats only.
      return ModeRoute(
        mode: mode,
        capture: CaptureKind.nightBurst,
        night: true,
        aiMode: aiMode ? 'night' : 'photo',
        analyzers: {
          if (features.scanQr) LiveAnalyzer.barcodes,
          LiveAnalyzer.frameStats,
        },
      );
    case ShootMode.macro:
      if (!aiMode) {
        return ModeRoute(
          mode: mode,
          capture: CaptureKind.single,
          analyzers: base,
          block: ModeBlock.macroNeedsPro,
        );
      }
      return const ModeRoute(
        mode: ShootMode.macro,
        capture: CaptureKind.macroBurst,
        aiMode: 'macro',
        // v11.10: faces → zoom-aware label (Face / Skin / Eye / Hair …).
        analyzers: {
          LiveAnalyzer.labels,
          LiveAnalyzer.faces,
          LiveAnalyzer.frameStats,
        },
      );
    case ShootMode.document:
      return const ModeRoute(
        mode: ShootMode.document,
        capture: CaptureKind.documentScanner,
        analyzers: {},
      );
    case ShootMode.hdr:
      // v11.48 Pro / v11.49 everywhere: no HDR bracket (single capture).
      return ModeRoute(
        mode: ShootMode.photo,
        capture: CaptureKind.single,
        analyzers: base,
      );
    case ShootMode.pose:
      return ModeRoute(
        mode: mode,
        capture: CaptureKind.single,
        analyzers: {
          LiveAnalyzer.labels, // scene-based pose category order
          LiveAnalyzer.frameStats,
          if (features.faceFocus || features.smileShot) LiveAnalyzer.faces,
        },
      );
  }
}
