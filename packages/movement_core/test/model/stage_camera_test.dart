import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    setStageSize(200, 100);
    clearStateCaches();
  });

  List<double> view(Project p, List<double> world) => applyAffine(cameraViewMatrix(p, 0, 200, 100)!, world);

  test('a new camera shows the stage as it is', () {
    final cam = createCameraLayer(200, 100);
    final p = Project(layers: [cam]);
    expect(view(p, [30, 40]), [closeTo(30, 1e-9), closeTo(40, 1e-9)]);
    expect(Project(layers: []).layers.isEmpty && cameraViewMatrix(Project(), 0, 200, 100) == null, isTrue);
  });

  test('moving the camera right moves the scene left; a bigger frame zooms out', () {
    final cam = createCameraLayer(200, 100)..transform.anchor.defaultValue = [0.6, 0.5];
    final p = Project(layers: [cam]);
    expect(view(p, [100, 50])[0], closeTo(80, 1e-9));
    cam.transform.anchor.defaultValue = [0.5, 0.5];
    cam.transform.scale.defaultValue = [2.0, 2.0];
    clearStateCaches();
    expect(view(p, [200, 50])[0], closeTo(150, 1e-9), reason: 'half as big on screen');
  });

  test('a camera parented to an object follows it', () {
    final obj = createLayer('rect')
      ..id = 'o'
      ..durationFrames = 100
      ..transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.5, 0.5]),
        Keyframe(frame: 100, value: [0.7, 0.5]),
      ]);
    final cam = createCameraLayer(200, 100, durationFrames: 100);
    final p = Project(layers: [obj, cam]);
    reparentPreservingWorldPosition(p, cam, 'o', 0);
    clearStateCaches();
    final objAt100 = applyAffine(toFrameMatrix(getLayerStateAt(p, 'o', 100).matrix), [0, 0]);
    expect(applyAffine(cameraViewMatrix(p, 100, 200, 100)!, objAt100)[0], closeTo(100, 1e-6),
        reason: 'the object stays in the middle of the picture');
  });
}
