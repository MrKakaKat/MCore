import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _rect(String id) => createLayer('rect')..id = id;

void main() {
  setUpAll(() {
    registerFont(defaultFontId, File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    editAllKeys = false;
    activeAnimLayer = 0;
  });

  group('free move', () {
    test('a cubic fit goes through the stroke (a quarter circle)', () {
      final pts = [
        for (var i = 0; i <= 40; i++) [100 * math.cos(i / 40 * math.pi / 2), 100 * math.sin(i / 40 * math.pi / 2)]
      ];
      final inner = fitCubicInner(pts);
      // the curve's middle lies on the circle.
      final p0 = pts.first, p3 = pts.last;
      List<double> at(double t) {
        final u = 1 - t;
        return [
          for (var c = 0; c < 2; c++)
            u * u * u * p0[c] + 3 * u * u * t * inner[0][c] + 3 * u * t * t * inner[1][c] + t * t * t * p3[c]
        ];
      }

      final mid = at(0.5);
      expect(math.sqrt(mid[0] * mid[0] + mid[1] * mid[1]), closeTo(100, 1.5));
    });

    test('the path becomes a key layer of two keys, the curve kept, the layer\'s own keys untouched', () {
      final l = _rect('A')..durationFrames = 10;
      l.transform.anchor.defaultValue = [0.1, 0.1];
      final p = Project(layers: [l]);
      // a hump: from (100,100) to (300,100) over (200,0).
      final path = [
        for (var i = 0; i <= 20; i++) [100.0 + 10 * i, 100 - 100 * math.sin(i / 20 * math.pi)]
      ];
      final n = addFreeMoveLayer(p, l, path, 0, 24);
      expect(n, 1);
      final trk = l.transform.anchor.animLayers.single.track;
      expect(trk.spatial, isTrue);
      expect(trk.keyframes.map((k) => k.frame), [0, 24]);
      expect((trk.keyframes.last.value as List)[0], closeTo(0.2, 1e-9));
      expect(l.durationFrames, 24, reason: 'its time reaches the second key');
      expect(l.transform.anchor.keyframes, isEmpty);
      // the middle of the move rises (a curve, not the straight line).
      final mid = evaluateTrack(p, l.transform.anchor, 12.0, l) as List<double>;
      expect(mid[1], lessThan(0.1 - 0.03));
      final end = evaluateTrack(p, l.transform.anchor, 24.0, l) as List<double>;
      expect(end[0], closeTo(0.3, 1e-9));
      expect(end[1], closeTo(0.1, 1e-9));
    });

    test('no movement: nothing is made', () {
      final l = _rect('A');
      final p = Project(layers: [l]);
      expect(addFreeMoveLayer(p, l, [[5, 5], [5, 5]], 0, 24), 0);
      expect(l.transform.anchor.animLayers, isEmpty);
    });
  });

  group('edit the whole object', () {
    test('an edit moves every key alike; the animation keeps its shape; saved', () {
      final l = _rect('A');
      final s = l.transform.scale
        ..keyframes = [
          Keyframe(frame: 0, value: [1.0, 1.0]),
          Keyframe(frame: 10, value: [2.0, 2.0]),
        ];
      editAllKeys = true;
      // between the keys (no key here): still changes the whole object.
      setTrackValueAt(s, 5, [2.0, 1.5]);
      expect(s.keyframes.map((k) => k.value), [
        [1.5, 1.0],
        [2.5, 2.0]
      ]);
      editAllKeys = false;
      setTrackValueAt(s, 10, [3.0, 3.0]);
      expect(s.keyframes.first.value, [1.5, 1.0], reason: 'off: one key as before');
      l.editAll = true;
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
      expect(back.editAll, isTrue);
      expect(cloneLayer(l).editAll, isTrue);
    });

    test('a parameter without keys is set as usual', () {
      final l = _rect('A');
      editAllKeys = true;
      setTrackValueAt(l.transform.rotation, 3, 45.0);
      expect(l.transform.rotation.defaultValue, 45.0);
    });
  });

  group('path on the timeline', () {
    Track path() => Track([0.0, 0.0], true)
      ..keyframes = [
        Keyframe(frame: 0, value: [0.0, 0.0], temporal: easingPresets['easeIn']),
        Keyframe(frame: 10, value: [1.0, 0.0], temporal: easingPresets['easeOut']),
        Keyframe(
            frame: 20,
            value: [1.0, 1.0],
            temporal: easingPresets['linear'],
            spatialTangent: SpatialTangent(inTan: [0.2, 0], outTan: [0, 0])),
      ];

    test('turned and sized round its middle: places and curve handles, times and eases kept', () {
      final t = path();
      // in a 100 x 100 space: a quarter turn.
      final c = pathMiddle(t, 0, 20);
      turnPathKeys(t, 0, 20, degrees: 90, w: 100, h: 100);
      expect(pathMiddle(t, 0, 20)[0], closeTo(c[0], 1e-9), reason: 'its middle stays');
      // (0,0) is (-2/3,-1/3) from the middle (2/3,1/3): turned, (1/3,-2/3).
      final v = t.keyframes.first.value as List;
      expect(v[0], closeTo(c[0] + 1 / 3, 1e-9));
      expect(v[1], closeTo(c[1] - 2 / 3, 1e-9));
      expect(t.keyframes.map((k) => k.frame), [0, 10, 20]);
      expect(t.keyframes[1].temporal, easingPresets['easeOut']);
      final tan = t.keyframes.last.spatialTangent.inTan;
      expect(tan[0], closeTo(0, 1e-9));
      expect(tan[1], closeTo(0.2, 1e-9), reason: 'the handle turns with it');
      turnPathKeys(t, 0, 20, k: 2, w: 100, h: 100);
      final v2 = t.keyframes.first.value as List;
      expect(v2[0], closeTo(c[0] + 2 / 3, 1e-9), reason: 'twice as far from the middle');
    });

    test('only the keys of the line; moved as a whole', () {
      final t = path();
      turnPathKeys(t, 10, 20, degrees: 180, w: 100, h: 100);
      expect(t.keyframes.first.value, [0.0, 0.0], reason: 'outside the line: untouched');
      expect(t.keyframes[1].value[0], closeTo(1.0, 1e-9));
      expect(t.keyframes[1].value[1], closeTo(1.0, 1e-9));
      shiftPathKeys(t, 0, 20, [0.5, -0.5]);
      expect(t.keyframes.first.value, [0.5, -0.5]);
      expect(hasPathIn(t, 0, 5), isFalse);
      final l = _rect('A');
      expect(spanPositionTrack(l, 'Movement'), same(l.transform.anchor));
      expect(spanPositionTrack(l, 'Layer 1'), isNull);
      addTransformAnimLayer(l);
      expect(spanPositionTrack(l, 'Layer 1'), same(l.transform.anchor.animLayers.first.track));
    });
  });

  group('along a path', () {
    test('along an open line from its start to its end; round a shape\'s outline', () {
      final line = createLayer('line')..id = 'L';
      line.content.lineNodes = [LineNode(-100, 0), LineNode(100, 0)];
      line.transform.anchor.defaultValue = [0.5, 0.5];
      final mover = _rect('M');
      addMotionPanelEntry(mover, 'path');
      expect(effectPanelEntries(mover), contains('path'));
      mover.transform.pathFollow.sourceLayerId = 'L';
      final p = Project(layers: [line, mover]);
      final d = mover.durationFrames;
      List<double> at(int f) {
        clearStateCaches();
        return getLayerStateAt(p, 'M', f).matrix.sublist(4).map((v) => v * 1000).toList();
      }

      expect(at(0)[0], closeTo(400, 1));
      expect(at(d)[0], closeTo(600, 1), reason: 'an open line: its end, not back to the start');
      expect(at(d ~/ 2)[0], closeTo(500, 2));
      removeMotionPanelEntry(mover, 'path');
      expect(mover.transform.pathFollow.enabled, isFalse);
    });
  });

  group('text', () {
    test('words and letters as pieces', () {
      expect(textPieces('Hi  there\nyou', 'word'), [(0, 2), (4, 9), (10, 13)]);
      expect(textPieces('a b', 'char'), [(0, 1), (2, 3)]);
    });

    test('separated into layers: each where its letters were', () {
      final text = createTextLayer(text: 'AB CD', fontSize: 60)..id = 'T';
      text.transform.anchor.defaultValue = [0.5, 0.5];
      final p = Project(layers: [text]);
      final full = textLetterFrameBoxes(p, text, 0)!;
      final made = splitTextIntoLayers(p, text, 'word', 0);
      expect(made, hasLength(2));
      expect(p.layers, made, reason: 'the text is replaced');
      expect(made.map((l) => l.content.text!.text), ['AB', 'CD']);
      final pieces = [for (final l in made) ...textLetterFrameBoxes(p, l, 0)!];
      expect(pieces, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(pieces[i].minX, closeTo(full[i].minX, 0.5));
        expect(pieces[i].minY, closeTo(full[i].minY, 0.5));
      }
      expect(made.first.id, isNot(made.last.id));
    });

    test('letter snapping: a "T" lands in the "T" of "Text"', () {
      final word = createTextLayer(text: 'Text', fontSize: 80)..id = 'W';
      word.transform.anchor.defaultValue = [0.5, 0.5];
      final t = createTextLayer(text: 'T', fontSize: 80)..id = 'T';
      final p = Project(layers: [word, t]);
      final target = textLetterFrameBoxes(p, word, 0)!.first;
      final own = textLetterFrameBoxes(p, t, 0)!.single;
      // dragged to 4 px off the T's middle.
      final tc = [(target.minX + target.maxX) / 2 + 4, (target.minY + target.maxY) / 2 - 3];
      final oc = [(own.minX + own.maxX) / 2, (own.minY + own.maxY) / 2];
      final a = t.transform.anchor.defaultValue as List<double>;
      final newLocal = [a[0] + (tc[0] - oc[0]) / 1000, a[1] + (tc[1] - oc[1]) / 1000];
      final saved = (snapEnabled, snapCenterToCenterEnabled, snapEdgeToEdgeEnabled);
      snapEnabled = true;
      snapCenterToCenterEnabled = false;
      snapEdgeToEdgeEnabled = false;
      final r = computeAnchorSnap(project: p, layer: t, globalFrame: 0, newLocal: newLocal);
      snapEnabled = saved.$1;
      snapCenterToCenterEnabled = saved.$2;
      snapEdgeToEdgeEnabled = saved.$3;
      expect(r.newLocal[0], closeTo(newLocal[0] - 4 / 1000, 1e-6));
      expect(r.newLocal[1], closeTo(newLocal[1] + 3 / 1000, 1e-6));
      expect(r.guides.map((g) => g.category).toSet(), {SnapCategory.textLetter});
    });

    test('a part\'s size: the others stay in place; from its middle', () {
      final spec = TextSpec(text: 'abc', fontSize: 40);
      final plain = layoutText(spec, const [0, 0], const [1000, 1000]);
      spec.spans.add(TextStyleSpan(1, 2, size: 2)..sizeKeepsOthers = true);
      final kept = layoutText(spec, const [0, 0], const [1000, 1000]);
      expect(kept.glyphs[2].x, closeTo(plain.glyphs[2].x, 1e-6), reason: 'the next letter did not move');
      expect(kept.glyphs[1].fontSize, 80);
      final grown = (kept.glyphs[1].x + kept.glyphs[1].advance / 2) - (plain.glyphs[1].x + plain.glyphs[1].advance / 2);
      expect(grown.abs(), lessThan(1e-6), reason: 'round its own middle');
      spec.spans.single.sizeFromMiddle = true;
      final mid = layoutText(spec, const [0, 0], const [1000, 1000]);
      expect(mid.glyphs[1].baseline, greaterThan(kept.glyphs[1].baseline), reason: 'it reaches below the line');
      final back = textSpecFromJson(jsonDecode(jsonEncode(textSpecToJson(spec))) as Map<String, dynamic>);
      expect(back.spans.single.sizeKeepsOthers, isTrue);
      expect(back.spans.single.sizeFromMiddle, isTrue);
    });
  });

  test('grid snapping pulls the middle onto a grid line', () {
    final saved = (snapEnabled, snapGridEnabled, snapGridCols, snapGridRows, snapGridFrameRadius, gridLineKinds);
    snapEnabled = true;
    snapGridEnabled = true;
    snapGridCols = 4;
    snapGridRows = 4;
    snapGridFrameRadius = 8;
    gridLineKinds = 3;
    final l = _rect('A')..content.size = [100, 100];
    final p = Project(layers: [l]);
    // its middle 5 px right of the line x = 250 (edges far from lines).
    final r = computeAnchorSnap(project: p, layer: l, globalFrame: 0, newLocal: [0.255, 0.62]);
    snapEnabled = saved.$1;
    snapGridEnabled = saved.$2;
    snapGridCols = saved.$3;
    snapGridRows = saved.$4;
    snapGridFrameRadius = saved.$5;
    gridLineKinds = saved.$6;
    expect(r.newLocal[0], closeTo(0.25, 1e-9));
  });

  test('a trail point: a box to move and size only, a fifth of the stage', () {
    final t = createTrailLayer();
    expect(isNullLikeShape(t.content.shape), isTrue);
    expect(t.content.size[0], closeTo(200, 1e-9));
  });
}
