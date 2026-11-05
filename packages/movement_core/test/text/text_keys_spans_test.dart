import 'dart:convert';
import 'dart:io';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    registerFont(defaultFontId, File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });

  test('text keys: each key\'s text from its frame on; typing edits the one in effect', () {
    final t = TextSpec(text: 'Hello');
    t.addKey(10);
    t.setTextAt(12, 'World');
    t.addKey(30);
    t.setTextAt(30, 'Bye');
    expect([t.textAt(0), t.textAt(9), t.textAt(10), t.textAt(29), t.textAt(30), t.textAt(99)],
        ['Hello', 'Hello', 'World', 'World', 'Bye', 'Bye']);
    t.setTextAt(5, 'Hi');
    expect(t.textAt(0), 'Hi');
    expect(t.atFrame(20).text, 'World');
    final back = textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(t))) as Map<String, dynamic>);
    expect([back.textAt(0), back.textAt(15), back.textAt(40)], ['Hi', 'World', 'Bye']);
  });

  test('letter styles: bigger letters widen the line, coloured ones come apart', () {
    final plain = TextSpec(text: 'abcd');
    final styled = TextSpec(text: 'abcd', spans: [TextStyleSpan(1, 3, size: 2, color: '#ff0000', rise: -5)]);
    final a = layoutText(plain, const [0, 0], const [1e6, 1e6]);
    final b = layoutText(styled, const [0, 0], const [1e6, 1e6]);
    expect(b.width, greaterThan(a.width * 1.3));
    expect(b.height, greaterThan(a.height * 1.5), reason: 'the line is as tall as its largest letter');
    expect(b.colored.keys, ['#ff0000']);
    expect(b.plain.length + b.colored['#ff0000']!.length, b.path.length);
    expect(identical(a.plain, a.path), isTrue);
    final back = textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(styled))) as Map<String, dynamic>);
    expect([back.spans.single.start, back.spans.single.end, back.spans.single.size, back.spans.single.color, back.spans.single.rise],
        [1, 3, 2.0, '#ff0000', -5.0]);
  });

  test('long shadow round-trips', () {
    final t = TextSpec(shadow: TextShadowSpec(enabled: true, long: true));
    expect(textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(t))) as Map<String, dynamic>).shadow.long, isTrue);
  });

  test('text keys are a track like any other: on the timeline, held, moved and deleted as keys', () {
    final l = createTextLayer(text: 'A');
    final t = l.content.text!;
    t.addKey(10);
    t.setTextAt(10, 'B');
    final tracks = <String, Track>{};
    visitLayerTracksNamed(l, (n, trk) => tracks[n] = trk);
    expect(identical(tracks['text'], t.textKeys), isTrue);
    expect(keyDetailTabOf('text'), 'Text');
    expect(collectVisibleLayerKeyframeFrames(l), contains(10));
    expect(evaluateTrack(null, t.textKeys, 15), 'B');
    // moved like a key on the timeline.
    t.keys.single.frame = 20;
    expect(t.textAt(15), 'A');
    expect(t.textAt(20), 'B');
    final back = textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(t))) as Map<String, dynamic>);
    expect(back.textAt(25), 'B');
  });
}
