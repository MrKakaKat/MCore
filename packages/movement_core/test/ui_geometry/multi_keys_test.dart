import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('an ordinary key made a multi-key: every parameter keyed there, nothing moves there', () {
    activeAnimLayer = 0;
    final l = createLayer('rect')..durationFrames = 60;
    l.transform.rotation.keyframes = [
      Keyframe(frame: 0, value: 0.0),
      Keyframe(frame: 20, value: 90.0),
    ];
    l.transform.scale.keyframes = [
      Keyframe(frame: 0, value: [1.0, 1.0]),
      Keyframe(frame: 40, value: [2.0, 2.0]),
    ];
    final p = Project(layers: [l]);
    final before = [
      evaluateTrack(p, l.transform.scale, 20.0, l),
      evaluateTrack(p, l.transform.anchor, 20.0, l),
      evaluateTrack(p, l.transform.opacity, 20.0, l),
    ];
    expect(allTracksKeyedAt(l, 20), isFalse);
    expect(makeMultiKeys(p, l, [20]), 1);
    expect(allTracksKeyedAt(l, 20), isTrue);
    expect(evaluateTrack(p, l.transform.scale, 20.0, l), before[0]);
    expect(evaluateTrack(p, l.transform.anchor, 20.0, l), before[1]);
    expect(evaluateTrack(p, l.transform.opacity, 20.0, l), before[2]);
    expect(makeMultiKeys(p, l, [20]), 0, reason: 'already one');
  });
}
