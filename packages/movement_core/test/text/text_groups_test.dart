import 'dart:convert';
import 'dart:io';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    registerFont(defaultFontId, File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });

  test('markers: shown text and groups', () {
    final p = parseTextGroups('#T#ext', '#');
    expect(p.text, 'Text');
    expect(p.groups, [(0, 1)]);
    expect(parseTextGroups('a*bc*d*ef', '*').groups, [(1, 3), (4, 6)], reason: 'one left open runs to the end');
    expect(parseTextGroups('##x', '#').groups, isEmpty, reason: 'empty groups dropped');
    expect(parseTextGroups('plain', '#').text, 'plain');
  });

  test('a text with groups off shows its markers; on, it hides them', () {
    final t = TextSpec(text: '#T#ext');
    expect(t.atFrame(0).text, '#T#ext');
    t.groupsEnabled = true;
    expect(t.atFrame(0).text, 'Text');
  });

  test('group layers: one per group, parented, on the letters; the text leaves them out', () {
    setStageSize(1000, 1000);
    final text = createTextLayer(text: 'A#B#C', fontSize: 60)..id = 'T';
    text.content.text!.groupsEnabled = true;
    final p = Project(layers: [text]);
    final made = addTextGroupLayers(p, text);
    expect(made, hasLength(1));
    final g = made.single;
    expect(g.parentId, 'T');
    expect(g.content.shape, 'textGroup');
    expect(addTextGroupLayers(p, text), isEmpty, reason: 'not twice');
    expect(textGroupHidden(p, text, 0), {1});
    final spec = textGroupSpec(p, g, 0)!;
    expect(spec.hidden, {0, 2});
    final full = layoutText(text.content.text!.atFrame(0), text.content.offset, text.content.size);
    final only = layoutText(spec, text.content.offset, text.content.size);
    expect(only.glyphs.map((e) => e.x), full.glyphs.map((e) => e.x), reason: 'letters keep their places');
    expect(only.path.length, lessThan(full.path.length));
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(g))) as Map<String, dynamic>);
    expect(back.content.textGroup, 0);
    expect(back.content.textGroupPivot, g.content.textGroupPivot);
  });
}
