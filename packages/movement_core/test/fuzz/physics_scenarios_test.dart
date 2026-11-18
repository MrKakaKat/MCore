// Randomized falling scenes: the same every time, never through the floor,
// never out of the stage, and settled by the end (no endless jitter).
import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });
  setUp(() => fps = 60);

  double rnd(math.Random r, double a, double b) => a + r.nextDouble() * (b - a);

  Project scene(math.Random r) {
    Layer box(String id, double x, double y, double w, double h) {
      final l = createLayer('rect')
        ..id = id
        ..durationFrames = 400
        ..content.offset = [0, 0]
        ..content.size = [w, h]
        ..transform.anchor.defaultValue = [x / 1000, y / 1000];
      l.physics.collide = true;
      return l;
    }

    final floor = box('F', 500, 900, 1000, 40)..physics.role = 'immovable';
    final ls = [floor];
    final n = 1 + r.nextInt(3);
    for (var i = 0; i < n; i++) {
      final b = box('B$i', 150 + 700 * (i + 0.5) / n, rnd(r, 100, 500), rnd(r, 30, 160), rnd(r, 30, 160))
        ..physics.falls = true
        ..physics.bounce = r.nextBool() ? 0 : rnd(r, 0, 0.6);
      if (r.nextBool()) {
        b.transform.rotation.defaultValue = rnd(r, -40, 40);
      }
      ls.add(b);
    }
    return Project(layers: ls, gravity: rnd(r, 600, 3000), gravityAngle: 90, stageWalls: true);
  }

  List<double> at(Project p, String id, int f) {
    final m = getLayerStateAt(p, id, f).matrix;
    return [m[4] * 1000, m[5] * 1000, math.atan2(m[1], m[0])];
  }

  for (var seed = 1; seed <= 20; seed++) {
    test('a falling scene (seed $seed)', () {
      final r = math.Random(seed);
      final p = scene(r);
      final ids = [for (final l in p.layers.skip(1)) l.id];
      clearStateCaches();
      physicsWorldOf(p).bakeTo(400);
      clearStateCaches();
      final run1 = {for (final id in ids) id: [for (var f = 0; f <= 400; f += 10) at(p, id, f)]};
      // the same scene again, opened from its save.
      final p2 = Project(
          layers: projectLayersFromJson(jsonDecode(jsonEncode(projectLayersToJson(p))) as List<dynamic>),
          gravity: p.gravity,
          gravityAngle: 90,
          stageWalls: true);
      clearStateCaches();
      physicsWorldOf(p2).bakeTo(400);
      clearStateCaches();
      for (final id in ids) {
        final run2 = [for (var f = 0; f <= 400; f += 10) at(p2, id, f)];
        for (var i = 0; i < run2.length; i++) {
          for (var c = 0; c < 3; c++) {
            expect(run2[i][c], closeTo(run1[id]![i][c], 1e-6), reason: '$id frame ${i * 10}: the same again');
          }
        }
        for (final v in run1[id]!) {
          expect(v.every((x) => x.isFinite), isTrue);
          expect(v[1], lessThan(880), reason: '$id: above the floor\'s top');
          expect(v[0], inInclusiveRange(0, 1000), reason: '$id: on the stage');
        }
        // settled: hardly moving over its last 30 frames.
        var most = 0.0;
        for (var f = 371; f <= 400; f++) {
          final a = at(p, id, f - 1), b = at(p, id, f);
          most = math.max(most, math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2)));
        }
        expect(most, lessThan(0.5), reason: '$id still moving ${most.toStringAsFixed(2)} px a frame at the end');
      }
    });
  }
}
