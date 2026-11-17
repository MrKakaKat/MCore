import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Flat sides meeting: the contact sits in the middle of where they touch
/// - not at one of the floor's far corners (which one was farthest
/// flipped with rounding, so the contact jumped corner to corner).
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });
  setUp(() => fps = 60);

  Layer box(String id, double x, double y, double w, double h, double turn) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = 300
      ..content.offset = [0, 0]
      ..content.size = [w, h]
      ..transform.anchor.defaultValue = [x / 1000, y / 1000]
      ..transform.rotation.defaultValue = turn;
    l.physics.collide = true;
    return l;
  }

  for (final turn in [0.0, 20.0]) {
    test('a box landing hard on a floor turned $turn degrees: the contact stays under it', () {
      final floor = box('F', 500, 700, 800, 40, turn)..physics.role = 'immovable';
      final b = box('B', 500, 200, 80, 80, turn)..physics.falls = true;
      final p = Project(layers: [floor, b], gravity: 3000, gravityAngle: 90);
      clearStateCaches();
      final w = physicsWorldOf(p)..bakeTo(60);
      clearStateCaches();
      var seen = 0;
      for (var f = 0; f <= 60; f++) {
        final c = w.contactsAt(f);
        if (c.isEmpty) continue;
        final m = getLayerStateAt(p, 'B', f).matrix;
        final centre = [m[4] * 1000, m[5] * 1000];
        final pt = c.first.point, n = c.first.normal;
        // along the floor (across the normal): right under the box.
        final along = (pt[0] - centre[0]) * -n[1] + (pt[1] - centre[1]) * n[0];
        expect(along.abs(), lessThan(5), reason: 'frame $f');
        seen++;
      }
      expect(seen, greaterThan(10));
      expect(math.max(0, seen), greaterThan(0));
    });
  }
}
