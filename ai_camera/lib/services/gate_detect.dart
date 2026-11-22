import 'dart:convert';
import 'dart:math' as math;

import 'micro_lock.dart' show isUsableLock;
import 'mode_prompts.dart' show sanitizeDetected;

// v11.67 zoom-gate detection for EVERY macro level (Macro, Close,
// Microscope, Extreme, Ultra). The zoom stops at 5x and 10x; at each stop
// one photo is taken and Flash-Lite describes it. The 10x call gets the 5x
// answer, so both detections are connected: 5x names the object and what is
// around it, 10x names the PART of that object in the centre box (or says
// it is a different object now → the lock follows it).
// Pure helpers (tested); the same prompts / parsing live in the server
// (prompts.py GATE_DETECT_5_PROMPT & co.).

/// Gate zooms for every macro level (lowest first). v11.67: 1.5x (micro)
/// and 2x (Macro / Close) gates removed.
const List<double> kGateZooms = [5.0, 10.0];

/// A gate photo is sent with the shot when the shot is at least this much
/// further zoomed (10x gate at a 10x shot = the same frame → skipped).
const double kGateStepMinWider = 1.05;

/// v11.67 the measured 5x / 10x JSON needs ~190 tokens → room to 300.
const int kDetectGateMaxTokens = 300;

/// 5x gate (first look): object in the centre box + what else is in frame.
const String kGateDetect5Prompt =
    'Look at this photo. What is the object in the centre box (red outline), and what else is in the frame? '
    'Describe what is visible: colours, texture, shapes, patterns, raised or sunken areas, marks, text or symbols if any. '
    'Only what is really visible; do not guess. Keep visible under 40 words. '
    'Reply only as JSON {"object": "<object name>", "context": "<what else is in the frame>", "visible": "<what is visible>"}.';

/// 10x gate: the 5x answer is included ({earlier}).
const String kGateDetect10Prompt =
    'Earlier (5x) this was seen: {earlier}. Now zoomed in: which part of that object is in the centre box (red outline), '
    'and what is visible on that part (colours, texture, shapes, raised/sunken areas, marks, text/symbols)? '
    'If it is a different object now, say so. Keep visible under 40 words. '
    'Reply only as JSON {"object": "<object name>", "part": "<part of the object>", "visible": "<what is visible>", "same_object": true}.';

/// Longest kept "visible" / "context" text.
const int kGateVisibleMaxWords = 45;

/// One gate's detection result.
class GateDetect {
  const GateDetect({
    this.object = '',
    this.context = '',
    this.part = '',
    this.visible = '',
    this.sameObject,
    this.newSubject = false,
  });

  /// Object name ('' = vague / unknown).
  final String object;

  /// 5x: what else is in the frame.
  final String context;

  /// 10x: the part of the object in the centre box.
  final String part;

  /// What is visible (colours, texture, marks …), ≤ ~40 words.
  final String visible;

  /// 10x: the model's same_object answer (null = not asked / unknown).
  final bool? sameObject;

  /// 10x: the lock moved to a new object.
  final bool newSubject;

  bool get isEmpty => object.isEmpty && part.isEmpty && visible.isEmpty;

  /// The 5x answer as JSON for the 10x prompt.
  String toEarlierJson() => jsonEncode({
    'object': object,
    if (context.isNotEmpty) 'context': context,
    if (part.isNotEmpty) 'part': part,
    'visible': visible,
  });

  Map<String, Object?> toJson() => {
    'object': object,
    'context': context,
    'part': part,
    'visible': visible,
    'same_object': sameObject,
  };

  static GateDetect fromJson(Map<dynamic, dynamic> j) {
    String s(Object? v) => v is String ? v : '';
    final so = j['same_object'];
    return GateDetect(
      object: gateObjectName(s(j['object'])),
      context: sanitizeVisible(s(j['context'])),
      part: sanitizeDetected(s(j['part'])),
      visible: sanitizeVisible(s(j['visible'])),
      sameObject: so is bool ? so : null,
    );
  }
}

/// Free text from the model (visible / context): plain words + simple
/// punctuation, ≤ [kGateVisibleMaxWords] words, ≤ 320 chars.
String sanitizeVisible(String? raw) {
  var s = (raw ?? '').replaceAll(RegExp(r"[^A-Za-z0-9 ,.;:&'()/%+-]+"), ' ');
  final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  s = words.take(kGateVisibleMaxWords).join(' ');
  if (s.length > 320) s = s.substring(0, 320);
  return s.trim().replaceAll(RegExp(r'[,;:]+$'), '').trim();
}

/// Object name: ≤8 plain words; '' when vague (only look / colour words).
String gateObjectName(String? raw) {
  final n = sanitizeDetected(raw);
  return isUsableLock(n) ? n : '';
}

/// The 5x / 10x prompt. 10x without a usable 5x answer → the 5x prompt
/// (first look).
String gateDetectPrompt(GateDetect? earlier) => earlier == null || earlier.isEmpty
    ? kGateDetect5Prompt
    : kGateDetect10Prompt.replaceAll('{earlier}', earlier.toEarlierJson());

/// Model reply → result; null when no JSON with anything usable.
GateDetect? parseGateReply(String? text) {
  final m = RegExp(r'\{.*\}', dotAll: true).firstMatch((text ?? '').trim());
  if (m == null) return null;
  try {
    final j = jsonDecode(m.group(0)!);
    if (j is! Map) return null;
    final r = GateDetect.fromJson(j);
    return r.isEmpty ? null : r;
  } catch (_) {
    return null;
  }
}

/// 10x result joined with the 5x one: same object → the 5x name is kept
/// (the 10x part / visible added); a different object (same_object false
/// with a name) → the lock follows the new object.
GateDetect mergeGate(GateDetect? earlier, GateDetect now) {
  if (earlier == null || earlier.isEmpty) return now;
  if (now.sameObject == false && now.object.isNotEmpty) {
    return GateDetect(
      object: now.object,
      part: now.part,
      visible: now.visible,
      sameObject: false,
      newSubject: true,
    );
  }
  return GateDetect(
    object: earlier.object.isNotEmpty ? earlier.object : now.object,
    context: earlier.context,
    part: now.part,
    visible: now.visible.isNotEmpty ? now.visible : earlier.visible,
    sameObject: now.sameObject,
  );
}

/// The lock at the shutter: the highest gate with a result (null = none).
GateDetect? gateLock(Map<double, GateDetect> info) {
  if (info.isEmpty) return null;
  return info[info.keys.reduce(math.max)];
}

/// Debug line for one gate, e.g. "5x: coin · visible: silver disc …" /
/// "10x: coin · part: rim · new object · visible: …".
String gateDebugLine(double gate, GateDetect? r, {int maxVisible = 140}) {
  final z = gate == gate.roundToDouble()
      ? gate.toStringAsFixed(0)
      : gate.toStringAsFixed(1);
  if (r == null) return '${z}x: detect failed';
  String cut(String s) =>
      s.length <= maxVisible ? s : '${s.substring(0, maxVisible)}…';
  return [
    '${z}x: ${r.object.isEmpty ? '(vague)' : r.object}',
    if (r.part.isNotEmpty) 'part: ${r.part}',
    if (r.newSubject) 'new object',
    if (r.context.isNotEmpty) 'around: ${cut(r.context)}',
    if (r.visible.isNotEmpty) 'visible: ${cut(r.visible)}',
  ].join(' · ');
}

/// All gates, lowest first, one line each (null result = failed).
String gateDebugText(List<double> gates, Map<double, GateDetect?> info) => [
  for (final g in gates)
    if (info.containsKey(g)) gateDebugLine(g, info[g]),
].join('\n');
