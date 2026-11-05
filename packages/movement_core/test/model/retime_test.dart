import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => fps = 60);

  test('retiming keeps the real timing of layers and keys', () {
    fps = 60;
    final l = createLayer('rect')
      ..startFrame = 30
      ..durationFrames = 120;
    l.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 60, value: 90.0)]);
    final p = Project(layers: [l]);
    double rotAtSecond(double s) => evaluateTrack(p, l.transform.rotation, s * fps) as double;
    final before = rotAtSecond(0.5);

    retimeProject(p, 24);
    expect(fps, 24);
    expect(p.fps, 24);
    expect(l.startFrame, 12);
    expect(l.durationFrames, 48);
    expect([for (final k in l.transform.rotation.keyframes) k.frame], [0, 24]);
    expect(rotAtSecond(0.5), closeTo(before, 1e-9));
  });

  test('keys that land on one frame merge (the later wins)', () {
    fps = 60;
    final l = createLayer('rect');
    l.transform.opacity.keyframes.addAll([Keyframe(frame: 10, value: 0.2), Keyframe(frame: 11, value: 0.8)]);
    retimeProject(Project(layers: [l]), 12);
    expect(l.transform.opacity.keyframes.single.value, 0.8);
  });

  test('time quantize steps follow the project rate', () {
    fps = 24;
    final l = createLayer('rect')..timeQuantize = TimeQuantize(enabled: true, fps: 12);
    expect(layerTimeFrame(l, 1), 0);
    expect(layerTimeFrame(l, 2), 2);
  });
}
