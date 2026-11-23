import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Project chain() {
  final a = createLayer('rect')..id = 'A'..durationFrames = 3000;
  a.transform.anchor.keyframes = [
    for (var i = 0; i <= 10; i++) Keyframe(frame: i * 300, value: <double>[i.isEven ? 0.2 : 0.8, 0.5]),
  ];
  a.pendulum = Pendulum(enabled: true);
  final b = createLayer('rect')..id = 'B'..durationFrames = 3000..parentId = 'A';
  b.pendulum = Pendulum(enabled: true);
  final c = createLayer('rect')..id = 'C'..durationFrames = 3000..parentId = 'B';
  c.pendulum = Pendulum(enabled: true);
  return Project(layers: [a, b, c]);
}

void main() {
  setUp(() {
    fps = 60;
    setStageSize(480, 480);
    clearStateCaches();
  });

  test('a chain of pendulums: the same swing played on as worked out from the start, and no slower late on', () {
    final p = chain();
    final sw = Stopwatch()..start();
    var last = 0.0;
    for (var f = 0; f <= 2400; f++) {
      clearStateCaches(); // as each rendered frame does
      last = getLayerStateAt(p, 'C', f).rot;
    }
    final perFrame = sw.elapsedMicroseconds / 2400;
    // a fresh project: worked out from the start.
    final fresh = chain();
    clearStateCaches();
    expect(getLayerStateAt(fresh, 'C', 2400).rot, closeTo(last, 1e-9));
    // late frames as quick as early ones (was: a few seconds a frame).
    final t = Stopwatch()..start();
    for (var f = 2401; f <= 2420; f++) {
      clearStateCaches();
      getLayerStateAt(p, 'C', f);
    }
    expect(t.elapsedMicroseconds / 20, lessThan(perFrame * 20 + 5000));
    // an edit: the kept swing is not used.
    p.layers.first.transform.anchor.keyframes[3].value = <double>[0.5, 0.1];
    clearStateCaches();
    final edited = getLayerStateAt(p, 'C', 2400).rot;
    final fresh2 = chain()..layers.first.transform.anchor.keyframes[3].value = <double>[0.5, 0.1];
    clearStateCaches();
    expect(getLayerStateAt(fresh2, 'C', 2400).rot, closeTo(edited, 1e-9));
  });
}
