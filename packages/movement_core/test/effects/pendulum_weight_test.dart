import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  Layer swinging() {
    final l = createLayer('rect')
      ..id = 'p'
      ..durationFrames = 60
      ..content.offset = [0, 0]
      ..content.size = [40, 40];
    l.pendulum = Pendulum(enabled: true, pivotOffset: track([0.0, -20.0], true));
    l.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.2, 0.5]),
      Keyframe(frame: 20, value: [0.8, 0.5]),
    ]);
    return l;
  }

  test('the weight decides the lever: under the grip it swings, beside it on the same line it does not', () {
    final l = swinging();
    final p = Project(layers: [l]);
    expect(pendulumWeightPoint(l), [0.0, 0.0], reason: 'the middle of the content by default');
    l.pendulum.weightPoint = [0, 20]; // straight below the grip
    clearStateCaches();
    final hanging = evaluatePendulumOffset(p, l, 15).abs();
    // a weight level with the grip, along the motion: no sideways push.
    l.pendulum.weightPoint = [30, -20];
    clearStateCaches();
    final level = evaluatePendulumOffset(p, l, 15).abs();
    expect(hanging, greaterThan(level * 3));
  });

  test('the weight drag moves it, and it is saved and cloned', () {
    final l = swinging();
    final p = Project(layers: [l]);
    final h = getPendulumWeightHandleScreen(p, l, 0);
    final op = PendulumWeightDragOp.grab(p, l, 0, h.screen);
    op.apply(p, 0, [h.screen[0] + 10, h.screen[1]]);
    expect(l.pendulum.weightPoint![0], closeTo(10, 1e-6));
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.pendulum.weightPoint, l.pendulum.weightPoint);
    expect(cloneLayer(l).pendulum.weightPoint, l.pendulum.weightPoint);
  });
}
