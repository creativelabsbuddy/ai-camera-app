import 'mode_prompts.dart' show isVagueDetect, microSpotText, sanitizeDetected;
import 'zoom_assist.dart' show isSameSubject;

/// v11.58 Microscope / Extreme / Ultra coordinated detection:
///  1. a 1.5x photo is taken at the shutter and the OBJECT in it is named
///     and LOCKED (e.g. "red aluminium soda can");
///  2. at the high zoom only the PART of that locked object is detected
///     (the locked name is never replaced);
///  v11.64: the name step sends the 1.5x photo + the zoomed final photo
///  (flash-lite, `<colour> <name>, <part>`, once per shot); the part step
///  (flash-lite) gives only the part / side; spot = part of the name.
///  3. if the high-zoom frame does not match the 1.5x frame → "Hold steady"
///     and the shot is retaken (up to [kMicroRetakes] times). Still no
///     match → the photo flow without a lock (nothing invented from a
///     wrong name).
class MicroLock {
  const MicroLock({
    required this.name,
    required this.path,
    required this.cameraZoom,
    required this.at,
    this.others = const [],
  });

  /// Locked object name (colour + object + material, ≤8 words).
  final String name;

  /// Private copy of the 1.5x photo the name came from.
  final String path;
  final double cameraZoom;
  final DateTime at;
  final List<String> others;
}

/// Retakes after a mismatch (so at most 1 + 2 shots).
const int kMicroRetakes = 2;

/// A lock is reused (no new detection call) while the next 1.5x photo
/// still shows the same thing and it is younger than this.
const Duration kMicroLockReuse = Duration(minutes: 3);

const String kMicroHoldSteady = 'Hold steady';

/// Mismatch between the 1.5x photo and the high-zoom frame: the vision
/// model says it is another place, or the pixels do not match and the
/// model did not confirm it.
bool microFrameMismatch({required double pixelScore, bool? inScene}) =>
    inScene == false || (!isSameSubject(pixelScore) && inScene != true);

/// v11.64: the spot = locked NAME + detected part / side (e.g. "surface of
/// a white paper napkin"). Look words are stripped; the part never
/// replaces the name (empty part → the name alone).
String microPartText(String? part, String lock) => microSpotText(lock, part);

/// A usable lock name (clear, not only look / colour words).
bool isUsableLock(String? name) {
  final n = sanitizeDetected(name);
  return n.isNotEmpty && !isVagueDetect(n);
}

/// v11.59 F6 fail-closed messages (no AI call, nothing charged).
const String kMicroNoLock =
    "Couldn't recognise the object at 1.5x. Point at it, hold steady and "
    'try again. No credits used.';
const String kMicroNoMatch =
    'Hold steady: the zoomed photo did not match the object. Try again. '
    'No credits used.';
