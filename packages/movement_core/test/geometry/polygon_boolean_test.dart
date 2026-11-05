import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

PolyRing diamond(double cx, double cy, double r) => [
      [cx, cy - r],
      [cx + r, cy],
      [cx, cy + r],
      [cx - r, cy],
    ];

PolyRing square(double x0, double y0, double s) => [
      [x0, y0],
      [x0 + s, y0],
      [x0 + s, y0 + s],
      [x0, y0 + s],
    ];

double distToRing(List<double> p, PolyRing r) {
  var best = double.infinity;
  for (var i = 0; i < r.length; i++) {
    final a = r[i], b = r[(i + 1) % r.length];
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final t = (((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
    final x = a[0] + dx * t - p[0], y = a[1] + dy * t - p[1];
    best = math.min(best, math.sqrt(x * x + y * y));
  }
  return best;
}

double totalArea(List<PolyRing> rings) => rings.fold(0.0, (s, r) => s + ringArea(r));

void main() {
  final big = diamond(0, 0, 200);
  List<PolyRing> notched(double sx, double sy, {double gap = 20, OffsetJoin join = OffsetJoin.miter}) =>
      polygonBoolean([big], offsetRings([diamond(sx, sy, 70)], gap, join: join), BoolOp.subtract);

  /// Every result edge not on the big diamond's own outline (the notch)
  /// keeps exactly `gap` from the small diamond, all along it.
  void expectGap(List<PolyRing> rings, PolyRing small, double gap) {
    var notchEdges = 0;
    for (final r in rings) {
      for (var i = 0; i < r.length; i++) {
        final a = r[i], b = r[(i + 1) % r.length];
        final onBig = distToRing(a, big) < 1e-6 && distToRing(b, big) < 1e-6 &&
            distToRing([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], big) < 1e-6;
        if (onBig) continue;
        notchEdges++;
        // the small diamond's edge it faces: the parallel one nearest.
        final ex = b[0] - a[0], ey = b[1] - a[1];
        final el = math.sqrt(ex * ex + ey * ey);
        double? facing;
        for (var j = 0; j < small.length; j++) {
          final s0 = small[j], s1 = small[(j + 1) % small.length];
          final sx = s1[0] - s0[0], sy = s1[1] - s0[1];
          final sl = math.sqrt(sx * sx + sy * sy);
          if ((ex * sy - ey * sx).abs() / (el * sl) > 1e-6) continue;
          // distance of the notch edge's points to that edge's line.
          double dist(List<double> p) => ((p[0] - s0[0]) * sy - (p[1] - s0[1]) * sx).abs() / sl;
          final d = dist(a);
          if (facing == null || d < facing) facing = d;
          if (d == facing) {
            expect(dist(b), closeTo(d, 1e-9), reason: 'parallel');
          }
        }
        expect(facing, isNotNull, reason: 'notch edge $a-$b faces an edge');
        expect(facing!, closeTo(gap, 0.01), reason: 'notch edge $a-$b');
      }
    }
    expect(notchEdges, greaterThan(0));
  }

  test('position 1 (0,200): one ring, a symmetric V-notch, apex on the axis, the gap all along', () {
    final r = notched(0, 200);
    expect(r, hasLength(1));
    const apexY = 200 - (70 + 20 * math.sqrt2);
    final apex = r.single.where((p) => p[0].abs() < 0.01).toList();
    expect(apex.any((p) => (p[1] - apexY).abs() < 0.01), isTrue, reason: 'apex at (0, $apexY)');
    // symmetric: each point mirrored is a point too.
    for (final p in r.single) {
      expect(r.single.any((q) => (q[0] + p[0]).abs() < 0.01 && (q[1] - p[1]).abs() < 0.01), isTrue);
    }
    expectGap(r, diamond(0, 200, 70), 20);
  });

  for (final (name, x, y) in [('2 (-60,190)', -60.0, 190.0), ('3 (0,140)', 0.0, 140.0), ('5 (150,50)', 150.0, 50.0)]) {
    test('position $name: one ring, notched, the gap all along', () {
      final r = notched(x, y);
      expect(r, hasLength(1));
      expect(totalArea(r), lessThan(ringArea(big) - 1));
      expectGap(r, diamond(x, y, 70), 20);
    });
  }

  test('position 4 (0,320): no overlap, the big diamond as it was', () {
    final r = notched(0, 320);
    expect(r, hasLength(1));
    expect(totalArea(r), closeTo(ringArea(big), 1e-6));
    for (final p in big) {
      expect(r.single.any((q) => (q[0] - p[0]).abs() < 0.01 && (q[1] - p[1]).abs() < 0.01), isTrue);
    }
  });

  test('position 6 (0,0): inside - an outer ring plus one hole', () {
    final r = notched(0, 0);
    expect(r, hasLength(2));
    expect(r.where((q) => ringArea(q) < 0), hasLength(1), reason: 'one hole');
    const hole = (70 + 20 * math.sqrt2) * (70 + 20 * math.sqrt2) * 2;
    expect(totalArea(r), closeTo(ringArea(big) - hole, 0.01));
  });

  test('position 7: moving 1 -> 5 over 60 frames, the notch moves smoothly (no jumps)', () {
    double? last;
    for (var f = 0; f <= 60; f++) {
      final k = f / 60;
      final a = totalArea(notched(150 * k, 200 - 150 * k));
      if (last != null) expect((a - last).abs(), lessThan(ringArea(big) * 0.05), reason: 'frame $f');
      last = a;
    }
  });

  test('gap 0 touches; a negative gap overlaps by as much', () {
    final small = diamond(0, 200, 70);
    expectGap(notched(0, 200, gap: 0), small, 0);
    final r = notched(0, 200, gap: -10);
    // the notch apex sits 10 inside the small diamond's top vertex.
    expect(r.single.any((p) => p[0].abs() < 0.01 && (p[1] - (130 + 10 * math.sqrt2)).abs() < 0.01), isTrue);
  });

  test('miter keeps the notch corners sharp; round makes arcs', () {
    final miter = notched(150, 50), round = notched(150, 50, join: OffsetJoin.round);
    expect(round.single.length, greaterThan(miter.single.length + 3));
    expect(miter.single.length, lessThan(12));
  });

  test('modes on two overlapping squares give the expected areas', () {
    final a = square(0, 0, 100), b = square(50, 50, 100);
    expect(totalArea(polygonBoolean([a], [b], BoolOp.union)), closeTo(17500, 1e-6));
    expect(totalArea(polygonBoolean([a], [b], BoolOp.intersect)), closeTo(2500, 1e-6));
    expect(totalArea(polygonBoolean([a], [b], BoolOp.subtract)), closeTo(7500, 1e-6));
    expect(totalArea(polygonBoolean([a], [b], BoolOp.exclude)), closeTo(15000, 1e-6));
  });

  test('degenerate: shared edge, shared vertex, collinear points, the cutter equal to the cut', () {
    final a = square(0, 0, 100);
    expect(totalArea(polygonBoolean([a], [square(100, 0, 100)], BoolOp.union)), closeTo(20000, 1e-6), reason: 'shared edge');
    expect(totalArea(polygonBoolean([a], [square(100, 100, 100)], BoolOp.union)), closeTo(20000, 1e-6), reason: 'shared vertex');
    final withCollinear = [[0.0, 0.0], [50.0, 0.0], [100.0, 0.0], [100.0, 100.0], [0.0, 100.0]];
    expect(totalArea(polygonBoolean([withCollinear], [square(50, 50, 100)], BoolOp.subtract)), closeTo(7500, 1e-6));
    expect(polygonBoolean([a], [a], BoolOp.subtract), isEmpty, reason: 'nothing left');
    expect(totalArea(polygonBoolean([a], [a], BoolOp.union)), closeTo(10000, 1e-6));
    expect(totalArea(polygonBoolean([a], [a], BoolOp.intersect)), closeTo(10000, 1e-6));
  });

  test('deterministic: two runs are bit-identical', () {
    expect(notched(-60, 190), notched(-60, 190));
  });
}
