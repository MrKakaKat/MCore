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
import '../model/prop_links.dart';
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
final Map<String, LayerBaseState> _baseStateCache = {};

// cleared at the top of every render() call, and ALSO whenever
// layer_ops.dart mutates parentId mid-frame (a stale cache entry keyed
// on the old parent would otherwise survive a reparent that happened
// between two calls at the same global frame).
void clearStateCaches() {
  _stateCache.clear();
  _baseStateCache.clear();
}

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
  final cacheKey = '${identityHashCode(project)}|$layerId|$globalFrame';
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
  final clamped = math.min(layer.durationFrames, math.max(0, localFrame)).toDouble();

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
    final outlineCanvas = [
      // path-follow's own outline sampling isn't designed for
      // sub-frame precision (getContentOutline takes an int) - rounds
      // here, same deliberate scope-limit as pendulum/wiggle below.
      for (final p in getContentOutline(pfSource.content, pfSource, globalFrame.round(), project: project)) mm.applyAffine(sourceMCanvas, p),
    ];
    final canvasPoint = pointOnOutline(outlineCanvas, t, pf.parametrization);
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
  if (layer.wiggle.enabled && effectActiveAt(layer, 'wiggle', clamped)) {
    final off = evaluateWiggleOffset(layer, globalFrame.round());
    anchor = [anchor[0] + off[0], anchor[1] + off[1]];
  }

  // swing rocks the layer around its own rotation.
  final baseRot = (evaluateTrack(project, layer.transform.rotation, clamped, layer) as double) +
      (effectActiveAt(layer, 'swing', clamped) ? evaluateSwing(layer.swing, clamped) : 0.0) +
      (layer.links.isEmpty ? 0.0 : linkOffset(project, layer, 'rotation', globalFrame));
  var scale = evaluateTrack(project, layer.transform.scale, clamped, layer) as List<double>;
  if (layer.links.isNotEmpty) {
    scale = [
      scale[0] + linkOffset(project, layer, 'scaleX', globalFrame),
      scale[1] + linkOffset(project, layer, 'scaleY', globalFrame),
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
  final cacheKey = '${identityHashCode(project)}|$layerId|$globalFrame';
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
  final clamped = math.min(layer.durationFrames, math.max(0, localFrame)).toDouble();
  final base = getLayerBaseStateAt(project, layerId, globalFrame);
  final anchor = base.anchor, baseRot = base.baseRot, scale = base.scale, inRange = base.inRange;
  final baseFinalMatrix = base.baseMatrix;

  var finalMatrix = baseFinalMatrix;
  var rot = baseRot;
  if (layer.pendulum.enabled && effectActiveAt(layer, 'pendulum', clamped)) {
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
    if (off != null && (off[0] != 0 || off[1] != 0)) {
      finalMatrix = [
        finalMatrix[0], finalMatrix[1], finalMatrix[2], finalMatrix[3],
        finalMatrix[4] + off[0] / stageSize.width, finalMatrix[5] + off[1] / stageSize.height,
      ];
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
  final now = getLayerStateAt(project, pid, globalFrame).matrix;
  if (layer.inheritPosition && layer.inheritRotation && layer.inheritScale && !layer.parentKeepDifference) return now;
  final ref = getLayerStateAt(project, pid, layer.startFrame).matrix;
  final a = decomposeAffine(now), r = decomposeAffine(ref);
  return mm.matFromTRS(
    layer.inheritPosition ? a.pos : r.pos,
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
    if (mb.enabled && mb.samples > 1 && effectActiveAt(p, 'motionBlur', globalFrame - p.startFrame)) return p;
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
