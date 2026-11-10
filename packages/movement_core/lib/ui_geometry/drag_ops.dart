/// ============================================================
/// Pure port of movement-core/src/ui/stage/pointerRouter.js's 8
/// pointermove mutation modes (corner/mesh/pendulumPivot/station/
/// anchor/path/rotate/scale) - this IS the "underlying reparent/mesh-
/// warp/corner-pin logic" the gesture spec says is explicitly out of
/// scope to change; only capture priority/visibility/touch-radius are
/// new (movement_mobile's stage_gesture_controller.dart). Each class
/// here mirrors one JS `stageDragHandle` mode: a `.grab(...)` factory
/// captures whatever JS's pointerdown handler captures into that mode's
/// object literal, and `.apply(...)` mirrors JS's pointermove branch
/// for that mode exactly, including which fields get recomputed fresh
/// each move vs. which stay fixed from the grab (that split isn't
/// uniform in JS - e.g. mesh-warp's `natural` is captured once, corner-
/// pin's is recomputed every move - preserved deliberately, not
/// "cleaned up" into a uniform pattern JS doesn't actually have).
///
/// `framePoint` throughout is a FRAME-space [x,y] (see handles.dart's
/// own note on this convention) - the caller (movement_mobile's gesture
/// controller) converts raw touch input through the pan/zoom camera
/// transform before calling in here; this file has no camera/screen
/// concept at all, same separation as handles.dart.
/// ============================================================
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../core/math.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../model/project.dart';
import '../model/track_edit.dart';
import '../effects/motion/pendulum.dart' show pendulumWeightPoint;
import 'handles.dart';
import 'snapping.dart';

// which keyframe an edit changes (exact / boundary / static default) is
// decided by track_edit.dart's keyframeToEdit - one rule for every op
// below and every parameter field in the app.

/// converts a FRAME-space point into the anchor VALUE that would place
/// this layer there, in the layer's own PARENT's coordinate frame - same
/// inverse-matrix math already used for path-follow and reparenting.
List<double> anchorLocalFromScreen(
    Project project, Layer layer, double mx, double my, int globalFrame) {
  final parentMatrix = layer.parentId != null
      ? parentMatrixFor(project, layer, globalFrame)
      : <double>[1, 0, 0, 1, 0, 0];
  final targetFraction = [mx / stageSize.width, my / stageSize.height];
  return applyAffine(invertAffine(parentMatrix), targetFraction);
}

/// common interface every drag mode below implements - lets
/// movement_mobile's stage_gesture_controller.dart hold "whichever mode
/// is currently captured" as one typed reference instead of a manual
/// tag+union, without needing to know which of the 8 concrete modes
/// it's holding to call apply() on a pointer move.
abstract class DragOp {
  void apply(Project project, int globalFrame, List<double> framePoint);

  /// which snap candidate(s) (if any) won during the most recent
  /// apply() call - movement_mobile's stage_painter.dart reads this off
  /// the currently-held op to draw transient guide lines, cleared
  /// automatically the instant the drag ends (the op itself is
  /// discarded on pointer-up). Only AnchorDragOp/ScaleDragOp/RotateDragOp
  /// override this - the other 5 modes are out of scope for snapping
  /// (whole-object position/size/rotation only, not sub-handle
  /// deformation).
  List<SnapGuideLine> get snapGuides => const [];
}

// ===== corner-pin =====

class CornerDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  final String corner;
  CornerDragOp({required this.layer, required this.inst, required this.corner});

  @override
  List<SnapGuideLine> get snapGuides =>
      const []; // out of scope: sub-handle deformation, not whole-object position/size

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final handles = getCornerPinHandles(project, layer, inst, globalFrame);
    final localPoint = applyAffine(invertAffine(handles.mCanvas), framePoint);
    final natural = handles.natural[corner]!;
    final newOffset = [localPoint[0] - natural[0], localPoint[1] - natural[1]];
    final trk = inst.params[corner] as Track;
    setTrackValueAt(trk, localFrameOf(layer, globalFrame), newOffset);
  }
}

// ===== mesh-warp =====

class MeshDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  final String pinKey;
  final List<double>
      natural; // captured once at grab, unlike corner's (matches JS)
  MeshDragOp(
      {required this.layer,
      required this.inst,
      required this.pinKey,
      required this.natural});

  @override
  List<SnapGuideLine> get snapGuides =>
      const []; // out of scope: sub-handle deformation, not whole-object position/size

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final handles = getMeshWarpHandles(project, layer, inst, globalFrame);
    final localPoint = applyAffine(invertAffine(handles.mCanvas), framePoint);
    final newOffset = [localPoint[0] - natural[0], localPoint[1] - natural[1]];
    final trk = inst.params[pinKey] as Track;
    setTrackValueAt(trk, localFrameOf(layer, globalFrame), newOffset);
  }
}

// ===== pendulum pivot =====

class PendulumPivotDragOp implements DragOp {
  final Layer layer;
  final List<double> grabDelta;
  PendulumPivotDragOp({required this.layer, required this.grabDelta});

  @override
  List<SnapGuideLine> get snapGuides =>
      const []; // out of scope: sub-handle deformation, not whole-object position/size

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final handle = getPendulumPivotHandleScreen(project, layer, globalFrame);
    final localPoint = applyAffine(invertAffine(handle.mCanvas), framePoint);
    final newOffset = [
      localPoint[0] - grabDelta[0],
      localPoint[1] - grabDelta[1]
    ];
    final trk = layer.pendulum.pivotOffset;
    setTrackValueAt(trk, localFrameOf(layer, globalFrame), newOffset);
  }

  factory PendulumPivotDragOp.grab(Project project, Layer layer,
      int globalFrame, List<double> grabFramePoint) {
    final handle = getPendulumPivotHandleScreen(project, layer, globalFrame);
    final grabLocal = applyAffine(invertAffine(handle.mCanvas), grabFramePoint);
    final currentVal = evaluateTrack(project, layer.pendulum.pivotOffset,
        localFrameOf(layer, globalFrame).toDouble(), layer) as List<double>;
    return PendulumPivotDragOp(layer: layer, grabDelta: [
      grabLocal[0] - currentVal[0],
      grabLocal[1] - currentVal[1]
    ]);
  }
}

/// Drags the pendulum's weight (the line's other end).
class PendulumWeightDragOp implements DragOp {
  final Layer layer;
  final List<double> grabDelta;
  PendulumWeightDragOp({required this.layer, required this.grabDelta});

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final h = getPendulumWeightHandleScreen(project, layer, globalFrame);
    final p = applyAffine(invertAffine(h.mCanvas), framePoint);
    layer.pendulum.weightPoint = [p[0] - grabDelta[0], p[1] - grabDelta[1]];
  }

  factory PendulumWeightDragOp.grab(Project project, Layer layer, int globalFrame, List<double> grabFramePoint) {
    final h = getPendulumWeightHandleScreen(project, layer, globalFrame);
    final g = applyAffine(invertAffine(h.mCanvas), grabFramePoint);
    final cur = pendulumWeightPoint(layer);
    return PendulumWeightDragOp(layer: layer, grabDelta: [g[0] - cur[0], g[1] - cur[1]]);
  }
}

// ===== 3D Rotate pivot =====

class Rotate3dPivotDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  final List<double> grabDelta; // local grab point minus the pivot's local point
  Rotate3dPivotDragOp({required this.layer, required this.inst, required this.grabDelta});

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final h = getRotate3dPivotHandle(project, layer, inst, globalFrame);
    final local = applyAffine(invertAffine(h.mCanvas), framePoint);
    final b = h.bbox;
    final w = b.maxX - b.minX, hh = b.maxY - b.minY;
    if (w <= 0 || hh <= 0) return;
    setTrackValueAt(inst.params['pivot'] as Track, localFrameOf(layer, globalFrame), [
      (local[0] - grabDelta[0] - b.minX) / w,
      (local[1] - grabDelta[1] - b.minY) / hh,
    ]);
  }

  factory Rotate3dPivotDragOp.grab(Project project, Layer layer, EffectInstance inst, int globalFrame, List<double> grabFramePoint) {
    final h = getRotate3dPivotHandle(project, layer, inst, globalFrame);
    final inv = invertAffine(h.mCanvas);
    final grab = applyAffine(inv, grabFramePoint);
    final pivot = applyAffine(inv, h.screen);
    return Rotate3dPivotDragOp(layer: layer, inst: inst, grabDelta: [grab[0] - pivot[0], grab[1] - pivot[1]]);
  }
}

// ===== bend v2: start / end lines, axis angle =====

/// Drags one of a v2 bend's handles: `which` is 'start' or 'end' (the line
/// moves along its own axis by the finger's movement projected onto the
/// axis direction where it sits) or 'angle' (turns the bend axis around
/// the start line's centre).
class BendHandleDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  final String which;
  final List<double> grab;
  final double startValue;
  final List<double> axis; // frame px per rest unit along the axis
  final double extent;
  final List<double> pivot;
  final bool mirrored;
  BendHandleDragOp._(this.layer, this.inst, this.which, this.grab, this.startValue, this.axis, this.extent,
      this.pivot, this.mirrored);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  factory BendHandleDragOp.grab(
      Project project, Layer layer, BendLinesHandle h, String which, int globalFrame, List<double> grabFramePoint) {
    final key = which == 'angle' ? 'axisAngle' : which;
    final value = evaluateTrack(project, h.inst.params[key] as Track, layerLocalFrame(layer, globalFrame), layer) as double;
    final m = getLayerStateAt(project, layer.id, globalFrame).matrix;
    return BendHandleDragOp._(layer, h.inst, which, grabFramePoint, value, which == 'end' ? h.endAxis : h.startAxis,
        h.extent, h.pivot, m[0] * m[3] - m[1] * m[2] < 0);
  }

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final frame = localFrameOf(layer, globalFrame);
    double param(String k) => evaluateTrack(project, inst.params[k] as Track, frame.toDouble(), layer) as double;
    if (which == 'angle') {
      double ang(List<double> p) => math.atan2(p[1] - pivot[1], p[0] - pivot[0]);
      var d = (ang(framePoint) - ang(grab)) * 180 / math.pi;
      if (mirrored) d = -d;
      var v = startValue + d;
      v = ((v + 180) % 360 + 360) % 360 - 180;
      setTrackValueAt(inst.params['axisAngle'] as Track, frame, v);
      return;
    }
    final l2 = axis[0] * axis[0] + axis[1] * axis[1];
    if (l2 < 1e-12 || extent <= 0) return;
    final ds = ((framePoint[0] - grab[0]) * axis[0] + (framePoint[1] - grab[1]) * axis[1]) / l2;
    var v = startValue + ds / extent;
    v = which == 'start' ? v.clamp(0.0, param('end') - 0.02) : v.clamp(param('start') + 0.02, 1.0);
    setTrackValueAt(inst.params[which] as Track, frame, v.toDouble());
  }
}

// ===== path: existing station =====

class StationDragOp implements DragOp {
  final Layer layer;
  final int keyframeIdx;
  final List<double> startLocal;
  final List<double> startValue;
  StationDragOp(
      {required this.layer,
      required this.keyframeIdx,
      required this.startLocal,
      required this.startValue});

  @override
  List<SnapGuideLine> get snapGuides =>
      const []; // out of scope: sub-handle deformation, not whole-object position/size

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    // the keys being edited (the base's or an animation layer's).
    final trk = editTrackOf(layer.transform.anchor);
    final nowLocal = anchorLocalFromScreen(
        project, layer, framePoint[0], framePoint[1], globalFrame);
    trk.keyframes[keyframeIdx].value = [
      startValue[0] + (nowLocal[0] - startLocal[0]),
      startValue[1] + (nowLocal[1] - startLocal[1])
    ];
    if (trk.spatial) autoComputeTangents(trk);
  }

  factory StationDragOp.grab(Project project, Layer layer, int keyframeIdx,
      int globalFrame, List<double> grabFramePoint) {
    final startLocal = anchorLocalFromScreen(
        project, layer, grabFramePoint[0], grabFramePoint[1], globalFrame);
    final startValue = List<double>.from(
        editTrackOf(layer.transform.anchor).keyframes[keyframeIdx].value as List<double>);
    return StationDragOp(
        layer: layer,
        keyframeIdx: keyframeIdx,
        startLocal: startLocal,
        startValue: startValue);
  }
}

// ===== transform box: move/anchor handle =====

/// Moving on the stage only along one axis: 'x', 'y' or null (free).
String? dragAxisLock;

class AnchorDragOp implements DragOp {
  final Layer layer;
  final List<double> startLocal;
  final List<double> startValue;
  AnchorDragOp(
      {required this.layer,
      required this.startLocal,
      required this.startValue});

  List<SnapGuideLine> _snapGuides = const [];
  @override
  List<SnapGuideLine> get snapGuides => _snapGuides;

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final trk = layer.transform.anchor;
    final nowLocal = anchorLocalFromScreen(
        project, layer, framePoint[0], framePoint[1], globalFrame);
    var newLocal = [
      startValue[0] + (nowLocal[0] - startLocal[0]),
      startValue[1] + (nowLocal[1] - startLocal[1])
    ];
    final snap = computeAnchorSnap(
        project: project,
        layer: layer,
        globalFrame: globalFrame,
        newLocal: newLocal);
    newLocal = snap.newLocal;
    _snapGuides = snap.guides;
    // the stage's axis lock: only along x, or only along y.
    if (dragAxisLock == 'x') newLocal = [newLocal[0], startValue[1]];
    if (dragAxisLock == 'y') newLocal = [startValue[0], newLocal[1]];
    setTrackValueAt(trk, localFrameOf(layer, globalFrame), newLocal);
  }

  factory AnchorDragOp.grab(Project project, Layer layer, int globalFrame,
      List<double> grabFramePoint) {
    final trk = layer.transform.anchor;
    final startValue = List<double>.from(
        trackValueToEdit(trk, localFrameOf(layer, globalFrame)) as List<double>);
    final startLocal = anchorLocalFromScreen(
        project, layer, grabFramePoint[0], grabFramePoint[1], globalFrame);
    return AnchorDragOp(
        layer: layer, startLocal: startLocal, startValue: startValue);
  }
}

// ===== path body (drag the whole path by a uniform delta) =====

class PathDragOp implements DragOp {
  final Layer layer;
  final List<double> startLocal;
  final List<double> snapshotDefault;
  final List<List<double>> snapshotValues;
  PathDragOp(
      {required this.layer,
      required this.startLocal,
      required this.snapshotDefault,
      required this.snapshotValues});

  @override
  List<SnapGuideLine> get snapGuides =>
      const []; // out of scope: sub-handle deformation, not whole-object position/size

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final trk = layer.transform.anchor;
    final nowLocal = anchorLocalFromScreen(
        project, layer, framePoint[0], framePoint[1], globalFrame);
    final delta = [nowLocal[0] - startLocal[0], nowLocal[1] - startLocal[1]];
    trk.defaultValue = [
      snapshotDefault[0] + delta[0],
      snapshotDefault[1] + delta[1]
    ];
    for (var i = 0; i < trk.keyframes.length; i++) {
      trk.keyframes[i].value = [
        snapshotValues[i][0] + delta[0],
        snapshotValues[i][1] + delta[1]
      ];
    }
    if (trk.spatial) autoComputeTangents(trk);
  }

  factory PathDragOp.grab(Project project, Layer layer, int globalFrame,
      List<double> grabFramePoint) {
    final trk = layer.transform.anchor;
    final startLocal = anchorLocalFromScreen(
        project, layer, grabFramePoint[0], grabFramePoint[1], globalFrame);
    final snapshotDefault = List<double>.from(trk.defaultValue as List<double>);
    final snapshotValues = [
      for (final k in trk.keyframes) List<double>.from(k.value as List<double>)
    ];
    return PathDragOp(
        layer: layer,
        startLocal: startLocal,
        snapshotDefault: snapshotDefault,
        snapshotValues: snapshotValues);
  }
}

// ===== transform box: rotate corner =====

class RotateDragOp implements DragOp {
  final Layer layer;
  final List<double> anchorScreen;
  final double startAngle;
  final double startRotation;
  RotateDragOp(
      {required this.layer,
      required this.anchorScreen,
      required this.startAngle,
      required this.startRotation});

  SnapGuideLine? _snapGuide;
  @override
  List<SnapGuideLine> get snapGuides =>
      _snapGuide == null ? const [] : [_snapGuide!];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final angleNow = math.atan2(
        framePoint[1] - anchorScreen[1], framePoint[0] - anchorScreen[0]);
    final deltaDeg = (angleNow - startAngle) * 180 / math.pi;
    final trk = layer.transform.rotation;
    final snap = computeRotationSnap(
        project: project,
        layer: layer,
        globalFrame: globalFrame,
        newRotation: startRotation + deltaDeg);
    final newRotation = snap.newRotation;
    _snapGuide = snap.guide;
    setTrackValueAt(trk, localFrameOf(layer, globalFrame), newRotation);
  }

  factory RotateDragOp.grab(Project project, Layer layer, int globalFrame,
      List<double> grabFramePoint) {
    final anchorScreen = getAnchorLiveHandleScreen(project, layer, globalFrame);
    final startAngle = math.atan2(grabFramePoint[1] - anchorScreen[1],
        grabFramePoint[0] - anchorScreen[0]);
    final startRotation = evaluateTrack(project, layer.transform.rotation,
        localFrameOf(layer, globalFrame).toDouble(), layer) as double;
    return RotateDragOp(
        layer: layer,
        anchorScreen: anchorScreen,
        startAngle: startAngle,
        startRotation: startRotation);
  }
}

// ===== transform box: edge/scale-corner handles =====

double _orOne(double v) => v == 0 ? 1 : v;

/// Text layers: the side handles resize the text box instead of scaling
/// the object - the text reflows (narrow it far enough and it stacks into
/// a vertical column). Both handles of an axis do the same thing: the box
/// stays centred and only its width (left/right) or height (top/bottom)
/// changes.
class TextBoxDragOp implements DragOp {
  final Layer layer;
  final String handle; // 'left' | 'right' | 'top' | 'bottom'
  TextBoxDragOp({required this.layer, required this.handle});

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    // a box sized by hand: the text wraps to it, no more auto box.
    layer.content.text?.autoBox = false;
    final tb = getTransformBoxHandles(project, layer, globalFrame);
    final local = applyAffine(invertAffine(tb.mCanvas), framePoint);
    final c = layer.content;
    if (handle == 'left' || handle == 'right') {
      c.size = [math.max(1.0, 2 * (local[0] - c.offset[0]).abs()), c.size[1]];
    } else {
      c.size = [c.size[0], math.max(1.0, 2 * (local[1] - c.offset[1]).abs())];
    }
  }
}

/// A null's corner handle: grows / shrinks its square (its size), never
/// the point itself (its scale stays).
class NullSizeDragOp implements DragOp {
  final Layer layer;
  NullSizeDragOp({required this.layer});

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final tb = getTransformBoxHandles(project, layer, globalFrame);
    final local = applyAffine(invertAffine(tb.mCanvas), framePoint);
    final c = layer.content;
    final double side = math.max(4.0, 2 * math.max((local[0] - c.offset[0]).abs(), (local[1] - c.offset[1]).abs()));
    c.size = [side, side];
  }
}

class ScaleDragOp implements DragOp {
  final Layer layer;
  final String handle; // 'scaleCorner' | 'left' | 'right' | 'top' | 'bottom'
  ScaleDragOp({required this.layer, required this.handle});

  SnapGuideLine? _snapGuide;
  @override
  List<SnapGuideLine> get snapGuides =>
      _snapGuide == null ? const [] : [_snapGuide!];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final tb = getTransformBoxHandles(project, layer, globalFrame);
    final localPt = applyAffine(invertAffine(tb.mCanvasNoScale), framePoint);
    final trk = layer.transform.scale;
    final current =
        trackValueToEdit(trk, localFrameOf(layer, globalFrame)) as List<double>;
    if (rectExtendMode && layer.content.shape == 'rect') {
      _applyExtend(localPt, current);
      return;
    }
    if (scaleKeepsOppositeEdge) {
      _applyFromOppositeEdge(project, globalFrame, tb, localPt, current);
      return;
    }
    List<double> newScale;
    if (handle == 'scaleCorner') {
      // keeps the current aspect ratio a non-uniformly scaled object snapped
      // back to 1:1): project the finger onto the direction of the corner as
      // it's drawn now, (minX*sx, minY*sy), and scale both axes by that one
      // factor.
      final corner = scaleCornerLocal(tb.bbox);
      final cx = corner[0] * current[0], cy = corner[1] * current[1];
      final len2 = cx * cx + cy * cy;
      if (len2 > 1e-9) {
        // abs: like the old distance-based ratio, dragging past the
        // anchor never flips the object.
        final k = ((localPt[0] * cx + localPt[1] * cy) / len2).abs();
        newScale = [current[0] * k, current[1] * k];
      } else {
        final origDist = _orOne(math.sqrt(corner[0] * corner[0] + corner[1] * corner[1]));
        final ratio =
            math.sqrt(localPt[0] * localPt[0] + localPt[1] * localPt[1]) /
                origDist;
        newScale = [ratio, ratio];
      }
    } else if (handle == 'left' || handle == 'right') {
      final origX = _orOne(handle == 'left' ? tb.bbox.minX : tb.bbox.maxX);
      // abs: dragging an edge past the anchor doesn't flip the object
      // (mirroring is Crop's / Stage's, not the size handles').
      newScale = [(localPt[0] / origX).abs(), current[1]];
    } else {
      final origY = _orOne(handle == 'top' ? tb.bbox.minY : tb.bbox.maxY);
      newScale = [current[0], (localPt[1] / origY).abs()];
    }
    final snap = computeScaleSnap(
        project: project,
        layer: layer,
        globalFrame: globalFrame,
        handle: handle,
        newScale: newScale,
        localBbox: tb.bbox);
    newScale = snap.newScale;
    _snapGuide = snap.guide;
    setTrackValueAt(trk, localFrameOf(layer, globalFrame), newScale);
  }

  /// Lengthens the rect: its side (or corner) to the finger, the one
  /// across where it was (in the layer's own units, so its scale stays).
  /// While lengthening: the rect when the drag started (content box:
  /// minX, minY, maxX, maxY) - the stage shows what grew and what went.
  List<double>? extendStart;

  void _applyExtend(List<double> localPt, List<double> current) {
    final c = layer.content;
    extendStart ??= [c.offset[0] - c.size[0] / 2, c.offset[1] - c.size[1] / 2, c.offset[0] + c.size[0] / 2, c.offset[1] + c.size[1] / 2];
    final sx = current[0].abs() < 1e-9 ? 1.0 : current[0], sy = current[1].abs() < 1e-9 ? 1.0 : current[1];
    final q = [localPt[0] / sx, localPt[1] / sy];
    var minX = c.offset[0] - c.size[0] / 2, maxX = c.offset[0] + c.size[0] / 2;
    var minY = c.offset[1] - c.size[1] / 2, maxY = c.offset[1] + c.size[1] / 2;
    final left = handle == 'left' || (handle == 'scaleCorner' && q[0] < c.offset[0]);
    final right = handle == 'right' || (handle == 'scaleCorner' && q[0] >= c.offset[0]);
    final top = handle == 'top' || (handle == 'scaleCorner' && q[1] < c.offset[1]);
    final bottom = handle == 'bottom' || (handle == 'scaleCorner' && q[1] >= c.offset[1]);
    if (left) minX = math.min(q[0], maxX - 1);
    if (right) maxX = math.max(q[0], minX + 1);
    if (top) minY = math.min(q[1], maxY - 1);
    if (bottom) maxY = math.max(q[1], minY + 1);
    c
      ..size = [maxX - minX, maxY - minY]
      ..offset = [(minX + maxX) / 2, (minY + maxY) / 2];
    _snapGuide = null;
  }

  /// The edge (or corner) across from the handle stays where it is: the
  /// size runs from it to the finger, and the layer moves to keep it.
  void _applyFromOppositeEdge(
      Project project, int globalFrame, TransformBoxHandles tb, List<double> localPt, List<double> current) {
    final b = tb.bbox;
    final midX = (b.minX + b.maxX) / 2, midY = (b.minY + b.maxY) / 2;
    final List<double> here, opp;
    switch (handle) {
      case 'left':
        here = [b.minX, midY];
        opp = [b.maxX, midY];
      case 'right':
        here = [b.maxX, midY];
        opp = [b.minX, midY];
      case 'top':
        here = [midX, b.minY];
        opp = [midX, b.maxY];
      case 'bottom':
        here = [midX, b.maxY];
        opp = [midX, b.minY];
      default:
        here = scaleCornerLocal(b);
        opp = [b.minX + b.maxX - here[0], b.minY + b.maxY - here[1]];
    }
    final before = applyAffine(tb.mCanvas, opp);
    // the finger and the handle, measured from the fixed side (scaled).
    final fx = localPt[0] - opp[0] * current[0], fy = localPt[1] - opp[1] * current[1];
    final hx = (here[0] - opp[0]) * current[0], hy = (here[1] - opp[1]) * current[1];
    List<double> next;
    if (handle == 'left' || handle == 'right') {
      next = [hx.abs() < 1e-9 ? current[0] : (current[0] * fx / hx).abs(), current[1]];
    } else if (handle == 'top' || handle == 'bottom') {
      next = [current[0], hy.abs() < 1e-9 ? current[1] : (current[1] * fy / hy).abs()];
    } else {
      final len2 = hx * hx + hy * hy;
      final k = len2 < 1e-9 ? 1.0 : ((fx * hx + fy * hy) / len2).abs();
      next = [current[0] * k, current[1] * k];
    }
    next = [math.max(1e-4, next[0]), math.max(1e-4, next[1])];
    final lf = localFrameOf(layer, globalFrame);
    setTrackValueAt(layer.transform.scale, lf, next);
    _snapGuide = null;
    // move the layer so the fixed side is back where it was (the new
    // scale, not the cached state).
    clearStateCaches();
    final after = applyAffine(getTransformBoxHandles(project, layer, globalFrame).mCanvas, opp);
    final d = frameDeltaToLocal(project, layer, globalFrame, after, [before[0] - after[0], before[1] - after[1]]);
    final a = trackValueToEdit(layer.transform.anchor, lf) as List<double>;
    setTrackValueAt(layer.transform.anchor, lf, [a[0] + d[0], a[1] + d[1]]);
    clearStateCaches();
  }
}

/// Stage, rects: a size handle adds surface instead of stretching (the
/// rect's own size changes, its corners and outline as they were); the
/// side across stays put.
bool rectExtendMode = false;

/// Stage: a size handle keeps the edge across from it in place (off: the
/// object grows / shrinks about its anchor, both sides moving).
bool scaleKeepsOppositeEdge = false;
