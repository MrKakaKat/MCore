/// ============================================================
/// Pure position-computation port of movement-core/src/ui/stage/
/// handles.js - every function here returns DATA (matrices, screen-
/// space points), never draws anything. movement_mobile's
/// stage_painter.dart (Canvas/dart:ui, unverifiable in this sandbox)
/// consumes this data to actually paint; that split is what lets this
/// file get real `dart test` coverage the same way pendulum/layerOps
/// did, instead of being unverifiable along with the rest of ui/.
///
/// "screen" throughout this file means FRAME-space pixels (the
/// `stageSize.width x stageSize.height` convention every other render-
/// adjacent file in this package already uses - see core/stage_size.dart)
/// - NOT raw on-screen widget/device pixels. Converting between actual
/// touch input and this frame space (via the pan/zoom camera transform)
/// is movement_mobile's job, not this file's - same separation
/// movement-core's own canvas.width/height-vs-CSS-pixel conversion in
/// pointerRouter.js already drew, just made explicit here since Dart
/// has no single implicit global canvas to lean on.
/// ============================================================
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../core/math.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../effects/builtins/bend_arc.dart';
import '../effects/geometry_effect_registry.dart';
import '../effects/motion/pendulum.dart' show pendulumWeightPoint;
import '../geometry/piece_outline.dart';
import '../geometry/shapes.dart';
import '../model/project.dart';
import '../model/track_edit.dart' show activeAnimLayerOf;

/// composes a world-space matrix (translation in normalized 0..1
/// root-space, per getLayerStateAt's own convention) into a FRAME-
/// PIXEL-space matrix - public (was private) so ui_geometry/
/// snapping.dart can reuse this exact composition instead of
/// duplicating it, per the shared "frame-space AABB" helper below.
/// Settings: the transform handles laid out for the right hand (move
/// bottom right, size top right, turn top left); false mirrors them.
bool handlesRightHanded = true;

/// Where the size (scale) corner is on a box: top right, or top left
/// when the handles are mirrored.
List<double> scaleCornerLocal(BoundingBox bbox) => [handlesRightHanded ? bbox.maxX : bbox.minX, bbox.minY];

List<double> toFrameMatrix(List<double> m) =>
    [m[0], m[1], m[2], m[3], m[4] * stageSize.width, m[5] * stageSize.height];

/// world matrix for a keyframe's OWN stored value, bypassing temporal
/// evaluation entirely - see handles.js's own doc comment on why
/// (whole-path easing makes intermediate keyframe TIMES flexible, so
/// station markers must show the keyframe's stored point, not wherever
/// the object is at that raw frame).
List<double> stationWorldMatrix(Project project, Layer layer, List<double> anchorValue, int globalFrame) {
  final localFrame = layerLocalFrame(layer, globalFrame);
  final rot = _evalScalar(project, layer.transform.rotation, localFrame, layer);
  final scale = _evalVec2(project, layer.transform.scale, localFrame, layer);
  final localMatrix = matFromTRS(anchorValue, rot, scale);
  final parentMatrix = layer.parentId != null ? parentMatrixFor(project, layer, globalFrame) : <double>[1, 0, 0, 1, 0, 0];
  return matMul(parentMatrix, localMatrix);
}

List<double> getAnchorLiveHandleScreen(Project project, Layer layer, int globalFrame) {
  final m = getLayerStateAt(project, layer.id, globalFrame).matrix;
  return [m[4] * stageSize.width, m[5] * stageSize.height];
}

// ===== instance lookups =====

EffectInstance? getCornerPinInstance(Layer layer) {
  for (final i in layer.effectStack) {
    if (i.effectId == 'corner_pin' && i.enabled) return i;
  }
  return null;
}

EffectInstance? getMeshWarpInstance(Layer layer) {
  for (final i in layer.effectStack) {
    if (i.effectId == 'mesh_warp' && i.enabled) return i;
  }
  return null;
}

/// any effect occupying the shape's own corners - used to keep the
/// transform box's scale/rotate corners from fighting the same spots.
EffectInstance? getActiveMeshOrPinInstance(Layer layer) {
  for (final i in layer.effectStack) {
    if (i.enabled && (i.effectId == 'corner_pin' || i.effectId == 'mesh_warp')) return i;
  }
  return null;
}

// ===== shared frame-space geometry (movement-mobile-snapping-spec.md) =====

/// a layer's frame-space bbox/center/candidate-vertex list at a given
/// frame - factors out the "local bbox -> frame-space AABB" composition
/// that used to be duplicated informally at every call site that needed
/// it (canvas_renderer.dart, stage_gesture_controller.dart's
/// _handleTap, getTransformBoxHandles above). `vertices` is empty when
/// `includeVertices: false` (equal-size/grid/frame-boundary snapping
/// never needs a vertex list, only bbox/center).
class LayerFrameGeometry {
  final BoundingBox bbox;
  final List<double> center;
  final List<List<double>> vertices;
  LayerFrameGeometry({required this.bbox, required this.center, required this.vertices});
}

List<List<double>> _withMidpoints(List<List<double>> pts) {
  final out = <List<double>>[];
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    out.add(a);
    out.add([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]);
  }
  return out;
}

/// corner-to-corner candidate vertices for a layer, ALREADY projected
/// to frame space via `mCanvas` - the mesh-warp/corner-pin-aware
/// branching the snapping spec calls for:
/// - no active mesh-warp/corner-pin: plain shape corners/vertices, PLUS
///   edge-midpoints (a small, well-defined set regardless of any other
///   enabled effect like squeeze_axis/bend_arc - deliberately matching
///   getTransformBoxHandles's own existing getActiveMeshOrPinInstance
///   gate, which already treats "corners follow the plain shape" as
///   the default for anything not occupied by mesh/corner-pin).
/// - active corner-pin: its 4 mapped corners, PLUS their midpoints -
///   still a small, well-defined set.
/// - active mesh-warp: ONLY its own pin-grid intersections (the same
///   points already shown as draggable handles), NO midpoint
///   extension - a subdivided mesh has far more edges than a simple
///   shape, and getContentOutline's dense render-subdivision contour
///   (37 points for one 10x10-subdivided rect) would produce a cluster
///   of unhelpful near-duplicates rather than a small useful set.
List<List<double>> _cornerCandidateVertices(Project project, Layer layer, int globalFrame, List<double> mCanvas) {
  final deform = getActiveMeshOrPinInstance(layer);
  if (deform == null) {
    // cut by "Detach a piece": the corners of what is left.
    if (layer.pieceClips.isNotEmpty) {
      return [for (final p in pieceOutlinePoints(layer)) applyAffine(mCanvas, p)];
    }
    final local = isRectLikeShape(layer.content.shape)
        ? () {
            final b = shapeBoundingBox(layer.content);
            return [[b.minX, b.minY], [b.maxX, b.minY], [b.maxX, b.maxY], [b.minX, b.maxY]];
          }()
        : shapePoints(layer.content);
    final projected = [for (final p in local) applyAffine(mCanvas, p)];
    return _withMidpoints(projected);
  }
  if (deform.effectId == 'corner_pin') {
    final corners = getCornerPinHandles(project, layer, deform, globalFrame).screen.values.toList();
    return _withMidpoints(corners);
  }
  // mesh_warp
  return [for (final h in getMeshWarpHandles(project, layer, deform, globalFrame).handles) h.screen];
}

/// computes a layer's frame-space bbox/center/vertex-list either at its
/// CURRENT authored anchor (`anchorOverride: null`) or at a
/// HYPOTHETICAL anchor value (`anchorOverride: non-null`) - the latter
/// is what lets the dragged layer's own would-be geometry be computed
/// from a drag op's `newLocal` before it's actually written. Anchor is
/// the only param ever overridden; rotation/scale are always the
/// layer's normal evaluated (possibly parent-interpolated) value, since
/// only the dragged value itself carries the snapping spec's "authored,
/// not interpolated" requirement - a candidate (non-dragged) layer's
/// current position is read via the normal, fully-evaluated
/// `getLayerStateAt`, exactly where it visually sits right now,
/// including mid-interpolation between its own keyframes (that's
/// exactly what a user expects to snap against).
LayerFrameGeometry computeLayerFrameGeometry(
  Project project,
  Layer layer,
  int globalFrame, {
  List<double>? anchorOverride,
  bool includeVertices = true,
}) {
  final m = anchorOverride != null
      ? stationWorldMatrix(project, layer, anchorOverride, globalFrame)
      : getLayerStateAt(project, layer.id, globalFrame).matrix;
  final mCanvas = toFrameMatrix(m);
  final bboxLocal = pieceBoundingBox(layer);
  final corners = [
    [bboxLocal.minX, bboxLocal.minY],
    [bboxLocal.maxX, bboxLocal.minY],
    [bboxLocal.maxX, bboxLocal.maxY],
    [bboxLocal.minX, bboxLocal.maxY],
  ].map((p) => applyAffine(mCanvas, p)).toList();
  final xs = [for (final p in corners) p[0]], ys = [for (final p in corners) p[1]];
  final bbox = BoundingBox(minX: xs.reduce(math.min), maxX: xs.reduce(math.max), minY: ys.reduce(math.min), maxY: ys.reduce(math.max));
  final center = [(bbox.minX + bbox.maxX) / 2, (bbox.minY + bbox.maxY) / 2];
  if (!includeVertices) return LayerFrameGeometry(bbox: bbox, center: center, vertices: const []);
  return LayerFrameGeometry(bbox: bbox, center: center, vertices: _cornerCandidateVertices(project, layer, globalFrame, mCanvas));
}

// ===== transform box: edge handles + scale/rotate/move corners =====

class TransformBoxHandles {
  final BoundingBox bbox;
  final List<double> mCanvas;
  final List<double> mCanvasNoScale;
  final Map<String, List<double>> screen;
  TransformBoxHandles({required this.bbox, required this.mCanvas, required this.mCanvasNoScale, required this.screen});
}

/// Transform-box handles left out on a small or narrow box, so a tiny
/// object stays easy to grab (`framePerPx`: frame units per screen pixel).
/// A box too narrow for its top/bottom handles loses them (they'd sit on
/// the corners), too low for left/right the same; the smallest keeps only
/// the corner scale handle (and its move handle).
Set<String> crowdedTransformHandles(TransformBoxHandles tb, double framePerPx, {double minSidePx = 37, double minBoxPx = 21}) {
  double len(String a, String b) {
    final p = tb.screen[a]!, q = tb.screen[b]!;
    return math.sqrt(math.pow(p[0] - q[0], 2) + math.pow(p[1] - q[1], 2)) / framePerPx;
  }

  final w = len('tl', 'tr'), h = len('tl', 'bl');
  return {
    if (w < minSidePx) ...['top', 'bottom'],
    if (h < minSidePx) ...['left', 'right'],
    if (w < minBoxPx && h < minBoxPx) 'rotateCorner',
  };
}

TransformBoxHandles getTransformBoxHandles(Project project, Layer layer, int globalFrame) {
  // a detached piece (or what is left of its source) gets a box around
  // its own part, not around the whole original shape.
  final bbox = pieceBoundingBox(layer);
  final state = getLayerStateAt(project, layer.id, globalFrame);
  final m = state.matrix;
  final sx = state.scale[0], sy = state.scale[1];
  final safeSx = sx == 0 ? 1e-6 : sx, safeSy = sy == 0 ? 1e-6 : sy;
  final unscaled = [m[0] / safeSx, m[1] / safeSx, m[2] / safeSy, m[3] / safeSy];
  final mCanvas = toFrameMatrix(m);
  final mCanvasNoScale = [unscaled[0], unscaled[1], unscaled[2], unscaled[3], m[4] * stageSize.width, m[5] * stageSize.height];

  final midX = (bbox.minX + bbox.maxX) / 2, midY = (bbox.minY + bbox.maxY) / 2;

  final activeDeform = getActiveMeshOrPinInstance(layer);
  // a null: move and size handles in opposite corners.
  // right-handed: the move handle bottom right (a null's sits opposite
  // its size corner).
  final nearX = handlesRightHanded ? bbox.maxX : bbox.minX, farX = handlesRightHanded ? bbox.minX : bbox.maxX;
  var moveLocal = isNullLikeShape(layer.content.shape) ? [farX, bbox.maxY] : [nearX, bbox.maxY];
  if (activeDeform != null) {
    final deformed = getContentOutline(layer.content, layer, globalFrame, project: project);
    if (deformed.isNotEmpty) {
      var sx2 = 0.0, sy2 = 0.0;
      for (final p in deformed) {
        sx2 += p[0];
        sy2 += p[1];
      }
      moveLocal = [sx2 / deformed.length, sy2 / deformed.length];
    }
  }

  final localPoints = <String, List<double>>{
    'top': [midX, bbox.minY],
    'bottom': [midX, bbox.maxY],
    'left': [bbox.minX, midY],
    'right': [bbox.maxX, midY],
    'scaleCorner': scaleCornerLocal(bbox),
    'rotateCorner': [handlesRightHanded ? bbox.minX : bbox.maxX, bbox.minY],
    'moveCorner': moveLocal,
    'tl': [bbox.minX, bbox.minY],
    'tr': [bbox.maxX, bbox.minY],
    'br': [bbox.maxX, bbox.maxY],
    'bl': [bbox.minX, bbox.maxY],
  };
  final screen = <String, List<double>>{
    for (final entry in localPoints.entries) entry.key: applyAffine(mCanvas, entry.value),
  };
  return TransformBoxHandles(bbox: bbox, mCanvas: mCanvas, mCanvasNoScale: mCanvasNoScale, screen: screen);
}

// ===== corner-pin handles =====

class CornerPinHandles {
  final Map<String, List<double>> natural;
  final List<double> mCanvas;
  final Map<String, List<double>> screen;
  final List<String> keys;
  CornerPinHandles({required this.natural, required this.mCanvas, required this.screen, required this.keys});
}

CornerPinHandles getCornerPinHandles(Project project, Layer layer, EffectInstance inst, int globalFrame) {
  final localFrame = layerLocalFrame(layer, globalFrame);
  final isExact = inst.params.containsKey('p0');
  List<String> pKeys = const [];
  if (isExact) {
    pKeys = inst.params.keys.where((k) => RegExp(r'^p\d+$').hasMatch(k)).toList()
      ..sort((a, b) => int.parse(a.substring(1)).compareTo(int.parse(b.substring(1))));
  }
  final keys = isExact ? pKeys : const ['tl', 'tr', 'br', 'bl'];
  final off = <String, List<double>>{for (final k in keys) k: _evalVec2(project, inst.params[k] as Track, localFrame, layer)};

  final natural = <String, List<double>>{};
  if (isExact) {
    final pts = shapePoints(layer.content);
    for (var i = 0; i < pKeys.length; i++) {
      natural[pKeys[i]] = pts[i];
    }
  } else {
    final bbox = shapeBoundingBox(layer.content);
    natural['tl'] = [bbox.minX, bbox.minY];
    natural['tr'] = [bbox.maxX, bbox.minY];
    natural['br'] = [bbox.maxX, bbox.maxY];
    natural['bl'] = [bbox.minX, bbox.maxY];
  }

  final state = getLayerStateAt(project, layer.id, globalFrame);
  final mCanvas = toFrameMatrix(state.matrix);
  final screen = <String, List<double>>{
    for (final k in keys) k: applyAffine(mCanvas, [natural[k]![0] + off[k]![0], natural[k]![1] + off[k]![1]]),
  };
  return CornerPinHandles(natural: natural, mCanvas: mCanvas, screen: screen, keys: keys);
}

// ===== mesh-warp handles =====

class MeshWarpHandleEntry {
  final String key;
  final List<double> natural;
  final List<double> screen;
  MeshWarpHandleEntry({required this.key, required this.natural, required this.screen});
}

class MeshWarpHandles {
  final List<MeshWarpHandleEntry> handles;
  final List<double> mCanvas;
  final int rows;
  final int cols;
  MeshWarpHandles({required this.handles, required this.mCanvas, required this.rows, required this.cols});
}

MeshWarpHandles getMeshWarpHandles(Project project, Layer layer, EffectInstance inst, int globalFrame) {
  final localFrame = layerLocalFrame(layer, globalFrame);
  final bbox = shapeBoundingBox(layer.content);
  final rows = inst.params['rows'] as int;
  final cols = inst.params['cols'] as int;
  final state = getLayerStateAt(project, layer.id, globalFrame);
  final mCanvas = toFrameMatrix(state.matrix);
  final handles = <MeshWarpHandleEntry>[];
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      final key = 'r${r}c$c';
      final natX = bbox.minX + (bbox.maxX - bbox.minX) * (cols == 1 ? 0 : c / (cols - 1));
      final natY = bbox.minY + (bbox.maxY - bbox.minY) * (rows == 1 ? 0 : r / (rows - 1));
      final off = _evalVec2(project, inst.params[key] as Track, localFrame, layer);
      final local = [natX + off[0], natY + off[1]];
      handles.add(MeshWarpHandleEntry(key: key, natural: [natX, natY], screen: applyAffine(mCanvas, local)));
    }
  }
  return MeshWarpHandles(handles: handles, mCanvas: mCanvas, rows: rows, cols: cols);
}

// ===== generic effect deformation grid (squeeze/bend/any non-mesh,
// non-corner-pin vertex effect) =====

/// Not a port of anything in handles.js - JS never drew a preview grid
/// for anything besides mesh_warp/corner_pin, since those are the only
/// two effects with their own draggable stage handles. Real device
/// feedback: squeeze_axis (and bend_arc) edit purely through number
/// fields/a dropdown with no stage interaction at all, and without ANY
/// visual feedback on the actual object, their axisX/axisY/angle numbers
/// were "unclear" - this gives the same kind of on-stage readout
/// mesh_warp's own grid provides, just non-interactive (no handles to
/// drag, since these effects have no per-point params to drag).
class DeformationGridScreen {
  final List<List<double>> screen; // flattened row-major, `rows` x `cols`
  final int rows;
  final int cols;
  DeformationGridScreen({required this.screen, required this.rows, required this.cols});
}

/// samples the layer's OWN content bbox as an n x n grid, runs it
/// through the layer's full enabled effect stack (matching exactly what
/// the renderer itself would draw), and projects it to frame-space
/// screen points - null if the layer has no enabled effect at all,
/// so the caller never draws an empty/meaningless flat grid.
DeformationGridScreen? getEffectDeformationGridScreen(Project project, Layer layer, int globalFrame, {int n = 6}) {
  if (!layer.effectStack.any(isDeformingEffect)) return null;
  final state = getLayerStateAt(project, layer.id, globalFrame);
  final mCanvas = toFrameMatrix(state.matrix);
  // laid on the shape's own box (a triangle doesn't fill its content
  // box) - the same grid the shape is drawn through.
  final bb = shapeBoundingBox(layer.content);
  final box = Content(
    shape: 'rect',
    offset: [(bb.minX + bb.maxX) / 2, (bb.minY + bb.maxY) / 2],
    size: [bb.maxX - bb.minX, bb.maxY - bb.minY],
  );
  final srcGrid = buildEffectGrid(layer, isRectLikeShape(layer.content.shape) ? layer.content : box, globalFrame,
      project: project, n: n);
  final dstGrid = applyEffectStack(layer, srcGrid, globalFrame, project: project);
  final screen = <List<double>>[
    for (final row in dstGrid)
      for (final p in row) applyAffine(mCanvas, p),
  ];
  return DeformationGridScreen(screen: screen, rows: dstGrid.length, cols: dstGrid.isEmpty ? 0 : dstGrid[0].length);
}

// ===== pendulum pivot handle =====

class PendulumPivotHandle {
  final List<double> screen;
  final List<double> mCanvas;
  PendulumPivotHandle({required this.screen, required this.mCanvas});
}

/// uses the BASE (pre-swing) matrix, matching exactly how
/// getLayerStateAt derives the pivot's own world position internally -
/// see handles.js's own extensive doc comment on why the full post-
/// swing matrix would be wrong here (specifically under
/// rotateWithLine=false, where translation and the linear part are
/// deliberately decoupled).
PendulumPivotHandle getPendulumPivotHandleScreen(Project project, Layer layer, int globalFrame) {
  final state = getLayerStateAt(project, layer.id, globalFrame);
  final mCanvas = toFrameMatrix(state.baseMatrix);
  final localFrame = layerLocalFrame(layer, globalFrame);
  final local = _evalVec2(project, layer.pendulum.pivotOffset, localFrame, layer);
  return PendulumPivotHandle(screen: applyAffine(mCanvas, local), mCanvas: mCanvas);
}

/// The pendulum's weight handle (frame space).
PendulumPivotHandle getPendulumWeightHandleScreen(Project project, Layer layer, int globalFrame) {
  final mCanvas = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).baseMatrix);
  return PendulumPivotHandle(screen: applyAffine(mCanvas, pendulumWeightPoint(layer)), mCanvas: mCanvas);
}

// ===== 3D Rotate pivot =====

EffectInstance? getRotate3dInstance(Layer layer) {
  for (final inst in layer.effectStack) {
    if (inst.enabled && inst.effectId == 'rotate_3d') return inst;
  }
  return null;
}

class Rotate3dPivotHandle {
  final List<double> screen;
  final List<double> mCanvas;
  final BoundingBox bbox;

  /// The axis direction on screen (a unit-ish vector), for drawing it.
  final List<double> axisScreen;
  Rotate3dPivotHandle({required this.screen, required this.mCanvas, required this.bbox, required this.axisScreen});
}

/// The 3D Rotate pivot (a fraction of the content box) on the stage.
Rotate3dPivotHandle getRotate3dPivotHandle(Project project, Layer layer, EffectInstance inst, int globalFrame) {
  final localFrame = layerLocalFrame(layer, globalFrame);
  final bbox = shapeBoundingBox(layer.content);
  final f = _evalVec2(project, inst.params['pivot'] as Track, localFrame, layer);
  final local = [bbox.minX + f[0] * (bbox.maxX - bbox.minX), bbox.minY + f[1] * (bbox.maxY - bbox.minY)];
  final mCanvas = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  final axisParam = inst.params['axis'];
  final axisDeg = axisParam is Track ? evaluateTrack(project, axisParam, localFrame, layer) as double : 90.0;
  final a = axisDeg * math.pi / 180;
  final screen = applyAffine(mCanvas, local);
  final tip = applyAffine(mCanvas, [local[0] + math.cos(a), local[1] + math.sin(a)]);
  return Rotate3dPivotHandle(
      screen: screen, mCanvas: mCanvas, bbox: bbox, axisScreen: [tip[0] - screen[0], tip[1] - screen[1]]);
}

// ===== path: sampled line + station markers =====

class PathStation {
  final int idx;
  final List<double> screen;
  PathStation({required this.idx, required this.screen});
}

List<PathStation> getAnchorStationsScreen(Project project, Layer layer, int globalFrame) {
  // the keys being edited: an animation layer's sit where the object is
  // at their frame (they add to the base).
  final layered = activeAnimLayerOf(layer.transform.anchor);
  if (layered != null) {
    return [
      for (var idx = 0; idx < layered.track.keyframes.length; idx++)
        () {
          final m = getLayerStateAt(project, layer.id, layered.track.keyframes[idx].frame + layer.startFrame).matrix;
          return PathStation(idx: idx, screen: [m[4] * stageSize.width, m[5] * stageSize.height]);
        }()
    ];
  }
  final trk = layer.transform.anchor;
  if (!trk.spatial) return const [];
  final result = <PathStation>[];
  for (var idx = 0; idx < trk.keyframes.length; idx++) {
    final k = trk.keyframes[idx];
    final m = stationWorldMatrix(project, layer, k.value as List<double>, k.frame + layer.startFrame);
    result.add(PathStation(idx: idx, screen: [m[4] * stageSize.width, m[5] * stageSize.height]));
  }
  return result;
}

/// dotted-path polyline: samples the ACTUAL composed world position
/// (through the full parent matrix chain) at each step, not the raw
/// local anchor curve - stays correct if a parent is ever animated.
///
/// `steps` samples spread evenly across the WHOLE keyframe span, not per
/// segment - with many keyframes concentrated tightly together (a sharp turn
/// taking only a handful of frames out of a much longer overall span), that
/// segment could end up with only 1-2 of the `steps` samples, showing as
/// visible straight-line faceting instead of a smooth curve at exactly the
/// point where the path bends hardest. Fixed by using `steps` as a floor, not
/// a fixed total - guaranteeing roughly 30 samples per SEGMENT regardless of
/// how many segments the whole path has, so curve density scales with path
/// complexity instead of staying flat. Also samples at the exact fractional
/// frame now (state_cache.dart's getLayerStateAt accepts `num`) rather than
/// rounding each sample to the nearest integer frame first - a further
/// precision improvement, same reasoning as the motion-blur fractional-frame
/// fix. The path the object's centre really travels on the stage, over the
/// whole layer - whatever moves it (keys, animation layers, parents, wiggle,
/// pendulum,.). Empty when it doesn't move.
List<List<double>> samplePathScreen(Project project, Layer layer, int steps) {
  final box = pieceBoundingBox(layer);
  final centre = [(box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2];
  final from = layer.startFrame, to = layer.startFrame + layer.durationFrames;
  // about every frame, at most 600 points.
  final n = math.max(steps, math.min(600, to - from));
  final pts = <List<double>>[];
  var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
  for (var s = 0; s <= n; s++) {
    final f = from + (to - from) * s / n;
    final p = applyAffine(toFrameMatrix(getLayerStateAt(project, layer.id, f).matrix), centre);
    pts.add(p);
    minX = math.min(minX, p[0]);
    maxX = math.max(maxX, p[0]);
    minY = math.min(minY, p[1]);
    maxY = math.max(maxY, p[1]);
  }
  if (maxX - minX < 0.5 && maxY - minY < 0.5) return const [];
  return pts;
}

double distToSegment(List<double> p, List<double> a, List<double> b) {
  final dx = b[0] - a[0], dy = b[1] - a[1];
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return math.sqrt(math.pow(p[0] - a[0], 2) + math.pow(p[1] - a[1], 2));
  var t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
  t = math.max(0, math.min(1, t));
  return math.sqrt(math.pow(p[0] - (a[0] + t * dx), 2) + math.pow(p[1] - (a[1] + t * dy), 2));
}

double distToPolyline(List<double> p, List<List<double>> pts) {
  var best = double.infinity;
  for (var i = 0; i < pts.length - 1; i++) {
    best = math.min(best, distToSegment(p, pts[i], pts[i + 1]));
  }
  return best;
}

// ===== small typed wrappers around evaluateTrack's dynamic return, so
// call sites above don't each need their own `as double`/`as List<double>` =====

double _evalScalar(Project project, Track trk, double localFrame, Layer layer) => evaluateTrack(project, trk, localFrame, layer) as double;
List<double> _evalVec2(Project project, Track trk, double localFrame, Layer layer) => evaluateTrack(project, trk, localFrame, layer) as List<double>;

// ===== bend v2: start / end lines =====

/// A v2 bend on the stage, in frame space: its two lines and their
/// handles (drawn at their DEFORMED positions - rest points mapped
/// through the whole effect stack - so on chained bends each line sits
/// on the visible shape), the angle handle on the start line, and the
/// static / carried zones as polygons (for the tints).
class BendLinesHandle {
  final EffectInstance inst;
  final List<List<double>> startLine, endLine;
  final List<double> startHandle, endHandle, angleHandle;

  /// The start line's centre (the angle handle turns around it).
  final List<double> pivot;
  final List<List<double>> staticZone, carriedZone;

  /// Frame-space movement per unit of rest distance along the axis at
  /// each line (dragging a line projects the finger onto these).
  final List<double> startAxis, endAxis;

  /// The rest extent along the axis (start/end are fractions of it).
  final double extent;
  BendLinesHandle({
    required this.inst,
    required this.startLine,
    required this.endLine,
    required this.startHandle,
    required this.endHandle,
    required this.angleHandle,
    required this.pivot,
    required this.staticZone,
    required this.carriedZone,
    required this.startAxis,
    required this.endAxis,
    required this.extent,
  });
}

List<EffectInstance> getBendV2Instances(Layer layer) =>
    [for (final i in layer.effectStack) if (i.enabled && isBendV2(i)) i];

List<BendLinesHandle> getBendHandles(Project project, Layer layer, int globalFrame) {
  final insts = getBendV2Instances(layer);
  if (insts.isEmpty) return const [];
  final localFrame = layerLocalFrame(layer, globalFrame);
  final box = shapeBoundingBox(layer.content);
  final mCanvas = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  List<List<double>> deform(List<List<double>> rest) =>
      [for (final p in applyEffectStack(layer, [rest], globalFrame, project: project)[0]) applyAffine(mCanvas, p)];

  final out = <BendLinesHandle>[];
  for (final inst in insts) {
    final params = resolveEffectParams(inst, localFrame)
      ..['angle'] = bendPhysicsAngle(project, layer, inst, localFrame);
    final f = bendFrameFor(params, box);
    final len = f.sMax - f.sMin;
    const eps = 1.0;
    final s0a = bendChord(f, box, f.s0), s1a = bendChord(f, box, f.s1);
    final mid0 = f.at(f.s0, (f.wOf(s0a[0]) + f.wOf(s0a[1])) / 2);
    final mid1 = f.at(f.s1, (f.wOf(s1a[0]) + f.wOf(s1a[1])) / 2);
    // just inside the static side / the band, so each point is classified
    // with the zone it belongs to.
    final pts = deform([
      s0a[0], s0a[1], s1a[0], s1a[1], mid0, mid1,
      f.at(f.s0 - eps, f.wOf(mid0)), f.at(f.s1 + eps, f.wOf(mid1)),
      // angle knob: on the start line, a bit past its end.
      f.at(f.s0, f.wOf(s0a[1]) + len * 0.12),
    ]);
    List<double> dir(List<double> a, List<double> b) => [(b[0] - a[0]) / eps, (b[1] - a[1]) / eps];

    // zones: the box part before the start line / after the end line,
    // edges sampled so they follow the deformation.
    List<List<double>> zone(double sFrom, double sTo) {
      const k = 10;
      final rest = <List<double>>[];
      for (var i = 0; i <= k; i++) {
        rest.add(bendChord(f, box, sFrom + (sTo - sFrom) * i / k)[0]);
      }
      for (var i = k; i >= 0; i--) {
        rest.add(bendChord(f, box, sFrom + (sTo - sFrom) * i / k)[1]);
      }
      return deform(rest);
    }

    out.add(BendLinesHandle(
      inst: inst,
      startLine: [pts[0], pts[1]],
      endLine: [pts[2], pts[3]],
      startHandle: pts[4],
      endHandle: pts[5],
      angleHandle: pts[8],
      pivot: pts[4],
      // the static zone is everything before the start line; the tip side
      // after the end line moves without bending.
      staticZone: zone(f.sMin, f.s0 - 1e-6),
      carriedZone: zone(f.s1 + 1e-6, f.sMax),
      startAxis: dir(pts[6], pts[4]),
      endAxis: dir(pts[5], pts[7]),
      extent: len,
    ));
  }
  return out;
}
