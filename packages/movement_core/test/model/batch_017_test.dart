import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/effects/builtins/origami_fold.dart' show origamiResolved;
import 'package:movement_core/effects/builtins/rotate_3d.dart' show rotate3dGrid;
import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _rect(String id) => createLayer('rect')..id = id;

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    registerBuiltinEffects();
  });

  group('loops', () {
    Track shrink() => Track([1.0, 1.0])
      ..keyframes = [
        Keyframe(frame: 0, value: [1.0, 1.0], temporal: easingPresets['linear']),
        Keyframe(frame: 10, value: [0.9, 0.9], temporal: easingPresets['linear']),
      ];

    test('offset: each pass goes on from the last; it stops before going below 0', () {
      final t = shrink();
      setTrackLoop(t, 'scale', on: true, mode: 'offset');
      expect(t.loopMin, 0);
      double at(double f) => (evaluateTrack(null, t, f) as List<double>)[0];
      expect(at(15), closeTo(0.85, 1e-9));
      expect(at(20), closeTo(0.8, 1e-9));
      expect(loopOffsetPasses(t), 9);
      expect(loopStopFrame(t), 100);
      expect(at(95), closeTo(0.05, 1e-9));
      expect(at(100), closeTo(0.0, 1e-9));
      expect(at(250), closeTo(0.0, 1e-9), reason: 'held where it stopped');
      final back = trackFromJson(jsonDecode(jsonEncode(trackToJson(t))) as Map<String, dynamic>);
      expect([back.loopMode, back.loopMin], ['offset', 0]);
    });

    test('repeat: back to the start each pass; a position never stops', () {
      final t = shrink();
      setTrackLoop(t, 'scale', on: true);
      expect((evaluateTrack(null, t, 15.0) as List<double>)[0], closeTo(0.95, 1e-9));
      final a = Track([0.0, 0.0])
        ..keyframes = [
          Keyframe(frame: 0, value: [0.0, 0.0]),
          Keyframe(frame: 10, value: [-0.1, 0.0]),
        ];
      setTrackLoop(a, 'anchor', on: true, mode: 'offset');
      expect(loopOffsetPasses(a), isNull);
      expect((evaluateTrack(null, a, 210.0) as List<double>)[0], closeTo(-2.1, 1e-9));
    });

    test('the layer shows where it stops; the rows show the passes to come', () {
      final l = _rect('A')..durationFrames = 60;
      l.transform.scale = shrink();
      setTrackLoop(l.transform.scale, 'scale', on: true, mode: 'offset');
      l.transform.scale.keyframes.last.value = [0.5, 0.5]; // 1 -> 0.5: one more pass to 0
      expect(layerLoopStops(l), [20]);
      final ghosts = keyDetailLoopGhosts(l)['Movement']!;
      expect(ghosts.keys, [20]);
      expect(ghosts.spans, [(10, 20)]);
      // a position goes on to the layer's end.
      l.transform.anchor.keyframes = [
        Keyframe(frame: 0, value: [0.0, 0.0]),
        Keyframe(frame: 20, value: [0.1, 0.0]),
      ];
      setTrackLoop(l.transform.anchor, 'anchor', on: true);
      final g2 = keyDetailLoopGhosts(l)['Movement']!;
      expect(g2.keys, containsAll([40, 60]));
    });
  });

  group('free move points', () {
    test('the way\'s own points are passive: faint on the line, not in the rows', () {
      final l = _rect('A')..durationFrames = 60;
      final p = Project(layers: [l]);
      final path = [
        for (var i = 0; i <= 60; i++) [100.0 + 5 * i, 300 + 60 * math.sin(i / 8)]
      ];
      addFreeMoveLayer(p, l, path, 0, 48, smoothing: 0);
      final trk = l.transform.anchor.animLayers.single.track;
      expect(trk.keyframes.first.passive, isFalse);
      expect(trk.keyframes.last.passive, isFalse);
      expect(trk.keyframes.where((k) => k.passive), isNotEmpty);
      expect(collectVisibleLayerKeyframeFrames(l), [0, 48]);
      expect(collectPassiveLayerKeyframeFrames(l), isNotEmpty);
      expect(keyDetailRows(l)['Layer 1'], [0, 48]);
      final back = keyframeFromJson(jsonDecode(jsonEncode(keyframeToJson(trk.keyframes[1]))) as Map<String, dynamic>);
      expect(back.passive, isTrue);
    });
  });

  group('split', () {
    test('a key layer over before the cut leaves no key at the new part\'s start', () {
      final l = _rect('A')..durationFrames = 60;
      final n = addTransformAnimLayer(l);
      l.transform.anchor.animLayers[n - 1].track.keyframes = [
        Keyframe(frame: 0, value: [0.0, 0.0]),
        Keyframe(frame: 10, value: [0.2, 0.0]),
      ];
      final p = Project(layers: [l]);
      final right = splitLayer(p, l, 30, 'B')!;
      final t = right.transform.anchor.animLayers[n - 1].track;
      expect(t.keyframes, isEmpty);
      expect(t.defaultValue, [0.2, 0.0]);
      expect(keyDetailRows(right).containsKey('Layer 1'), isFalse);
    });

    test('a loop goes on in step across the cut (repeat and offset)', () {
      for (final mode in ['repeat', 'offset']) {
        final l = _rect('A')..durationFrames = 100;
        l.transform.rotation.keyframes = [
          Keyframe(frame: 0, value: 0.0, temporal: easingPresets['linear']),
          Keyframe(frame: 10, value: 90.0, temporal: easingPresets['easeIn']),
        ];
        setTrackLoop(l.transform.rotation, 'rotation', on: true, mode: mode);
        final orig = cloneTrack(l.transform.rotation);
        final p = Project(layers: [l]);
        final right = splitLayer(p, l, 37, 'B')!;
        // (off the passes' boundaries: a repeat jumps back there)
        for (final t in [0.0, 2.0, 8.0, 21.0, 40.0]) {
          expect(evaluateTrack(p, right.transform.rotation, t, right) as double,
              closeTo(evaluateTrack(p, orig, 37 + t) as double, 1e-9),
              reason: '$mode at $t');
        }
        for (final t in [0.0, 12.0, 36.0]) {
          expect(evaluateTrack(p, l.transform.rotation, t, l) as double, closeTo(evaluateTrack(p, orig, t) as double, 1e-9));
        }
      }
    });
  });

  group('centre', () {
    test('moved to a corner: the object stays put, it turns round the corner now', () {
      final l = _rect('A')..content.size = [100, 50];
      l.transform.anchor.defaultValue = [0.5, 0.5];
      l.transform.rotation.defaultValue = 30.0;
      final p = Project(layers: [l]);
      List<List<double>> corners() {
        clearStateCaches();
        final m = getTransformBoxHandles(p, l, 0).mCanvas;
        final b = shapeBoundingBox(l.content);
        return [
          for (final c in [
            [b.minX, b.minY],
            [b.maxX, b.maxY]
          ])
            applyAffine(m, c)
        ];
      }

      final before = corners();
      setLayerPivot(p, l, layerBoxPoint(l, 0, 0), 0);
      final after = corners();
      for (var i = 0; i < 2; i++) {
        expect(after[i][0], closeTo(before[i][0], 1e-6));
        expect(after[i][1], closeTo(before[i][1], 1e-6));
      }
      // its position is the corner now.
      final a = l.transform.anchor.defaultValue as List;
      expect((a[0] as num) * 1000, closeTo(before[0][0], 1e-6));
      expect((a[1] as num) * 1000, closeTo(before[0][1], 1e-6));
    });
  });

  group('origami', () {
    EffectInstance origami(Layer l) {
      final inst = createEffectInstance('origami_fold', 'o', l);
      (inst.params['angle'] as Track).defaultValue = 90.0;
      l.effectStack.add(inst);
      return inst;
    }

    test('the bend lies between its own start and end', () {
      final l = _rect('A')..content.size = [200, 100];
      final inst = origami(l);
      final params = resolveEffectParams(inst, 0)
        ..['_box'] = [-100.0, -50.0, 100.0, 50.0]
        ..['bendFrom'] = 10.0
        ..['bendTo'] = 40.0;
      final f = origamiResolved(params, buildGrid(l.content, 2, 2)).first;
      expect(f.s, closeTo(10, 1e-9), reason: 'the crease (the middle) moved to the start');
      expect(f.len, closeTo(30, 1e-9));
    });

    test('with a 3D tilt: cut along the creases (point by point), the tilt round the layer\'s own box', () {
      final l = _rect('A')..content.size = [200, 100];
      origami(l);
      final tilt = createEffectInstance('rotate_3d', 't', l);
      (tilt.params['angle'] as Track).defaultValue = 30.0;
      l.effectStack.add(tilt);
      expect(deformsPointwise(l), isTrue);
      final pieces = origamiRingPieces(l, layerFlatOutline(l), 0);
      expect(pieces, isNotNull);
      expect(pieces!.length, 2);
      for (final r in pieces) {
        for (final q in r) {
          expect(q[0].isFinite && q[1].isFinite, isTrue);
        }
      }
      // the tilt's pivot: the same for a part as for the whole.
      final params = {'angle': 30.0, 'axis': 90.0, 'pivot': [0.5, 0.5], 'perspective': 0.5, '_box': [-100.0, -50.0, 100.0, 50.0]};
      final whole = rotate3dGrid([
        [
          [-100.0, -50.0],
          [100.0, 50.0],
          [60.0, 20.0]
        ]
      ], params, 0);
      final part = rotate3dGrid([
        [
          [60.0, 20.0],
          [80.0, 40.0]
        ]
      ], params, 0);
      expect(part[0][0][0], closeTo(whole[0][2][0], 1e-9));
      expect(part[0][0][1], closeTo(whole[0][2][1], 1e-9));
    });
  });

  test('vignette: on, saved', () {
    final f = LayerFilters()..vignette = Track(0.6, false)..vignetteSize = 0.3;
    expect(f.any, isTrue);
    final back = LayerFilters.fromJson(jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>);
    expect(back.vignette.defaultValue, 0.6);
    expect(back.vignetteSize, 0.3);
  });
}
