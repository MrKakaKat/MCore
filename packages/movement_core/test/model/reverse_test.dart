import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('reversed keys play the animation exactly backwards', () {
    final l = createLayer('rect')..durationFrames = 100;
    final rot = l.transform.rotation;
    rot.keyframes.addAll([
      Keyframe(frame: 10, value: 0.0),
      Keyframe(frame: 40, value: 90.0, temporal: easingPresets['easeIn']),
      Keyframe(frame: 90, value: 30.0, temporal: easingPresets['easeOut']),
    ]);
    final before = [for (var f = 0; f <= 100; f++) evaluateTrack(null, rot, f.toDouble()) as double];
    reverseLayerKeys(l, {'Movement'});
    expect(rot.keyframes.map((k) => k.frame), [10, 60, 90]);
    for (var f = 0; f <= 100; f++) {
      expect(evaluateTrack(null, rot, f.toDouble()) as double, closeTo(before[100 - f], 1e-6), reason: 'frame $f');
    }
    reverseLayerKeys(l, {'Movement'});
    expect(rot.keyframes.map((k) => k.frame), [10, 40, 90], reason: 'twice is the original');
  });

  test('only the chosen tabs; effect ranges mirror with Effects', () {
    final l = createLayer('rect')..durationFrames = 100;
    l.transform.opacity.keyframes.add(Keyframe(frame: 20, value: 1.0));
    l.masks.add(Mask()..feather.keyframes.add(Keyframe(frame: 30, value: 1.0)));
    l.effectRanges['wiggle'] = [10, 30];
    reverseLayerKeys(l, {'Masks', 'Effects'});
    expect(l.transform.opacity.keyframes.single.frame, 20);
    expect(l.masks.single.feather.keyframes.single.frame, 70);
    expect(l.effectRanges['wiggle'], [70, 90]);
  });

  test('a reversed video is saved and cloned', () {
    final l = createLayer('rect')..content.playReversed = true;
    expect(cloneLayer(l).content.playReversed, isTrue);
    expect(layerFromJson(layerToJson(l)).content.playReversed, isTrue);
  });
}
