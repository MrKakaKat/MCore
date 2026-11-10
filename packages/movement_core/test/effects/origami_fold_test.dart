import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Grid _grid() => [
      for (var y = 0; y <= 4; y++) [for (var x = 0; x <= 4; x++) <double>[x * 25.0, y * 25.0]]
    ];

void main() {
  setUpAll(registerBuiltinEffects);

  Map<String, dynamic> p(Map<String, dynamic> over) => {
        'angle': 0.0,
        'direction': 0.0,
        'position': 0.5,
        'softness': 0.0,
        'angle2': 0.0,
        'position2': 0.75,
        'angle3': 0.0,
        'position3': 0.9,
        'perspective': 0.0,
        ...over,
      };

  test('a 180 fold lays the right half back over the left; the left half stays', () {
    final g = origamiGrid(_grid(), p({'angle': 180.0}), 0);
    expect(g[0][0], [0.0, 0.0]);
    expect(g[2][2][0], closeTo(50, 1e-9));
    // the right edge lands on the left edge.
    expect(g[2][4][0], closeTo(0, 1e-9));
    expect(g[2][3][0], closeTo(25, 1e-9));
  });

  test('at 90 (no perspective) the folded part stands on edge: it collapses onto the fold line', () {
    final g = origamiGrid(_grid(), p({'angle': 90.0}), 0);
    for (final row in g) {
      expect(row[4][0], closeTo(50, 1e-9));
      expect(row[3][0], closeTo(50, 1e-9));
    }
  });

  test('a second fold folds the folded part again', () {
    // fold at the middle by 90, then at 3/4 by 90 more: the last quarter
    // comes back flat, pointing back over the left half.
    final g = origamiGrid(_grid(), p({'angle': 90.0, 'angle2': 90.0, 'position2': 0.75}), 0);
    expect(g[0][3][0], closeTo(50, 1e-9), reason: 'the first flap stands up');
    expect(g[0][4][0], closeTo(25, 1e-9), reason: 'the second lies back flat, 25 px long');
  });

  test('softness bends round instead of creasing; the fold direction can turn', () {
    final soft = origamiGrid(_grid(), p({'angle': 180.0, 'softness': 0.2}), 0);
    // a round bend leaves the far edge short of a sharp fold's.
    expect(soft[2][4][0], greaterThan(0));
    final down = origamiGrid(_grid(), p({'angle': 180.0, 'direction': 90.0}), 0);
    expect(down[4][2][1], closeTo(0, 1e-9), reason: 'the lower half folds up over the top');
    expect(down[4][2][0], closeTo(50, 1e-9));
  });

  test('perspective: a part folding toward the viewer grows', () {
    final g = origamiGrid(_grid(), p({'angle': 60.0, 'perspective': 0.5}), 0);
    final flat = origamiGrid(_grid(), p({'angle': 60.0}), 0);
    final dy = (g[4][4][1] - g[0][4][1]).abs(), dyFlat = (flat[4][4][1] - flat[0][4][1]).abs();
    expect(dy, greaterThan(dyFlat));
    expect(math.max(1, 1), 1);
  });

  test('the grid gets rows at the folds', () {
    final def = effectRegistry['origami_fold']!;
    final hints = def.gridHints!(p({'angle': 90.0, 'angle2': 45.0}), _grid());
    expect(hints, hasLength(2));
    expect(hints.first.from, closeTo(0, 1e-9));
  });

  test('folds are added and removed; a fold line on the stage drags its position', () {
    stageSize.width = 480;
    stageSize.height = 480;
    final project = Project(fps: 30);
    final l = createLayer('rect', size: 100);
    project.layers.add(l);
    final inst = createEffectInstance('origami_fold', 'o1', l);
    l.effectStack.add(inst);
    expect(origamiFoldKeys(inst.params), hasLength(1));
    final n = addOrigamiFold(inst);
    expect(origamiFoldKeys(inst.params), hasLength(2));
    final lines = origamiFoldLinesFrame(project, l, 0);
    expect(lines, hasLength(2), reason: 'shown even at angle 0');
    // past the shape's edge, a turn handle at each line's end.
    expect(origamiDirectionHandlesFrame(project, l, 0), hasLength(2));
    // drag the first line a quarter of the way left.
    final m = getTransformBoxHandles(project, l, 0).mCanvas;
    // (the drag follows the finger from where it went down.)
    final op = OrigamiFoldDragOp(l, inst, 'position');
    op.apply(project, 0, applyAffine(m, [l.content.offset[0], 0]));
    op.apply(project, 0, applyAffine(m, [l.content.offset[0] - 25, 0]));
    expect((inst.params['position'] as Track).defaultValue as double, closeTo(0.25, 1e-6));
    removeOrigamiFold(inst, n);
    expect(origamiFoldKeys(inst.params), hasLength(1));
  });

  test('folds in different directions, each in its own part, on the folded paper', () {
    // fold 1: the right half up by 180 (over the left); fold 2 in that
    // half, its lower part folding (direction 90) by 180.
    final params = p({'angle': 180.0})
      ..['fold2_angle'] = 180.0
      ..['fold2_direction'] = 90.0
      ..['fold2_position'] = 0.5
      ..['fold2_in'] = '1:far';
    final g = origamiGrid(_grid(), params, 0);
    // the bottom-right corner (100, 100): first down-up onto (100, 0), then
    // over to (0, 0).
    expect(g[4][4][0], closeTo(0, 1e-9));
    expect(g[4][4][1], closeTo(0, 1e-9));
    // the bottom-left one is in neither: it stays.
    expect(g[4][0], [0.0, 100.0]);
    // anywhere: fold 2 folds the left part's bottom too.
    params['fold2_in'] = 'free';
    final f = origamiGrid(_grid(), params, 0);
    expect(f[4][0][1], closeTo(0, 1e-9));
  });

  test('a rounded crease leaves the parts where they are', () {
    final sharp = origamiGrid(_grid(), p({'angle': 90.0}), 0);
    final round = origamiGrid(_grid(), p({'angle': 90.0, 'round': 10.0}), 0);
    // far from the crease: the same.
    expect(round[0][0], sharp[0][0]);
    expect(round[0][4][0], closeTo(sharp[0][4][0], 1e-9));
  });

  test('a fold through two points', () {
    final l = createLayer('rect', size: 100);
    final inst = createEffectInstance('origami_fold', 'o1', l);
    final rest = buildGrid(l.content, 2, 2);
    // the diagonal from top-left to bottom-right.
    origamiFoldThrough(inst, rest, 1, [-50, -50], [50, 50], 0, (t, f, v) => t.defaultValue = v);
    final d = ((inst.params['direction'] as Track).defaultValue as num).toDouble();
    expect(d % 180, closeTo(135, 1e-6), reason: "across the diagonal");
    expect(((inst.params['position'] as Track).defaultValue as num).toDouble(), closeTo(0.5, 1e-6));
  });

  test('the bend and the rounding have a shape; each stays within the paper', () {
    // a soft 90 bend: the folded part ends in the same place whatever the
    // shape; in between, a sharper shape hugs the corner more.
    final circle = origamiGrid(_grid(), p({'angle': 90.0, 'softness': 0.4}), 0);
    final sharp = origamiGrid(_grid(), p({'angle': 90.0, 'softness': 0.4, 'softShape': 1.0}), 0);
    final cut = origamiGrid(_grid(), p({'angle': 90.0, 'softness': 0.4, 'softShape': 0.0}), 0);
    expect(sharp[2][4][0], closeTo(circle[2][4][0], 1e-6), reason: 'the far edge where it was');
    expect(cut[2][4][0], closeTo(circle[2][4][0], 1e-6));
    // a point in the bend sits differently.
    final f = [for (final g in [circle, sharp, cut]) g[2][3][0]];
    expect(f.toSet(), hasLength(greaterThan(1)));
    // a huge rounding is held to the paper there is (50 px each side).
    final big = origamiGrid(_grid(), p({'angle': 90.0, 'round': 500.0}), 0);
    final held = origamiGrid(_grid(), p({'angle': 90.0, 'round': 50.0}), 0);
    expect(big[2][1][0], closeTo(held[2][1][0], 1e-6));
    // the rounding's shape changes the corner, not the parts past it.
    final r1 = origamiGrid(_grid(), p({'angle': 90.0, 'round': 20.0, 'roundShape': 0.0}), 0);
    final r2 = origamiGrid(_grid(), p({'angle': 90.0, 'round': 20.0, 'roundShape': 1.0}), 0);
    expect(r1[0][0], r2[0][0]);
    expect((r1[0][2][0] - r2[0][2][0]).abs() + (r1[0][2][1] - r2[0][2][1]).abs(), greaterThan(1e-6));
  });

  test('the turn handle turns the fold the way the finger goes', () {
    stageSize.width = 480;
    stageSize.height = 480;
    final project = Project(fps: 30);
    final l = createLayer('rect', size: 100);
    project.layers.add(l);
    final inst = createEffectInstance('origami_fold', 'o1', l);
    l.effectStack.add(inst);
    final h = origamiDirectionHandlesFrame(project, l, 0).single;
    final mid = origamiFoldLinesFrame(project, l, 0).single.mid;
    final op = OrigamiDirectionDragOp(l, inst);
    op.apply(project, 0, h.p);
    // 20 degrees clockwise on the screen (y down) round the middle.
    final a = math.atan2(h.p[1] - mid[1], h.p[0] - mid[0]) + 20 * math.pi / 180;
    final r = math.sqrt(math.pow(h.p[0] - mid[0], 2) + math.pow(h.p[1] - mid[1], 2));
    op.apply(project, 0, [mid[0] + r * math.cos(a), mid[1] + r * math.sin(a)]);
    final d = ((inst.params['direction'] as Track).defaultValue as num).toDouble();
    expect(d, closeTo(20, 1e-6), reason: 'clockwise on screen, the direction grows');
  });
}
