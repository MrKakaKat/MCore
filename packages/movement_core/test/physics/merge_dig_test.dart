import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// The screenshot's case: a rect with a hole-digging rect merged into an
/// arch; a square in the arch grows; the arch grows to hold it.
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
    registerBuiltinEffects();
  });

  Layer rect(String id, double x, double y, double w, double h) => createLayer('rect')
    ..id = id
    ..startFrame = 0
    ..durationFrames = 100
    ..content.offset = [0, 0]
    ..content.size = [w, h]
    ..transform.anchor.defaultValue = [x / 1000, y / 1000];

  Layer arch(Project p) {
    // pink 300 x 300 at (500, 500); the dig 200 x 300 lower, past its bottom.
    final pink = rect('pink', 500, 500, 300, 300);
    final dig = rect('dig', 500, 600, 200, 300)..dig = true;
    p.layers.addAll([pink, dig]);
    return mergeLayers(p, [pink, dig], 'U', 0)!;
  }

  test('merging a hole-digging layer keeps its hole; its own outline is gone', () {
    final p = Project(layers: []);
    final u = arch(p);
    expect(p.layers, [u]);
    final rings = u.content.contours!;
    // one shape: the arch (8 corners), nothing below the pink's bottom.
    expect(rings, hasLength(1));
    final m = toFrameMatrix(getLayerStateAt(p, 'U', 0).matrix);
    final pts = [for (final q in rings.single) applyAffine(m, q)];
    expect(pts.map((q) => q[1]).reduce(math.max), closeTo(650, 1e-6), reason: "the dig's part below is not a shape");
    expect(pts, hasLength(8));
    // the hole is open: its middle is not inside.
    bool inside(List<double> q) {
      var c = false;
      for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
        final a = pts[i], b = pts[j];
        if ((a[1] > q[1]) != (b[1] > q[1]) && q[0] < (b[0] - a[0]) * (q[1] - a[1]) / (b[1] - a[1]) + a[0]) c = !c;
      }
      return c;
    }

    expect(inside([500, 550]), isFalse);
    expect(inside([370, 550]), isTrue, reason: 'the left leg');
    // the collision contour is the arch.
    final vr = layerVectorRings(p, u, 0)!;
    expect(vr, hasLength(1));
  });

  test('a square inside the arch grows: the arch grows to hold it', () {
    final p = Project(layers: []);
    arch(p)
      ..physics.collide = true
      ..physics.grows = true;
    final sq = rect('sq', 500, 500, 100, 100)
      ..physics.collide = true
      ..physics.role = 'immovable';
    sq.transform.scale.keyframes = [
      Keyframe(frame: 0, value: <double>[1.0, 1.0], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 60, value: <double>[2.6, 2.6], temporal: const Easing(0, 0, 1, 1)), // 260 > the 200 gap
    ];
    p.layers.add(sq);
    clearStateCaches();
    physicsWorldOf(p).bakeTo(70);
    clearStateCaches();
    final m = toFrameMatrix(getLayerStateAt(p, 'U', 70).matrix);
    final k = math.sqrt(m[0] * m[0] + m[1] * m[1]);
    expect(k, greaterThan(1.25), reason: 'the 200 px gap made room for 260');
  });
}
