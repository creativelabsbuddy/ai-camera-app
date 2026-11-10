import 'package:ai_camera/services/mode_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('other levels unchanged (prefix + hint)', () {
    expect(
      macroPrompt(
        'skin',
        level: 'microscope',
        zoom: 15,
        part: null,
      ), // v11.47: a spot → text prompt
      kMacroMicroscopePhotoPrompt.replaceAll('{subject}', 'skin'), // v11.33
    );
  });
}
