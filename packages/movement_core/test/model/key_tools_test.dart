import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(registerBuiltinEffects);

  Layer moving() {
    final l = createLayer('rect')..durationFrames = 100;
    l.transform.rotation.keyframes.addAll([
      Keyframe(frame: 0, value: 0.0),
      Keyframe(frame: 10, value: 90.0),
      Keyframe(frame: 40, value: 0.0),
    ]);
    l.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.2, 0.5]),
      Keyframe(frame: 10, value: [0.8, 0.5]),
    ]);
    return l;
  }

  test('picked keys repeat as keys; later keys move on; the layer grows', () {
    final l = moving();
    final p = Project(layers: [l]);
    final added = repeatPickedKeys(l, {0, 10}, 2);
    expect(added, 22);
    expect(l.transform.rotation.keyframes.map((k) => k.frame), [0, 10, 11, 21, 22, 32, 62]);
    expect(l.transform.rotation.keyframes.map((k) => k.value), [0.0, 90.0, 0.0, 90.0, 0.0, 90.0, 0.0]);
    expect(evaluateTrack(p, l.transform.anchor, 16, l), [closeTo(0.5, 1e-9), closeTo(0.5, 1e-9)]);
    expect(l.durationFrames, 122);
  });

  test('picked last keys loop for real, from the first of them', () {
    final l = moving();
    expect(pickedKeysEndLast(l, {0, 10}), isFalse, reason: 'rotation goes on after them');
    expect(loopPickedKeys(l, {0, 10}), isFalse);
    expect(pickedKeysEndLast(l, {10, 40}), isTrue);
    expect(loopPickedKeys(l, {10, 40}), isTrue);
    final r = l.transform.rotation;
    expect([r.loop, r.loopFrom], [true, 10]);
    expect(evaluateTrack(Project(layers: [l]), r, 70, l), closeTo(90, 1e-6), reason: 'past its last key: from the first picked again');
  });

  test('base keys into an animation layer: the object stays where it was', () {
    final l = moving();
    final p = Project(layers: [l]);
    final before = [for (final f in [0, 10, 40]) evaluateTrack(p, l.transform.rotation, f.toDouble(), l) as double];
    final n = movePickedKeysToAnimLayer(p, l, {10}, null);
    expect(n, 1);
    expect(l.transform.rotation.keyframes.map((k) => k.frame), [0, 40]);
    expect(l.transform.rotation.animLayers.single.track.keyframes.map((k) => k.frame), [10]);
    final after = [for (final f in [0, 10, 40]) evaluateTrack(p, l.transform.rotation, f.toDouble(), l) as double];
    expect(after[1], closeTo(before[1], 1e-9));
    final a10 = evaluateTrack(p, l.transform.anchor, 10, l) as List;
    expect(a10, [closeTo(0.8, 1e-9), closeTo(0.5, 1e-9)]);
  });

  test('take from another layer: its keys come in, its own stay; set values stay', () {
    final src = moving()..motionBlur.enabled = true;
    src.transform.opacity.defaultValue = 0.5;
    src.effectStack.add(EffectInstance(id: 'w', effectId: 'wave', params: {}));
    final dst = createLayer('rect');
    dst.transform.rotation.keyframes.addAll([Keyframe(frame: 10, value: 45.0), Keyframe(frame: 50, value: 0.0)]);
    dst.transform.scale.defaultValue = [2.0, 2.0];
    final n = takeParamsFrom(dst, src, newId: () => 'new');
    expect(n, greaterThan(0));
    expect(dst.transform.rotation.keyframes.map((k) => '${k.frame}:${k.value}'), ['0:0.0', '10:45.0', '40:0.0', '50:0.0'],
        reason: 'its own key at 10 stays');
    expect(dst.transform.anchor.keyframes.length, 2);
    expect(dst.transform.opacity.defaultValue, 0.5, reason: 'not set here: taken');
    expect(dst.transform.scale.defaultValue, [2.0, 2.0], reason: 'set here: kept');
    expect(dst.motionBlur.enabled, isTrue);
    expect(dst.effectStack.single.id, 'new');
  });
}
