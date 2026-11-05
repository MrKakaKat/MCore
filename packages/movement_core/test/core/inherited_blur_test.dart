import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  Layer moving(String id, double from, double to) => createLayer('rect')
    ..id = id
    ..durationFrames = 100
    ..transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [from, 0.5]),
      Keyframe(frame: 100, value: [to, 0.5]),
    ]);

  test('a child is blurred by its parent\'s motion only', () {
    final parent = moving('p', 0.2, 0.8)..motionBlur = MotionBlur(enabled: true, samples: 4);
    final child = moving('c', 0.0, 0.3)..parentId = 'p';
    final still = createLayer('rect')
      ..id = 's'
      ..motionBlur = MotionBlur(enabled: true, samples: 4);
    final child2 = moving('c2', 0.0, 0.3)..parentId = 's';
    final p = Project(layers: [parent, child, still, child2]);
    expect(blurringAncestor(p, child, 50)?.id, 'p');
    double dx(Layer l) => inheritedBlurMatrix(p, l, 51, 50)[4] - inheritedBlurMatrix(p, l, 50, 50)[4];
    // the parent moves 0.006 of the stage a frame; the child's own 0.003
    // a frame is held still.
    expect(dx(child), closeTo(0.006, 1e-9));
    expect(dx(child2), closeTo(0, 1e-12), reason: 'a still parent leaves a moving child sharp');
    expect(inheritedBlurMatrix(p, child, 50, 50), getLayerStateAt(p, 'c', 50).matrix);
  });

  test('no ancestor with blur, or the blur outside its time range: none', () {
    final parent = moving('p', 0.2, 0.8)..motionBlur = MotionBlur(enabled: true, samples: 4);
    final child = moving('c', 0, 0.3)..parentId = 'p';
    final p = Project(layers: [parent, child]);
    setEffectRange(parent, 'motionBlur', 0, 10);
    expect(blurringAncestor(p, child, 50), isNull);
    expect(blurringAncestor(p, parent, 5), isNull);
  });
}
