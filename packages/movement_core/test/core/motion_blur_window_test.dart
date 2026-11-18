import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
  });
  test('slow moves: the shutter stays open longer for a slow move (sensitivity), by the angle when off', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 100;
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.2, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 100, value: <double>[0.3, 0.5], temporal: const Easing(0, 0, 1, 1)),
    ];
    final p = Project(layers: [l]);
    l.motionBlur = MotionBlur(enabled: true, shutterAngle: 180);
    expect(motionBlurWindow(p, l, 50), 0.5);
    l.motionBlur.sensitivity = 0.5;
    // 1 px a frame: a 20 px streak wants 20 frames - at most 8.
    expect(motionBlurWindow(p, l, 50), 8);
    l.motionBlur.sensitivity = 0.05;
    expect(motionBlurWindow(p, l, 50), closeTo(2, 1e-6));
    expect(motionBlurFromJson(motionBlurToJson(l.motionBlur)).sensitivity, 0.05);
  });
}
