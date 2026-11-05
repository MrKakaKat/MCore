import 'dart:convert';
import 'dart:io';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double _minX(List<PathCmd> p) => p.expand((c) => [for (var i = 0; i < c.p.length; i += 2) c.p[i]]).reduce((a, b) => a < b ? a : b);
double _maxX(List<PathCmd> p) => p.expand((c) => [for (var i = 0; i < c.p.length; i += 2) c.p[i]]).reduce((a, b) => a > b ? a : b);

void main() {
  setUpAll(() {
    registerFont(defaultFontId, File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
    registerFont('cff', File('test/fixtures/test_cff.otf').readAsBytesSync());
  });

  test('one line fits; the box is centred on the offset', () {
    final spec = TextSpec(text: 'Hello', fontSize: 40);
    final l = layoutText(spec, [100, 50], [400, 100]);
    expect(l.lineCount, 1);
    expect(l.path, isNotEmpty);
    // centred: ink roughly symmetric around x = 100.
    expect((_minX(l.path) + _maxX(l.path)) / 2, closeTo(100, 4));
  });

  test('wraps at spaces, and a narrow box stacks letters vertically', () {
    final spec = TextSpec(text: 'ab cd', fontSize: 40);
    expect(layoutText(spec, [0, 0], [1000, 100]).lineCount, 1);
    final twoWords = layoutText(spec, [0, 0], [60, 100]);
    expect(twoWords.lineCount, 2);
    final column = layoutText(spec, [0, 0], [5, 100]);
    expect(column.lineCount, 4, reason: 'every letter on its own line');
    expect(layoutText(TextSpec(text: 'a\nb'), [0, 0], [1000, 100]).lineCount, 2);
  });

  test('letter spacing widens the line; left/right alignment follow the box edges', () {
    final plain = layoutText(TextSpec(text: 'AAAA', fontSize: 40), [0, 0], [1000, 100]);
    final spaced = layoutText(TextSpec(text: 'AAAA', fontSize: 40, letterSpacing: 10), [0, 0], [1000, 100]);
    expect(spaced.width, closeTo(plain.width + 30, 0.01));
    final left = layoutText(TextSpec(text: 'A', fontSize: 40, align: 'left'), [0, 0], [300, 100]);
    expect(_minX(left.path), closeTo(-150, 2));
    final right = layoutText(TextSpec(text: 'A', fontSize: 40, align: 'right'), [0, 0], [300, 100]);
    expect(_maxX(right.path), closeTo(150, 2));
  });

  test('kerning tightens AV', () {
    final av = layoutText(TextSpec(text: 'AV', fontSize: 2048), [0, 0], [1e6, 1e4]);
    // A (1336) + V (1304) - 87 kern, at 1 unit per px.
    expect(av.width, closeTo(1336 + 1304 - 87, 0.01));
  });

  test('a character the font lacks falls back to the default font', () {
    final withCyrillic = layoutText(TextSpec(text: 'AЖ', fontId: 'cff', fontSize: 100), [0, 0], [1e6, 1e4]);
    final onlyA = layoutText(TextSpec(text: 'A', fontId: 'cff', fontSize: 100), [0, 0], [1e6, 1e4]);
    expect(withCyrillic.width, greaterThan(onlyA.width + 50));
  });

  test('new text layers fit their text; conversion keeps the box and the colour', () {
    final layer = createTextLayer(text: 'Hi', fontSize: 40);
    expect(layer.content.shape, 'text');
    expect(layer.content.size[0], greaterThan(40));
    layer.content.text!.color = '#ff0000';
    final box = [...layer.content.size];
    convertTextToShape(layer);
    expect(layer.content.shape, 'compound');
    expect(layer.content.size, box);
    expect(layer.color, '#ff0000');
    expect(layer.content.contours!.length, greaterThanOrEqualTo(2));
    final b = contoursBounds(layer.content.contours!);
    expect(b.maxX - b.minX, lessThanOrEqualTo(box[0]));
  });

  test('text and compound content survive JSON and cloning', () {
    final layer = createTextLayer(text: 'Round\ntrip');
    layer.content.text!
      ..shadow.enabled = true
      ..shadow.dx = 7
      ..background.enabled = true
      ..background.padding = 3
      ..strokeWidth = 2;
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(layer))) as Map<String, dynamic>);
    expect(back.content.text!.text, 'Round\ntrip');
    expect(back.content.text!.shadow.dx, 7);
    expect(back.content.text!.background.padding, 3);
    expect(back.content.text!.strokeWidth, 2);
    final clone = cloneLayer(layer);
    clone.content.text!.text = 'changed';
    expect(layer.content.text!.text, 'Round\ntrip');

    convertTextToShape(layer);
    final c2 = layerFromJson(jsonDecode(jsonEncode(layerToJson(layer))) as Map<String, dynamic>);
    expect(c2.content.contours!.length, layer.content.contours!.length);
  });

  test('resolution rescale scales the text with the frame', () {
    final layer = createTextLayer(fontSize: 40);
    final p = Project(layers: [layer]);
    rescaleProjectContent(p, 2, 2);
    expect(layer.content.text!.fontSize, 80);
  });

  test('side handles resize the text box symmetrically (both sides the same)', () {
    setStageSize(400, 400);
    final layer = createTextLayer(text: 'ab cd', fontSize: 40);
    layer.content.size = [300, 60];
    final p = Project(layers: [layer]);
    clearStateCaches();
    // the layer sits at the frame centre (200, 200), unscaled.
    TextBoxDragOp(layer: layer, handle: 'right').apply(p, 0, [230, 200]);
    expect(layer.content.size, [60, 60]);
    TextBoxDragOp(layer: layer, handle: 'left').apply(p, 0, [230, 200]);
    expect(layer.content.size, [60, 60], reason: 'the left handle does the same');
    expect(layoutText(layer.content.text!, layer.content.offset, layer.content.size).lineCount, 2);
    TextBoxDragOp(layer: layer, handle: 'top').apply(p, 0, [200, 150]);
    expect(layer.content.size, [60, 100]);
  });

  test('SVG export writes the letters as paths', () {
    setStageSize(400, 400);
    final layer = createTextLayer(text: 'A');
    layer.content.text!.shadow.enabled = true;
    final svg = exportProjectToSvg(Project(layers: [layer]), 0, 400, 400);
    expect(RegExp('<path d="M').allMatches(svg).length, 2, reason: 'shadow + text');
    convertTextToShape(layer);
    final svg2 = exportProjectToSvg(Project(layers: [layer]), 0, 400, 400);
    expect(svg2, contains('<path d="M'));
    expect(svg2, contains('fill="#ffffff"'));
  });
}
