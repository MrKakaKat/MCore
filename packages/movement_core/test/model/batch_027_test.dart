import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });
  tearDown(() => rectExtendMode = false);
  const lin = Easing(0, 0, 1, 1);

  Layer rect(String id, double x, double y, double w, double h) => createLayer('rect')
    ..id = id
    ..startFrame = 0
    ..durationFrames = 100
    ..content.offset = [0, 0]
    ..content.size = [w, h]
    ..transform.anchor.defaultValue = [x / 1000, y / 1000];

  test('lengthening is keyed: the box grows on its sides over time; the own box stays in the model; saved', () {
    final r = rect('r', 500, 500, 100, 50);
    r.transform.extend.keyframes = [
      Keyframe(frame: 0, value: <double>[0, 0, 0, 0], temporal: lin),
      Keyframe(frame: 50, value: <double>[0, 0, 100, 20], temporal: lin),
    ];
    final p = Project(layers: [r]);
    expect(layerExtendAt(r, 25), [0, 0, 50, 10]);
    final seen = withExtendedBoxes(p, 50, () => [...r.content.offset, ...r.content.size]);
    expect(seen, [50, 10, 200, 70], reason: 'the right side 100 px out, the bottom 20');
    expect([...r.content.offset, ...r.content.size], [0, 0, 100, 50], reason: 'its own box after');
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(r))) as Map<String, dynamic>);
    expect(back.transform.extend.keyframes, hasLength(2));
    expect(cloneLayer(r).transform.extend.keyframes, hasLength(2));
    expect(keyDetailRows(r).keys, contains('Movement'));
  });

  test('the right size handle lengthening a rect writes the key (the left side stays)', () {
    rectExtendMode = true;
    final r = rect('r', 500, 500, 100, 50);
    final p = Project(layers: [r]);
    setTrackValueAt(r.transform.extend, 0, <double>[0, 0, 0, 0]);
    r.transform.extend.keyframes = [Keyframe(frame: 0, value: <double>[0, 0, 0, 0], temporal: lin)];
    final op = ScaleDragOp(layer: r, handle: 'right');
    withExtendedBoxes(p, 0, () => op.apply(p, 0, [600, 500]));
    expect(layerExtendAt(r, 0), [closeTo(0, 1e-9), 0, closeTo(50, 1e-6), 0]);
    expect(r.content.size, [100, 50], reason: 'the own box is not touched');
    // dragged again, from where it is now.
    withExtendedBoxes(p, 0, () => op.apply(p, 0, [620, 500]));
    expect(layerExtendAt(r, 0)[2], closeTo(70, 1e-6));
  });

  test('physics collides with the lengthened box', () {
    final wall = rect('w', 500, 500, 100, 100)
      ..physics.collide = true
      ..physics.role = 'immovable';
    wall.transform.extend.defaultValue = <double>[0, 0, 200, 0]; // right side at 750
    final b = rect('b', 900, 500, 50, 50)..physics.collide = true;
    b.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.9, 0.5], temporal: lin),
      Keyframe(frame: 40, value: <double>[0.6, 0.5], temporal: lin),
    ];
    final p = Project(layers: [wall, b]);
    physicsWorldOf(p).bakeTo(50);
    clearStateCaches();
    expect(getLayerStateAt(p, 'b', 50).matrix[4] * 1000, closeTo(775, 1.5));
  });

  test('a link from a lengthened side: a picture grows by as many px on that side', () {
    final vec = rect('v', 300, 500, 100, 100);
    vec.transform.extend.keyframes = [
      Keyframe(frame: 0, value: <double>[0, 0, 0, 0], temporal: lin),
      Keyframe(frame: 50, value: <double>[0, 0, 60, 0], temporal: lin),
    ];
    final pic = rect('p', 700, 500, 200, 100);
    pic.links.add(PropLink(sourceId: 'v', from: 'growRight', to: 'scaleRight'));
    final p = Project(layers: [vec, pic]);
    pinLinkBase(p, pic.links.single, 0);
    clearStateCaches();
    final m = toFrameMatrix(getLayerStateAt(p, 'p', 50).matrix);
    expect(applyAffine(m, [100, 0])[0], closeTo(860, 1e-6), reason: 'its right side 60 px further');
    expect(applyAffine(m, [-100, 0])[0], closeTo(600, 1e-6), reason: 'its left side held');
  });

  test('contact squares: a touch broken for a frame or two is one touch', () {
    final a = rect('A', 300, 500, 100, 100)..physics.collide = true;
    final b = rect('B', 500, 500, 100, 100)
      ..physics.collide = true
      ..physics.role = 'immovable';
    // in, out for a frame, in again.
    a.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.3, 0.5], temporal: lin),
      Keyframe(frame: 20, value: <double>[0.41, 0.5], temporal: lin),
      Keyframe(frame: 21, value: <double>[0.39, 0.5], temporal: lin),
      Keyframe(frame: 22, value: <double>[0.41, 0.5], temporal: lin),
      Keyframe(frame: 60, value: <double>[0.41, 0.5], temporal: lin),
      Keyframe(frame: 80, value: <double>[0.2, 0.5], temporal: lin),
    ];
    final p = Project(layers: [a, b]);
    physicsWorldOf(p).bakeTo(100);
    final m = physicsWorldOf(p).contactMarkers('A');
    expect(m.length, 2, reason: 'one start, one end: $m');
  });

  test("handle to handle, no keys anywhere: B's left side goes exactly as far as A's right handle is dragged", () {
    final a = rect('A', 300, 500, 100, 100), b = rect('B', 600, 500, 100, 100);
    final k = PropLink(sourceId: 'A', from: 'scaleRight', to: 'scaleLeft', mode: 'follow');
    b.links.add(k);
    final p = Project(layers: [a, b]);
    pinLinkBase(p, k, 0);
    double edge(Layer l, double x) {
      clearStateCaches();
      return applyAffine(toFrameMatrix(getLayerStateAt(p, l.id, 0).matrix), [x, 0])[0];
    }

    for (final keep in [false, true]) {
      scaleKeepsOppositeEdge = keep;
      final a0 = edge(a, 50), b0 = edge(b, -50);
      final h = applyAffine(getTransformBoxHandles(p, a, 0).mCanvas, [50, 0]);
      ScaleDragOp(layer: a, handle: 'right').apply(p, 0, [h[0] + 40, h[1]]);
      expect(edge(b, -50) - b0, closeTo(edge(a, 50) - a0, 1e-6), reason: 'keep opposite edge: $keep');
      expect(edge(b, 50), closeTo(650, 1e-6), reason: "B's right side held");
    }
    scaleKeepsOppositeEdge = false;
    expect(a.transform.scale.keyframes, isEmpty);
    expect(b.transform.scale.keyframes, isEmpty);
  });
}
