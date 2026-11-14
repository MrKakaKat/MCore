/// ============================================================
/// EFFECT PORT
/// - registerEffect(): the ONLY thing needed to add a new effect. one
///   file, one call, no changes anywhere else in the engine.
/// - params are self-describing (type/range/animatable) so a UI panel
///   could be generated automatically from them.
/// - "vertex" type effects deform a GRID of points, not a fixed
///   rectangle - required for anything that isn't a simple affine op.
/// - apply(grid, params, localFrame) is a pure function.
///
/// Ported from movement-core/src/effects/geometryEffectRegistry.js.
/// ============================================================
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../core/math.dart' show applyAffine, invertAffine;
import '../core/stage_size.dart';
import '../core/state_cache.dart' show getLayerStateAt;
import '../geometry/shapes.dart' show buildGrid, shapeBoundingBox;
import '../model/project.dart';
import 'builtins/bend_arc.dart' show applyBendGroup, bendPhysicsAngle, bendV2Keys, isBendV2;
import 'builtins/origami_fold.dart'
    show origamiScale, origamiGridScaled, origamiHintsScaled, origamiMixedDirections, origamiElasticAngles;

typedef GridPoint = List<double>;
typedef Grid = List<List<GridPoint>>;
typedef EffectApply = Grid Function(Grid grid, Map<String, dynamic> params, double localFrame);

class ParamDef {
  final String key;
  final String type; // "float" | "vec2" | "enum" | "int"
  final dynamic defaultValue;
  final List<double>? range;
  final bool animatable;
  final List<String>? options;
  const ParamDef({
    required this.key,
    required this.type,
    required this.defaultValue,
    this.range,
    this.animatable = true,
    this.options,
  });
}

/// Where an effect needs grid resolution: rows across `axisAngle`
/// (degrees) exactly at `from` and `to` (signed distances along the axis
/// from the rest box centre) and `rows` evenly between them. The grid
/// builder (buildEffectGrid) merges the hints of a whole stack.
class GridHint {
  final double axisAngle;
  final double from, to;
  final int rows;
  const GridHint({required this.axisAngle, required this.from, required this.to, required this.rows});
}

class EffectDef {
  final String id;
  final String name;
  final String category;
  final String type;
  final List<ParamDef> params;
  final EffectApply apply;

  /// Optional: how much the effect darkens the layer (1 = unchanged),
  /// from the resolved params - e.g. 3D Rotate's shading as the object
  /// turns away. Applied by the renderer as a multiply, alpha untouched.
  final double Function(Map<String, dynamic> params)? brightness;

  /// Optional: where this effect needs grid rows (see GridHint), from its
  /// resolved params and the rest grid. Effects without it get the
  /// uniform grid, as before.
  final List<GridHint> Function(Map<String, dynamic> params, Grid rest)? gridHints;

  /// False for effects that move no points (Outline draws on top): they
  /// never make the layer a warped texture.
  final bool deforms;
  const EffectDef({
    required this.id,
    required this.name,
    required this.category,
    required this.type,
    required this.params,
    required this.apply,
    this.brightness,
    this.gridHints,
    this.deforms = true,
  });
}

/// An enabled effect that moves the layer's points (not e.g. Outline).
bool isDeformingEffect(EffectInstance i) => i.enabled && (effectRegistry[i.effectId]?.deforms ?? true);

final Map<String, EffectDef> effectRegistry = {};

void registerEffect(EffectDef def) {
  effectRegistry[def.id] = def;
}

EffectInstance createEffectInstance(String effectId, String id, Layer? layer) {
  final def = effectRegistry[effectId]!;
  final params = <String, dynamic>{};
  // exact-N-point pin instead of the standard bounding-box homography:
  // a triangle IS exactly 3 vertices, and a "polygon" (baked from a
  // previous corner_pin confirm) has however many points it was
  // confirmed with.
  final shape = layer?.content.shape;
  final exactCount = shape == 'triangle'
      ? 3
      : (shape == 'polygon' && layer?.content.points != null && layer!.content.points!.length <= 4)
          ? layer.content.points!.length
          : 0;
  if (effectId == 'corner_pin' && exactCount >= 3) {
    for (var i = 0; i < exactCount; i++) {
      params['p$i'] = track([0.0, 0.0]);
    }
  } else if (effectId == 'mesh_warp') {
    const rows = 4, cols = 4; // fixed at creation, see the registration comment
    params['rows'] = rows;
    params['cols'] = cols;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        params['r${r}c$c'] = track([0.0, 0.0]);
      }
    }
  } else if (effectId == 'bend_arc') {
    // v2 params only - `base`/`baseAxis` exist for legacy instances.
    for (final p in def.params) {
      if (bendV2Keys.contains(p.key)) params[p.key] = track(p.defaultValue as double);
    }
  } else {
    for (final p in def.params) {
      final v = p.defaultValue is List ? List<double>.from(p.defaultValue as List) : p.defaultValue;
      params[p.key] = p.animatable ? track(v) : v;
    }
  }
  return EffectInstance(id: id, effectId: effectId, enabled: true, params: params);
}

Map<String, dynamic> resolveEffectParams(EffectInstance instance, double localFrame) {
  final out = <String, dynamic>{};
  instance.params.forEach((key, v) {
    out[key] = (v is Track) ? evaluateTrack(null, v, localFrame) : v;
  });
  // origami: elastic folds spring after their keys.
  if (instance.effectId == 'origami_fold') origamiElasticAngles(instance.params, out, localFrame);
  return out;
}

/// Runs the layer's enabled effects over `grid` (the pristine, undeformed
/// content grid - also the "rest" coordinates bends classify points by).
/// Consecutive v2 bends run together as joints (applyBendGroup); a bend's
/// angle includes its physics (bendPhysicsAngle) - pass `project` so the
/// lag follows the layer's world motion.
Grid applyEffectStack(Layer layer, Grid grid, int globalFrame, {Project? project}) {
  final localFrame = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
  final rest = grid;
  var g = grid;
  final insts = [
    for (final i in layer.effectStack)
      if (isDeformingEffect(i) && effectRegistry.containsKey(i.effectId) && effectActiveAt(layer, i.id, localFrame)) i
  ];
  var i = 0;
  while (i < insts.length) {
    final inst = insts[i];
    if (isBendV2(inst)) {
      final group = <Map<String, dynamic>>[];
      while (i < insts.length && isBendV2(insts[i])) {
        group.add(_resolveBend(project, layer, insts[i], localFrame));
        i++;
      }
      g = applyBendGroup(g, rest, group, shapeBoundingBox(layer.content));
      continue;
    }
    final fs = inst.effectId == 'origami_fold' ? origamiScale(layer, localFrame) : null;
    final params = _withBox(layer, inst, resolveEffectParams(inst, localFrame));
    g = fs != null ? origamiGridScaled(g, params, localFrame, fs) : effectRegistry[inst.effectId]!.apply(g, params, localFrame);
    i++;
  }
  return g;
}

/// Origami measures its creases on the layer's own box (whatever grid or
/// outline it is given).
Map<String, dynamic> _withBox(Layer layer, EffectInstance inst, Map<String, dynamic> params) {
  if (inst.effectId != 'origami_fold' && inst.effectId != 'rotate_3d') return params;
  final b = shapeBoundingBox(layer.content);
  return params..['_box'] = [b.minX, b.minY, b.maxX, b.maxY];
}

/// The effects deforming `layer` act point by point (an outline can go
/// through them directly, exactly, instead of through a grid).
/// (A 3D tilt is point by point too: it measures on the layer's box.)
bool deformsPointwise(Layer layer) => layer.effectStack.any((i) => i.enabled && i.effectId == 'origami_fold') &&
    layer.effectStack
        .every((i) => !i.enabled || !isDeformingEffect(i) || i.effectId == 'origami_fold' || i.effectId == 'rotate_3d');

/// Points (content space) through the deforming effects after instance
/// `instId` in the layer's stack (a fold's crease, carried by a tilt
/// after it).
List<List<double>> applyEffectsAfter(Layer layer, String instId, List<List<double>> pts, int globalFrame,
    {Project? project}) {
  final localFrame = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
  final at = layer.effectStack.indexWhere((i) => i.id == instId);
  if (at < 0 || pts.isEmpty) return pts;
  var g = [pts];
  for (final inst in layer.effectStack.skip(at + 1)) {
    if (!inst.enabled || !isDeformingEffect(inst) || !effectRegistry.containsKey(inst.effectId)) continue;
    if (!effectActiveAt(layer, inst.id, localFrame)) continue;
    if (inst.effectId != 'rotate_3d' && inst.effectId != 'origami_fold') continue; // point by point only
    final params = _withBox(layer, inst, resolveEffectParams(inst, localFrame));
    g = effectRegistry[inst.effectId]!.apply(g, params, localFrame);
  }
  return g.first;
}

Map<String, dynamic> _resolveBend(Project? project, Layer layer, EffectInstance inst, double localFrame) =>
    resolveEffectParams(inst, localFrame)..['angle'] = bendPhysicsAngle(project, layer, inst, localFrame);

/// The rest grid for a layer's content box (`content` - a rect, or the
/// bbox of any shape): uniform `n` x `n` unless an enabled effect asks for
/// rows (GridHint). Then rows run across the first hint's axis - exactly
/// on every hint's lines, densely inside their bands, and at the box
/// corners so the rows tile the box exactly - each clipped to the box,
/// with `cols` points across. Other vertex effects in the stack add
/// uniform rows and columns too.
Grid buildEffectGrid(Layer layer, Content content, int globalFrame, {Project? project, int n = 10}) {
  final uniform = buildGrid(content, n, n);
  final localFrame = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
  final hints = <GridHint>[];
  var others = false, fine = false;
  for (final inst in layer.effectStack) {
    if (!inst.enabled || !effectActiveAt(layer, inst.id, localFrame)) continue;
    final def = effectRegistry[inst.effectId];
    if (def == null) continue;
    final params =
        isBendV2(inst) ? _resolveBend(project, layer, inst, localFrame) : _withBox(layer, inst, resolveEffectParams(inst, localFrame));
    // creases in several directions: rows can follow only one - a fine
    // even grid instead.
    if (inst.effectId == 'origami_fold' && origamiMixedDirections(params)) {
      fine = true;
      continue;
    }
    final fs = inst.effectId == 'origami_fold' ? origamiScale(layer, localFrame) : null;
    final h = fs != null ? origamiHintsScaled(params, uniform, fs) : def.gridHints?.call(params, uniform) ?? const <GridHint>[];
    if (h.isEmpty) {
      others = true;
    } else {
      hints.addAll(h);
    }
  }
  if (fine) return buildGrid(content, math.max(n, 32), math.max(n, 32));
  if (hints.isEmpty) return uniform;

  final a = hints.first.axisAngle * math.pi / 180;
  final u = [math.cos(a), math.sin(a)], nv = [-u[1], u[0]];
  final cx = content.offset[0], cy = content.offset[1];
  final hw = content.size[0] / 2, hh = content.size[1] / 2;
  final reach = (hw * u[0]).abs() + (hh * u[1]).abs();
  final ss = <double>{-reach, reach};
  // box corners: rows through them keep the strips' sides straight edges
  // of the box.
  for (final sx in [-hw, hw]) {
    for (final sy in [-hh, hh]) {
      ss.add(sx * u[0] + sy * u[1]);
    }
  }
  for (final h in hints) {
    final from = h.from.clamp(-reach, reach), to = h.to.clamp(-reach, reach);
    for (var k = 0; k <= h.rows; k++) {
      ss.add(from + (to - from) * k / h.rows);
    }
  }
  if (others) {
    for (var k = 0; k <= n; k++) {
      ss.add(-reach + 2 * reach * k / n);
    }
  }
  final rowsS = ss.toList()..sort();
  final dedup = <double>[];
  for (final v in rowsS) {
    if (dedup.isEmpty || v - dedup.last > 1e-6) dedup.add(v);
  }
  final cols = others ? n : 3;

  // the chord of the box along the row at `s`: w range where
  // c + s*u + w*n stays inside the box.
  (double, double) chord(double s) {
    var lo = -double.infinity, hi = double.infinity;
    void slab(double base, double dir, double half) {
      if (dir.abs() < 1e-12) return; // parallel: base is inside by construction
      final t1 = (-half - base) / dir, t2 = (half - base) / dir;
      lo = math.max(lo, math.min(t1, t2));
      hi = math.min(hi, math.max(t1, t2));
    }

    slab(s * u[0], nv[0], hw);
    slab(s * u[1], nv[1], hh);
    // through a corner the range collapses to one point - rounding can
    // flip it, so take the middle rather than dropping it.
    if (lo > hi) return ((lo + hi) / 2, (lo + hi) / 2);
    return (lo, hi);
  }

  return [
    for (final s in dedup)
      () {
        final (lo, hi) = chord(s);
        return [
          for (var k = 0; k < cols; k++)
            () {
              final w = lo + (hi - lo) * k / (cols - 1);
              return [cx + s * u[0] + w * nv[0], cy + s * u[1] + w * nv[1]];
            }(),
        ];
      }(),
  ];
}

/// The parents (nearest first) whose shape effects (bend, twist, warp,
/// ...) act at `globalFrame` - their children are deformed with them.
List<Layer> deformingAncestors(Project project, Layer layer, int globalFrame) {
  final out = <Layer>[];
  final seen = <String>{};
  var id = layer.parentId;
  while (id != null && seen.add(id)) {
    final p = findLayer(project, id);
    if (p == null) break;
    final lf = math.min(p.durationFrames, math.max(0, layerTimeFrame(p, globalFrame) - p.startFrame));
    if (p.effectStack.any((i) => isDeformingEffect(i) && effectRegistry.containsKey(i.effectId) && effectActiveAt(p, i.id, lf))) {
      out.add(p);
    }
    id = p.parentId;
  }
  return out;
}

/// A child's grid (its content-local points) bent by its parents' shape
/// effects, as if drawn on the parent: the parent's own grid, at rest and
/// deformed, is a map - each child point (in the parent's content space)
/// is found in a cell of the rest grid and moved to the same spot of that
/// cell deformed. Points past the parent's edge carry on from the nearest
/// cell. Works for every effect, whatever it bases its shape on.
Grid applyInheritedDeform(Project project, Layer layer, Grid grid, int globalFrame) {
  final ancestors = deformingAncestors(project, layer, globalFrame);
  if (ancestors.isEmpty) return grid;
  final w = stageSize.width, h = stageSize.height;
  List<double> px(List<double> m) => [m[0], m[1], m[2], m[3], m[4] * w, m[5] * h];
  final toFrame = px(getLayerStateAt(project, layer.id, globalFrame).matrix), fromFrame = invertAffine(toFrame);
  var g = [for (final row in grid) [for (final p in row) applyAffine(toFrame, p)]];
  for (final a in ancestors) {
    final am = px(getLayerStateAt(project, a.id, globalFrame).matrix);
    final inv = invertAffine(am);
    // origami: the child's points fold with the paper exactly (a shape
    // joined at a crease or an edge takes the fold's angle).
    if (deformsPointwise(a)) {
      final local = [for (final row in g) [for (final p in row) applyAffine(inv, p)]];
      final folded = applyEffectStack(a, local, globalFrame, project: project);
      g = [for (final row in folded) [for (final p in row) applyAffine(am, p)]];
      continue;
    }
    final rest = buildEffectGrid(a, a.content, globalFrame, project: project);
    final bent = applyEffectStack(a, [for (final row in rest) [for (final p in row) [...p]]], globalFrame, project: project);
    g = [
      for (final row in g)
        [for (final p in row) applyAffine(am, _mapThroughGrids(applyAffine(inv, p), rest, bent))]
    ];
  }
  return [for (final row in g) [for (final p in row) applyAffine(fromFrame, p)]];
}

/// `p` in the cell of `rest` it falls in (or the nearest one), moved to
/// the same bilinear spot of that cell in `bent`.
List<double> _mapThroughGrids(List<double> p, Grid rest, Grid bent) {
  ({double u, double v}) inverse(List<double> a, List<double> b, List<double> c, List<double> d) {
    // a b / d c corners; Newton on the bilinear map.
    var u = 0.5, v = 0.5;
    for (var it = 0; it < 8; it++) {
      final x = (1 - u) * (1 - v) * a[0] + u * (1 - v) * b[0] + u * v * c[0] + (1 - u) * v * d[0] - p[0];
      final y = (1 - u) * (1 - v) * a[1] + u * (1 - v) * b[1] + u * v * c[1] + (1 - u) * v * d[1] - p[1];
      final xu = (1 - v) * (b[0] - a[0]) + v * (c[0] - d[0]), xv = (1 - u) * (d[0] - a[0]) + u * (c[0] - b[0]);
      final yu = (1 - v) * (b[1] - a[1]) + v * (c[1] - d[1]), yv = (1 - u) * (d[1] - a[1]) + u * (c[1] - b[1]);
      final det = xu * yv - xv * yu;
      if (det.abs() < 1e-12) break;
      u -= (x * yv - y * xv) / det;
      v -= (y * xu - x * yu) / det;
    }
    return (u: u, v: v);
  }

  var best = double.infinity;
  var at = (r: 0, c: 0, u: 0.0, v: 0.0);
  for (var r = 0; r + 1 < rest.length; r++) {
    for (var c = 0; c + 1 < rest[r].length && c + 1 < rest[r + 1].length; c++) {
      final q = inverse(rest[r][c], rest[r][c + 1], rest[r + 1][c + 1], rest[r + 1][c]);
      // how far outside the cell (0 inside).
      final out = math.max(0.0, math.max(-q.u, q.u - 1)) + math.max(0.0, math.max(-q.v, q.v - 1));
      if (out < best) {
        best = out;
        at = (r: r, c: c, u: q.u, v: q.v);
        if (out == 0) break;
      }
    }
    if (best == 0) break;
  }
  if (best.isInfinite) return p;
  final a = bent[at.r][at.c], b = bent[at.r][at.c + 1], c = bent[at.r + 1][at.c + 1], d = bent[at.r + 1][at.c];
  final u = at.u, v = at.v;
  return [
    (1 - u) * (1 - v) * a[0] + u * (1 - v) * b[0] + u * v * c[0] + (1 - u) * v * d[0],
    (1 - u) * (1 - v) * a[1] + u * (1 - v) * b[1] + u * v * c[1] + (1 - u) * v * d[1],
  ];
}

/// The product of every enabled effect's brightness on this layer at this
/// frame (1 = unchanged).
double layerEffectBrightness(Layer layer, int globalFrame) {
  final localFrame = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
  var b = 1.0;
  for (final inst in layer.effectStack) {
    if (!inst.enabled || !effectActiveAt(layer, inst.id, localFrame)) continue;
    final fn = effectRegistry[inst.effectId]?.brightness;
    if (fn == null) continue;
    b *= fn(resolveEffectParams(inst, localFrame)).clamp(0.0, 1.0);
  }
  return b;
}
