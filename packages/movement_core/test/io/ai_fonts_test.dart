import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('the prompt lists the fonts; a reply can set a text font', () {
    final p = buildAiPrompt('a title', fonts: {'roboto': 'Roboto', 'my_font': 'My Font'});
    expect(p, contains('`my_font`: My Font'));
    final r = expandMcj({
      'layers': [
        {'shape': 'text', 'text': {'text': 'Hi', 'font': 'my_font'}}
      ]
    });
    expect(r.project.layers.single.content.text!.fontId, 'my_font');
  });
}
