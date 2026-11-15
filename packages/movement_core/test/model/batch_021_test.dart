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
}
