import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
  });
  tearDown(() => scaleKeepsOppositeEdge = false);
  const lin = Easing(0, 0, 1, 1);

  test('turning by the handle goes the short way round each step: across the left of the pivot no whole-turn jump', () {
    final l = createLayer('rect')
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final p = Project(layers: [l]);
    final op = RotateDragOp.grab(p, l, 0, [400, 499]); // left of the pivot, a hair above
    // round to just below (crossing the -180/180 line).
    op.apply(p, 0, [400, 501]);
    final r = (l.transform.rotation.defaultValue as num).toDouble();
    expect(r.abs(), lessThan(2), reason: 'a small turn, not about 360: $r');
    // all the way round, step by step: one whole turn.
    for (var a = 1; a <= 36; a++) {
      final t = math.pi + 0.01 + a * 2 * math.pi / 36;
      op.apply(p, 0, [500 + 100 * math.cos(t), 500 + 100 * math.sin(t)]);
    }
    expect((l.transform.rotation.defaultValue as num).toDouble(), closeTo(360, 2));
  });

  test('keeping the far side in place holds for the scale keys too: the left side stays at every frame', () {
    scaleKeepsOppositeEdge = true;
    final l = createLayer('rect')
      ..content.size = [100, 100]
      ..durationFrames = 60
      ..transform.anchor.defaultValue = [0.5, 0.5];
    l.transform.scale.keyframes = [
      Keyframe(frame: 0, value: <double>[1.0, 1.0], temporal: lin),
      Keyframe(frame: 30, value: <double>[1.0, 1.0], temporal: lin),
    ];
    final p = Project(layers: [l]);
    double left(int f) {
      clearStateCaches();
      return applyAffine(toFrameMatrix(getLayerStateAt(p, l.id, f).matrix), [-50, 0])[0];
    }

    expect(left(30), closeTo(450, 1e-9));
    final h = applyAffine(getTransformBoxHandles(p, l, 30).mCanvas, [50, 0]);
    ScaleDragOp(layer: l, handle: 'right').apply(p, 30, [h[0] + 100, h[1]]); // twice as wide at 30
    clearStateCaches();
    expect((l.transform.scale.keyframes.last.value as List)[0], closeTo(2, 1e-9));
    for (final f in [0, 10, 15, 30]) {
      expect(left(f), closeTo(450, 1e-6), reason: 'frame $f');
    }
    expect(l.scaleOrigin, [closeTo(-50, 1e-9), closeTo(0, 1e-9)]);
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.scaleOrigin, l.scaleOrigin);
    // scaled about its centre again: the origin goes, the layer stays put.
    scaleKeepsOppositeEdge = false;
    final before = left(30);
    final h2 = applyAffine(getTransformBoxHandles(p, l, 30).mCanvas, [50, 0]);
    ScaleDragOp(layer: l, handle: 'right').apply(p, 30, h2);
    expect(l.scaleOrigin, isNull);
    expect(left(30), closeTo(before, 1e-6));
  });
}
