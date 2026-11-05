import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer({int startFrame = 0}) {
  return Layer(
    id: 'L_test',
    name: 'test',
    startFrame: startFrame,
    parentId: null,
    transform: Transform(
        anchor: track([0.5, 0.5], true),
        scale: track([1.0, 1.0]),
        rotation: track(0.0),
        opacity: track(1.0)),
    content: Content(shape: 'rect', offset: [0, 0], size: [46, 46]),
  );
}

void main() {
  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
  });

  group('collectLayerKeyframeFrames', () {
    test(
        'collects across anchor, rotation, mesh-warp effect params, and mask feather - as GLOBAL frames, sorted, deduplicated',
        () {
      final layer = _layer(startFrame: 100);
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 5, value: [0.1, 0.1]),
        Keyframe(frame: 20, value: [0.2, 0.2])
      ]);
      layer.transform.rotation.keyframes.add(Keyframe(
          frame: 5,
          value:
              10.0)); // same local frame as an anchor key - must not duplicate in the result
      layer.masks.add(Mask(feather: track(0.0)));
      layer.masks[0].feather.keyframes.add(Keyframe(frame: 12, value: 3.0));
      final inst = createEffectInstance('mesh_warp', 'fx1', layer);
      layer.effectStack.add(inst);
      final pinTrack = inst.params.values.whereType<Track>().first;
      pinTrack.keyframes.add(Keyframe(frame: 30, value: [0.0, 0.0]));

      final frames = collectLayerKeyframeFrames(layer);
      expect(
          frames,
          equals([
            105,
            112,
            120,
            130
          ])); // 5,12,20,30 + startFrame 100, sorted, no duplicate for the shared frame 5
    });

    test('an empty/default layer (no keyframes anywhere) collects nothing', () {
      expect(collectLayerKeyframeFrames(_layer()), isEmpty);
    });
  });

  group('collectVisibleLayerKeyframeFrames', () {
    test(
        'a hidden track\'s keyframes are excluded, but an untouched track\'s own frames still appear',
        () {
      final layer = _layer(startFrame: 100);
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 5, value: [0.1, 0.1]),
        Keyframe(frame: 20, value: [0.2, 0.2])
      ]);
      layer.transform.rotation.keyframes.add(Keyframe(frame: 5, value: 10.0));
      layer.transform.anchor.hidden = true;

      final frames = collectVisibleLayerKeyframeFrames(layer);
      expect(
          frames,
          equals([
            105
          ])); // only rotation's frame 5+100 - anchor's 105/120 excluded

      // unhiding restores it, and the DATA-layer function is untouched
      // by hidden at all either way - a display-only flag never affects
      // what copy/paste or any other data operation sees.
      layer.transform.anchor.hidden = false;
      expect(collectVisibleLayerKeyframeFrames(layer), equals([105, 120]));
      expect(collectLayerKeyframeFrames(layer), equals([105, 120]));
      layer.transform.anchor.hidden = true;
      expect(collectLayerKeyframeFrames(layer), equals([105, 120]),
          reason:
              'collectLayerKeyframeFrames must never consult the hidden flag');
    });
  });

  group('collectKeyframesAtFrames', () {
    test(
        'returns exactly the keyframe objects (with owning track) at the given LOCAL frames - nothing from other frames',
        () {
      final layer = _layer();
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 5, value: [0.1, 0.1]),
        Keyframe(frame: 20, value: [0.2, 0.2])
      ]);
      layer.transform.rotation.keyframes.add(Keyframe(frame: 5, value: 10.0));

      final items = collectKeyframesAtFrames(layer, {5});
      expect(items.length, equals(2));
      expect(items.map((it) => it.keyframe.frame), everyElement(equals(5)));
      expect(items.map((it) => it.track),
          containsAll([layer.transform.anchor, layer.transform.rotation]));
    });
  });

  group('copy/paste', () {
    test(
        'paste preserves the group\'s internal frame spacing relative to where you paste, and deep-copies values/tangents (not aliased)',
        () {
      final layer = _layer();
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 10, value: [0.3, 0.3])
      ]);
      layer.transform.rotation.keyframes.addAll([
        Keyframe(frame: 14, value: 45.0)
      ]); // 4 frames after the anchor key - spacing must survive the paste

      copySelectedKeyframes(layer, {10, 14});
      // mutate the ORIGINAL after copying - paste must not reflect this, proving the clipboard deep-copied rather than aliased the value list.
      (layer.transform.anchor.keyframes.first.value as List<double>)[0] = 999.0;

      final newSelection =
          pasteKeyframes(layer, 100); // paste at global frame 100
      expect(newSelection,
          equals({100, 104})); // 100 (min) and 100+4 (spacing preserved)

      final pastedAnchor =
          layer.transform.anchor.keyframes.firstWhere((k) => k.frame == 100);
      expect((pastedAnchor.value as List<double>)[0], equals(0.3),
          reason:
              'must be the value at COPY time, not corrupted by the later mutation of the original');
      final pastedRotation =
          layer.transform.rotation.keyframes.firstWhere((k) => k.frame == 104);
      expect(pastedRotation.value, equals(45.0));
    });

    test(
        'pasting onto an EXISTING keyframe at the target frame overwrites its value/temporal/tangent in place, not a duplicate',
        () {
      final layer = _layer();
      layer.transform.rotation.keyframes.add(Keyframe(
          frame: 10,
          value:
              45.0)); // the copy SOURCE - stays untouched by copying, remains in the track throughout
      copySelectedKeyframes(layer, {10});

      layer.transform.rotation.keyframes.add(Keyframe(
          frame: 50,
          value:
              0.0)); // pre-existing keyframe sitting exactly where the paste will land
      pasteKeyframes(layer, 50);

      expect(layer.transform.rotation.keyframes.length, equals(2),
          reason:
              'the frame-10 copy source is untouched; only the frame-50 target gets overwritten, not duplicated into a 3rd entry');
      expect(
          layer.transform.rotation.keyframes.where((k) => k.frame == 50).length,
          equals(1),
          reason: 'overwritten in place, not duplicated');
      expect(
          layer.transform.rotation.keyframes
              .firstWhere((k) => k.frame == 50)
              .value,
          equals(45.0));
    });
  });

  group('KeyframeGroupDragOp', () {
    test(
        'moves every keyframe in the selected group by the same delta, across multiple tracks, and re-sorts affected tracks',
        () {
      final layer = _layer();
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 10, value: [0.1, 0.1]),
        Keyframe(frame: 30, value: [0.3, 0.3])
      ]);
      layer.transform.rotation.keyframes.add(Keyframe(frame: 10, value: 5.0));

      final op = KeyframeGroupDragOp.grab(
          layer, {10}, 10); // grab the frame-10 group, origin = frame 10
      final newSelection =
          op.apply(layer, 25); // dragged to frame 25 -> delta +15

      expect(newSelection, equals({25}));
      expect(
          layer.transform.anchor.keyframes.map((k) => k.frame),
          containsAll(
              [25, 30])); // the OTHER anchor key (frame 30) is untouched
      expect(layer.transform.rotation.keyframes.first.frame, equals(25));
      // re-sorted: since anchor now has keys at 25 and 30, order must stay ascending
      expect(layer.transform.anchor.keyframes.map((k) => k.frame).toList(),
          equals([25, 30]));
    });

    test(
        'clamps so no keyframe\'s LOCAL frame goes negative, matching JS\'s own scrub-input clamp',
        () {
      final layer = _layer();
      layer.transform.rotation.keyframes.add(Keyframe(frame: 5, value: 1.0));

      final op = KeyframeGroupDragOp.grab(layer, {5}, 5);
      final newSelection = op.apply(layer, -50); // huge negative delta

      expect(layer.transform.rotation.keyframes.first.frame, equals(0));
      expect(newSelection, equals({0}));
    });

    test(
        'respects a non-zero layer.startFrame throughout (grab/apply both work in GLOBAL frames)',
        () {
      final layer = _layer(startFrame: 200);
      layer.transform.rotation.keyframes
          .add(Keyframe(frame: 10, value: 1.0)); // LOCAL frame 10 -> global 210

      final op = KeyframeGroupDragOp.grab(layer, {210}, 210);
      final newSelection = op.apply(layer, 220); // global 220 -> local 20

      expect(layer.transform.rotation.keyframes.first.frame, equals(20));
      expect(newSelection, equals({220}));
    });
  });
}
