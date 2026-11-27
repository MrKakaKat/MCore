/// ============================================================
/// PULL-MODEL EVALUATION
/// - single entry point the render backend calls. can be called for ANY
///   global frame directly (scrubbing), never depends on the previous
///   frame having been computed.
///
/// Ported from movement-core/src/core/stateCache.js. One real
/// adaptation: the JS cache keys on `layerId|frame` alone because
/// there's only ever one module-global `project` singleton. Dart has no
/// such singleton - every caller threads a `Project` through explicitly,
/// and tests legitimately create many short-lived `Project` instances
/// whose layers can share ids (e.g. every `createDefaultProject()` has
/// an `"L_child"`). Keying on `layerId|frame` alone would let a cache
/// entry from one Project's "L_child" silently answer a query for a
/// DIFFERENT Project's own "L_child" - so the key includes
/// `identityHashCode(project)` too, scoping the cache per Project
/// instance without needing every test to remember to clear it first.
/// ============================================================
library;

import 'dart:math' as math;

import '../effects/motion/follow.dart' show applyFollow, followBusy;
import '../effects/motion/pendulum.dart';
import '../effects/motion/wiggle.dart';
import '../geometry/path_follow.dart';
import '../geometry/shapes.dart';
import '../model/project.dart';
import '../model/line_path.dart' show sampleLine;
import '../model/prop_links.dart';
import 'render_budget.dart';
import 'interpolation.dart';
import 'math.dart' as mm;
import 'perf.dart';
import 'stage_size.dart';

class LayerBaseState {
  final List<double> baseMatrix;
  final List<double> anchor;
  final double baseRot;
  final List<double> scale;
  final bool inRange;
  const LayerBaseState({
    required this.baseMatrix,
    required this.anchor,
    required this.baseRot,
    required this.scale,
    required this.inRange,
  });
}

class LayerState {
  final List<double> matrix;
  final List<double> baseMatrix;
  final List<double> anchor;
  final double rot;
  final List<double> scale;
  final bool inRange;
  const LayerState({
    required this.matrix,
    required this.baseMatrix,
    required this.anchor,
    required this.rot,
    required this.scale,
    required this.inRange,
  });
}

/// Contour physics: the induced offset (frame px) of a colliding layer at
/// a frame, added to its final position (see physics/contour_physics.dart).
List<double>? Function(Project project, String layerId, int frame)? physicsOffsetLookup;

/// True while physics reads the keyed poses (offsets left out).
bool physicsSuspended = false;

final Map<String, LayerState> _stateCache = {};

/// While true, layers are evaluated past their own time too (a child
/// following its parent there - see Layer.parentOutside).
bool _unclamped = false;

T _withUnclamped<T>(bool on, T Function() f) {
  if (!on || _unclamped) return f();
  _unclamped = true;
  try {
    return f();
  } finally {
    _unclamped = false;
  }
}
final Map<String, LayerBaseState> _baseStateCache = {};

// cleared at the top of every render() call, and ALSO whenever
// layer_ops.dart mutates parentId mid-frame (a stale cache entry keyed
// on the old parent would otherwise survive a reparent that happened
// between two calls at the same global frame).
void clearStateCaches() {
  _stateCache.clear();
  _baseStateCache.clear();
  stateEpoch++;
}

/// Goes up every time the state caches are cleared (anything may have
/// changed since): what is worked out once per epoch knows when to look
/// again.
int stateEpoch = 0;

// computes everything EXCEPT this layer's own pendulum swing - anchor
// (incl. path-follow/wiggle), rotation, scale, and the full parent-
// composed base matrix. split out from getLayerStateAt specifically so
// pendulum's own velocity sampling can call this directly instead of
// getLayerStateAt: calling getLayerStateAt(THIS layer's own id) from
// inside its OWN evaluatePendulumOffset would unconditionally recompute
// evaluatePendulumOffset again internally - self-referential recursion
// with no base case. This function has NO pendulum branch at all, so it
// can never re-enter evaluatePendulumOffset for this layer, while still
// correctly recursing into the PARENT's FULL getLayerStateAt.
/// `globalFrame` is `num`, not `int`: motion blur needs to sample SUB-
/// FRAME time offsets (a fraction of a frame's duration either side of
/// the current frame) to actually see fast motion smear across a
/// shutter window - JS's own `getLayerStateAt(layerId, sampleFrame)` in
/// renderLayer.js passes those fractional sample times straight through
/// (JS numbers are just floats, no int/float distinction to round away).
/// This port previously required an `int` here, so every motion-blur
/// sample got `.round()`ed before reaching this function - real device
/// report: with a one-frame-wide shutter (360°) and several samples, ALL
/// of them round to the SAME one or two integer frames, collapsing what
/// should be a smooth blur streak into what looks like a duplicated,
/// slightly-offset, half-transparent ghost (exactly the reported
/// symptom). Anchor/rotation/scale (evaluateTrack, already `double`-based)
/// get the full fractional precision now; pendulum/wiggle - inherently
/// discrete-step simulations, never designed or tested against a
/// fractional frame - keep sampling at the nearest whole frame via an
/// explicit `.round()` at their own call sites below, a deliberate,
/// narrower fix rather than a wider one risking their own correctness.
LayerBaseState getLayerBaseStateAt(Project project, String layerId, num globalFrame) {
  final cacheKey = '${_unclamped ? 'u' : ''}${identityHashCode(project)}|$layerId|$globalFrame';
  final cached = _baseStateCache[cacheKey];
  if (cached != null) return cached;
  final layer = findLayer(project, layerId);
  if (layer != null) {
    // loop repeats and time quantize evaluate at another frame.
    final q = layerTimeFrame(layer, globalFrame);
    if (q != globalFrame) return getLayerBaseStateAt(project, layerId, q);
  }
  if (layer == null) {
    return const LayerBaseState(baseMatrix: [1, 0, 0, 1, 0, 0], anchor: [0, 0], baseRot: 0, scale: [1, 1], inRange: false);
  }
  final localFrame = globalFrame - layer.startFrame;
  final clamped = _unclamped ? localFrame.toDouble() : math.min(layer.durationFrames, math.max(0, localFrame)).toDouble();

  List<double> anchor;
  final pf = layer.transform.pathFollow;
  final pfSource = pf.enabled && pf.sourceLayerId != null ? findLayer(project, pf.sourceLayerId) : null;
  if (pf.enabled && pfSource != null) {
    final t = evaluateTrack(project, pf.t, clamped) as double;
    final sourceState = getLayerStateAt(project, pfSource.id, globalFrame);
    final sourceMCanvas = [
      sourceState.matrix[0], sourceState.matrix[1], sourceState.matrix[2], sourceState.matrix[3],
      sourceState.matrix[4] * stageSize.width, sourceState.matrix[5] * stageSize.height,
    ];
    // a line: along the line itself (open unless it is closed); any
    // other shape: round its outline.
    final sc = pfSource.content;
    final isLine = sc.shape == 'line' && sc.lineNodes != null && sc.lineNodes!.length >= 2;
    final outlineCanvas = [
      // path-follow's own outline sampling isn't designed for
      // sub-frame precision (getContentOutline takes an int) - rounds
      // here, same deliberate scope-limit as pendulum/wiggle below.
      for (final p in isLine
          ? sampleLine(sc.lineNodes!, closed: sc.lineClosed, perCurve: 16, frame: globalFrame.round() - pfSource.startFrame)
          : getContentOutline(sc, pfSource, globalFrame.round(), project: project))
        mm.applyAffine(sourceMCanvas, p),
    ];
    final canvasPoint = pointOnOutline(outlineCanvas, t, pf.parametrization, closed: !isLine || sc.lineClosed);
    final parentMatrix = layer.parentId != null
        ? parentMatrixFor(project, layer, globalFrame)
        : <double>[1, 0, 0, 1, 0, 0];
    final targetFraction = [canvasPoint[0] / stageSize.width, canvasPoint[1] / stageSize.height];
    anchor = mm.applyAffine(mm.invertAffine(parentMatrix), targetFraction);
  } else {
    anchor = evaluateTrack(project, layer.transform.anchor, clamped, layer) as List<double>;
  }
  // dependencies: x / y taken from other layers.
  if (layer.links.isNotEmpty) {
    anchor = [
      anchor[0] + linkOffset(project, layer, 'x', globalFrame) / stageSize.width,
      anchor[1] + linkOffset(project, layer, 'y', globalFrame) / stageSize.height,
    ];
  }
  if (layer.wiggle.enabled && effectActiveAt(layer, 'wiggle', clamped, project)) {
    final off = evaluateWiggleOffset(layer, globalFrame.round());
    anchor = [anchor[0] + off[0], anchor[1] + off[1]];
  }

  // swing rocks the layer around its own rotation.
  final baseRot = (evaluateTrack(project, layer.transform.rotation, clamped, layer) as double) +
      (effectActiveAt(layer, 'swing', clamped, project) ? swingAngleAt(project, layer, clamped) : 0.0) +
      (layer.links.isEmpty ? 0.0 : linkOffset(project, layer, 'rotation', globalFrame));
  var scale = evaluateTrack(project, layer.transform.scale, clamped, layer) as List<double>;
  if (layer.scaleWiggle.enabled && effectActiveAt(layer, 'scaleWiggle', clamped, project)) {
    final k = evaluateScaleWiggle(layer, globalFrame.round());
    scale = [scale[0] * k[0], scale[1] * k[1]];
  }
  if (layer.links.isNotEmpty) {
    scale = [
      // its sides, and its whole size (both at once).
      scale[0] + linkOffset(project, layer, 'scaleX', globalFrame) + linkOffset(project, layer, 'scale.x', globalFrame),
      scale[1] + linkOffset(project, layer, 'scaleY', globalFrame) + linkOffset(project, layer, 'scale.y', globalFrame),
    ];
  }
  // dependencies on one size handle: that side grows, the one across
  // stays where it was.
  if (layer.links.any((k) => k.to.startsWith('scale') && k.to.length > 6)) {
    final dL = linkOffset(project, layer, 'scaleLeft', globalFrame), dR = linkOffset(project, layer, 'scaleRight', globalFrame);
    final dT = linkOffset(project, layer, 'scaleTop', globalFrame), dB = linkOffset(project, layer, 'scaleBottom', globalFrame);
    if (dL != 0 || dR != 0 || dT != 0 || dB != 0) {
      final c = layer.content;
      final minX = c.offset[0] - c.size[0] / 2, maxX = c.offset[0] + c.size[0] / 2;
      final minY = c.offset[1] - c.size[1] / 2, maxY = c.offset[1] + c.size[1] / 2;
      scale = [scale[0] + dL + dR, scale[1] + dT + dB];
      // the shift that keeps the far sides in place, turned with the layer.
      final vx = -(dR * minX + dL * maxX), vy = -(dT * minY + dB * maxY);
      final a = baseRot * math.pi / 180;
      final fx = vx * math.cos(a) - vy * math.sin(a), fy = vx * math.sin(a) + vy * math.cos(a);
      anchor = [anchor[0] + fx / stageSize.width, anchor[1] + fy / stageSize.height];
    }
  }
  // scaling round a point of its own (a side kept in place): that point
  // stays where it is at scale 1 - turned with the layer.
  final so = layer.scaleOrigin;
  if (so != null) {
    final vx = so[0] * (1 - scale[0]), vy = so[1] * (1 - scale[1]);
    final a = baseRot * math.pi / 180;
    anchor = [
      anchor[0] + (vx * math.cos(a) - vy * math.sin(a)) / stageSize.width,
      anchor[1] + (vx * math.sin(a) + vy * math.cos(a)) / stageSize.height,
    ];
  }
  // turning round a point of its own: that point stays where it is
  // whatever the turn (only the turn moves round it).
  final ro = layer.rotateOrigin;
  if (ro != null && baseRot != 0) {
    // where that point is from the anchor, unturned (with the scale and a
    // kept side's shift above).
    final wx = (so == null ? 0.0 : so[0] * (1 - scale[0])) + ro[0] * scale[0];
    final wy = (so == null ? 0.0 : so[1] * (1 - scale[1])) + ro[1] * scale[1];
    final a = baseRot * math.pi / 180, cs = math.cos(a), sn = math.sin(a);
    anchor = [
      anchor[0] + (wx - (wx * cs - wy * sn)) / stageSize.width,
      anchor[1] + (wy - (wx * sn + wy * cs)) / stageSize.height,
    ];
  }
  if (layer.parentKeepDifference && layer.inheritScale && layer.parentId != null) {
    scale = keepDifferenceScale(project, layer, globalFrame, scale);
  }
  final baseLocalMatrix = mm.matFromTRS(anchor, baseRot, scale);
  final baseMatrix = layer.parentId != null
      ? mm.matMul(parentMatrixFor(project, layer, globalFrame), baseLocalMatrix)
      : baseLocalMatrix;

  final result = LayerBaseState(
    baseMatrix: baseMatrix,
    anchor: anchor,
    baseRot: baseRot,
    scale: scale,
    inRange: localFrame >= 0 && localFrame <= layer.durationFrames,
  );
  _baseStateCache[cacheKey] = result;
  return result;
}

/// `num` for the same reason as getLayerBaseStateAt above - see its own
/// doc comment.
LayerState getLayerStateAt(Project project, String layerId, num globalFrame) {
  if (!perfInstrumentation) return _layerStateAt(project, layerId, globalFrame);
  return timeStateEval(() => _layerStateAt(project, layerId, globalFrame));
}

LayerState _layerStateAt(Project project, String layerId, num globalFrame) {
  final cacheKey = '${_unclamped ? 'u' : ''}${identityHashCode(project)}|$layerId|$globalFrame';
  final cached = _stateCache[cacheKey];
  if (cached != null) {
    if (perfInstrumentation) perfCounters.stateHits++;
    return cached;
  }
  if (perfInstrumentation) perfCounters.stateMisses++;
  final layer = findLayer(project, layerId);
  if (layer != null) {
    final q = layerTimeFrame(layer, globalFrame);
    if (q != globalFrame) return getLayerStateAt(project, layerId, q);
  }
  if (layer == null) {
    // defensive: any dangling id reference (parentId, mask source,
    // path-follow source) should degrade to "acts like identity / out
    // of range" instead of taking down the entire render loop.
    return const LayerState(matrix: [1, 0, 0, 1, 0, 0], baseMatrix: [1, 0, 0, 1, 0, 0], anchor: [0, 0], rot: 0, scale: [1, 1], inRange: false);
  }
  final localFrame = globalFrame - layer.startFrame;
  final clamped = _unclamped ? localFrame.toDouble() : math.min(layer.durationFrames, math.max(0, localFrame)).toDouble();
  final base = getLayerBaseStateAt(project, layerId, globalFrame);
  final anchor = base.anchor, baseRot = base.baseRot, scale = base.scale, inRange = base.inRange;
  final baseFinalMatrix = base.baseMatrix;

  var finalMatrix = baseFinalMatrix;
  var rot = baseRot;
  if (layer.pendulum.enabled && effectActiveAt(layer, 'pendulum', clamped, project)) {
    // pendulum is a discrete-step simulation (walks frame-by-frame
    // internally) never designed for a fractional frame - rounds here,
    // same deliberate scope-limit as wiggle/path-follow above.
    if (perfInstrumentation) perfCounters.pendulumEvals++;
    final swingDeg = evaluatePendulumOffset(project, layer, globalFrame.round());
    rot = layer.pendulum.rotateWithLine ? baseRot + swingDeg : baseRot;
    final pivotLocal = evaluateTrack(project, layer.pendulum.pivotOffset, clamped, layer) as List<double>;
    // grip point's world (root-fraction) position, BEFORE the swing.
    final g = [
      baseFinalMatrix[4] + (baseFinalMatrix[0] * pivotLocal[0] + baseFinalMatrix[2] * pivotLocal[1]) / stageSize.width,
      baseFinalMatrix[5] + (baseFinalMatrix[1] * pivotLocal[0] + baseFinalMatrix[3] * pivotLocal[1]) / stageSize.height,
    ];
    // rotate the WHOLE already-composed matrix around g, in world space.
    final swingRad = swingDeg * math.pi / 180;
    final cs = math.cos(swingRad), sn = math.sin(swingRad);
    final rg = [cs, sn, -sn, cs, g[0] - (cs * g[0] - sn * g[1]), g[1] - (sn * g[0] + cs * g[1])];
    if (layer.pendulum.rotateWithLine) {
      finalMatrix = mm.matMul(rg, baseFinalMatrix);
    } else {
      // content stays at its own baseRot orientation - only its
      // POSITION travels along the arc around g.
      final newTranslation = mm.applyAffine(rg, [baseFinalMatrix[4], baseFinalMatrix[5]]);
      finalMatrix = [baseFinalMatrix[0], baseFinalMatrix[1], baseFinalMatrix[2], baseFinalMatrix[3], newTranslation[0], newTranslation[1]];
    }
  }

  // Follow: trails its target (a keyed-like pose - collisions resolve
  // against it).
  var cacheable = true;
  if (layer.follow.enabled) {
    if (followBusy(project, layer)) {
      cacheable = false; // its own pose, asked for while following
    } else {
      finalMatrix = applyFollow(project, layer, globalFrame, finalMatrix);
    }
  }

  // pushed by a collision: the offset on top of the keyed pose (children
  // follow through this matrix).
  final lookup = physicsOffsetLookup;
  if (lookup != null && !physicsSuspended && layer.physics.collide) {
    final off = lookup(project, layerId, globalFrame.round());
    // a third value: its size (shrunk to keep turning, grown to hold);
    // a fourth: how far a hit turned it (degrees) - both about its pivot.
    final k = off != null && off.length > 2 ? off[2] : 1.0;
    final turn = off != null && off.length > 3 ? off[3] : 0.0;
    // a fifth and sixth: squashed / grown by its scale handles (its own x, y).
    final kx = off != null && off.length > 5 ? off[4] : 1.0, ky = off != null && off.length > 5 ? off[5] : 1.0;
    if (off != null && (off[0] != 0 || off[1] != 0 || k != 1 || turn != 0 || kx != 1 || ky != 1)) {
      var a = finalMatrix[0] * k * kx, b = finalMatrix[1] * k * kx, c = finalMatrix[2] * k * ky, d = finalMatrix[3] * k * ky;
      if (turn != 0) {
        final r = turn * math.pi / 180, cs = math.cos(r), sn = math.sin(r);
        (a, b, c, d) = (cs * a - sn * b, sn * a + cs * b, cs * c - sn * d, sn * c + cs * d);
      }
      finalMatrix = [a, b, c, d, finalMatrix[4] + off[0] / stageSize.width, finalMatrix[5] + off[1] / stageSize.height];
    }
  }

  final result = LayerState(matrix: finalMatrix, baseMatrix: baseFinalMatrix, anchor: anchor, rot: rot, scale: scale, inRange: inRange);
  if (cacheable) _stateCache[cacheKey] = result;
  return result;
}

/// The parent's matrix as `layer` follows it - all of it, or with
/// selective parenting only the parts switched on (position / rotation /
/// scale); a part switched off stays as the parent had it on the
/// layer's first frame, so nothing jumps there. Identity without a
/// parent. A skewed parent (non-uniform scale under a rotated
/// grandparent) loses its skew when filtered.
List<double> parentMatrixFor(Project project, Layer layer, num globalFrame) {
  final pid = layer.parentId;
  if (pid == null) return const [1, 0, 0, 1, 0, 0];
  // a link for a time only: outside it, the parent as at its edge.
  final from = layer.parentFrom, until = layer.parentUntil;
  if (from != null && globalFrame < from) globalFrame = from;
  if (until != null && globalFrame > until) globalFrame = until;
  final gf = globalFrame;
  final now = _withUnclamped(layer.parentOutside, () => getLayerStateAt(project, pid, gf).matrix);
  if (layer.inheritPosition && layer.inheritRotation && layer.inheritScale && !layer.parentKeepDifference) return now;
  final ref = _withUnclamped(layer.parentOutside, () => getLayerStateAt(project, pid, layer.startFrame).matrix);
  final a = decomposeAffine(now), r = decomposeAffine(ref);
  var pos = layer.inheritPosition ? a.pos : r.pos;
  // its turn not followed: the parent turning round a point of its own
  // (not its anchor) moves its anchor round that point - the child follows
  // where that point is instead, so the parent's turn doesn't move it.
  final ro = findLayer(project, pid)?.rotateOrigin;
  if (layer.inheritPosition && !layer.inheritRotation && ro != null) {
    List<double> pivot(({List<double> pos, double rot, List<double> scale}) d, double rot) {
      final x = ro[0] * d.scale[0], y = ro[1] * d.scale[1];
      final t = rot * math.pi / 180, cs = math.cos(t), sn = math.sin(t);
      return [(x * cs - y * sn) / stageSize.width, (x * sn + y * cs) / stageSize.height];
    }

    final now = pivot(a, a.rot), kept = pivot(a, r.rot);
    pos = [a.pos[0] + now[0] - kept[0], a.pos[1] + now[1] - kept[1]];
  }
  return mm.matFromTRS(
    pos,
    layer.inheritRotation ? a.rot : r.rot,
    // keep the difference: the parent's growth is added to the child's
    // size (see keepDifferenceScale), not to the distances.
    layer.inheritScale && !layer.parentKeepDifference ? a.scale : r.scale,
  );
}

/// Parenting that keeps the difference: the child's own `scale` with the
/// parent's growth since the child's first frame added as pixels - the
/// child grows by as many px as the parent does (each axis).
List<double> keepDifferenceScale(Project project, Layer layer, num globalFrame, List<double> scale) {
  final parent = findLayer(project, layer.parentId);
  if (parent == null) return scale;
  final a = decomposeAffine(getLayerStateAt(project, parent.id, globalFrame).matrix);
  final r = decomposeAffine(getLayerStateAt(project, parent.id, layer.startFrame).matrix);
  final pw = parent.content.size, cw = layer.content.size;
  return [
    for (var i = 0; i < 2; i++)
      () {
        final base = cw[i].abs() * scale[i] * r.scale[i];
        if (base.abs() < 1e-9) return scale[i];
        return scale[i] * (1 + pw[i].abs() * (a.scale[i] - r.scale[i]) / base);
      }()
  ];
}

/// The nearest ancestor of `layer` whose motion blur is on at
/// `globalFrame` - a child without its own blur is blurred by the
/// parent's motion only (see inheritedBlurMatrix).
Layer? blurringAncestor(Project project, Layer layer, int globalFrame) {
  var id = layer.parentId;
  final seen = <String>{};
  while (id != null && seen.add(id)) {
    final p = findLayer(project, id);
    if (p == null) return null;
    final mb = p.motionBlur;
    if (mb.enabled && mb.samples > 1 && effectActiveAt(p, 'motionBlur', globalFrame - p.startFrame, project)) return p;
    id = p.parentId;
  }
  return null;
}

/// `layer`'s matrix for a motion-blur sample at `sampleFrame` when the
/// blur comes from a parent: the parent's chain moves with the sample
/// time, the child's own transform is held at `globalFrame` (so a child
/// moving under a still parent stays sharp).
List<double> inheritedBlurMatrix(Project project, Layer layer, num sampleFrame, int globalFrame) {
  final own = getLayerStateAt(project, layer.id, globalFrame).matrix;
  final parentNow = parentMatrixFor(project, layer, globalFrame);
  final parentThen = parentMatrixFor(project, layer, sampleFrame);
  return mm.matMul(parentThen, mm.matMul(mm.invertAffine(parentNow), own));
}

/// Position, rotation (degrees) and scale of a [a,b,c,d,tx,ty] matrix
/// built like matFromTRS (skew is dropped).
({List<double> pos, double rot, List<double> scale}) decomposeAffine(List<double> m) {
  final sx = math.sqrt(m[0] * m[0] + m[1] * m[1]);
  final rot = math.atan2(m[1], m[0]) * 180 / math.pi;
  final sy = sx < 1e-12 ? math.sqrt(m[2] * m[2] + m[3] * m[3]) : (m[0] * m[3] - m[1] * m[2]) / sx;
  return (pos: [m[4], m[5]], rot: rot, scale: [sx, sy]);
}

/// Motion blur: how many frames the shutter is open for `layer` at
/// `globalFrame` - its shutter angle, or longer for a slow move with
/// sensitivity on (its streak at least `sensitivity` × 40 px long, open at
/// most 8 frames).
/// The effect layer whose motion blur reaches `layer` at `globalFrame`:
/// the nearest one above it that runs then (null: none, or the layer
/// blurs on its own).
Layer? blurringEffectLayer(Project project, Layer layer, num globalFrame) {
  if (layer.adjustment || layer.motionBlur.enabled) return null;
  final i = project.layers.indexOf(layer);
  if (i < 0) return null;
  for (var j = i + 1; j < project.layers.length; j++) {
    final a = project.layers[j];
    if (!a.adjustment || a.hidden || !a.motionBlur.enabled || a.motionBlur.samples < 2) continue;
    if (globalFrame < a.startFrame || globalFrame > a.startFrame + a.durationFrames) continue;
    return a;
  }
  return null;
}

double motionBlurWindow(Project project, Layer layer, num globalFrame, {MotionBlur? using}) {
  final mb = using ?? layer.motionBlur;
  final shutter = mb.shutterAngle / 360;
  if (mb.sensitivity <= 0) return shutter;
  final a = getLayerStateAt(project, layer.id, globalFrame - 0.5).matrix,
      b = getLayerStateAt(project, layer.id, globalFrame + 0.5).matrix;
  // px a frame (its middle's way, and its corners' turn / size change).
  final c = layer.content.size;
  final r = math.max(c.isEmpty ? 0.0 : c[0], c.length > 1 ? c[1] : 0.0) / 2;
  final dx = (a[4] - b[4]) * stageSize.width, dy = (a[5] - b[5]) * stageSize.height;
  final dl = math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2)) * r;
  final speed = math.sqrt(dx * dx + dy * dy) + dl;
  if (speed < 1e-6) return shutter;
  return math.max(shutter, math.min(8.0, mb.sensitivity * 40 / speed));
}

/// The swing's angle at the layer's local frame. With damping it swings
/// only from the object's moving: at full size while it moves, dying out
/// after it stops - none before it first moves.
double swingAngleAt(Project project, Layer layer, num localFrame) {
  final s = layer.swing;
  if (!s.enabled) return 0;
  if (s.damping <= 0) return evaluateSwing(s, localFrame);
  List<double> at(int f) {
    final v = evaluateTrack(project, layer.transform.anchor, f.toDouble(), layer);
    return [for (final e in v as List) (e as num).toDouble()];
  }

  final look = math.min(600, (fps * 6 / s.damping).ceil());
  final f0 = localFrame.floor();
  var env = 0.0;
  var next = at(f0);
  for (var f = f0; f > 0 && f >= f0 - look; f--) {
    if (RenderBudget.over) break;
    final prev = at(f - 1);
    final moving = (next[0] - prev[0]).abs() > 1e-7 || (next[1] - prev[1]).abs() > 1e-7;
    if (moving) {
      env = math.exp(-s.damping * (localFrame - f) / fps);
      break;
    }
    next = prev;
  }
  final center = (s.minAngle + s.maxAngle) / 2, amp = (s.maxAngle - s.minAngle) / 2;
  final t = localFrame / fps;
  return center + amp * env * math.sin(2 * math.pi * s.frequency * t + s.phase * math.pi / 180);
}
