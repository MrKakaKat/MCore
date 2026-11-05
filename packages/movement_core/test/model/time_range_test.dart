import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => fps = 60);

  Layer at(String id, int start, int dur) => createLayer('rect')
    ..id = id
    ..startFrame = start
    ..durationFrames = dur;

  test('range actions touch only the layers in it', () {
    final a = at('a', 0, 20), b = at('b', 30, 40), c = at('c', 100, 10);
    b.transform.rotation.keyframes.addAll([Keyframe(frame: 5, value: 0.0), Keyframe(frame: 30, value: 1.0)]);
    final p = Project(layers: [a, b, c]);
    expect(layersInRange(p, 25, 60).map((l) => l.id), ['b']);
    shiftLayersInRange(p, 25, 60, 10);
    expect([a.startFrame, b.startFrame, c.startFrame], [0, 40, 100]);
    expect(deleteKeysInRange(p, 40, 50), 1, reason: 'the key at 45');
    trimLayersToRange(p, 50, 70);
    expect([b.startFrame, b.durationFrames], [50, 20]);
    expect(b.transform.rotation.keyframes.single.frame, 20, reason: 'stays at global 70');
  });

  test('selected keys move to the same parameters of another layer, same moments', () {
    final a = at('a', 0, 100), b = at('b', 20, 100);
    a.transform.rotation.keyframes.addAll([Keyframe(frame: 30, value: 5.0), Keyframe(frame: 60, value: 9.0)]);
    a.transform.opacity.keyframes.add(Keyframe(frame: 30, value: 0.5));
    expect(moveKeysToLayer(a, b, {30}), 2);
    expect(a.transform.rotation.keyframes.single.frame, 60);
    expect(b.transform.rotation.keyframes.single.frame, 10);
    expect(b.transform.opacity.keyframes.single.value, 0.5);
  });
}
