import 'dart:math' as math;
import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
  });

  List<List<double>> wave() => [for (var i = 0; i <= 120; i++) [200.0 + i * 5, 500 + 120 * math.sin(i / 120 * 4 * math.pi)]];

  // the way's places along its keys (shape only, not timing).
  List<List<double>> shape(Track t) {
    final ks = t.keyframes;
    return [
      for (var i = 0; i + 1 < ks.length; i++)
        for (var s = 0; s < 20; s++) spatialLerpVec2(ks[i], ks[i + 1], s / 20),
    ];
  }

  double far(List<List<double>> a, List<List<double>> b) {
    var worst = 0.0;
    for (final p in a) {
      var best = double.infinity;
      for (final q in b) {
        best = math.min(best, math.sqrt(math.pow(p[0] - q[0], 2) + math.pow(p[1] - q[1], 2)));
      }
      worst = math.max(worst, best);
    }
    return worst;
  }

  test('drawn as the hand went: a pause in the drawing is a pause in the move', () {
    final l = createLayer('rect')
      ..id = 'A'
      ..durationFrames = 300;
    l.transform.anchor.defaultValue = <double>[0.1, 0.5];
    final p = Project(layers: [l]);
    // 0 -> 300 px in 0.5 s, still for 0.5 s, on to 600 px in 0.5 s.
    final pts = <List<double>>[], times = <double>[];
    for (var i = 0; i <= 30; i++) {
      pts.add([100.0 + i * 10, 500]);
      times.add(i / 60);
    }
    for (var i = 1; i <= 30; i++) {
      pts.add([400.0, 500]);
      times.add(0.5 + i / 60);
    }
    for (var i = 1; i <= 30; i++) {
      pts.add([400.0 + i * 10, 500]);
      times.add(1.0 + i / 60);
    }
    fps = 60;
    final n = addFreeMoveLayer(p, l, pts, 0, 0, smoothing: 0, times: times);
    expect(n, greaterThan(0));
    clearStateCaches();
    double x(int f) => (getLayerStateAt(p, 'A', f).matrix[4]) * 1000;
    expect(x(45), closeTo(400, 3), reason: 'standing still in the pause');
    expect(x(55), closeTo(400, 3));
    expect(x(15), inInclusiveRange(200, 300));
    expect(x(90), closeTo(700, 3));
  });

  for (final where in ['key layer', 'base keys'])
    test('as drawn ($where): the object goes exactly as fast as the finger did, pauses too', () {
      fps = 60;
      final l = createLayer('rect')
        ..id = 'A'
        ..durationFrames = 300;
      l.transform.anchor.defaultValue = <double>[0.1, 0.5];
      final p = Project(layers: [l]);
      // slow for 1 s (100 -> 400 px), still for 0.5 s, fast for 0.2 s (-> 700 px).
      final pts = <List<double>>[], times = <double>[];
      for (var i = 0; i <= 60; i++) {
        pts.add([100.0 + i * 5, 500]);
        times.add(i / 60);
      }
      for (var i = 1; i <= 30; i++) {
        pts.add([400.0, 500]);
        times.add(1 + i / 60);
      }
      for (var i = 1; i <= 12; i++) {
        pts.add([400.0 + i * 25, 500]);
        times.add(1.5 + i / 60);
      }
      if (where == 'key layer') {
        expect(addFreeMoveLayer(p, l, pts, 0, 0, smoothing: 0, times: times), greaterThan(0));
      } else {
        expect(addFreeMoveInto(p, l, l.transform.anchor, pts, 0, 10, smoothing: 0, times: times), isTrue);
      }
      double x(int f) {
        clearStateCaches();
        return getLayerStateAt(p, 'A', f).matrix[4] * 1000;
      }
      expect(x(30), closeTo(250, 6), reason: 'half way through the slow part');
      expect(x(75), closeTo(400, 4), reason: 'in the pause');
      expect(x(96), closeTo(550, 15), reason: 'half way through the fast part');
      expect(x(102), closeTo(700, 4));
    });

  for (final where in ['key layer', 'base keys'])
    test('a free move squeezed into fewer frames than it has points ($where): fewer points, one a frame, the same way', () {
      final l = createLayer('rect')
        ..id = 'A'
        ..durationFrames = 200;
      l.transform.anchor.defaultValue = <double>[0.2, 0.5];
      final p = Project(layers: [l]);
      late Track t;
      if (where == 'key layer') {
        final n = addFreeMoveLayer(p, l, wave(), 0, 100, smoothing: 0);
        t = l.transform.anchor.animLayers[n - 1].track;
      } else {
        t = l.transform.anchor;
        expect(addFreeMoveInto(p, l, t, wave(), 0, 100, smoothing: 0), isTrue);
      }
      final points = t.keyframes.where((k) => k.passive).length;
      expect(points, greaterThan(8));
      final before = shape(t);
      bindFreeMoveKeys(l);
      // its end key dragged to frame 6: room for 5 points.
      final end = t.keyframes.where((k) => !k.passive).reduce((a, b) => a.frame > b.frame ? a : b);
      end.frame = 6;
      bindFreeMoveKeys(l);
      final frames = t.keyframes.map((k) => k.frame).toList();
      expect(frames.toSet().length, frames.length, reason: 'one key a frame');
      expect(t.keyframes.where((k) => k.passive).length, lessThanOrEqualTo(5));
      expect(t.keyframes.where((k) => k.passive).every((k) => k.frame > 0 && k.frame < 6), isTrue);
      expect(far(shape(t), before), lessThan(0.02), reason: 'about the same way (fractions of the stage)');
      // stretched back out: every point it was drawn with comes back -
      // the same wave, not a few straight stretches.
      end.frame = 100;
      bindFreeMoveKeys(l);
      expect(t.keyframes.where((k) => k.passive).every((k) => k.frame > 0 && k.frame < 100), isTrue);
      expect(t.keyframes.where((k) => k.passive).last.frame, greaterThan(50));
      expect(t.keyframes.where((k) => k.passive).length, points);
      expect(far(shape(t), before), lessThan(1e-6));
      // and kept through a save.
      end.frame = 6;
      bindFreeMoveKeys(l);
      final back = trackFromJson(trackToJson(t));
      expect(back.keyframes.where((k) => k.way != null).length, 1);
    });
}
