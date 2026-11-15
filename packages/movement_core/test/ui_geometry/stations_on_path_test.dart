import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double _toPath(List<double> p, List<List<double>> path) {
  var best = double.infinity;
  for (var i = 0; i + 1 < path.length; i++) {
    final a = path[i], b = path[i + 1];
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final l2 = dx * dx + dy * dy;
    final t = l2 == 0 ? 0.0 : (((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2).clamp(0.0, 1.0);
    final x = a[0] + dx * t - p[0], y = a[1] + dy * t - p[1];
    best = math.min(best, math.sqrt(x * x + y * y));
  }
  return best;
}

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    activeAnimLayer = 0;
  });
  tearDown(() => activeAnimLayer = 0);

  test('the stops lie on the path: a moved centre, a key layer after the keys', () {
    final l = createLayer('rect')
      ..id = 'A'
      ..durationFrames = 60
      ..content.size = [100, 60];
    l.transform.anchor = Track([0.2, 0.2], true)
      ..keyframes = [
        Keyframe(frame: 0, value: [0.2, 0.2]),
        Keyframe(frame: 20, value: [0.5, 0.3]),
        Keyframe(frame: 40, value: [0.7, 0.6]),
      ];
    autoComputeTangents(l.transform.anchor);
    l.transform.rotation.defaultValue = 30.0;
    final p = Project(layers: [l]);
    // its centre moved to a corner of its box.
    setLayerPivot(p, l, layerBoxPoint(l, 0, 0), 0);
    // a key layer moving it on from frame 10.
    final n = addTransformAnimLayer(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 10, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [0.1, 0.0]),
    ];
    clearStateCaches();
    final path = samplePathScreen(p, l, 60);
    for (final st in getAnchorStationsScreen(p, l, 0)) {
      expect(_toPath(st.screen, path), lessThan(0.5), reason: 'base stop ${st.idx}');
    }
    activeAnimLayer = n;
    for (final st in getAnchorStationsScreen(p, l, 0)) {
      expect(_toPath(st.screen, path), lessThan(0.5), reason: 'key layer stop ${st.idx}');
    }
    for (final o in getOtherStationsScreen(p, l)) {
      expect(_toPath(o, path), lessThan(0.5));
    }
  });
}
