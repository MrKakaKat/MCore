import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Content _line(List<List<double>> pts) {
  final c = createLayer('line').content..lineNodes = [for (final p in pts) LineNode(p[0], p[1])];
  syncLineBox(c);
  return c;
}

void main() {
  setUp(() {
    registerBuiltinEffects();
    setStageSize(400, 400);
    clearStateCaches();
  });

  test('stops: the nearest within reach wins, none: as it is', () {
    expect(snapToStops(0.51, const [0.25, 0.5, 0.75], 0.025), 0.5);
    expect(snapToStops(0.6, const [0.25, 0.5, 0.75], 0.025), 0.6);
    expect(snapToStops(134, origamiAngleStops, 4), 135);
  });

  test('a point goes into the line where it is tapped; a line splits at a middle point', () {
    final c = _line([
      [0, 0],
      [100, 0],
      [100, 100]
    ]);
    final i = insertLinePointOn(c, const [50, 2], 5);
    expect(i, 1);
    expect(c.lineNodes!.length, 4);
    expect(insertLinePointOn(c, const [50, 40], 5), isNull, reason: 'off the line');
    final rest = splitLineAt(c, 2)!;
    expect(c.lineNodes!.length, 3);
    expect(rest.length, 2);
    expect([rest.first.x, rest.first.y], [100.0, 0.0], reason: 'both halves share the point');
    expect(splitLineAt(c, 0), isNull, reason: 'an end');
  });

  test('a loop opens at the split point', () {
    final c = _line([
      [0, 0],
      [100, 0],
      [100, 100],
      [0, 100]
    ])
      ..lineClosed = true;
    expect(splitLineAt(c, 2), isEmpty);
    expect(c.lineClosed, isFalse);
    expect(c.lineNodes!.length, 5);
    expect([c.lineNodes!.first.x, c.lineNodes!.first.y], [c.lineNodes!.last.x, c.lineNodes!.last.y]);
  });

  test('flipping a line moves its points and handles (and keys)', () {
    final c = _line([
      [0, 0],
      [100, 50]
    ]);
    c.lineNodes![0].hOut = [20, 5];
    toggleLinePointKey(c, 1, 10);
    final mid = c.offset[0];
    flipLineNodes(c, horizontal: true);
    expect(c.lineNodes![0].x, closeTo(2 * mid, 1e-9));
    expect(c.lineNodes![0].hOut, [-20.0, 5.0]);
    expect((c.lineNodes![1].posT!.keyframes.single.value as List)[0], closeTo(2 * mid - 100, 1e-9));
  });

  test('handle keys: the handle follows them over time', () {
    final c = _line([
      [0, 0],
      [100, 0]
    ]);
    final n = c.lineNodes![0]..hOut = [10, 0];
    toggleLineHandleKey(c, 0, 'hOut', 0);
    n.hOut = [30, 0];
    toggleLineHandleKey(c, 0, 'hOut', 20);
    expect(n.handleAt('hOut', 10)[0], closeTo(20, 1e-6));
    setLineHandle(c, 0, 'hOut', [40, 0], 20);
    expect(n.handleAt('hOut', 20)[0], 40);
  });

  test('origami: a stretched layer folds at the angles shown (the switch on), not off', () {
    final l = createLayer('rect')..content.size = [100, 100];
    l.transform.scale.defaultValue = [3.0, 1.0];
    l.effectStack.add(EffectInstance(id: 'o', effectId: 'origami_fold', params: {
      'angle': track(90.0),
      'direction': track(45.0),
      'position': track(0.5),
      'softness': track(0.0),
      'perspective': track(0.0),
    }));
    expect(origamiScale(l, 0), [3.0, 1.0]);
    final on = buildEffectGrid(l, l.content, 0);
    final folded = applyEffectStack(l, [for (final r in on) [for (final p in r) [...p]]], 0);
    l.foldsIgnoreScale = false;
    expect(origamiScale(l, 0), isNull);
    final off = buildEffectGrid(l, l.content, 0);
    final folded2 = applyEffectStack(l, [for (final r in off) [for (final p in r) [...p]]], 0);
    // a different fold line: the results differ.
    double sum(Grid g) => g.expand((r) => r).fold(0.0, (a, p) => a + p[0] * 3 + p[1]);
    expect((sum(folded) - sum(folded2)).abs(), greaterThan(1));
    // the stage line: on screen at 45 degrees (x stretched 3x).
    l.foldsIgnoreScale = true;
    final line = origamiFoldLines(resolveEffectParams(l.effectStack.first, 0), buildGrid(l.content, 2, 2),
        scale: origamiScale(l, 0)).first;
    final dx = (line.b[0] - line.a[0]) * 3, dy = line.b[1] - line.a[1];
    expect((math.atan2(dy, dx) * 180 / math.pi).abs() % 180, closeTo(135, 1e-6));
    expect(projectLayersFromJson(projectLayersToJson(Project(layers: [l..foldsIgnoreScale = false]))).single.foldsIgnoreScale, isFalse);
  });

  test('a size handle can keep the opposite side in place', () {
    final l = createLayer('rect')..content.size = [100, 100];
    l.transform.anchor.defaultValue = [0.5, 0.5];
    final p = Project(layers: [l]);
    scaleKeepsOppositeEdge = true;
    addTearDown(() => scaleKeepsOppositeEdge = false);
    final left = applyAffine(getTransformBoxHandles(p, l, 0).mCanvas, const [-50, 0]);
    ScaleDragOp(layer: l, handle: 'right').apply(p, 0, const [300, 200]);
    clearStateCaches();
    final s = l.transform.scale.defaultValue as List;
    expect(s[0], closeTo(1.5, 1e-6), reason: 'from the left edge (150) to the finger (300)');
    final left2 = applyAffine(getTransformBoxHandles(p, l, 0).mCanvas, const [-50, 0]);
    expect(left2[0], closeTo(left[0], 1e-6));
  });

  test('the piece rect is set like a crop and sticks at the quarters', () {
    final l = createLayer('rect')..content.size = [100, 100];
    final p = Project(layers: [l]);
    pieceInsets = [0.1, 0.1, 0.1, 0.1];
    addTearDown(() => pieceInsets = null);
    final h = getCropHandles(p, l, 0, insets: pieceInsets);
    final m = h.mCanvas;
    // drag the left edge to just past a quarter.
    CropDragOp(layer: l, handle: 'left', piece: true).apply(p, 0, applyAffine(m, const [-24, 0]));
    expect(pieceInsets![0], closeTo(0.25, 1e-9));
    expect(l.crop, [0.0, 0.0, 0.0, 0.0], reason: 'the crop itself stays');
    expect(pieceRectRing(l).first[0], closeTo(-25, 1e-9));
  });
}
