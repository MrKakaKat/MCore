import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    registerFont(defaultFontId, File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });

  test('graphemes: emoji, combining marks, Cyrillic stay whole', () {
    expect(graphemeRanges('a👍🏽b'), [(0, 1), (1, 3), (3, 4)]);
    expect(graphemeRanges('éx'), [(0, 2), (2, 3)]);
    expect(graphemeRanges('Привет').length, 6);
  });

  test('words and lines follow the wrapping', () {
    final spec = TextSpec(text: 'one two three four', fontSize: 40);
    final layout = layoutText(spec, const [0, 0], const [140, 400]);
    expect(layout.lineCount, greaterThan(1));
    expect(textUnits(spec.text, layout, 'word').length, 4);
    expect(textUnits(spec.text, layout, 'line').length, layout.lineCount);
    expect(textUnits(spec.text, layout, 'char').length, 15, reason: 'spaces left out');
    final wide = layoutText(spec, const [0, 0], const [2000, 400]);
    expect(textUnits(spec.text, wide, 'char', includeSpaces: true).length, 18, reason: 'with its 3 spaces');
  });

  test('selector shapes at the start, middle and end of the range', () {
    // a unit [40, 50] of a range 0..100.
    expect(rangeAmount(40, 50, 0, 100, 'square'), 1);
    expect(rangeAmount(40, 50, 45, 100, 'square'), 0.5, reason: 'half the unit inside');
    expect(rangeAmount(0, 0, 0, 100, 'rampUp'), 0);
    expect(rangeAmount(50, 50, 0, 100, 'rampUp'), 0.5);
    expect(rangeAmount(100, 100, 0, 100, 'rampUp'), 1);
    expect(rangeAmount(120, 120, 0, 100, 'rampUp'), 1, reason: 'past the end stays on');
    expect(rangeAmount(0, 0, 0, 100, 'rampDown'), 1);
    expect(rangeAmount(50, 50, 0, 100, 'triangle'), 1);
    expect(rangeAmount(25, 25, 0, 100, 'triangle'), 0.5);
    expect(rangeAmount(50, 50, 0, 100, 'round'), 1);
    expect(rangeAmount(50, 50, 0, 100, 'smooth'), closeTo(1, 1e-9));
    expect(rangeAmount(0, 0, 0, 100, 'smooth'), closeTo(0, 1e-9));
  });

  test('ease high / low and offset wrap', () {
    final r = TextRange(shape: 'rampUp');
    final plain = selectorAmounts(r, 10, 0);
    r.easeLow = 100;
    final low = selectorAmounts(r, 10, 0);
    expect(low[2], lessThan(plain[2]), reason: 'low eases near 0');
    r
      ..easeLow = 0
      ..easeHigh = 100;
    final high = selectorAmounts(r, 10, 0);
    expect(high[7], greaterThan(plain[7]), reason: 'high reaches 1 sooner');
    // offset 90 shifts a 0..20 range to 90..110: with wrap it also covers 0..10.
    final w = TextRange(end: Track(20.0, false), offset: Track(90.0, false), wrap: true);
    final a = selectorAmounts(w, 10, 0);
    expect(a[0], 1);
    expect(a[9], 1);
    expect(a[5], 0);
    w.wrap = false;
    expect(selectorAmounts(w, 10, 0)[0], 0);
  });

  test('order: reverse, from centre, from edges, random (the same every time)', () {
    expect(unitOrder(5, 'reverse', 1), [4, 3, 2, 1, 0]);
    expect(unitOrder(5, 'fromCenter', 1), [3, 1, 0, 2, 4]);
    expect(unitOrder(5, 'fromEdges', 1)[0], 0);
    expect(unitOrder(5, 'fromEdges', 1)[2], 4);
    expect(unitOrder(8, 'random', 7), unitOrder(8, 'random', 7));
    expect(unitOrder(8, 'random', 7).toSet(), {0, 1, 2, 3, 4, 5, 6, 7});
  });

  test('two animators add up; at amount 0 the letters sit exactly as plain text', () {
    final spec = TextSpec(text: 'AV', fontSize: 40);
    final plain = layoutText(spec, const [0, 0], const [400, 100]);
    spec.animators.add(TextAnimator(range: TextRange(end: Track(0.0, false)), props: {'position': Track([0.0, 10.0], false)}));
    final still = animatedTextUnits(spec, const [0, 0], const [400, 100], 0)!;
    expect([for (final u in still) ...u.cmds].map((c) => c.p).toList(), plain.path.map((c) => c.p).toList(),
        reason: 'kerning kept, nothing moved');
    spec.animators
      ..clear()
      ..add(TextAnimator(props: {'position': Track([0.0, 10.0], false)}))
      ..add(TextAnimator(props: {'position': Track([0.0, 5.0], false)}));
    final moved = animatedTextUnits(spec, const [0, 0], const [400, 100], 0)!;
    expect(moved.first.cmds.first.p[1] - plain.path.first.p[1], closeTo(15, 1e-9));
  });

  test('presets: first and last frames', () {
    final spec = TextSpec(text: 'Hello', fontSize: 40)..animators.add(textAnimatorPreset('Typewriter', frames: 50));
    final first = animatedTextUnits(spec, const [0, 0], const [400, 100], 0)!;
    expect(first.every((u) => u.opacity == 0), isTrue, reason: 'nothing typed yet');
    final half = animatedTextUnits(spec, const [0, 0], const [400, 100], 25)!;
    expect(half.where((u) => u.opacity > 0.99).length, inInclusiveRange(2, 3));
    final last = animatedTextUnits(spec, const [0, 0], const [400, 100], 50)!;
    expect(last.every((u) => u.opacity == 1), isTrue);
    for (final p in textAnimatorPresets) {
      final s = TextSpec(text: 'one two', fontSize: 40)..animators.add(textAnimatorPreset(p, frames: 40));
      final end = animatedTextUnits(s, const [0, 0], const [400, 100], 40)!;
      if (p != 'Wave') {
        expect(end.every((u) => u.opacity > 0.99), isTrue, reason: '$p ends with the text shown');
      }
    }
  });

  test('scramble is the same at the same frame', () {
    final spec = TextSpec(text: 'Hello', fontSize: 40)..animators.add(textAnimatorPreset('Scramble', frames: 50));
    List<List<double>> at(int f) => [for (final u in animatedTextUnits(spec, const [0, 0], const [400, 100], f)!) ...u.cmds.map((c) => c.p)];
    expect(at(10), at(10));
    expect(at(10), isNot(at(50)), reason: 'all revealed by the end');
  });

  test('json round trip; old texts without animators load', () {
    final spec = TextSpec(text: 'x')..animators.add(textAnimatorPreset('Wave'));
    spec.animators.first.fillColor = '#ff0000';
    final back = textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(spec))) as Map<String, dynamic>);
    expect(jsonEncode(back.animators.first.toJson()), jsonEncode(spec.animators.first.toJson()));
    expect(textSpecFromJson({'text': 'old'}).animators, isEmpty);
  });

  test('whole letters: a letter is either in or out (no fading in)', () {
    final r = TextRange(start: Track(0.0, false), end: Track(45.0, false), whole: true);
    expect(selectorAmounts(r, 4, 0), [1, 1, 0, 0]);
    r.whole = false;
    expect(selectorAmounts(r, 4, 0)[1], closeTo(0.8, 1e-9));
  });

  test('scramble keeps the case of each letter', () {
    final spec = TextSpec(text: 'aB', fontSize: 40)..animators.add(TextAnimator(scramble: true, scrambleChars: 'xY'));
    final plain = layoutText(spec, const [0, 0], const [400, 100]);
    final units = animatedTextUnits(spec, const [0, 0], const [400, 100], 3)!;
    final font = plain.glyphs.first.font;
    final s = plain.glyphs.first.fontSize / font.unitsPerEm;
    final smallX = [for (final c in font.glyphPath(font.glyphIndex('x'.runes.first))) c.transformed(s, 0, 0, -s, plain.glyphs[0].x, plain.glyphs[0].baseline).p];
    final bigX = [for (final c in font.glyphPath(font.glyphIndex('X'.runes.first))) c.transformed(s, 0, 0, -s, plain.glyphs[0].x, plain.glyphs[0].baseline).p];
    final first = units.first.cmds.map((c) => c.p).toList();
    expect(first.length == smallX.length || first.length == font.glyphPath(font.glyphIndex('y'.runes.first)).length, isTrue);
    expect(first, isNot(bigX));
  });

  test('breathe and jitter: living, the same at the same frame, breathe only ever wider', () {
    final spec = TextSpec(text: 'Hello', fontSize: 40)..animators.add(textAnimatorPreset('Breathe'));
    final plain = layoutText(spec, const [0, 0], const [400, 100]);
    double width(List<UnitState> us, int i) {
      final xs = us[i].cmds.expand((c) => [for (var k = 0; k < c.p.length; k += 2) c.p[k]]);
      return xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b);
    }

    final plainW = () {
      final g = plain.glyphs.first;
      final xs = plain.path.sublist(g.cmdStart, g.cmdEnd).expand((c) => [for (var k = 0; k < c.p.length; k += 2) c.p[k]]);
      return xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b);
    }();
    for (final f in [0, 7, 19, 40]) {
      final us = animatedTextUnits(spec, const [0, 0], const [400, 100], f)!;
      expect(width(us, 0), greaterThanOrEqualTo(plainW - 1e-6), reason: 'never narrower');
    }
    expect(width(animatedTextUnits(spec, const [0, 0], const [400, 100], 7)!, 0),
        width(animatedTextUnits(spec, const [0, 0], const [400, 100], 7)!, 0));
    final j = TextSpec(text: 'Hi', fontSize: 40)..animators.add(textAnimatorPreset('Jitter'));
    final a = animatedTextUnits(j, const [0, 0], const [400, 100], 5)!.first.cmds.first.p;
    final b = animatedTextUnits(j, const [0, 0], const [400, 100], 5)!.first.cmds.first.p;
    final c = animatedTextUnits(j, const [0, 0], const [400, 100], 9)!.first.cmds.first.p;
    expect(a, b);
    expect(a, isNot(c), reason: 'it shakes over time');
  });

  test('text parts: their own move and opacity, only in their time window; saved', () {
    final spec = TextSpec(text: 'Lol', fontSize: 40);
    final plain = layoutText(spec, const [0, 0], const [400, 100]);
    spec.spans.add(TextStyleSpan(1, 2, name: 'o', move: Track([0.0, 10.0], false), opacity: Track(0.5, false), from: 40, to: 60));
    expect(animatedTextUnits(spec, const [0, 0], const [400, 100], 10), isNull, reason: 'outside its time: plain text');
    final at = animatedTextUnits(spec, const [0, 0], const [400, 100], 50)!;
    // the "o" moved 10 down, half see-through; "L" stays.
    // parts draw last: find each letter by its box.
    UnitState unitAt(int g) => at.firstWhere((u) => (u.box[0][0] - plain.glyphs[g].x).abs() < 1e-6);
    final o = unitAt(1), l = unitAt(0);
    expect(o.opacity, closeTo(0.5, 1e-9));
    expect(l.opacity, 1);
    final gO = plain.glyphs[1];
    final ys = [for (final c in o.cmds) if (c.p.length >= 2) c.p[1]];
    final plainYs = [for (final c in plain.path.sublist(gO.cmdStart, gO.cmdEnd)) if (c.p.length >= 2) c.p[1]];
    expect(ys.first - plainYs.first, closeTo(10, 1e-6));
    final back = textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(spec))) as Map<String, dynamic>);
    expect(back.spans.single.to, 60);
    expect(back.spans.single.move, isNotNull);
  });

  test('text parts: a later part draws over an earlier one; one part as its own outline', () {
    final spec = TextSpec(text: 'Lol', fontSize: 40);
    spec.spans
      ..add(TextStyleSpan(2, 3, name: 'l', move: Track([-20.0, 0.0], false)))
      ..add(TextStyleSpan(0, 1, name: 'L', move: Track([0.0, 0.0], false)));
    final units = animatedTextUnits(spec, const [0, 0], const [400, 100], 0)!;
    // "o" (no part) first, then part 1 ("l"), then part 2 ("L") on top.
    final layout = layoutText(spec, const [0, 0], const [400, 100]);
    final lastBox = units.last.box[0][0];
    expect(lastBox, closeTo(layout.glyphs[0].x, 1e-6), reason: 'the L (the later part) drawn last');
    final only = textPartCmds(spec, const [0, 0], const [400, 100], 0, 0);
    final xs = [for (final c in only) if (c.p.length >= 2) c.p[0]];
    // the "l", moved 20 px left of where it was.
    expect(xs.reduce(math.max), lessThan(layout.glyphs[2].x + layout.glyphs[2].advance - 15));
  });

  test('text parts: their own blur, tint, spacing and shake; only in the part; saved', () {
    final spec = TextSpec(text: 'Lol', fontSize: 40);
    final plain = layoutText(spec, const [0, 0], const [400, 100]);
    spec.spans.add(TextStyleSpan(0, 1,
        name: 'L',
        blur: Track(4.0, false),
        tint: Track(0.5, false),
        tintColor: '#ff0000',
        spacing: Track(10.0, false),
        shake: Track(6.0, false),
        wobble: Track(10.0, false)));
    final at = animatedTextUnits(spec, const [0, 0], const [400, 100], 12)!;
    UnitState unitAt(int g, double shift) => at.firstWhere((u) => (u.box[0][0] - plain.glyphs[g].x - shift).abs() < 1e-6);
    final l = unitAt(0, 0), o = unitAt(1, 10);
    expect(l.blur, closeTo(4, 1e-9));
    expect(l.tint, '#ff0000');
    expect(l.tintAmount, closeTo(0.5, 1e-9));
    expect(o.blur, 0, reason: 'outside the part: untouched');
    expect(o.tint, isNull);
    // the "L" shakes: its outline differs between frames.
    final a = animatedTextUnits(spec, const [0, 0], const [400, 100], 3)!.firstWhere((u) => u.blur > 0).cmds.first.p;
    final b = animatedTextUnits(spec, const [0, 0], const [400, 100], 20)!.firstWhere((u) => u.blur > 0).cmds.first.p;
    expect(a, isNot(b));
    final back = textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(spec))) as Map<String, dynamic>);
    final s = back.spans.single;
    expect([s.blur, s.tint, s.spacing, s.shake, s.wobble].every((t) => t != null), isTrue);
    expect(s.tintColor, '#ff0000');
    expect(s.copy().tintColor, '#ff0000');
  });
}
