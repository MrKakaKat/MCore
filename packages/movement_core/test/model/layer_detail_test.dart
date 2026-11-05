import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  test('an effect acts only inside its own time range', () {
    final l = createLayer('rect')
      ..id = 'a'
      ..durationFrames = 100;
    l.wiggle = Wiggle(enabled: true, amplitude: 50);
    final p = Project(layers: [l]);
    expect(effectSpans(l).single.end, 100, reason: 'the whole layer by default');
    setEffectRange(l, 'wiggle', 40, 60);
    expect(l.effectRanges['wiggle'], [40, 60]);
    clearStateCaches();
    final still = getLayerStateAt(p, 'a', 10).anchor;
    expect(still, l.transform.anchor.defaultValue, reason: 'no wiggle before its range');
    expect(effectActiveAt(l, 'wiggle', 50), isTrue);
    setEffectRange(l, 'wiggle', -5, 500);
    expect(l.effectRanges.containsKey('wiggle'), isFalse, reason: 'the whole layer again');
    setEffectRange(l, 'wiggle', 30, 30);
    expect(l.effectRanges['wiggle'], [30, 31], reason: 'at least one frame');
  });

  test('ranges are saved, cloned and follow pasted effects', () {
    final l = createLayer('rect')..durationFrames = 100;
    l.effectStack.add(EffectInstance(id: 'fx1', effectId: 'twist'));
    setEffectRange(l, 'fx1', 10, 20);
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.effectRanges['fx1'], [10, 20]);
    expect(cloneLayer(l).effectRanges['fx1'], [10, 20]);
    final target = createLayer('rect');
    applyLayerParamsJson(Project(layers: [target]), target, layerParamsToJson(l));
    expect(target.effectRanges[target.effectStack.single.id], [10, 20]);
  });

  test('expanded keys: a row per tab, and a line deletes both its keys', () {
    final l = createLayer('rect');
    l.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 90.0)]);
    l.masks.add(Mask()..feather.keyframes.add(Keyframe(frame: 5, value: 2.0)));
    final rows = keyDetailRows(l);
    expect(rows.keys, ['Movement', 'Masks']);
    expect(rows['Movement'], [0, 10]);
    deleteKeyDetailSpan(l, 'Movement', 0, 10);
    expect(l.transform.rotation.keyframes, isEmpty);
    expect(l.masks.single.feather.keyframes, hasLength(1), reason: 'other tabs untouched');
  });

  test('key lines are per parameter: movement A..D and rotation B..C, never A..B or C..D', () {
    final l = createLayer('rect')..durationFrames = 100;
    l.transform.anchor.keyframes
      ..add(Keyframe(frame: 0, value: [0.1, 0.5]))
      ..add(Keyframe(frame: 90, value: [0.9, 0.5]));
    l.transform.rotation.keyframes
      ..add(Keyframe(frame: 30, value: 0.0))
      ..add(Keyframe(frame: 60, value: 90.0));
    final spans = keyDetailSpans(l)['Movement']!;
    expect([for (final s in spans) '${s.a}-${s.b}']..sort(), ['0-90', '30-60']);
    // deleting the rotation's line leaves the movement's keys.
    final rot = spans.firstWhere((s) => s.a == 30);
    deleteKeyDetailSpan(l, 'Movement', rot.a, rot.b, track: rot.track);
    expect(l.transform.rotation.keyframes, isEmpty);
    expect(l.transform.anchor.keyframes, hasLength(2));
  });
}
