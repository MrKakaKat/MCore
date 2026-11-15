import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Grows to hold (something pressing from inside / in its notch makes it
/// grow) and Turns when hit.
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });

  Layer box(String id, double x, double y, {double w = 100, double h = 100}) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = 100
      ..content.offset = [0, 0]
      ..content.size = [w, h]
      ..transform.anchor.defaultValue = [x / 1000, y / 1000];
    l.physics.collide = true;
    return l;
  }

  const lin = Easing(0, 0, 1, 1);
  void growFrom(Layer l, double a, double b, int frames) => l.transform.scale.keyframes = [
        Keyframe(frame: 0, value: <double>[a, a], temporal: lin),
        Keyframe(frame: frames, value: <double>[b, b], temporal: lin),
      ];

  void bake(Project p, int to) {
    clearStateCaches();
    physicsWorldOf(p).reset();
    physicsWorldOf(p).bakeTo(to);
    clearStateCaches();
  }

  List<List<double>> corners(Project p, Layer l, int f) {
    final m = toFrameMatrix(getLayerStateAt(p, l.id, f).matrix);
    final w = l.content.size[0] / 2, h = l.content.size[1] / 2;
    return [for (final c in [[-w, -h], [w, -h], [w, h], [-w, h]]) applyAffine(m, c)];
  }

  test('a fixed square turned 45 degrees grows inside a hollow one: its corners push the walls, the cage grows', () {
    final cage = box('C', 500, 500, w: 200, h: 200)
      ..physics.hollow = true
      ..physics.grows = true;
    final sq = box('S', 500, 500, w: 60, h: 60)
      ..physics.role = 'immovable'
      ..transform.rotation.defaultValue = 45.0;
    growFrom(sq, 1, 3, 60); // its diagonal: 85 -> 255 px, past the 200 px cage
    final p = Project(layers: [cage, sq]);
    bake(p, 70);
    final cs = corners(p, cage, 70);
    final w = cs[1][0] - cs[0][0];
    expect(w, greaterThan(250), reason: 'the cage grew to hold it');
    expect((cs[0][0] + cs[1][0]) / 2, closeTo(500, 1.5), reason: 'about its own middle, not pushed away');
    for (final c in corners(p, sq, 70)) {
      expect(c[0], inInclusiveRange(cs[0][0] - 1.5, cs[1][0] + 1.5), reason: 'still inside');
    }
    // without it, it would have been pushed (no growth).
    cage.physics.grows = false;
    bake(p, 70);
    final w2 = corners(p, cage, 70)[1][0] - corners(p, cage, 70)[0][0];
    expect(w2, closeTo(200, 1e-6));
  });

  test('even an Immovable cage grows to hold', () {
    final cage = box('C', 500, 500, w: 200, h: 200)
      ..physics.hollow = true
      ..physics.role = 'immovable'
      ..physics.grows = true;
    final sq = box('S', 500, 500, w: 60, h: 60)..physics.role = 'immovable';
    growFrom(sq, 1, 4, 60); // 240 px
    final p = Project(layers: [cage, sq]);
    bake(p, 70);
    final cs = corners(p, cage, 70);
    expect(cs[1][0] - cs[0][0], greaterThan(238));
  });

  test('a U grows when what sits in its notch grows (it stays outside the U)', () {
    // a U, 100 x 100 around its centre, open at the top: the notch 40 wide.
    final u = createLayer('rect')
      ..id = 'U'
      ..startFrame = 0
      ..durationFrames = 100
      ..transform.anchor.defaultValue = [0.5, 0.5];
    u.content = Content(shape: 'compound', offset: [0, 0], size: [100, 100], contours: [
      [
        [-50.0, -50.0], [-20.0, -50.0], [-20.0, 20.0], [20.0, 20.0], [20.0, -50.0], [50.0, -50.0], [50.0, 50.0], [-50.0, 50.0]
      ]
    ]);
    u.physics
      ..collide = true
      ..grows = true;
    final k = box('K', 500, 485, w: 20, h: 20)..physics.role = 'immovable';
    growFrom(k, 1, 3, 60); // 60 px wide, in a 40 px notch
    final p = Project(layers: [u, k]);
    bake(p, 70);
    final m = toFrameMatrix(getLayerStateAt(p, 'U', 70).matrix);
    final scale = math.sqrt(m[0] * m[0] + m[1] * m[1]);
    expect(scale, greaterThan(1.4), reason: 'the notch widened by growing (40 -> 60+)');
    final wallR = applyAffine(m, [20, 0])[0];
    final kRight = corners(p, k, 70)[1][0];
    expect(kRight, lessThanOrEqualTo(wallR + 1.5), reason: 'it stays in the notch, outside the U');
  });

  test('turns when hit: an off-centre push turns it, the lighter the more', () {
    double turnOf(double weight) {
      final pusher = box('P', 300, 470, w: 60, h: 20)..physics.role = 'immovable';
      pusher.transform.anchor.keyframes = [
        Keyframe(frame: 0, value: <double>[0.3, 0.47], temporal: lin),
        Keyframe(frame: 40, value: <double>[0.5, 0.47], temporal: lin),
      ];
      final b = box('B', 560, 500, w: 100, h: 100)
        ..physics.spin = true
        ..physics.weight = weight;
      final p = Project(layers: [pusher, b]);
      bake(p, 50);
      return getLayerStateAt(p, 'B', 50).matrix[1];
    }

    final light = turnOf(0.5), heavy = turnOf(4);
    expect(light.abs(), greaterThan(0.01), reason: 'hit above its middle: it turns');
    expect(light.abs(), greaterThan(heavy.abs()), reason: 'lighter turns more');
  });
}
