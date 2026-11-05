import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    snapEnabled = true;
    snapEqualSizeEnabled = true;
    clearStateCaches();
  });
  tearDown(() {
    snapEnabled = false;
    snapEqualSizeEnabled = false;
  });

  Layer square(String id, double side) => createLayer('rect')
    ..id = id
    ..content.size = [side, side]
    ..transform.anchor.defaultValue = [0.5, 0.5];

  test('a third square in the same centre snaps to the same step (100, 140 -> 180)', () {
    final a = square('a', 100), b = square('b', 140), c = square('c', 100);
    final p = Project(layers: [a, b, c]);
    final r = computeScaleSnap(
        project: p,
        layer: c,
        globalFrame: 0,
        handle: 'scaleCorner',
        newScale: [1.77, 1.77],
        localBbox: shapeBoundingBox(c.content));
    expect(r.newScale[0] * 100, closeTo(180, 1e-6));
    expect(r.guide, isNotNull);
  });

  test('far from the next step: no nested snap', () {
    final a = square('a', 100), b = square('b', 140), c = square('c', 100);
    final p = Project(layers: [a, b, c]);
    final r = computeScaleSnap(
        project: p, layer: c, globalFrame: 0, handle: 'right', newScale: [2.4, 1], localBbox: shapeBoundingBox(c.content));
    expect(r.newScale[0] * 100, isNot(closeTo(180, 1)));
  });

  test('a shape inside another keeps its own size: equal size only snaps when already close', () {
    final big = square('big', 300), c = square('c', 100);
    final p = Project(layers: [big, c]);
    for (final k in [1.2, 1.5, 2.0, 2.5]) {
      final r = computeScaleSnap(
          project: p, layer: c, globalFrame: 0, handle: 'scaleCorner', newScale: [k, k], localBbox: shapeBoundingBox(c.content));
      expect(r.newScale[0], closeTo(k, 1e-9), reason: 'at $k nothing is near 300 px');
    }
    final near = computeScaleSnap(
        project: p, layer: c, globalFrame: 0, handle: 'scaleCorner', newScale: [2.95, 2.95], localBbox: shapeBoundingBox(c.content));
    expect(near.newScale[0], closeTo(3, 1e-9));
  });
}
