import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double _area(List<List<double>> r) {
  var a = 0.0;
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a / 2;
}

void main() {
  test('a rounded corner curves between its two neighbours, sharp ones stay', () {
    final nodes = [LineNode(0, 0), LineNode(100, 0)..round = 20, LineNode(100, 100)];
    final pts = sampleLine(nodes);
    expect(pts.any((p) => p[0] == 100 && p[1] == 0), isFalse, reason: 'the corner is cut off');
    expect(pts.any((p) => (p[0] - 80).abs() < 1e-9 && p[1].abs() < 1e-9), isTrue);
    expect(pts.any((p) => (p[0] - 100).abs() < 1e-9 && (p[1] - 20).abs() < 1e-9), isTrue);
    // a circle's middle: about 20 * (1 - 1/sqrt2) in from the corner.
    final mid = pts[pts.length ~/ 2];
    final dCorner = math.sqrt(math.pow(mid[0] - 100, 2) + math.pow(mid[1], 2));
    expect(dCorner, closeTo(20 * (math.sqrt2 - 1), 0.5));
    // shape 1: as sharp as before.
    nodes[1].roundK = 1;
    final sharp = sampleLine(nodes);
    final mid2 = sharp[sharp.length ~/ 2];
    expect(math.sqrt(math.pow(mid2[0] - 100, 2) + math.pow(mid2[1], 2)), lessThan(dCorner));
  });

  test('a rounded first point of a loop closes onto its own curve', () {
    final nodes = [LineNode(0, 0)..round = 10, LineNode(100, 0), LineNode(100, 100), LineNode(0, 100)];
    final pts = sampleLine(nodes, closed: true);
    expect(pts.first, pts.last);
    expect(pts.any((p) => p[0] == 0 && p[1] == 0), isFalse);
  });

  test('stroke pieces: a band per stretch, joins, ends - all wound the same way', () {
    final c = createLayer('line').content
      ..lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(100, 100)]
      ..lineWidth = 10;
    expect(lineNeedsShapedStroke(c), isFalse);
    c.lineCap = 'square';
    expect(lineNeedsShapedStroke(c), isTrue);
    var rings = lineStrokeRings(c);
    expect(rings.every((r) => _area(r) > 0), isTrue);
    // 2 bands + 1 round join + 2 square ends.
    expect(rings, hasLength(5));
    // the square end reaches half the width past the first point.
    final minX = rings.expand((r) => r).map((p) => p[0]).reduce(math.min);
    expect(minX, closeTo(-5, 1e-9));
    c
      ..lineCap = 'triangle'
      ..lineCapLength = 3
      ..lineJoin = 'miter';
    rings = lineStrokeRings(c);
    final minX2 = rings.expand((r) => r).map((p) => p[0]).reduce(math.min);
    expect(minX2, closeTo(-15, 1e-9), reason: 'the tip 3 half widths out');
    // the miter's tip at the outer corner (105, -5).
    expect(rings.expand((r) => r).any((p) => (p[0] - 105).abs() < 1e-6 && (p[1] + 5).abs() < 1e-6), isTrue);
  });

  test('a width per point narrows the band toward the thin end', () {
    final c = createLayer('line').content
      ..lineNodes = [LineNode(0, 0)..w = 20, LineNode(100, 0)..w = 2]
      ..lineWidth = 10;
    expect(lineNeedsShapedStroke(c), isTrue);
    final band = lineStrokeRings(c).first;
    final ys = band.map((p) => p[1].abs()).toList()..sort();
    expect(ys.first, closeTo(1, 1e-9));
    expect(ys.last, closeTo(10, 1e-9));
  });

  test('a point snaps along a diagonal from its neighbour, and to another stretch\'s length', () {
    final project = Project(fps: 30);
    stageSize.width = 480;
    stageSize.height = 480;
    final l = createLayer('line');
    l.content.lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(150, 3)];
    syncLineBox(l.content);
    project.layers.add(l);
    snapEnabled = true;
    snapLinePointsEnabled = false;
    snapFrameBoundaryEnabled = false;
    final m = getTransformBoxHandles(project, l, 0).mCanvas;
    final p1 = applyAffine(m, [100, 0]);
    // dragging point 2 near the horizontal from point 1: it lies flat.
    final r = snapLineHandle(project, l, 'n2', [p1[0] + 70, p1[1] + 2], 0);
    expect(r.point[1], closeTo(p1[1], 1e-9));
    // ... and its length snaps to the first stretch's 100.
    snapEqualSizeFrameRadius = 40;
    final r2 = snapLineHandle(project, l, 'n2', [p1[0] + 80, p1[1] + 1], 0);
    expect(r2.point[0] - p1[0], closeTo(100, 1e-6));
    snapEnabled = false;
  });

  test('the pivot moves to the middle of the points without moving the line', () {
    final project = Project(fps: 30);
    stageSize.width = 480;
    stageSize.height = 480;
    final l = createLayer('line');
    l.content.lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(100, 60)];
    project.layers.add(l);
    l.transform.rotation.defaultValue = 30.0;
    final before = lineFramePoints(project, l, 0);
    clearStateCaches();
    centerLinePivot(project, l, 0);
    clearStateCaches();
    final after = lineFramePoints(project, l, 0);
    for (var i = 0; i < before.length; i++) {
      expect(after[i][0], closeTo(before[i][0], 1e-6));
      expect(after[i][1], closeTo(before[i][1], 1e-6));
    }
    final xs = l.content.lineNodes!.map((p) => p.x), ys = l.content.lineNodes!.map((p) => p.y);
    expect(xs.reduce((a, b) => a + b), closeTo(0, 1e-9));
    expect(ys.reduce((a, b) => a + b), closeTo(0, 1e-9));
  });

  test('two lines join at their nearest ends into one', () {
    final project = Project(fps: 30);
    stageSize.width = 480;
    stageSize.height = 480;
    final a = createLayer('line'), b = createLayer('line');
    a.content.lineNodes = [LineNode(0, 0), LineNode(100, 0)];
    b.content.lineNodes = [LineNode(100, 50), LineNode(100, 0)];
    project.layers.addAll([a, b]);
    expect(joinLines(project, a, b, 0), isTrue);
    expect(project.layers, [a]);
    final pts = [for (final p in a.content.lineNodes!) [p.x.roundToDouble(), p.y.roundToDouble()]];
    expect(pts, [
      [0.0, 0.0],
      [100.0, 0.0],
      [100.0, 50.0]
    ]);
  });

  test('tap-add: past the last point or before the first; not from the middle', () {
    final c = createLayer('line').content..lineNodes = [LineNode(0, 0), LineNode(10, 0), LineNode(20, 0)];
    expect(addLinePointAt(c, 2, [30, 0]), 3);
    expect(addLinePointAt(c, 0, [-10, 0]), 0);
    expect(c.lineNodes!.first.x, -10);
    expect(addLinePointAt(c, 2, [5, 5]), isNull);
  });

  test('the new line settings survive a save', () {
    final l = createLayer('line');
    l.content
      ..lineCap = 'square'
      ..lineCapRound = 0.5
      ..lineJoin = 'miter'
      ..lineNodes![0].w = 7
      ..lineNodes![1].round = 3;
    final back = layerFromJson(layerToJson(l));
    expect(back.content.lineCap, 'square');
    expect(back.content.lineCapRound, 0.5);
    expect(back.content.lineJoin, 'miter');
    expect(back.content.lineNodes![0].w, 7);
    expect(back.content.lineNodes![1].round, 3);
  });

  test('a keyed point moves over time; the line samples it at each frame', () {
    final l = createLayer('line');
    final c = l.content..lineNodes = [LineNode(0, 0), LineNode(100, 0)];
    toggleLinePointKey(c, 1, 0);
    c.lineNodes![1]
      ..x = 100
      ..y = 100;
    toggleLinePointKey(c, 1, 10);
    expect(c.lineNodes![1].posT!.keyframes, hasLength(2));
    final mid = sampleLine(c.lineNodes!, frame: 5);
    expect(mid.last[1], greaterThan(10));
    expect(mid.last[1], lessThan(90));
    expect(sampleLine(c.lineNodes!, frame: 0).last, [100.0, 0.0]);
    syncLineToFrame(l, l.startFrame + 10);
    expect(c.lineNodes![1].y, closeTo(100, 1e-9));
    // saved and loaded with its keys.
    final back = layerFromJson(layerToJson(l));
    expect(back.content.lineNodes![1].posT!.keyframes, hasLength(2));
  });

  test('sharpest reach: a right-angle turn reaches 1.41 half widths - kept at 4, cut at 1.2', () {
    final c = createLayer('line').content
      ..lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(100, 100)]
      ..lineWidth = 10
      ..lineJoin = 'miter';
    bool tip() => lineStrokeRings(c).expand((r) => r).any((p) => (p[0] - 105).abs() < 1e-6 && (p[1] + 5).abs() < 1e-6);
    c.lineMiterLimit = 4;
    expect(tip(), isTrue);
    c.lineMiterLimit = 1.2;
    expect(tip(), isFalse, reason: 'past the limit: cut straight');
  });

  test('fill kinds: outer keeps the width around the points, inner takes it out', () {
    double area(List<List<List<double>>> rings) {
      var t = 0.0;
      for (final r in rings) {
        var a = 0.0;
        for (var i = 0; i < r.length; i++) {
          a += r[i][0] * r[(i + 1) % r.length][1] - r[(i + 1) % r.length][0] * r[i][1];
        }
        t += a.abs() / 2;
      }
      return t;
    }

    final c = createLayer('line').content
      ..lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(100, 100), LineNode(0, 100)]
      ..lineWidth = 10;
    closeLine(c);
    c.lineFillMode = 'points';
    expect(area(filledLineRings(c)), closeTo(10000, 1));
    c.lineFillMode = 'outer';
    expect(area(filledLineRings(c)), greaterThan(10900));
    c.lineFillMode = 'inner';
    expect(area(filledLineRings(c)), closeTo(8100, 30));
  });

  test("a point's width and rounding take keys", () {
    final l = createLayer('line');
    final c = l.content..lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(100, 100)];
    toggleLinePointValueKey(c, 1, 'round', 0);
    setLinePointValue(c, 1, 'round', 0, 0);
    toggleLinePointValueKey(c, 1, 'round', 10);
    setLinePointValue(c, 1, 'round', 40, 10);
    expect(c.lineNodes![1].valueAt('round', 5)!, closeTo(20, 1e-6));
    syncLineToFrame(l, l.startFrame + 10);
    expect(c.lineNodes![1].round, closeTo(40, 1e-6));
    final back = layerFromJson(layerToJson(l));
    expect(back.content.lineNodes![1].keys['round']!.keyframes, hasLength(2));
  });
}
