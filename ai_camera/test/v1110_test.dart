import 'dart:ui';

import 'package:ai_camera/models/shoot_mode.dart';
import 'package:ai_camera/services/live_policies.dart';
import 'package:ai_camera/services/macro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Face filling the middle of the frame.
  const face = LiveFace(box: Rect.fromLTWH(0.3, 0.25, 0.4, 0.5));

  test('low zoom with a face in frame → Face (not Hair)', () {
    expect(
      zoomAwareLabel(faces: [face], regionScale: 1, sceneLabel: 'hair'),
      'Face',
    );
  });

  test('zooming in re-identifies the centre part', () {
    // Centre (0.5,0.5) is at u=0.5, v=0.5 of the face → nose/cheek area.
    expect(zoomAwareLabel(faces: [face], regionScale: 0.1), 'Skin');
    // Shift the face so the centre lands on the left eye / mouth / above.
    const eyeFace = LiveFace(box: Rect.fromLTWH(0.372, 0.3, 0.4, 0.5));
    expect(zoomAwareLabel(faces: [eyeFace], regionScale: 0.1), 'Eye');
    const mouthFace = LiveFace(box: Rect.fromLTWH(0.3, 0.12, 0.4, 0.5));
    expect(zoomAwareLabel(faces: [mouthFace], regionScale: 0.1), 'Lips');
    const browFace = LiveFace(box: Rect.fromLTWH(0.372, 0.36, 0.4, 0.5));
    expect(zoomAwareLabel(faces: [browFace], regionScale: 0.1), 'Eyebrow');
    const hairFace = LiveFace(box: Rect.fromLTWH(0.3, 0.6, 0.4, 0.5));
    expect(zoomAwareLabel(faces: [hairFace], regionScale: 0.1), 'Hair');
  });

  test('landmarks win over default proportions', () {
    const f = LiveFace(
      box: Rect.fromLTWH(0.3, 0.25, 0.4, 0.5),
      parts: {'leftEye': Offset(0.5, 0.5)},
    );
    expect(zoomAwareLabel(faces: [f], regionScale: 0.05), 'Eye');
  });

  test('no face → scene label; region scale maps memory frame', () {
    expect(
      zoomAwareLabel(faces: [], regionScale: 0.2, sceneLabel: 'coin'),
      'coin',
    );
    expect(regionScaleIn(1.0, 25), closeTo(0.04, 1e-9));
    expect(regionScaleIn(2.0, 1.0), 1.0);
  });

  test('live label keeps updating; manual pick wins', () {
    final l = SubjectLock();
    expect(l.setLive('Face'), isTrue);
    expect(l.subject, 'Face');
    expect(l.setLive('skin'), isTrue);
    expect(l.subject, 'Skin');
    expect(l.setLive(null), isFalse);
    expect(l.subject, 'Skin');
    l.setManual('Coin');
    expect(l.setLive('Hair'), isFalse);
    expect(l.subject, 'Coin');
  });

  test('Macro runs face detection', () {
    final r = routeFor(ShootMode.macro, aiMode: true);
    expect(r.analyzers, contains(LiveAnalyzer.faces));
  });
}
