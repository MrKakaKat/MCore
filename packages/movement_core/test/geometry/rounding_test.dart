import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double _area(List<List<double>> r) {
  var a = 0.0;
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return (a / 2).abs();
}

void main() {
  setUpAll(registerBuiltinEffects);

  // an L: one inward corner at (50, 50).
  final l = [
    [0.0, 0.0], [100.0, 0.0], [100.0, 50.0], [50.0, 50.0], [50.0, 100.0], [0.0, 100.0]
  ];

  test('rounding cuts the outward corners and fills the inward one', () {
    final a0 = _area(l);
    expect(_area(roundRingCorners(l, 10, 0)), lessThan(a0));
    expect(_area(roundRingCorners(l, 0, 10)), greaterThan(a0));
    // the same the other way round (wound the other way).
    final rev = l.reversed.toList();
    expect(_area(roundRingCorners(rev, 0, 10)), greaterThan(a0));
  });

  test('the shape factor: 0 cuts straight, 1 keeps the corner', () {
    final cut = roundedRectRing(0, 0, 100, 100, 20, 20, k: 0);
    final sharp = roundedRectRing(0, 0, 100, 100, 20, 20, k: 1);
    final circle = roundedRectRing(0, 0, 100, 100, 20, 20);
    expect(_area(cut), lessThan(_area(circle)));
    expect(_area(sharp), greaterThan(_area(circle)));
    expect(_area(cut), closeTo(10000 - 4 * 200, 1));
  });

  test('a triangle gets rounded corners from the Fill tab', () {
    final t = createLayer('triangle');
    final plain = getContentOutline(t.content, t, 0);
    t.fill.cornerRadius = 8;
    final round = getContentOutline(t.content, t, 0);
    expect(round.length, greaterThan(plain.length));
    expect(_area(round), lessThan(_area(plain)));
  });

  test('the radius handle sets the rect\'s rounding; the shape handle its shape', () {
    final project = Project(fps: 30);
    stageSize.width = 480;
    stageSize.height = 480;
    final r = createLayer('rect', size: 100);
    project.layers.add(r);
    final m = getTransformBoxHandles(project, r, 0).mCanvas;
    final x0 = r.content.offset[0] - r.content.size[0] / 2, y0 = r.content.offset[1] - r.content.size[1] / 2;
    RoundDragOp(r, 'rr').apply(project, 0, applyAffine(m, [x0 + 15, y0]));
    expect(r.fill.cornerRadius, closeTo(15, 1e-6));
    clearStateCaches();
    final h = roundHandlesFrame(project, r, 0);
    expect(h.containsKey('rk'), isTrue);
    // dragging the shape handle onto the chord's middle: a straight cut.
    RoundDragOp(r, 'rk').apply(project, 0, applyAffine(m, [x0 + 7.5, y0 + 7.5]));
    expect(r.fill.cornerShape, closeTo(0, 1e-6));
    expect(roundRegionsFrame(project, r, 0), hasLength(4));
  });

  test("a line corner's radius handle rounds it", () {
    final c = createLayer('line').content..lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(100, 100)];
    expect(lineHandleKeys(c, editing: true, selected: 1), contains('r1'));
    moveLineHandle(c, 'r1', [100, 30]);
    expect(c.lineNodes![1].round, closeTo(30, 1e-9));
    expect(lineHandleKeys(c, editing: true, selected: 1), contains('k1'));
    expect(math.max(1, 0), 1);
  });
}
