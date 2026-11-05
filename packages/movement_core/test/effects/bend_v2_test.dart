import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Bend v2: lines across an axis, arc band, rigid carried part, adaptive
/// grid, joints, physics.
void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(640, 400);
    clearStateCaches();
  });

  // a 40 x 200 stick centred at the origin (y from -100 at the top to
  // +100 at the bottom); the default axis points up (-90°).
  Layer stick({List<EffectInstance>? fx}) => createLayer('rect')
    ..id = 'L'
    ..content.offset = [0, 0]
    ..content.size = [40, 200]
    ..effectStack.addAll(fx ?? []);

  EffectInstance bend(String id, {double angle = 90, double axis = -90, double start = 0.25, double end = 0.75}) {
    final i = createEffectInstance('bend_arc', id, null);
    (i.params['angle'] as Track).defaultValue = angle;
    (i.params['axisAngle'] as Track).defaultValue = axis;
    (i.params['start'] as Track).defaultValue = start;
    (i.params['end'] as Track).defaultValue = end;
    return i;
  }

  double dist(List<double> a, List<double> b) => math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));

  List<List<double>> run(Layer l, List<List<double>> pts) => applyEffectStack(l, [pts], 0)[0];

  test('new instances are v2 (no legacy params); legacy instances keep the old formula exactly', () {
    final v2 = createEffectInstance('bend_arc', 'a', null);
    expect(v2.params.keys, containsAll(['angle', 'axisAngle', 'start', 'end', 'inertia', 'spring']));
    expect(v2.params.containsKey('base'), isFalse);

    final legacy = EffectInstance(
        id: 'old', effectId: 'bend_arc', enabled: true, params: {'angle': track(60.0), 'base': track(0.2), 'baseAxis': 'bottom'});
    final grid = buildGrid(Content(shape: 'rect', offset: [0, 0], size: [40, 200]), 5, 5);
    final direct = effectRegistry['bend_arc']!.apply(grid, {'angle': 60.0, 'base': 0.2, 'baseAxis': 'bottom'}, 0);
    final viaStack = applyEffectStack(stick(fx: [legacy]), grid, 0);
    for (var r = 0; r < grid.length; r++) {
      for (var c = 0; c < grid[r].length; c++) {
        expect(viaStack[r][c], equals(direct[r][c]));
      }
    }
    final back = effectInstanceFromJson(effectInstanceToJson(legacy));
    expect(isBendV2(back), isFalse, reason: 'old JSON stays legacy');
  });

  test('static zone unchanged, carried zone rigid, continuous at both lines', () {
    final l = stick(fx: [bend('b')]);
    // lines: start at y = 100 - 0.25*200 = 50, end at y = -50.
    final staticPts = [
      [-20.0, 100.0], [20.0, 60.0], [0.0, 50.0]
    ];
    expect(run(l, staticPts), equals(staticPts));

    final carried = [
      [-20.0, -60.0], [20.0, -60.0], [0.0, -100.0]
    ];
    final out = run(l, carried);
    for (var i = 0; i < 3; i++) {
      for (var j = i + 1; j < 3; j++) {
        expect(dist(out[i], out[j]), closeTo(dist(carried[i], carried[j]), 1e-9));
      }
    }

    for (final y in [50.0, -50.0]) {
      final a = run(l, [[10.0, y + 1e-7]])[0], b = run(l, [[10.0, y - 1e-7]])[0];
      expect(dist(a, b), lessThan(1e-5), reason: 'no jump at the line y=$y');
    }
  });

  test('the centre line bends into an arc of the same length and leaves it tangentially (no kink at the end)', () {
    final l = stick(fx: [bend('b', angle: 90)]);
    // the band is 100 long; the centre line's end point lies on a quarter
    // circle of radius 100/(pi/2).
    const r = 100 / (math.pi / 2);
    final endPt = run(l, [[0.0, -50.0]])[0];
    expect(endPt[0], closeTo(r, 1e-9));
    expect(endPt[1], closeTo(50 - r, 1e-9));
    // direction just before and just after the end line along the axis.
    List<double> d(double y0, double y1) {
      final a = run(l, [[0.0, y0]])[0], b = run(l, [[0.0, y1]])[0];
      final len = dist(a, b);
      return [(b[0] - a[0]) / len, (b[1] - a[1]) / len];
    }

    final inBand = d(-49.999, -50.0), carried = d(-50.0, -50.001);
    expect(inBand[0], closeTo(carried[0], 1e-3));
    expect(inBand[1], closeTo(carried[1], 1e-3));
  });

  test('grid: rows on both lines at any axis angle, ~one row per 5° inside, none elsewhere but the corners', () {
    final l = stick(fx: [bend('b', angle: 90, axis: 37)]);
    final grid = buildEffectGrid(l, l.content, 0);
    final f = bendFrameFor(resolveEffectParams(l.effectStack.single, 0), shapeBoundingBox(l.content));
    final rowS = [for (final row in grid) f.sOf(row.first)];
    bool has(double s) => rowS.any((v) => (v - s).abs() < 1e-6);
    expect(has(f.s0) && has(f.s1), isTrue);
    for (final row in grid) {
      final s0 = f.sOf(row.first);
      for (final p in row) {
        expect(f.sOf(p), closeTo(s0, 1e-6), reason: 'each row is a line across the axis');
      }
    }
    final inside = rowS.where((s) => s > f.s0 + 1e-6 && s < f.s1 - 1e-6).length;
    expect(inside, 18 - 1, reason: '90° -> 18 rows -> 17 interior lines');
    final outside = rowS.where((s) => s < f.s0 - 1e-6 || s > f.s1 + 1e-6).length;
    expect(outside, lessThanOrEqualTo(4), reason: 'only the box extremes / corners');

    (l.effectStack.single.params['angle'] as Track).defaultValue = 10.0;
    final small = buildEffectGrid(l, l.content, 0);
    expect(small.length, lessThan(grid.length), reason: '10° -> 2 rows in the band');
  });

  test('two bands give dense rows in both; squeeze alone keeps the uniform grid', () {
    final l = stick(fx: [bend('a', start: 0.1, end: 0.3), bend('b', start: 0.6, end: 0.8)]);
    final grid = buildEffectGrid(l, l.content, 0);
    expect(grid.length, greaterThan(30));
    final sq = stick(fx: [createEffectInstance('squeeze_axis', 's', null)]);
    final g2 = buildEffectGrid(sq, sq.content, 0);
    expect(g2, equals(buildGrid(sq.content, 10, 10)));
  });

  test('chained bends act as joints: turning the lower one carries the upper joint with the stick', () {
    final lower = bend('lo', angle: 0, start: 0.2, end: 0.3);
    final upper = bend('up', angle: 45, start: 0.6, end: 0.7);
    final l = stick(fx: [lower, upper]);
    // the upper bend's start line (y = 100 - 0.6*200 = -20) and a point past it.
    final joint = [0.0, -20.0], tip = [0.0, -100.0];
    final before = run(l, [joint, tip]);
    expect(before[0], equals(joint), reason: 'lower bend off: the joint is where it was');

    (lower.params['angle'] as Track).defaultValue = 30.0;
    final after = run(l, [joint, tip]);
    // the lower bend alone, applied to the already-bent points, must give the same.
    final lowerOnly = stick(fx: [bend('x', angle: 30, start: 0.2, end: 0.3)]);
    expect(after[0][0], closeTo(run(lowerOnly, [joint])[0][0], 1e-9));
    expect(after[0][1], closeTo(run(lowerOnly, [joint])[0][1], 1e-9));
    final bentTip = run(stick(fx: [bend('u2', angle: 45, start: 0.6, end: 0.7)]), [tip])[0];
    final expectedTip = bendMap(bendFrameFor({'angle': 30.0, 'axisAngle': -90.0, 'start': 0.2, 'end': 0.3},
        shapeBoundingBox(l.content)), tip, bentTip);
    expect(after[1][0], closeTo(expectedTip[0], 1e-9));
    expect(after[1][1], closeTo(expectedTip[1], 1e-9));
  });

  test('converting a legacy bend maps its base and side onto the lines and axis', () {
    final legacy = EffectInstance(
        id: 'old', effectId: 'bend_arc', enabled: true, params: {'angle': track(30.0), 'base': track(0.2), 'baseAxis': 'left'});
    convertLegacyBend(legacy);
    expect(isBendV2(legacy), isTrue);
    expect((legacy.params['axisAngle'] as Track).defaultValue, 0.0);
    expect((legacy.params['start'] as Track).defaultValue, 0.2);
    expect((legacy.params['end'] as Track).defaultValue, 1.0);
    final back = effectInstanceFromJson(effectInstanceToJson(legacy));
    expect(isBendV2(back), isTrue);
  });

  group('physics', () {
    test('off: the keyed angle exactly', () {
      final b = bend('b', angle: 40);
      expect(bendPhysicsAngle(null, stick(fx: [b]), b, 30), 40);
    });

    test('spring: overshoots a key change and settles on it', () {
      final b = bend('b');
      final t = b.params['angle'] as Track;
      t.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 60.0)]);
      (b.params['spring'] as Track).defaultValue = 100.0;
      (b.params['damping'] as Track).defaultValue = 10.0;
      final l = stick(fx: [b]);
      final peak = [for (var f = 10; f < 60; f++) bendPhysicsAngle(null, l, b, f.toDouble())].reduce(math.max);
      expect(peak, greaterThan(62));
      expect(bendPhysicsAngle(null, l, b, 170), closeTo(60, 1.5));
    });

    test('inertia: a sideways start makes the free end lag behind, then it rings out', () {
      final b = bend('b', angle: 0);
      (b.params['inertia'] as Track).defaultValue = 100.0;
      final l = stick(fx: [b]);
      l.transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.5, 0.5]),
        Keyframe(frame: 20, value: [0.9, 0.5]),
      ]);
      final p = Project(layers: [l]);
      // axis up (-90°) -> normal points +x... the layer accelerates to +x.
      final early = bendPhysicsAngle(p, l, b, 6);
      expect(early, lessThan(-1), reason: 'leans away from the acceleration');
      expect(bendPhysicsAngle(p, l, b, 200).abs(), lessThan(1));
    });
  });

  test('at angle 0 the grid tiles the box exactly at any axis (no point outside, area preserved)', () {
    for (final axis in [-107.0, -90.0, 37.0, 0.0, 45.0, 180.0]) {
      final l = createLayer('rect')
        ..content.offset = [0, 0]
        ..content.size = [100, 100]
        ..effectStack.add(bend('b', angle: 0, axis: axis));
      final g = applyEffectStack(l, buildEffectGrid(l, l.content, 0), 0);
      var area = 0.0;
      for (var r = 0; r < g.length - 1; r++) {
        for (var c = 0; c < g[r].length - 1; c++) {
          final q = [g[r][c], g[r][c + 1], g[r + 1][c + 1], g[r + 1][c]];
          var a = 0.0;
          for (var i = 0; i < 4; i++) {
            a += q[i][0] * q[(i + 1) % 4][1] - q[(i + 1) % 4][0] * q[i][1];
          }
          area += a.abs() / 2;
        }
      }
      for (final row in g) {
        for (final p in row) {
          expect(p[0].abs() <= 50 + 1e-6 && p[1].abs() <= 50 + 1e-6, isTrue, reason: 'axis $axis: $p outside');
        }
      }
      expect(area, closeTo(10000, 1e-3), reason: 'axis $axis');
    }
  });
}
