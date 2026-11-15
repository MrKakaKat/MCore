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

    test('a key jumps a layer to its place from that frame on; saved', () {
      final a = named('a'), b = named('b'), c = named('c'), d = named('d');
      final p = Project(layers: [a, b, c, d]); // list top first: d c b a
      setStackKey(a, 10, 1); // a on top from frame 10
      setStackKey(a, 20, 3);
      List<String> top(int f) => [for (final l in stackOrderAt(p, f).reversed) l.id];
      expect(top(5), ['d', 'c', 'b', 'a'], reason: 'before its first key: where the list puts it');
      expect(top(10), ['a', 'd', 'c', 'b']);
      expect(top(25), ['d', 'c', 'a', 'b']);
      expect(stackPlaceOf(p, a, 15), 1);
      expect(stackPlaceOf(p, a, 25), 3);
      expect([for (final l in p.layers) l.id], ['a', 'b', 'c', 'd'], reason: 'the list stays');
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(a))) as Map<String, dynamic>);
      expect([for (final k in back.stackKeys) (k.frame, k.position)], [(10, 1), (20, 3)]);
      expect(cloneLayer(a).stackKeys, hasLength(2));
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
}
