import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Something in a U's notch (not hollow) is pushed by whichever wall
/// comes at it - it never sticks to one wall.
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });

  const lin = Easing(0, 0, 1, 1);
  Layer arch() {
    final u = createLayer('rect')
      ..id = 'U'
      ..startFrame = 0
      ..durationFrames = 200
      ..transform.anchor.defaultValue = [0.5, 0.5];
    // 300 x 300 around its middle, open at the bottom: walls 50 thick, the
    // notch 200 wide (x -100..100), from y -100 down.
    u.content = Content(shape: 'compound', offset: [0, 0], size: [300, 300], contours: [
      [
        [-150.0, -150.0], [150.0, -150.0], [150.0, 150.0], [100.0, 150.0], [100.0, -100.0], [-100.0, -100.0],
        [-100.0, 150.0], [-150.0, 150.0]
      ]
    ]);
    u.physics
      ..collide = true
      ..role = 'immovable';
    return u;
  }

  Layer square() {
    final s = createLayer('rect')
      ..id = 'S'
      ..startFrame = 0
      ..durationFrames = 200
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.52];
    s.physics.collide = true;
    return s;
  }

  double x(Project p, String id, int f) => getLayerStateAt(p, id, f).matrix[4] * 1000;

  test('the U goes right (its left wall pushes), then left (its right wall pushes): no sticking', () {
    final u = arch(), s = square();
    u.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.5, 0.5], temporal: lin),
      Keyframe(frame: 30, value: <double>[0.6, 0.5], temporal: lin), // +100
      Keyframe(frame: 60, value: <double>[0.6, 0.5], temporal: lin),
      Keyframe(frame: 120, value: <double>[0.4, 0.5], temporal: lin), // -200
    ];
    final p = Project(layers: [u, s]);
    physicsWorldOf(p).bakeTo(130);
    clearStateCaches();
    // the left wall's inside at 600 - 100 = 500: the square's middle at 550.
    expect(x(p, 'S', 40), closeTo(550, 1.5), reason: 'pushed by the left wall');
    // coming back, the square stays put until the right wall reaches it.
    expect(x(p, 'S', 75), closeTo(550, 1.5), reason: 'it does not follow the left wall back');
    // at the end the right wall's inside is at 400 + 100 = 500: middle at 450.
    expect(x(p, 'S', 125), closeTo(450, 1.5), reason: 'pushed by the right wall');
  });

  test('the U shrinks around it: it stays in the middle, squeezed between both walls', () {
    final u = arch(), s = square()..transform.anchor.defaultValue = [0.5, 0.52];
    u.transform.scale.keyframes = [
      Keyframe(frame: 0, value: <double>[1.0, 1.0], temporal: lin),
      Keyframe(frame: 40, value: <double>[0.5, 0.5], temporal: lin), // the notch 100 wide
    ];
    final p = Project(layers: [u, s]);
    physicsWorldOf(p).bakeTo(50);
    clearStateCaches();
    expect(x(p, 'S', 50), closeTo(500, 3), reason: 'not stuck against one wall');
  });

  test('squeezed narrower than itself: it stays between the walls (any roles), never pushed out through one', () {
    for (final (ur, sr) in [('pushable', 'pushable'), ('pushable', 'immovable'), ('immovable', 'pushable')]) {
      final u = arch()..physics.role = ur;
      final s = square()
        ..physics.role = sr
        ..transform.anchor.defaultValue = [0.51, 0.52];
      u.transform.scale.keyframes = [
        Keyframe(frame: 0, value: <double>[1.0, 1.0], temporal: lin),
        Keyframe(frame: 40, value: <double>[0.4, 0.4], temporal: lin), // the notch 80 wide, the square 100
        Keyframe(frame: 80, value: <double>[1.0, 1.0], temporal: lin),
      ];
      final p = Project(layers: [u, s]);
      clearStateCaches();
      physicsWorldOf(p).bakeTo(90);
      clearStateCaches();
      for (final f in [40, 90]) {
        expect((x(p, 'S', f) - x(p, 'U', f)).abs(), lessThan(15), reason: '$ur / $sr at $f: still in the notch');
      }
    }
  });
}
