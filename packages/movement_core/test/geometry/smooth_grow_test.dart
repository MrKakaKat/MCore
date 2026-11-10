import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  final square = [
    [-50.0, -50.0], [50.0, -50.0], [50.0, 50.0], [-50.0, 50.0],
  ];

  test('smoothing eases the sharp corners; a gentle one is left', () {
    final s = smoothRing(square, 1, 30);
    expect(s.length, greaterThan(4));
    // no point is a corner any more.
    expect(s.any((p) => p[0].abs() == 50 && p[1].abs() == 50), isFalse);
    // turning 90 degrees is below a 120 degree sensitivity: unchanged.
    expect(smoothRing(square, 1, 120), square);
  });

  test('grow pushes the outline out by its amount, round at the corners', () {
    final g = growRing(square, 10);
    var maxX = -1e9;
    for (final p in g) {
      if (p[0] > maxX) maxX = p[0];
    }
    expect(maxX, closeTo(60, 1e-9));
    // the corner rounded: nothing reaches past 10 from the old corner.
    for (final p in g) {
      final dx = (p[0].abs() - 50).clamp(0.0, 1e9), dy = (p[1].abs() - 50).clamp(0.0, 1e9);
      expect(dx * dx + dy * dy, lessThanOrEqualTo(100 + 1e-6));
    }
  });

  test('a rect with grow / smoothing: its outline changes, saved and loaded', () {
    final l = createLayer('rect')
      ..content.offset = [0, 0]
      ..content.size = [100, 100];
    l.fill.grow = 5;
    l.fill.smooth = 0.5;
    final o = layerFlatOutline(l);
    expect(o.length, greaterThan(4));
    final back = layerFromJson(layerToJson(l));
    expect(back.fill.grow, 5);
    expect(back.fill.smooth, 0.5);
  });

  test('line: middle points have no shape of their own unless asked', () {
    final l = createLayer('line');
    final c = l.content;
    final nodes = c.lineNodes!;
    expect(nodes.length, greaterThanOrEqualTo(2));
    c.lineNodes = [
      LineNode(-50, 0),
      LineNode(0, 0),
      LineNode(50, 0),
    ];
    c.lineWidth = 10;
    c.lineCap = 'square';
    final plain = lineStrokeRings(c).length;
    c.lineStationShapes = true;
    expect(lineStrokeRings(c).length, plain + 1, reason: 'one shape at the middle point');
    expect(smoothLineCorners(c, 1, 30), 0, reason: 'a straight line has nothing to smooth');
    c.lineNodes![1].y = 40;
    expect(smoothLineCorners(c, 1, 30), 1);
    expect(c.lineNodes![1].kind, 'bezier');
  });
}
