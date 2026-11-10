import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Hollow shapes (hit from within) and turning against an Immovable
/// (rotate logic: shrink / step aside, and back).
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });

  Layer box(String id, double x, double y, {double w = 100, double h = 100, int frames = 100}) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = frames
      ..content.offset = [0, 0]
      ..content.size = [w, h]
      ..transform.anchor.defaultValue = [x / 1000, y / 1000];
    l.physics.collide = true;
    return l;
  }

  void move(Layer l, int f0, List<double> from, int f1, List<double> to) {
    l.transform.anchor.keyframes
      ..clear()
      ..add(Keyframe(frame: f0, value: [from[0] / 1000, from[1] / 1000], temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: f1, value: [to[0] / 1000, to[1] / 1000], temporal: const Easing(0, 0, 1, 1)));
  }

  List<double> pos(Project p, String id, int f) {
    final m = getLayerStateAt(p, id, f).matrix;
    return [m[4] * 1000, m[5] * 1000];
  }

  void bake(Project p, int to) {
    clearStateCaches();
    physicsWorldOf(p).bakeTo(to);
    clearStateCaches();
  }

  test('hollow Immovable: a box inside stops at its wall from within', () {
    final cage = box('C', 500, 500, w: 400, h: 400)
      ..physics.hollow = true
      ..physics.role = 'immovable';
    final b = box('B', 500, 500, w: 50, h: 50);
    move(b, 0, [500, 500], 60, [900, 500]);
    final p = Project(layers: [cage, b]);
    bake(p, 80);
    // the cage's right wall at 700: the box's middle at most 675.
    expect(pos(p, 'B', 80)[0], closeTo(675, 1));
  });

  test('hollow and pushable: a box inside pushes the cage along', () {
    final cage = box('C', 500, 500, w: 400, h: 400)..physics.hollow = true;
    final b = box('B', 500, 500, w: 50, h: 50)..physics.role = 'immovable';
    move(b, 0, [500, 500], 60, [900, 500]);
    final p = Project(layers: [cage, b]);
    bake(p, 80);
    final c = pos(p, 'C', 80), bb = pos(p, 'B', 80);
    expect(bb[0], closeTo(900, 1e-6));
    expect(c[0] + 200 - (bb[0] + 25), closeTo(0, 1), reason: 'the wall carried just past the box');
  });

  test('outside a hollow one it is solid as usual', () {
    final cage = box('C', 500, 500, w: 200, h: 200)
      ..physics.hollow = true
      ..physics.role = 'immovable';
    final b = box('B', 100, 500, w: 50, h: 50);
    move(b, 0, [100, 500], 60, [500, 500]);
    final p = Project(layers: [cage, b]);
    bake(p, 80);
    expect(pos(p, 'B', 80)[0], closeTo(375, 1));
  });

  test('rotate logic "size": turning into an Immovable it shrinks, then grows back', () {
    final wall = box('W', 540, 500, w: 20, h: 400)..physics.role = 'immovable';
    final r = box('R', 500, 500, w: 100, h: 20)..physics.rotateLogic = 'size';
    // turns a quarter and back; its tip (50 out) would cross the wall at 530.
    r.transform.rotation.keyframes
      ..add(Keyframe(frame: 0, value: 90.0, temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 20, value: 0.0, temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 40, value: 90.0, temporal: const Easing(0, 0, 1, 1)));
    final p = Project(layers: [wall, r]);
    bake(p, 90);
    final m = getLayerStateAt(p, 'R', 20).matrix;
    final scaleAt20 = m[0].abs() + m[1].abs();
    expect(scaleAt20, lessThan(0.99), reason: 'shrunk where it meets the wall');
    expect(pos(p, 'R', 20)[0], closeTo(500, 1e-6), reason: 'it keeps its place');
    final m2 = getLayerStateAt(p, 'R', 90).matrix;
    expect(m2[0] * m2[0] + m2[1] * m2[1], closeTo(1, 0.01), reason: 'back to its size once free');
  });

  test('rotate logic "position": stepped aside, then back', () {
    final wall = box('W', 540, 500, w: 20, h: 400)..physics.role = 'immovable';
    final r = box('R', 500, 500, w: 100, h: 20)..physics.rotateLogic = 'position';
    r.transform.rotation.keyframes
      ..add(Keyframe(frame: 0, value: 90.0, temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 20, value: 0.0, temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 40, value: 90.0, temporal: const Easing(0, 0, 1, 1)));
    final p = Project(layers: [wall, r]);
    bake(p, 90);
    expect(pos(p, 'R', 20)[0], lessThan(499), reason: 'moved aside');
    expect(pos(p, 'R', 90)[0], closeTo(500, 0.1), reason: 'back in place');
  });
}
