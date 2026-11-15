import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
  });

  Project one(Layer l) => Project(layers: [l]);

  group('edges pin', () {
    test('a rect: dragging the top edge moves both top corners; the sides stretch', () {
      final l = createLayer('rect')
        ..id = 'r'
        ..content.size = [200, 100]
        ..transform.anchor.defaultValue = [0.5, 0.5];
      final inst = createEffectInstance('edges_pin', 'e', l);
      l.effectStack.add(inst);
      final p = one(l);
      final edges = getEdgesPinHandles(p, l, inst, 0);
      expect(edges.map((e) => e.key), ['tl|tr', 'tr|br', 'br|bl', 'bl|tl']);
      final top = edges.first.screen;
      expect(top[0], closeTo(500, 1e-6));
      expect(top[1], closeTo(450, 1e-6));
      EdgeDragOp(layer: l, inst: inst, a: 'tl', b: 'tr').apply(p, 0, [520, 400]);
      clearStateCaches();
      final h = getCornerPinHandles(p, l, inst, 0);
      expect(h.screen['tl'], [closeTo(420, 1e-6), closeTo(400, 1e-6)]);
      expect(h.screen['tr'], [closeTo(620, 1e-6), closeTo(400, 1e-6)]);
      expect(h.screen['bl'], [closeTo(400, 1e-6), closeTo(550, 1e-6)], reason: 'the bottom stays');
      // the shape follows: its outline's top is the moved edge.
      final pts = applyEffectStack(l, [[[-100.0, -50.0], [100.0, -50.0], [100.0, 50.0], [-100.0, 50.0]]], 0, project: p)[0];
      expect(pts.map((q) => q[1]).reduce((a, b) => a < b ? a : b), closeTo(-100, 1e-6));
    });

    test('a triangle: its sides as edges, a side moved takes its two points', () {
      final l = createLayer('triangle')
        ..id = 't'
        ..content.size = [200, 200]
        ..transform.anchor.defaultValue = [0.5, 0.5];
      final inst = createEffectInstance('edges_pin', 'e', l);
      l.effectStack.add(inst);
      expect(inst.params.containsKey('p0'), isTrue);
      final p = one(l);
      final edges = getEdgesPinHandles(p, l, inst, 0);
      expect(edges, hasLength(3));
      final e = edges[1];
      final before = getCornerPinHandles(p, l, inst, 0);
      final third = before.keys.firstWhere((k) => k != e.a && k != e.b);
      EdgeDragOp(layer: l, inst: inst, a: e.a, b: e.b).apply(p, 0, [e.screen[0] + 30, e.screen[1]]);
      clearStateCaches();
      final after = getCornerPinHandles(p, l, inst, 0);
      expect(after.screen[e.a]![0] - before.screen[e.a]![0], closeTo(30, 1e-6));
      expect(after.screen[e.b]![0] - before.screen[e.b]![0], closeTo(30, 1e-6));
      expect(after.screen[third], before.screen[third], reason: 'the opposite point stays');
    });
  });

  group('links', () {
    Layer rect(String id, double x, double y) => createLayer('rect')
      ..id = id
      ..content.size = [100, 50]
      ..transform.anchor.defaultValue = [x, y];

    test('a link works only in its time: nothing before, held after', () {
      final src = rect('s', 0.1, 0.1), me = rect('m', 0.5, 0.5);
      src.durationFrames = me.durationFrames = 100;
      final lin = easingPresets['linear']!;
      src.transform.anchor.keyframes = [
        Keyframe(frame: 0, value: <double>[0.1, 0.1], temporal: lin),
        Keyframe(frame: 100, value: <double>[0.2, 0.1], temporal: lin), // +100 px over 100 frames
      ];
      final k = PropLink(sourceId: 's', from: 'x', to: 'x', fromFrame: 20, untilFrame: 60);
      me.links.add(k);
      final p = Project(layers: [src, me]);
      expect(linkOffset(p, me, 'x', 10), 0);
      expect(linkOffset(p, me, 'x', 20), closeTo(0, 1e-9));
      expect(linkOffset(p, me, 'x', 40), closeTo(20, 1e-6));
      expect(linkOffset(p, me, 'x', 60), closeTo(40, 1e-6));
      expect(linkOffset(p, me, 'x', 90), closeTo(40, 1e-6), reason: 'what it added stays');
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(me))) as Map<String, dynamic>).links.single;
      expect([back.fromFrame, back.untilFrame, back.mode], [20, 60, 'add']);
    });

    test('follow: the bottom size handle (bottom held) moves the top with the source, up and down only', () {
      final src = rect('s', 0.2, 0.2), me = rect('m', 0.5, 0.5);
      final k = PropLink(sourceId: 's', to: 'scaleBottom', mode: 'follow');
      me.links.add(k);
      final p = Project(layers: [src, me]);
      pinLinkBase(p, k, 0);
      double edge(double y) {
        clearStateCaches();
        final m = toFrameMatrix(getLayerStateAt(p, 'm', 0).matrix);
        return applyAffine(m, [0, y])[1];
      }

      expect([edge(-25), edge(25)], [closeTo(475, 1e-6), closeTo(525, 1e-6)]);
      src.transform.anchor.defaultValue = [0.2, 0.14]; // 60 px up
      expect(edge(-25), closeTo(415, 1e-6), reason: 'the top went exactly as far');
      expect(edge(25), closeTo(525, 1e-6), reason: 'the bottom stays');
      src.transform.anchor.defaultValue = [0.5, 0.14]; // and 300 px right
      expect(edge(-25), closeTo(415, 1e-6), reason: 'sideways does nothing to it');
      src.transform.anchor.defaultValue = [0.2, 0.26]; // 60 px down from the start
      expect(edge(-25), closeTo(535, 1e-6));
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(me))) as Map<String, dynamic>).links.single;
      expect(back.mode, 'follow');
      expect(back.baseY, closeTo(200, 1e-9));
    });

    test('follow: a turned layer follows along its own axis', () {
      final src = rect('s', 0.2, 0.2), me = rect('m', 0.5, 0.5);
      me.transform.rotation.defaultValue = 90.0;
      final k = PropLink(sourceId: 's', to: 'scaleRight', mode: 'follow');
      me.links.add(k);
      final p = Project(layers: [src, me]);
      pinLinkBase(p, k, 0);
      src.transform.anchor.defaultValue = [0.2, 0.23]; // 30 px down: along its right side (turned down)
      clearStateCaches();
      final m = toFrameMatrix(getLayerStateAt(p, 'm', 0).matrix);
      expect(applyAffine(m, [50, 0])[1], closeTo(580, 1e-6));
      expect(applyAffine(m, [-50, 0])[1], closeTo(450, 1e-6), reason: 'its left side stays');
    });
  });

  group('crop several', () {
    Layer rect(String id, double x) => createLayer('rect')
      ..id = id
      ..content.size = [200, 100]
      ..transform.anchor.defaultValue = [x, 0.5];

    tearDown(() => snapEnabled = false);

    test('the dragged handle moves the same edge of each by the same amount', () {
      snapEnabled = false;
      final a = rect('a', 0.25), b = rect('b', 0.7);
      final p = Project(layers: [a, b]);
      final grab = getCropHandles(p, a, 0).screen['left']!; // (150, 500)
      final op = GroupCropDragOp.grab(p, a, [b], 'left', 0, grab);
      op.apply(p, 0, [grab[0] + 40, grab[1]]);
      expect(a.crop[0], closeTo(0.2, 1e-9));
      expect(b.crop[0], closeTo(0.2, 1e-9));
      expect([a.crop[2], b.crop[2]], [0, 0]);
    });

    test('each edge snaps on its own (to the frame and to other objects)', () {
      snapEnabled = true;
      snapEdgeToEdgeFrameRadius = 8;
      final a = rect('a', 0.25), b = rect('b', 0.7);
      final wall = createLayer('rect')
        ..id = 'w'
        ..content.size = [10, 10]
        ..transform.anchor.defaultValue = [0.2, 0.2]; // its right side at x 205
      final p = Project(layers: [a, b, wall]);
      final grab = getCropHandles(p, a, 0).screen['left']!; // a: 150, b: 600
      final op = GroupCropDragOp.grab(p, a, [b], 'left', 0, grab);
      op.apply(p, 0, [grab[0] + 56, grab[1]]); // a's edge near 205 (wall), b's near 656
      clearStateCaches();
      expect(getCropHandles(p, a, 0).screen['left']![0], closeTo(205, 1e-6), reason: "a snaps to the wall's edge");
      expect(getCropHandles(p, b, 0).screen['left']![0], closeTo(656, 1e-6), reason: 'b has nothing near: no snap');
      expect(op.snapGuides, isNotEmpty);
    });
  });
}
