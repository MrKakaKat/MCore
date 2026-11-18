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
    replaceMoveBetweenKeys(p, l, l.transform.anchor, 0, 60, path, smoothing: 0);
    clearStateCaches();
    var best = 1e9;
    for (var f = 0; f <= 60; f++) {
      final c = centre(f);
      best = math.min(best, math.sqrt(math.pow(c[0] - 500, 2) + math.pow(c[1] - 335, 2)));
    }
    expect(best, lessThan(1), reason: 'through the drawn way (bent to its end key)');
  });
}
