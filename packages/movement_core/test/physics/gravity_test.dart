import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Gravity: layers that fall gather speed until something holds them.
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });
  setUp(() => fps = 60);

  Layer box(String id, double x, double y, double w, double h) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = 300
      ..content.offset = [0, 0]
      ..content.size = [w, h]
      ..transform.anchor.defaultValue = [x / 1000, y / 1000];
    l.physics.collide = true;
    return l;
  }

  List<double> pos(Project p, String id, int f) {
    final m = getLayerStateAt(p, id, f).matrix;
    return [m[4] * 1000, m[5] * 1000];
  }

  Project scene({double bounce = 0, double gravity = 1800, double angle = 90}) {
    final floor = box('F', 500, 900, 800, 40)..physics.role = 'immovable'; // its top at 880
    final ball = box('B', 500, 200, 60, 60)
      ..physics.falls = true
      ..physics.bounce = bounce;
    return Project(layers: [floor, ball], gravity: gravity, gravityAngle: angle);
  }

  void bake(Project p, int to) {
    clearStateCaches();
    physicsWorldOf(p).bakeTo(to);
    clearStateCaches();
  }

  test('it falls faster and faster and lands on the floor', () {
    final p = scene();
    bake(p, 200);
    final y = [for (final f in [0, 10, 20, 30]) pos(p, 'B', f)[1]];
    expect(y[1] - y[0], greaterThan(0));
    expect(y[2] - y[1], greaterThan(y[1] - y[0]), reason: 'speeding up');
    expect(y[3] - y[2], greaterThan(y[2] - y[1]));
    expect(pos(p, 'B', 200)[1], closeTo(850, 1.5), reason: 'resting on the floor (its top at 880)');
    expect(pos(p, 'B', 200)[0], closeTo(500, 1e-6), reason: 'straight down');
  });

  test('no gravity (or not falling): it stays', () {
    final p = scene(gravity: 0);
    bake(p, 60);
    expect(pos(p, 'B', 60)[1], closeTo(200, 1e-9));
    final q = scene()..layers.last.physics.falls = false;
    bake(q, 60);
    expect(pos(q, 'B', 60)[1], closeTo(200, 1e-9));
  });

  test('bounce: it comes back up off the floor, lower each time, and settles', () {
    final p = scene(bounce: 0.7);
    bake(p, 300);
    var landed = -1;
    for (var f = 1; f < 300; f++) {
      if (pos(p, 'B', f)[1] > 849) {
        landed = f;
        break;
      }
    }
    expect(landed, greaterThan(0));
    var top = double.infinity;
    for (var f = landed; f < landed + 60; f++) {
      top = top < pos(p, 'B', f)[1] ? top : pos(p, 'B', f)[1];
    }
    expect(top, lessThan(800), reason: 'it went back up');
    expect(top, greaterThan(200), reason: 'not as high as it started');
    expect(pos(p, 'B', 300)[1], closeTo(850, 3), reason: 'settled');
  });

  test('the frame edges hold it with walls on; gravity can pull any way', () {
    final p = Project(layers: [box('B', 500, 500, 100, 100)..physics.falls = true], gravity: 3000, gravityAngle: 0)
      ..stageWalls = true;
    p.layers.single.physics.falls = true;
    p.gravityAngle = 0; // to the right
    bake(p, 200);
    expect(pos(p, 'B', 200)[0], closeTo(950, 1.5), reason: 'against the right edge');
    expect(pos(p, 'B', 200)[1], closeTo(500, 1e-6));
  });

  test('saved: the layer falls and bounces', () {
    final l = box('B', 0, 0, 10, 10)
      ..physics.falls = true
      ..physics.bounce = 0.4;
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect([back.physics.falls, back.physics.bounce], [true, 0.4]);
  });

  test('two falling boxes stack on the floor', () {
    final floor = box('F', 500, 900, 800, 40)..physics.role = 'immovable';
    final a = box('A', 500, 600, 100, 100)..physics.falls = true;
    final b = box('B', 500, 300, 100, 100)..physics.falls = true;
    final p = Project(layers: [floor, a, b], gravity: 1800);
    bake(p, 240);
    expect(pos(p, 'A', 240)[1], closeTo(830, 2), reason: 'on the floor');
    expect(pos(p, 'B', 240)[1], closeTo(730, 3), reason: 'on A');
  });

  double turnOf(Project p, String id, int f) {
    final m = getLayerStateAt(p, id, f).matrix;
    return math.atan2(m[1], m[0]) * 180 / math.pi;
  }

  test('tipping: a box hanging past the floor\'s edge turns over and falls off; one resting on it stays square', () {
    final floor = box('F', 300, 900, 400, 40)..physics.role = 'immovable'; // 100..500, its top at 880
    final over = box('B', 520, 820, 100, 100)..physics.falls = true; // its middle 20 past the edge
    final p = Project(layers: [floor, over], gravity: 1800);
    bake(p, 200);
    expect(turnOf(p, 'B', 200).abs(), greaterThan(20), reason: 'it tipped over the edge');
    expect(pos(p, 'B', 200)[1], greaterThan(880), reason: 'and fell past the floor');
    final on = box('C', 300, 820, 100, 100)..physics.falls = true;
    final q = Project(layers: [box('F', 300, 900, 400, 40)..physics.role = 'immovable', on], gravity: 1800);
    bake(q, 200);
    expect(turnOf(q, 'C', 200).abs(), lessThan(0.5), reason: 'held under its middle: no turn');
    expect(pos(q, 'C', 200)[1], closeTo(830, 1.5));
  });

  test('a box landing a little tilted settles: no rocking corner to corner, no flip from a hard landing', () {
    for (final tilt in [3.0, 0.5]) {
      final floor = box('F', 500, 900, 800, 40)..physics.role = 'immovable';
      final b = box('B', 500, 500, 200, 200)
        ..physics.falls = true
        ..transform.rotation.defaultValue = tilt;
      final p = Project(layers: [floor, b], gravity: 3000);
      bake(p, 120);
      final turns = [for (var f = 60; f <= 120; f++) turnOf(p, 'B', f)];
      expect(turns.reduce(math.max) - turns.reduce(math.min), lessThan(0.01), reason: 'tilt $tilt: at rest');
      expect(turns.last.abs(), lessThan(tilt + 0.01), reason: 'tilt $tilt: not tipped over');
    }
  });

  test('tipping on the frame\'s edge too: a tilted box landing on the bottom edge turns down onto its side', () {
    final b = box('B', 500, 600, 200, 200)
      ..physics.falls = true
      ..transform.rotation.defaultValue = 10.0;
    final p = Project(layers: [b], gravity: 3000, stageWalls: true);
    bake(p, 150);
    expect(turnOf(p, 'B', 150).abs(), lessThan(3), reason: 'turned from 10 degrees toward lying flat');
    expect(pos(p, 'B', 150)[1], greaterThan(880), reason: 'down on the edge');
  });

  test('strong gravity, landing at an angle: no sudden flips, it comes to rest', () {
    for (final (w, h, tilt) in [(200.0, 200.0, 30.0), (300.0, 80.0, 25.0), (80.0, 300.0, 15.0)]) {
      final floor = box('F', 500, 950, 1000, 40)..physics.role = 'immovable';
      final b = box('B', 500, 300, w, h)
        ..physics.falls = true
        ..transform.rotation.defaultValue = tilt;
      final p = Project(layers: [floor, b], gravity: 9000);
      bake(p, 400);
      for (var f = 1; f <= 400; f++) {
        final d = (turnOf(p, 'B', f) - turnOf(p, 'B', f - 1)).abs();
        expect(d < 6 || d > 354, isTrue, reason: '$w x $h at $tilt: frame $f turned $d degrees at once');
      }
      final rest = [for (var f = 340; f <= 400; f++) turnOf(p, 'B', f)];
      expect(rest.reduce(math.max) - rest.reduce(math.min), lessThan(0.05), reason: '$w x $h at $tilt: at rest');
      final ys = [for (var f = 340; f <= 400; f++) pos(p, 'B', f)[1]];
      expect(ys.reduce(math.max) - ys.reduce(math.min), lessThan(0.5), reason: '$w x $h at $tilt: not jumping');
    }
  });

  test('its weight at the middle of its area: an L tips toward its heavy side', () {
    // a tall bar standing on its narrow bottom with an arm sticking out
    // right at the top: its area's middle is right of what holds it.
    final floor = box('F', 500, 950, 1000, 40)..physics.role = 'immovable';
    final l = box('L', 500, 600, 100, 100)..physics.falls = true;
    l.content
      ..shape = 'line'
      ..lineNodes = [
        LineNode(-50, -150), LineNode(150, -150), LineNode(150, -110), LineNode(-10, -110),
        LineNode(-10, 150), LineNode(-50, 150),
      ]
      ..lineClosed = true
      ..lineFilled = true;
    final p = Project(layers: [floor, l], gravity: 3000);
    bake(p, 200);
    expect(turnOf(p, 'L', 200), greaterThan(20), reason: 'tipped over to the right (clockwise)');
  });

  test('gravity\'s way keyed in time: it falls down, then from its key on, right', () {
    final b = box('B', 500, 500, 60, 60)..physics.falls = true;
    final p = Project(layers: [b], gravity: 1800, stageWalls: true)..gravityWays = [(40, 0.0)];
    bake(p, 120);
    expect(pos(p, 'B', 39)[1], greaterThan(600), reason: 'down first');
    expect(pos(p, 'B', 120)[0], greaterThan(900), reason: 'then right');
    expect(p.gravityAngleAt(39), 90);
    expect(p.gravityAngleAt(40), 0);
  });

  test('no endless sliding: dropped tilted onto the frame\'s bottom it comes to rest (no wandering wall to wall)', () {
    for (final tilt in [0.0, 20.0, 50.0]) {
      final b = box('B', 300, 200, 140, 60)
        ..physics.falls = true
        ..transform.rotation.defaultValue = tilt;
      final p = Project(layers: [b], gravity: 6000, stageWalls: true);
      bake(p, 300);
      final xs = [for (var f = 240; f <= 300; f++) pos(p, 'B', f)[0]];
      final ys = [for (var f = 240; f <= 300; f++) pos(p, 'B', f)[1]];
      expect(xs.reduce(math.max) - xs.reduce(math.min), lessThan(0.5), reason: 'tilt $tilt: stopped sliding');
      expect(ys.reduce(math.max) - ys.reduce(math.min), lessThan(0.5), reason: 'tilt $tilt: at rest');
      expect((xs.last - 300).abs(), lessThan(150), reason: 'tilt $tilt: no long slide from a straight drop');
    }
  });

  test('gravity turned from sideways to down: it slides along the floor only a little, and stops', () {
    final b = box('B', 500, 300, 80, 80)..physics.falls = true;
    final p = Project(layers: [b], gravity: 3000, stageWalls: true, gravityAngle: 0)..gravityWays = [(40, 90.0)];
    bake(p, 300);
    final xs = [for (var f = 240; f <= 300; f++) pos(p, 'B', f)[0]];
    expect(xs.reduce(math.max) - xs.reduce(math.min), lessThan(0.5), reason: 'stopped');
    expect(pos(p, 'B', 300)[1], closeTo(960, 1), reason: 'on the floor');
  });

  test('landing on a corner turns it (the hit, not only its weight): it lies down soon, bouncing or not', () {
    for (final bounce in [0.0, 0.52]) {
      final b = box('B', 500, 300, 200, 70)
        ..physics.falls = true
        ..physics.bounce = bounce
        ..transform.rotation.defaultValue = 30.0;
      final p = Project(layers: [b], gravity: 1500, stageWalls: true);
      bake(p, 200);
      // it lands about frame 55.
      expect(turnOf(p, 'B', 110).abs(), lessThan(10), reason: 'bounce $bounce: turned down within a second');
      final rest = [for (var f = 170; f <= 200; f++) turnOf(p, 'B', f)];
      expect(rest.reduce(math.max) - rest.reduce(math.min), lessThan(0.05), reason: 'bounce $bounce: at rest');
    }
  });

  test('friction 0 slides on; saved', () {
    final b = box('B', 300, 900, 80, 80)
      ..physics.falls = true
      ..physics.friction = 0;
    expect(PhysicsSettings.fromJson(b.physics.toJson()).friction, 0);
  });

  test('its own gravity: half falls slower, 0 does not fall', () {
    double yAt(double scale) {
      final b = box('B', 500, 200, 60, 60)
        ..physics.falls = true
        ..physics.gravityScale = scale;
      final p = Project(layers: [b], gravity: 1800);
      bake(p, 20);
      return pos(p, 'B', 20)[1] - 200;
    }

    final full = yAt(1), half = yAt(0.5);
    expect(half, closeTo(full / 2, full * 0.05));
    expect(yAt(0), 0);
  });

  test('any way: gravity at 45 degrees pulls down and right alike', () {
    final b = box('B', 500, 500, 60, 60)..physics.falls = true;
    final p = Project(layers: [b], gravity: 1800, gravityAngle: 45);
    bake(p, 20);
    final d = pos(p, 'B', 20);
    expect(d[0] - 500, closeTo(d[1] - 500, 1e-6));
    expect(d[0] - 500, greaterThan(0));
  });
}
