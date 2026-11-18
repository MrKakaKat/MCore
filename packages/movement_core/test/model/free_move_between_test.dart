import 'dart:math' as math;
import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
  });
  test('drawn anew between keys with another key layer moving it too: its middle follows the drawn way', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 100;
    l.content.offset = [0, 60];
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.2, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 60, value: <double>[0.8, 0.5], temporal: const Easing(0, 0, 1, 1)),
    ];
    final p = Project(layers: [l]);
    final n = addTransformAnimLayer(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 0, value: <double>[0.0, 0.0], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 60, value: <double>[0.0, 0.15], temporal: const Easing(0, 0, 1, 1)),
    ];
    clearStateCaches();
    List<double> centre(int f) => computeLayerFrameGeometry(p, l, f, includeVertices: false).center;
    final c0 = centre(0), c60 = centre(60);
    final path = [for (var i = 0; i <= 40; i++) [c0[0] + (c60[0] - c0[0]) * i / 40, c0[1] - 300 * math.sin(math.pi * i / 40)]];
    final end = centre(60);
    final mid = fitWayToEnds(path, c0, end)[20];
    replaceMoveBetweenKeys(p, l, l.transform.anchor, 0, 60, path, smoothing: 0);
    clearStateCaches();
    expect(centre(60)[0], closeTo(end[0], 1e-6));
    expect(centre(60)[1], closeTo(end[1], 1e-6));
    var best = 1e9;
    // nearest to it on the way (between frames too).
    for (var f = 0; f < 60; f++) {
      final c = centre(f), e = centre(f + 1);
      final vx = e[0] - c[0], vy = e[1] - c[1];
      final l2 = vx * vx + vy * vy;
      final t = l2 == 0 ? 0.0 : (((mid[0] - c[0]) * vx + (mid[1] - c[1]) * vy) / l2).clamp(0.0, 1.0);
      best = math.min(best, math.sqrt(math.pow(c[0] + vx * t - mid[0], 2) + math.pow(c[1] + vy * t - mid[1], 2)));
    }
    expect(best, lessThan(3), reason: 'through the drawn way (bent to its end key)');
  });

  test('a drawn way set between the keys stays exactly as drawn and is joined to the key at its end', () {
    final path = [for (var i = 0; i <= 100; i++) <double>[i * 3.0, 50 * math.sin(math.pi * i / 50)]];
    // the hand ended 10 px off the key.
    final out = fitWayToEnds(path, [0, 0], [300, 10]);
    expect(out.length, path.length + 1);
    for (var i = 0; i < path.length; i++) {
      expect(out[i], path[i]);
    }
    expect(out.last, [300, 10]);
    // ended on the key: nothing added.
    expect(fitWayToEnds(path, [0, 0], [300, 0]).length, path.length);
  });
}
