import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

AlphaMask maskOf(int w, int h, bool Function(int x, int y) inside) {
  final m = AlphaMask(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (inside(x, y)) m.a[y * w + x] = 1;
    }
  }
  return m;
}

double totalArea(Contour c) => c.rings.fold(0.0, (s, r) => s + ringSignedArea(r.points));

bool selfIntersects(List<List<double>> r) {
  bool cross(List<double> a, List<double> b, List<double> c, List<double> d) {
    double o(List<double> p, List<double> q, List<double> s) => (q[0] - p[0]) * (s[1] - p[1]) - (q[1] - p[1]) * (s[0] - p[0]);
    return o(a, b, c) * o(a, b, d) < 0 && o(c, d, a) * o(c, d, b) < 0;
  }

  for (var i = 0; i < r.length; i++) {
    for (var j = i + 2; j < r.length; j++) {
      if (i == 0 && j == r.length - 1) continue;
      if (cross(r[i], r[(i + 1) % r.length], r[j], r[(j + 1) % r.length])) return true;
    }
  }
  return false;
}

void main() {
  test('a filled square: one outer ring, a few points, counter-clockwise (area > 0)', () {
    final c = extractContour(maskOf(40, 40, (x, y) => x >= 10 && x < 30 && y >= 10 && y < 30));
    expect(c.rings, hasLength(1));
    final r = c.rings.single;
    expect(r.isHole, isFalse);
    expect(r.parent, -1);
    expect(r.points.length, inInclusiveRange(4, 8));
    expect(ringSignedArea(r.points), greaterThan(0));
  });

  test('a donut: one outer and one clockwise hole with its parent', () {
    final c = extractContour(maskOf(60, 60, (x, y) {
      final d = math.sqrt(math.pow(x - 30, 2) + math.pow(y - 30, 2));
      return d < 25 && d > 12;
    }));
    expect(c.outerCount, 1);
    expect(c.holeCount, 1);
    final hole = c.rings.firstWhere((r) => r.isHole);
    expect(ringSignedArea(hole.points), lessThan(0));
    expect(c.rings[hole.parent].isHole, isFalse);
  });

  test('two separate blobs: two outers', () {
    final c = extractContour(maskOf(60, 30, (x, y) => y > 5 && y < 25 && ((x > 5 && x < 20) || (x > 35 && x < 55))));
    expect(c.outerCount, 2);
    expect(c.holeCount, 0);
  });

  test('a "B"-like mask: one outer and two holes', () {
    final c = extractContour(maskOf(40, 60, (x, y) {
      final inBody = x >= 5 && x < 35 && y >= 5 && y < 55;
      final hole1 = x >= 12 && x < 28 && y >= 12 && y < 26;
      final hole2 = x >= 12 && x < 28 && y >= 34 && y < 48;
      return inBody && !hole1 && !hole2;
    }));
    expect(c.outerCount, 1);
    expect(c.holeCount, 2);
    for (final h in c.rings.where((r) => r.isHole)) {
      expect(h.parent, isNot(-1));
    }
  });

  test('a saddle (two diagonal pixels) resolves the same way every time', () {
    final m = maskOf(4, 4, (x, y) => (x == 1 && y == 1) || (x == 2 && y == 2));
    final a = extractContour(m, const ContourParams(minAreaFraction: 0, simplify: 0));
    final b = extractContour(m, const ContourParams(minAreaFraction: 0, simplify: 0));
    expect(a.rings.length, b.rings.length);
    expect(a.outerCount, 1, reason: 'at 0.5 the saddle centre is inside: the diagonal pixels join');
  });

  test('specks below the minimum area are dropped, bigger ones kept', () {
    final m = maskOf(100, 100, (x, y) => (x == 5 && y == 5) || (x >= 40 && x < 60 && y >= 40 && y < 60));
    expect(extractContour(m, const ContourParams(minAreaFraction: 0.001)).rings, hasLength(1));
    expect(extractContour(m, const ContourParams(minAreaFraction: 0)).rings, hasLength(2));
  });

  test('offset: growing grows the area; a big shrink removes a ring', () {
    final m = maskOf(80, 80, (x, y) => x >= 30 && x < 50 && y >= 30 && y < 50);
    final a0 = totalArea(extractContour(m));
    final a1 = totalArea(extractContour(m, const ContourParams(offset: 3)));
    final a2 = totalArea(extractContour(m, const ContourParams(offset: 6)));
    expect(a1, greaterThan(a0));
    expect(a2, greaterThan(a1));
    expect(extractContour(m, const ContourParams(offset: -12)).rings, isEmpty);
  });

  test('simplify keeps at least 3 points and no self-crossings', () {
    final shapes = [
      maskOf(50, 50, (x, y) => math.sqrt(math.pow(x - 25, 2) + math.pow(y - 25, 2)) < 18),
      maskOf(50, 50, (x, y) => x + y < 50 && x > 5 && y > 5),
      maskOf(6, 6, (x, y) => x == 2 && y == 2),
    ];
    for (final m in shapes) {
      for (final tol in [0.5, 1.0, 5.0, 50.0]) {
        for (final r in extractContour(m, ContourParams(simplify: tol, minAreaFraction: 0)).rings) {
          expect(r.points.length, greaterThanOrEqualTo(3));
          expect(selfIntersects(r.points), isFalse);
        }
      }
    }
  });

  test('vector rings without offset keep their exact geometry', () {
    final square = [
      [0.0, 0.0],
      [10.0, 0.0],
      [10.0, 10.0],
      [0.0, 10.0],
    ];
    final c = contourOfVectorRings([square], const ContourParams());
    expect(c.rings.single.points, hasLength(4));
    expect(ringSignedArea(c.rings.single.points), closeTo(100, 1e-9));
    final grown = contourOfVectorRings([square], const ContourParams(offset: 2));
    expect(totalArea(grown), greaterThan(100));
  });

  test('smoothing rounds a square\'s corners a little - it doesn\'t cut them off', () {
    final m = maskOf(200, 200, (x, y) => x >= 20 && x < 180 && y >= 20 && y < 180);
    for (final smooth in [1, 2, 3]) {
      final r = extractContour(m, ContourParams(simplify: 2, smooth: smooth)).rings.single;
      final area = ringSignedArea(r.points);
      expect(area, greaterThan(160 * 160 * 0.99), reason: 'smooth $smooth: corners barely rounded');
      // a corner stays close to the square's corner.
      final nearest = r.points.map((q) => math.sqrt(math.pow(q[0] - 20, 2) + math.pow(q[1] - 20, 2))).reduce(math.min);
      expect(nearest, lessThan(4), reason: 'smooth $smooth');
    }
  });
}
