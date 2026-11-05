import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('sharp outline: a square grows with pointed corners, either winding', () {
    for (final sq in [
      [
        [0.0, 0.0],
        [10.0, 0.0],
        [10.0, 10.0],
        [0.0, 10.0]
      ],
      [
        [0.0, 0.0],
        [0.0, 10.0],
        [10.0, 10.0],
        [10.0, 0.0]
      ],
    ]) {
      final c = contourOfVectorRings([sq], const ContourParams(offset: 2, sharp: true));
      final pts = c.rings.single.points;
      expect(pts, hasLength(4), reason: 'four sharp corners, no rounding');
      final xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
      expect(xs.reduce((a, b) => a < b ? a : b), closeTo(-2, 1e-9));
      expect(xs.reduce((a, b) => a > b ? a : b), closeTo(12, 1e-9));
      expect(ys.reduce((a, b) => a < b ? a : b), closeTo(-2, 1e-9));
    }
    final shrunk = contourOfVectorRings([
      [
        [0.0, 0.0],
        [10.0, 0.0],
        [10.0, 10.0],
        [0.0, 10.0]
      ]
    ], const ContourParams(offset: -2, sharp: true));
    expect(shrunk.rings.single.points.map((p) => p[0]).reduce((a, b) => a < b ? a : b), closeTo(2, 1e-9));
  });
}
