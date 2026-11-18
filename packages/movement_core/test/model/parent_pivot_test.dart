import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 600);
    clearStateCaches();
  });
  test('a parent turning round a point of its own does not move a child that follows only its place', () {
    final parent = createLayer('rect')..id = 'P'..durationFrames = 60;
    parent.transform.anchor.defaultValue = <double>[0.5, 0.5];
    parent.rotateOrigin = [80, 30];
    parent.transform.rotation.keyframes = [
      Keyframe(frame: 0, value: 0.0, temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 60, value: 120.0, temporal: const Easing(0, 0, 1, 1)),
    ];
    final child = createLayer('rect')..id = 'C'..durationFrames = 60;
    child.transform.anchor.defaultValue = <double>[0.2, 0.3];
    child.parentId = 'P';
    child
      ..inheritPosition = true
      ..inheritRotation = false
      ..inheritScale = false;
    final p = Project(layers: [parent, child]);
    clearStateCaches();
    final c0 = getLayerStateAt(p, 'C', 0).matrix, c1 = getLayerStateAt(p, 'C', 60).matrix;
    expect(c1[4], closeTo(c0[4], 1e-9));
    expect(c1[5], closeTo(c0[5], 1e-9));
  });
}
