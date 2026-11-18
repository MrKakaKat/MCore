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
      // stretched back out: its points spread over the time again.
      end.frame = 100;
      bindFreeMoveKeys(l);
      expect(t.keyframes.where((k) => k.passive).every((k) => k.frame > 0 && k.frame < 100), isTrue);
      expect(t.keyframes.where((k) => k.passive).last.frame, greaterThan(50));
    });
}
