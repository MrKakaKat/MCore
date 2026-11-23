import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Project scene() {
  final t = createLayer('rect')..id = 'T'..durationFrames = 2000;
  t.transform.anchor.keyframes = [
    for (var i = 0; i <= 8; i++) Keyframe(frame: i * 250, value: <double>[i.isEven ? 0.2 : 0.8, 0.5]),
  ];
  final f = createLayer('rect')..id = 'F'..durationFrames = 2000;
  f.follow
    ..enabled = true
    ..targetId = 'T';
  return Project(layers: [t, f]);
}

void main() {
  setUp(() {
    fps = 60;
    setStageSize(480, 480);
    clearStateCaches();
  });

  test('follow played on frame by frame: the same as worked out at once, and an edit to its target counts', () {
    final p = scene();
    late List<double> m;
    for (var f = 0; f <= 1500; f++) {
      clearStateCaches();
      m = getLayerStateAt(p, 'F', f).matrix;
    }
    final fresh = scene();
    clearStateCaches();
    final m2 = getLayerStateAt(fresh, 'F', 1500).matrix;
    expect(m[4], closeTo(m2[4], 1e-9));
    // the target moved: followed anew.
    p.layers.first.transform.anchor.keyframes[2].value = <double>[0.5, 0.9];
    fresh.layers.first.transform.anchor.keyframes[2].value = <double>[0.5, 0.9];
    clearStateCaches();
    final a = getLayerStateAt(p, 'F', 600).matrix, b = getLayerStateAt(fresh, 'F', 600).matrix;
    expect(a[5], closeTo(b[5], 1e-9));
  });
}
