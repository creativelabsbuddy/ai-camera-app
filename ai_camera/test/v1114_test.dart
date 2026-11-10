import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parent locked at 1x; zoomed labeler output never replaces it', () {
    final l = SubjectLock();
    expect(
      l.lockParent(cameraZoom: 1, face: false, sceneLabel: 'mobile phone'),
      isTrue,
    );
    expect(l.display(1), 'Mobile phone');
    // The video: Moon / Space / Jeans / Asphalt while zooming → ignored.
    for (final (z, t) in [(2.0, 'moon'), (4.0, 'space'), (8.0, 'jeans')]) {
      expect(l.lockParent(cameraZoom: z, face: false, sceneLabel: t), isFalse);
    }
    expect(
      l.lockParent(cameraZoom: 1, face: false, sceneLabel: 'asphalt'),
      isFalse,
    );
    expect(l.hint, 'Mobile phone');
    expect(l.setFacePart('Eye'), isFalse); // not a face parent
  });

  test('re-check / re-entering Macro re-locks', () {
    final l = SubjectLock()
      ..lockParent(cameraZoom: 1, face: false, sceneLabel: 'mobile phone');
    l.clearParent();
    l.lockParent(cameraZoom: 1, face: false, sceneLabel: 'flower');
    expect(l.hint, 'Flower');
    l.reset();
    expect(l.hint, isNull);
  });

  test('no confident 1x label → "Subject", no hint; not locked past 1x', () {
    final l = SubjectLock();
    expect(l.lockParent(cameraZoom: 1, face: false), isFalse);
    expect(
      l.lockParent(cameraZoom: 3, face: false, sceneLabel: 'moon'),
      isFalse,
    );
    expect(l.display(3), isNull);
    expect(l.hint, isNull);
    expect(
      macroPrompt(l.hint, level: 'macro', zoom: 5),
      kMacroPrompt.replaceAll('{subject}', fallbackDescription(null)),
    ); // v11.33
  });
}
