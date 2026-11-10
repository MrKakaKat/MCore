import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double area(List<List<List<double>>> rings) {
  var a = 0.0;
  for (final r in rings) {
    var s = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      s += p[0] * q[1] - q[0] * p[1];
    }
    a += s / 2;
  }
  return a.abs();
}

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    setStageSize(400, 200);
    clearStateCaches();
  });

  Layer sq(String id, double x, double y, double s) => createLayer('rect')
    ..id = id
    ..content.offset = [0, 0]
    ..content.size = [s, s]
    ..transform.anchor.defaultValue = [x / 400, y / 200];

  test('a tap on a square fills exactly the square', () {
    final p = Project(layers: [sq('a', 100, 100, 80)]);
    final r = fillRegionAt(p, 0, [100, 100]);
    expect(area(r), closeTo(6400, 1));
  });

  test('two overlapping squares: their overlap; ignoring one, the whole other', () {
    final p = Project(layers: [sq('a', 100, 100, 80), sq('b', 140, 100, 80)]);
    // a: 60..140, b: 100..180 -> overlap 100..140 (40 x 80).
    expect(area(fillRegionAt(p, 0, [120, 100])), closeTo(3200, 1));
    // only a counts: all of a.
    expect(area(fillRegionAt(p, 0, [120, 100], only: {'a'})), closeTo(6400, 1));
    // in a but not b: a less the overlap.
    expect(area(fillRegionAt(p, 0, [80, 100])), closeTo(3200, 1));
  });

  test('outside everything: the frame less the layers; a new Fill layer on top', () {
    final p = Project(layers: [sq('a', 100, 100, 80)]);
    expect(area(fillRegionAt(p, 0, [300, 20])), closeTo(400 * 200 - 6400, 2));
    final l = addFillShape(p, fillRegionAt(p, 0, [100, 100]), 'f', color: '#00ff00');
    expect(p.layers.last, same(l));
    expect(l.content.shape, 'compound');
    expect(l.color, '#00ff00');
  });

  test('a cropped square fills only what is left of it', () {
    final a = sq('a', 100, 100, 80)..crop = [0.5, 0, 0, 0]; // the left half cut away
    final p = Project(layers: [a]);
    expect(area(fillRegionAt(p, 0, [120, 100])), closeTo(3200, 1));
    // where the crop took it away: the frame less the half that shows.
    expect(area(fillRegionAt(p, 0, [80, 100])), closeTo(400 * 200 - 3200, 2));
  });

  test('a circle fills round, not as a polygon', () {
    final c = createLayer('circle')
      ..id = 'c'
      ..content.offset = [0, 0]
      ..content.size = [160, 160]
      ..transform.anchor.defaultValue = [200 / 400, 100 / 200];
    final r = fillRegionAt(Project(layers: [c]), 0, [200, 100]);
    expect(area(r), closeTo(3.141592653589793 * 80 * 80, 25));
  });

  test('only the selected: fills drawn before still bound it', () {
    final a = sq('a', 100, 100, 80);
    final p = Project(layers: [a]);
    final first = addFillShape(p, fillRegionAt(p, 0, [100, 100]), 'f1');
    expect(first.drawing, isTrue);
    // a second square, inside the first fill: chosen alone, the fill still counts.
    final b = sq('b', 300, 100, 60);
    p.layers.add(b);
    final r = fillRegionAt(p, 0, [100, 100], only: {'b'});
    expect(area(r), closeTo(6400, 1));
  });

  test('the point is always in the fill: a tap in a hole of the region fills nothing else', () {
    // a ring: a square with a square hole (a merged shape).
    final ring = createLayer('rect')
      ..id = 'r'
      ..content = Content(shape: 'compound', offset: [0, 0], size: [100, 100], contours: [
        [[-50, -50], [50, -50], [50, 50], [-50, 50]],
        [[-20, -20], [-20, 20], [20, 20], [20, -20]],
      ])
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final p = Project(layers: [ring]);
    // in the hole: just the hole.
    expect(area(fillRegionAt(p, 0, [200, 100])), closeTo(1600, 1));
    // on the ring: the ring.
    expect(area(fillRegionAt(p, 0, [160, 100])), closeTo(10000 - 1600, 1));
  });

  test('a see-through layer (opacity 0) bounds nothing', () {
    final a = sq('a', 100, 100, 80)..transform.opacity.defaultValue = 0.0;
    final p = Project(layers: [a]);
    expect(area(fillRegionAt(p, 0, [100, 100])), closeTo(400 * 200, 2));
  });

  test('a fill shape goes on top', () {
    final p = Project(layers: [sq('a', 100, 100, 80)]);
    final l = addFillShape(p, fillRegionAt(p, 0, [100, 100]), 'f');
    expect(p.layers.last, same(l));
    expect(l.drawing, isTrue);
  });

  Layer ringLine(String id, double cx, double cy, double r, double width) {
    final l = createLayer('line')..id = id;
    l.content.lineNodes = [
      for (var i = 0; i < 24; i++)
        LineNode(r * math.cos(i / 24 * 2 * math.pi), r * math.sin(i / 24 * 2 * math.pi))
    ];
    l.content
      ..lineClosed = true
      ..lineWidth = width;
    l.transform.anchor.defaultValue = [cx / 400, cy / 200];
    return l;
  }

  test('a closed line is a band: inside it fills the middle, outside the rest', () {
    final ring = ringLine('l', 200, 100, 60, 10);
    final p = Project(layers: [ring]);
    final inside = fillRegionAt(p, 0, [200, 100]);
    // the middle: a disc of about r 55 (polygon of 24 sides).
    expect(area(inside), inInclusiveRange(8000, 9600));
    final outside = fillRegionAt(p, 0, [20, 20]);
    expect(area(outside), greaterThan(400 * 200 - 13400));
    // never the middle when tapped outside.
    expect(windingNumber(outside, 200, 100), 0);
  });

  test('a circle with a wavy line beside it: outside stays outside', () {
    final c = createLayer('circle')
      ..id = 'c'
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final line = createLayer('line')..id = 'w';
    line.content.lineNodes = [for (var i = 0; i < 12; i++) LineNode(-120.0 + i * 20, (i.isEven ? -1 : 1) * 30.0)];
    line.content.lineWidth = 6;
    line.transform.anchor.defaultValue = [0.5, 0.5];
    final p = Project(layers: [c, line]);
    for (final tap in [
      [40.0, 20.0],
      [380.0, 180.0],
      [200.0, 170.0],
    ]) {
      final r = fillRegionAt(p, 0, tap);
      expect(windingNumber(r, tap[0], tap[1]), isNot(0), reason: 'the tap is in it');
      expect(windingNumber(r, 200, 100), 0, reason: 'the circle stays out ($tap)');
    }
    expect(windingNumber(fillRegionAt(p, 0, [200, 100]), 200, 100), isNot(0));
  });
}
