import '../models/pose_photo.dart';
import '../models/shoot_mode.dart';

/// A label from on-device image labeling (ML Kit base model).
class SceneLabel {
  const SceneLabel(this.text, this.confidence);
  final String text;
  final double confidence;
}

/// A subtle tip chip ("Food? Try Portrait").
class SceneSuggestion {
  const SceneSuggestion({
    required this.id,
    required this.text,
    required this.mode,
  });
  final String id;
  final String text;

  /// Tapping the chip switches to this mode.
  final ShootMode mode;
}

const _food = {
  'food',
  'dish',
  'cuisine',
  'cake',
  'dessert',
  'fruit',
  'bread',
  'pizza',
  'vegetable',
  'meal',
  'lunch',
  'breakfast',
  'dinner',
  'baked goods',
  'cookie',
  'sushi',
  'pasta',
  'sandwich',
  'coffee',
  'tea',
  'drink',
  'cup',
  'juice',
};
const _people = {
  'person',
  'selfie',
  'smile',
  'face',
  'hair',
  'beard',
  'eyelash',
  'skin',
  'lipstick',
  'muscle',
  'child',
  'baby',
  'bride',
  'groom',
};
const _pets = {'dog', 'cat', 'pet', 'bird', 'puppy', 'kitten'};
const _flowers = {'flower', 'plant', 'petal', 'rose', 'leaf'};
const _docs = {
  'paper',
  'receipt',
  'document',
  'menu',
  'newspaper',
  'poster',
  'book',
  'handwriting',
  'text',
  'letter',
  'notebook',
  'page',
  'whiteboard',
};
const _night = {'night', 'darkness', 'fireworks', 'moon', 'concert'};

bool _hit(Set<String> words, SceneLabel l) =>
    words.contains(l.text.toLowerCase().trim());

/// Pure rule: best suggestion for the labels in the current [mode], or null.
SceneSuggestion? suggestFor(
  List<SceneLabel> labels, {
  required ShootMode mode,
  int faces = 0,
  double minConfidence = 0.7,
}) {
  final strong = labels.where((l) => l.confidence >= minConfidence).toList();
  bool any(Set<String> s) => strong.any((l) => _hit(s, l));
  if (any(_docs) && mode != ShootMode.document) {
    return const SceneSuggestion(
      id: 'doc',
      text: 'Document? Try Document scan',
      mode: ShootMode.document,
    );
  }
  if (any(_food) && mode != ShootMode.portrait) {
    return const SceneSuggestion(
      id: 'food',
      text: 'Food? Try Portrait for a soft background',
      mode: ShootMode.portrait,
    );
  }
  if (any(_pets) && mode != ShootMode.portrait) {
    return const SceneSuggestion(
      id: 'pet',
      text: 'Pet? Try Portrait',
      mode: ShootMode.portrait,
    );
  }
  if ((faces >= 1 || any(_people)) && mode == ShootMode.photo && faces <= 2) {
    return const SceneSuggestion(
      id: 'people',
      text: 'People? Try Portrait',
      mode: ShootMode.portrait,
    );
  }
  if (any(_flowers) && mode != ShootMode.portrait) {
    return const SceneSuggestion(
      id: 'flower',
      text: 'Close-up? Try Portrait',
      mode: ShootMode.portrait,
    );
  }
  if (any(_night) && mode != ShootMode.night) {
    return const SceneSuggestion(
      id: 'night',
      text: 'Low light? Try Night',
      mode: ShootMode.night,
    );
  }
  // v11.49: no HDR tip (HDR removed).
  return null;
}

/// Rate limiting so tips stay subtle: a tip must be seen twice in a row,
/// then at most one tip per [gap], the same tip at most once per [repeat],
/// and a dismissed tip never returns this session.
class SuggestionGate {
  SuggestionGate({
    this.gap = const Duration(seconds: 20),
    this.repeat = const Duration(minutes: 2),
  });

  final Duration gap;
  final Duration repeat;
  String? _candidate;
  DateTime? _lastShown;
  final Map<String, DateTime> _shownAt = {};
  final Set<String> _dismissed = {};

  SceneSuggestion? offer(SceneSuggestion? s, DateTime now) {
    if (s == null) {
      _candidate = null;
      return null;
    }
    if (_dismissed.contains(s.id)) return null;
    if (_candidate != s.id) {
      _candidate = s.id;
      return null; // needs a second consistent sighting
    }
    if (_lastShown != null && now.difference(_lastShown!) < gap) return null;
    final prev = _shownAt[s.id];
    if (prev != null && now.difference(prev) < repeat) return null;
    _lastShown = now;
    _shownAt[s.id] = now;
    return s;
  }

  void dismiss(String id) => _dismissed.add(id);
}

const _couple = {'wedding', 'bride', 'groom', 'veil', 'gown', 'ceremony'};
const _seat = {'chair', 'couch', 'bench', 'sofa', 'sitting', 'stool'};
const _travel = {
  'mountain',
  'beach',
  'monument',
  'temple',
  'tower',
  'lake',
  'river',
  'sky',
  'sea',
  'desert',
  'waterfall',
  'bridge',
  'castle',
  'skyscraper',
};

/// Scene-based pose category order: what the camera sees comes first.
List<String> orderPoseCategories(
  List<SceneLabel> labels, {
  int faces = 0,
  bool front = false,
}) {
  final strong = labels.where((l) => l.confidence >= 0.6).toList();
  bool any(Set<String> s) => strong.any((l) => _hit(s, l));
  final first = <String>[
    if (front) 'Selfie',
    if (faces >= 3) 'Group',
    if (faces == 2 || any(_couple)) 'Couple',
    if (any(_seat)) 'Sitting',
    if (any(_travel)) 'Travel',
  ];
  return [
    ...first,
    for (final c in kPoseCategories)
      if (!first.contains(c)) c,
  ];
}
