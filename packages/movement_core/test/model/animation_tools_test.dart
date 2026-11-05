import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer({String id = 'L_a'}) => Layer(
      id: id,
      name: id,
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [40, 20]),
    );

void main() {
  setUpAll(registerBuiltinEffects);

  group('reverse keys', () {
    test('mirrors the cluster after its last key and plays every segment backwards', () {
      final l = _layer();
      final rot = l.transform.rotation;
      const easeIn = Easing(0.42, 0, 1, 1);
      rot.keyframes.addAll([
        Keyframe(frame: 10, value: 0.0),
        Keyframe(frame: 20, value: 90.0, temporal: easeIn),
        Keyframe(frame: 40, value: 180.0),
      ]);
      final sel = reverseKeyframeCluster(l, {10, 20, 40});
      expect(sel, {60, 70});
      expect([for (final k in rot.keyframes) k.frame], [10, 20, 40, 60, 70]);
      expect([for (final k in rot.keyframes) k.value], [0.0, 90.0, 180.0, 90.0, 0.0]);
      // the 20->40 segment (linear) runs backwards 40->60; 10->20 (easeIn)
      // becomes an ease-out on 60->70.
      expect(rot.keyframes[4].temporal.x1, closeTo(0, 1e-9));
      expect(rot.keyframes[4].temporal.x2, closeTo(0.58, 1e-9));
      // time symmetric about the pivot: value at 40-d == value at 40+d.
      for (final d in [3.0, 7.0, 15.0, 25.0]) {
        expect(evaluateTrack(null, rot, 40 + d), closeTo(evaluateTrack(null, rot, 40 - d) as double, 1e-6));
      }
    });

    test('all tracks share one pivot, and the layer grows to fit', () {
      final l = _layer()..durationFrames = 50;
      l.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 40, value: 10.0)]);
      l.transform.opacity.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 20, value: 1.0)]);
      final sel = reverseKeyframeCluster(l, {0, 20, 40});
      expect(sel, {80, 60});
      expect([for (final k in l.transform.opacity.keyframes) k.frame], [0, 20, 60, 80]);
      expect(l.durationFrames, 80);
    });

    test('nothing selected -> null', () {
      expect(reverseKeyframeCluster(_layer(), {5}), isNull);
    });
  });

  group('animation presets', () {
    test('only keyed tracks; anchor is relative, re-timed to the playhead', () {
      final src = _layer();
      src.transform.anchor.keyframes.addAll([
        Keyframe(frame: 30, value: [0.2, 0.2]),
        Keyframe(frame: 60, value: [0.4, 0.2]),
      ]);
      src.transform.scale.keyframes.add(Keyframe(frame: 45, value: [2.0, 2.0]));
      final preset = jsonDecode(jsonEncode(animationPresetToJson(src))) as Map<String, dynamic>;
      expect((preset['tracks'] as List).map((t) => t['target']), unorderedEquals(['anchor', 'scale']));

      final dst = _layer(id: 'L_b');
      dst.transform.anchor.defaultValue = [0.7, 0.7];
      applyAnimationPreset(Project(layers: [dst]), dst, preset, 10);
      final a = dst.transform.anchor.keyframes;
      expect([for (final k in a) k.frame], [10, 40]);
      expect(a[0].value[0], closeTo(0.7, 1e-9));
      expect(a[1].value[0], closeTo(0.9, 1e-9), reason: 'moved +0.2 from where the object is');
      expect(dst.transform.scale.keyframes.single.frame, 25);
      expect(dst.transform.scale.keyframes.single.value, [2.0, 2.0]);
    });

    test('an animated effect the target lacks is added', () {
      final src = _layer();
      final bend = createEffectInstance('bend_arc', 'b1', src);
      src.effectStack.add(bend);
      (bend.params['angle'] as Track).keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 45.0)]);
      final preset = animationPresetToJson(src);
      final dst = _layer(id: 'L_b');
      applyAnimationPreset(Project(layers: [dst]), dst, preset, 0);
      expect(dst.effectStack.single.effectId, 'bend_arc');
      expect((dst.effectStack.single.params['angle'] as Track).keyframes.length, 2);
    });
  });

  group('time quantize', () {
    test('holds each pose for 60/fps frames, counted from the layer start', () {
      final l = _layer()..startFrame = 3;
      l.timeQuantize = TimeQuantize(enabled: true, fps: 12);
      expect(layerTimeFrame(l, 3), 3);
      expect(layerTimeFrame(l, 7), 3);
      expect(layerTimeFrame(l, 8), 8);
      l.timeQuantize.enabled = false;
      expect(layerTimeFrame(l, 7), 7);
    });

    test('the layer transform steps instead of moving every frame', () {
      final l = _layer();
      l.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 60, value: 60.0)]);
      l.timeQuantize = TimeQuantize(enabled: true, fps: 10);
      final p = Project(layers: [l]);
      clearStateCaches();
      expect(getLayerStateAt(p, l.id, 5).rot, closeTo(0, 1e-9));
      expect(getLayerStateAt(p, l.id, 6).rot, closeTo(6, 1e-9));
      expect(getLayerStateAt(p, l.id, 11).rot, closeTo(6, 1e-9));
    });

    test('is an Effects-list add-on and round-trips through JSON', () {
      final l = _layer();
      addMotionPanelEntry(l, 'timeQuantize');
      expect(effectPanelEntries(l), ['timeQuantize']);
      l.timeQuantize.fps = 8;
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
      expect(back.timeQuantize.enabled, isTrue);
      expect(back.timeQuantize.fps, 8);
    });
  });

  group('copy / paste effect', () {
    test('an instance pastes as a new copy with its own id', () {
      final a = _layer();
      final bend = createEffectInstance('bend_arc', 'b1', a);
      (bend.params['angle'] as Track).defaultValue = 33.0;
      a.effectStack.add(bend);
      final clip = effectEntryToJson(a, 'b1')!;
      final b = _layer(id: 'L_b');
      final id = pasteEffectEntry(b, clip)!;
      expect(id, isNot('b1'));
      expect((b.effectStack.single.params['angle'] as Track).defaultValue, 33.0);
      expect(effectPanelEntries(b), [id]);
    });

    test('a motion add-on replaces that add-on and switches it on', () {
      final a = _layer();
      a.wiggle = Wiggle(enabled: true, speed: 5);
      final clip = effectEntryToJson(a, 'wiggle')!;
      final b = _layer(id: 'L_b');
      expect(pasteEffectEntry(b, clip), 'wiggle');
      expect(b.wiggle.enabled, isTrue);
      expect(b.wiggle.speed, 5);
    });
  });
}
