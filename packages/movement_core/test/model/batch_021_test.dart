import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
  });
  final lin = easingPresets['linear']!;

  test('key rows: a line joins two keys only when something changes between them', () {
    final l = createLayer('rect')..id = 'r';
    l.transform.rotation.keyframes = [
      Keyframe(frame: 0, value: 0.0, temporal: lin),
      Keyframe(frame: 10, value: 0.0, temporal: lin), // held: no line
      Keyframe(frame: 20, value: 45.0, temporal: lin),
    ];
    final spans = keyDetailSpans(l)['Movement']!;
    expect([for (final s in spans) (s.a, s.b)], [(10, 20)]);
    // a path bending between two equal points still moves: a line.
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.5, 0.5], temporal: lin,
          spatialTangent: SpatialTangent(inTan: [0, 0], outTan: [50, 0])),
      Keyframe(frame: 30, value: <double>[0.5, 0.5], temporal: lin),
    ];
    expect(keysChangeBetween(l.transform.anchor, 0, 30), isTrue);
  });

  group('order on the stage', () {
    Layer named(String id) => createLayer('rect')..id = id;

    test('one border: from 5 to 2 it drops behind the three layers at 2, 3, 4 (the list stays); saved', () {
      final ls = [for (var i = 1; i <= 5; i++) named('L$i')]; // the list: L1 at 1 (bottom) .. L5 at 5
      final p = Project(layers: ls);
      final top = ls.last;
      expect(stackPlaceOf(p, top, 0), 5);
      setStackKey(top, 10, 2);
      List<String> bottomUp(int f) => [for (final l in stackOrderAt(p, f)) l.id];
      expect(bottomUp(5), ['L1', 'L2', 'L3', 'L4', 'L5'], reason: 'before its border: its own place');
      expect(bottomUp(10), ['L1', 'L5', 'L2', 'L3', 'L4']);
      expect(stackPlaceOf(p, top, 5), 5);
      expect(stackPlaceOf(p, top, 15), 2);
      expect([for (final l in p.layers) l.id], ['L1', 'L2', 'L3', 'L4', 'L5'], reason: 'the list stays');
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(top))) as Map<String, dynamic>);
      expect([for (final k in back.stackKeys) (k.frame, k.position)], [(10, 2)]);
      expect(cloneLayer(top).stackKeys, hasLength(1));
    });
  });

  test('a link outside its time: the area where the layer would be', () {
    final src = createLayer('rect')
      ..id = 's'
      ..content.size = [10, 10]
      ..transform.anchor.defaultValue = [0.2, 0.2];
    final me = createLayer('rect')
      ..id = 'm'
      ..content.size = [100, 50]
      ..transform.anchor.defaultValue = [0.5, 0.5]
      ..durationFrames = 100;
    final k = PropLink(sourceId: 's', to: 'scaleBottom', mode: 'follow', fromFrame: 40);
    me.links.add(k);
    final p = Project(layers: [src, me]);
    pinLinkBase(p, k, 0);
    src.transform.anchor.defaultValue = [0.2, 0.14]; // 60 px up
    clearStateCaches();
    expect(linkPreviewOutline(p, me, 50), isNull, reason: 'it works now: nothing to show');
    final pts = linkPreviewOutline(p, me, 5)!;
    final ys = [for (final q in pts) q[1]];
    expect(ys.reduce((a, b) => a < b ? a : b), closeTo(415, 1e-6), reason: 'the top would be 60 px higher');
    expect(ys.reduce((a, b) => a > b ? a : b), closeTo(525, 1e-6));
    // the layer itself: as it is.
    final m = toFrameMatrix(getLayerStateAt(p, 'm', 5).matrix);
    expect(applyAffine(m, [0, -25])[1], closeTo(475, 1e-6));
  });

  group('links read real motion', () {
    Layer rect(String id, double x) => createLayer('rect')
      ..id = id
      ..durationFrames = 100
      ..content.size = [50, 50]
      ..transform.anchor.defaultValue = [x, 0.5];
    void moveA(Layer a) => a.transform.anchor.keyframes = [
          Keyframe(frame: 0, value: <double>[0.1, 0.5], temporal: lin),
          Keyframe(frame: 100, value: <double>[0.3, 0.5], temporal: lin),
        ];

    test('B moved by its parent A (no keys of its own) moves C linked to B', () {
      final a = rect('a', 0.1), b = rect('b', 0.3)..parentId = 'a', c = rect('c', 0.7);
      moveA(a);
      final k = PropLink(sourceId: 'b', from: 'x', to: 'x');
      c.links.add(k);
      final p = Project(layers: [a, b, c]);
      pinLinkBase(p, k, 0);
      clearStateCaches();
      expect(getLayerStateAt(p, 'c', 50).matrix[4], closeTo(0.8, 1e-9));
      expect(c.transform.anchor.keyframes, isEmpty);
    });

    test('a chain A -> B -> C with keys only on A; B following, C on its size handle', () {
      final a = rect('a', 0.1), b = rect('b', 0.4), c = rect('c', 0.7);
      a.transform.anchor.keyframes = [
        Keyframe(frame: 0, value: <double>[0.1, 0.5], temporal: lin),
        Keyframe(frame: 100, value: <double>[0.1, 0.3], temporal: lin), // 200 px up
      ];
      b.links.add(PropLink(sourceId: 'a', to: 'y', mode: 'follow'));
      c.links.add(PropLink(sourceId: 'b', to: 'scaleBottom', mode: 'follow'));
      final p = Project(layers: [a, b, c]);
      for (final l in [b, c]) {
        pinLinkBase(p, l.links.single, 0);
      }
      clearStateCaches();
      final m = toFrameMatrix(getLayerStateAt(p, 'c', 50).matrix);
      expect(applyAffine(m, [0, -25])[1], closeTo(375, 1e-6), reason: "C's top went up with B: 100 px");
    });

    test('turning: a parent turns B, C linked to B turns too', () {
      final a = rect('a', 0.5), b = rect('b', 0.6)..parentId = 'a', c = rect('c', 0.2);
      a.transform.rotation.keyframes = [
        Keyframe(frame: 0, value: 0.0, temporal: lin),
        Keyframe(frame: 100, value: 90.0, temporal: lin),
      ];
      final k = PropLink(sourceId: 'b', from: 'rotation', to: 'rotation');
      c.links.add(k);
      final p = Project(layers: [a, b, c]);
      pinLinkBase(p, k, 0);
      clearStateCaches();
      expect(getLayerStateAt(p, 'c', 100).rot, closeTo(90, 1e-9));
    });

    test('a source hanging on the layer itself: no endless loop, and refused when made', () {
      final a = rect('a', 0.2), b = rect('b', 0.4)..parentId = 'a';
      a.links.add(PropLink(sourceId: 'b', from: 'x', to: 'y'));
      final p = Project(layers: [a, b]);
      expect(linkWouldCycle(p, a, 'b'), isTrue);
      clearStateCaches();
      expect(() => getLayerStateAt(p, 'a', 10), returnsNormally);
    });
  });

  group('follow a size handle; the whole size', () {
    Layer rect(String id, double x, double y, double w, double h) => createLayer('rect')
      ..id = id
      ..durationFrames = 100
      ..content.size = [w, h]
      ..transform.anchor.defaultValue = [x, y];

    test("chasing the source's right size handle: it moves when the source grows, not only when it moves", () {
      final a = rect('a', 0.2, 0.5, 100, 100), c = rect('c', 0.7, 0.5, 50, 50);
      final k = PropLink(sourceId: 'a', from: 'scaleRight', to: 'x', mode: 'follow');
      c.links.add(k);
      final p = Project(layers: [a, c]);
      pinLinkBase(p, k, 0);
      expect(k.base, closeTo(250, 1e-9), reason: "the handle: a's right side middle");
      // a grows from its right side by 60 px (the left stays): the handle +60.
      a.transform.scale.defaultValue = [1.6, 1.0];
      a.transform.anchor.defaultValue = [0.23, 0.5];
      clearStateCaches();
      expect(getLayerStateAt(p, 'c', 0).matrix[4] * 1000, closeTo(760, 1e-6));
    });

    test('the whole size: add mode grows both scales at once', () {
      final a = rect('a', 0.2, 0.5, 100, 100), c = rect('c', 0.7, 0.5, 50, 50);
      final k = PropLink(sourceId: 'a', from: 'x', to: 'scale', factor: 0.01);
      c.links.add(k);
      final p = Project(layers: [a, c]);
      pinLinkBase(p, k, 0);
      a.transform.anchor.defaultValue = [0.25, 0.5]; // +50 px
      clearStateCaches();
      expect(getLayerStateAt(p, 'c', 0).scale, [closeTo(1.5, 1e-9), closeTo(1.5, 1e-9)]);
    });

    test('the whole size, following: both scales by one amount (a linked pair)', () {
      final a = rect('a', 0.2, 0.2, 10, 10), c = rect('c', 0.5, 0.5, 100, 50);
      final k = PropLink(sourceId: 'a', to: 'scale', mode: 'follow');
      c.links.add(k);
      final p = Project(layers: [a, c]);
      pinLinkBase(p, k, 0);
      a.transform.anchor.defaultValue = [0.25, 0.2]; // +50 px across
      clearStateCaches();
      final st = getLayerStateAt(p, 'c', 0);
      expect(st.scale, [closeTo(1.5, 1e-9), closeTo(1.5, 1e-9)], reason: 'width +50 (half), so height by half too');
    });

    test("following a size handle with the whole size: the whole object grows as the handle goes out", () {
      final a = rect('a', 0.2, 0.5, 100, 100), c = rect('c', 0.7, 0.5, 50, 40);
      final k = PropLink(sourceId: 'a', from: 'scaleBottom', to: 'scale', mode: 'follow');
      c.links.add(k);
      final p = Project(layers: [a, c]);
      pinLinkBase(p, k, 0);
      // a's bottom goes 20 px down (it grows from its top).
      a.transform.scale.defaultValue = [1.0, 1.2];
      a.transform.anchor.defaultValue = [0.2, 0.51];
      clearStateCaches();
      expect(getLayerStateAt(p, 'c', 0).scale, [closeTo(1.5, 1e-9), closeTo(1.5, 1e-9)]);
    });

    test('switching the kind: one works at a time, each keeps its own settings', () {
      final a = rect('a', 0.2, 0.5, 10, 10), c = rect('c', 0.7, 0.5, 50, 50);
      final k = PropLink(sourceId: 'a', from: 'rotation', to: 'rotation', factor: 2);
      c.links.add(k);
      final p = Project(layers: [a, c]);
      k.switchMode('follow');
      expect([k.from, k.to], ['position', 'y']);
      k.from = 'scaleRight';
      k.to = 'scaleBottom';
      k.factor = 1;
      pinLinkBase(p, k, 0);
      k.switchMode('add');
      expect([k.from, k.to, k.factor], ['rotation', 'rotation', 2]);
      k.switchMode('follow');
      expect([k.from, k.to, k.factor], ['scaleRight', 'scaleBottom', 1]);
      // only the follow works: moving a sideways (its right handle goes
      // along) does nothing to the rotation.
      pinLinkBase(p, k, 0);
      a.transform.rotation.defaultValue = 30.0;
      clearStateCaches();
      expect(getLayerStateAt(p, 'c', 0).rot, 0);
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(c))) as Map<String, dynamic>).links.single;
      expect(back.memory['add']?.from, 'rotation');
    });

    test('a source read as its whole size', () {
      final a = rect('a', 0.2, 0.5, 10, 10)..transform.scale.defaultValue = [2.0, 4.0];
      expect(linkedPropAt(Project(layers: [a]), a, 'scale', 0), closeTo(3, 1e-9));
    });
  });
}
