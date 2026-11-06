import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import 'stage_camera.dart';
import 'stage_painter.dart' show regionsPanelOpen, showRegionTints;

/// which magnet-drag family (if any) currently has a captured handle -
/// the painter uses this to hide that family's OTHER handles while
/// showing the active one, per the gesture spec's per-family sibling-
/// hide rule. `'path'` is not one of the 4 "families" the spec names
/// (station/path-body drags don't have siblings to hide within
/// themselves) but is tracked the same way so the painter can still
/// tell something is being dragged.
class ActiveDragInfo {
  final String family; // 'transformBox' | 'meshWarp' | 'cornerPin' | 'pendulumPivot' | 'rotate3dPivot' | 'glow' | 'bendLine' | 'path' | 'crop' | 'chromaRegion'
  final String? activeKey; // e.g. 'r0c0', 'p0', 'scaleCorner' - null for pendulumPivot/path (single handle, nothing to distinguish)
  final DragOp op;
  ActiveDragInfo({required this.family, required this.activeKey, required this.op});
}

/// Hand-rolled multi-pointer state machine - raw `Listener` events, NOT
/// `GestureDetector`/`ScaleGestureRecognizer`. Two reasons: (1) it needs
/// to coexist with a single-finger exclusive handle-drag that must win
/// outright over Flutter's own gesture arena rather than negotiate with
/// it, and (2) it mirrors JS's own pointerRouter.js, which is ALSO raw
/// `pointerdown`/`pointermove`/`pointerup` listeners, not any browser
/// high-level gesture API - same approach, not a Flutter-specific
/// reinvention.
///
/// UNVERIFIED - needs the Flutter engine (PointerEvent, Offset), not
/// available in this sandbox. The actual per-mode MUTATION math this
/// delegates to (movement_core's ui_geometry/drag_ops.dart) is real-
/// tested; what's unverified here is purely the pointer routing/
/// priority/camera glue around it.
class StageGestureController {
  final AppState app;
  final StageCamera camera;
  final ui.VoidCallback onNeedsRepaint;

  StageGestureController({required this.app, required this.camera, required this.onNeedsRepaint});

  final Map<int, ui.Offset> _pointers = {};

  int? _primaryPointerId; // owns either the active drag OR a pending tap
  ui.Offset? _primaryDownScreen;
  bool _primaryMovedPastTapThreshold = false;

  ActiveDragInfo? _activeDrag;

  int? _pinchA, _pinchB;
  ui.Offset? _pinchLastA, _pinchLastB;

  ActiveDragInfo? get activeDrag => _activeDrag;

  /// Where the eyedropper finger is on screen (null when not picking) -
  /// the painter draws the loupe above it.
  ui.Offset? chromaPickScreen;

  /// The selection rectangle being dragged (screen corners), or null.
  ui.Offset? marqueeA, marqueeB;
  bool get marqueeActive => marqueeA != null;
  bool get anyDragActive => _activeDrag != null;

  void onPointerDown(PointerDownEvent event) {
    if (_activeDrag != null) {
      // a second finger during the Chroma eyedropper left the loupe frozen on
      // the stage and blocked zooming. The chroma stage tools now give way:
      // the pick / region is dropped (nothing is taken) and the two fingers
      // pinch-zoom.
      final op = _activeDrag!.op;
      final primary = _primaryPointerId;
      if ((op is ChromaPickDragOp || op is ChromaRegionDragOp) && primary != null && _pointers.containsKey(primary)) {
        _activeDrag = null;
        app.endGroupTransform();
        chromaPickScreen = null;
        _pointers[event.pointer] = event.localPosition;
        _primaryPointerId = null;
        _primaryDownScreen = null;
        _pinchA = primary;
        _pinchB = event.pointer;
        _pinchLastA = _pointers[primary];
        _pinchLastB = event.localPosition;
        onNeedsRepaint();
      }
      return; // any other drag: one live gesture at a time - second touch ignored outright, not tracked
    }
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 1) {
      _primaryPointerId = event.pointer;
      _primaryDownScreen = event.localPosition;
      _primaryDownTime = event.timeStamp;
      _primaryMovedPastTapThreshold = false;
      // a new shape waits for its box: the drag draws it.
      if (app.pendingPlaceShape != null) {
        marqueeA = marqueeB = event.localPosition;
        return;
      }
      _tryCaptureHandle(event.localPosition);
      // the selection rectangle: a drag off the handles draws it.
      if (_activeDrag == null && app.marqueeMode) marqueeA = marqueeB = event.localPosition;
    } else if (_pointers.length == 2) {
      // a 2nd finger joining means whatever the 1st finger was doing
      // was never a tap - pinch/pan is only recognized when no handle
      // is captured (checked above), matching the addendum exactly.
      _primaryPointerId = null;
      _primaryDownScreen = null;
      marqueeA = marqueeB = null;
      final ids = _pointers.keys.toList();
      _pinchA = ids[0];
      _pinchB = ids[1];
      _pinchLastA = _pointers[_pinchA];
      _pinchLastB = _pointers[_pinchB];
    }
    // 3rd+ simultaneous pointer: tracked in _pointers (so its eventual
    // up/move doesn't throw on a missing key) but never drives anything.
  }

  void _tryCaptureHandle(ui.Offset screenPos) {
    if (app.parentPickFor != null) return; // taps pick children
    final picked = findLayer(app.project, app.selection.selectedLayer);
    // a locked layer can't be grabbed on the stage.
    final layer = picked != null && picked.locked ? null : picked;
    if (picked != null && picked.locked && chromaTool != 'stagePick') return;
    // a colour field's eyedropper: any colour on the stage.
    if (chromaTool == 'stagePick') {
      final fp = camera.screenToFrame(screenPos);
      final op = ChromaPickDragOp(layer ?? _pickDummy)..apply(app.project, app.currentFrame, [fp.dx, fp.dy]);
      _activeDrag = ActiveDragInfo(family: 'chromaPick', activeKey: null, op: op);
      chromaPickScreen = screenPos;
      onNeedsRepaint();
      return;
    }
    // Chroma tab stage tool: the eyedropper - press, slide to the colour
    // (a loupe shows it above the finger), lift to take it.
    if (layer != null && chromaCapable(layer.content.shape) && chromaTool != 'none') {
      final fp = camera.screenToFrame(screenPos);
      final op = ChromaPickDragOp(layer)..apply(app.project, app.currentFrame, [fp.dx, fp.dy]);
      _activeDrag = ActiveDragInfo(family: 'chromaPick', activeKey: null, op: op);
      chromaPickScreen = screenPos;
      onNeedsRepaint();
      return;
    }
    // Crop tab, detach a piece: drag a rectangle, lift to detach.
    if (layer != null && pieceRectTool) {
      final fp = camera.screenToFrame(screenPos);
      final op = PieceRectDragOp(layer)..apply(app.project, app.currentFrame, [fp.dx, fp.dy]);
      _activeDrag = ActiveDragInfo(family: 'pieceRect', activeKey: null, op: op);
      onNeedsRepaint();
      return;
    }
    // handles hidden: only the open tab's own tools (crop, gradient points)
    // can still be grabbed.
    if (layer != null && hideHandles && !app.cameraView && (cropEditing || pieceInsets != null || glowHandlesVisible)) {
      final fp = camera.screenToFrame(screenPos);
      final captured = _magnetCapture(layer, [fp.dx, fp.dy], tabToolsOnly: true);
      if (captured != null) {
        app.pushUndo();
        _activeDrag = captured;
        onNeedsRepaint();
      }
      return;
    }
    if (layer == null || hideHandles || app.cameraView) return; // nothing selected, or handles globally hidden - tap-to-select only
    if (isAudioShape(layer.content.shape)) return; // a sound has no handles
    final fp = camera.screenToFrame(screenPos);
    final captured = _magnetCapture(layer, [fp.dx, fp.dy]);
    if (captured != null) {
      app.pushUndo();
      if (captured.family == 'transformBox' || captured.family == 'path') app.beginGroupTransform();
      // text touched by corner pin / mesh warp becomes a vector shape
      // (same box, so the warp doesn't jump) - part of this undo step.
      if (layer.content.shape == 'text' && (captured.family == 'cornerPin' || captured.family == 'meshWarp')) {
        app.convertTextLayer(layer);
      }
      _activeDrag = captured;
      onNeedsRepaint();
    }
  }

  ActiveDragInfo? _magnetCapture(Layer layer, List<double> fp, {bool tabToolsOnly = false}) {
    final project = app.project;
    final globalFrame = app.currentFrame;
    final handleRadius = camera.radiusInFrameSpace(16);
    final pathBodyRadius = camera.radiusInFrameSpace(8);

    // crop editing (Crop tab): the crop handles are the only handles -
    // they sit on the same box midpoints/corners the transform box uses.
    if (cropEditing || pieceInsets != null) {
      final piece = !cropEditing;
      final h = getCropHandles(project, layer, globalFrame, insets: piece ? pieceInsets : null);
      String? bestCrop;
      var bestCropDist = handleRadius;
      for (final e in h.screen.entries) {
        final d = _dist(fp, e.value);
        if (d < bestCropDist) {
          bestCropDist = d;
          bestCrop = e.key;
        }
      }
      return bestCrop == null
          ? null
          : ActiveDragInfo(family: 'crop', activeKey: bestCrop, op: CropDragOp(layer: layer, handle: bestCrop, piece: piece));
    }

    // tier 1: corner-pin / mesh-warp / pendulum-pivot, closest wins.
    // pendulum-pivot's own handle can legitimately sit far from the
    // object (see the gesture spec addendum) - that's fine here, this
    // tier just checks distance to each handle's OWN screen position,
    // never assumes proximity to the shape.
    ActiveDragInfo? best;
    var bestDist = handleRadius;
    // handles hidden: only the Fill tab's gradient points.
    if (tabToolsOnly) {
      if (!glowHandlesVisible || !layer.fill.active) return null;
      for (final h in getGlowHandles(project, layer, globalFrame)) {
        final d = _dist(fp, h.screen);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(family: 'glow', activeKey: h.key, op: GlowDragOp.grab(project, layer, h, globalFrame, fp));
        }
      }
      return best;
    }

    final cpInst = getCornerPinInstance(layer);
    if (cpInst != null) {
      final h = getCornerPinHandles(project, layer, cpInst, globalFrame);
      for (final k in h.keys) {
        final d = _dist(fp, h.screen[k]!);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(family: 'cornerPin', activeKey: k, op: CornerDragOp(layer: layer, inst: cpInst, corner: k));
        }
      }
    }
    final mwInst = getMeshWarpInstance(layer);
    if (mwInst != null) {
      final h = getMeshWarpHandles(project, layer, mwInst, globalFrame);
      for (final entry in h.handles) {
        final d = _dist(fp, entry.screen);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(
            family: 'meshWarp',
            activeKey: entry.key,
            op: MeshDragOp(layer: layer, inst: mwInst, pinKey: entry.key, natural: entry.natural),
          );
        }
      }
    }
    final r3d = getRotate3dInstance(layer);
    if (r3d != null) {
      final h = getRotate3dPivotHandle(project, layer, r3d, globalFrame);
      final d = _dist(fp, h.screen);
      if (d < bestDist) {
        bestDist = d;
        best = ActiveDragInfo(
            family: 'rotate3dPivot', activeKey: null, op: Rotate3dPivotDragOp.grab(project, layer, r3d, globalFrame, fp));
      }
    }
    // bend v2: start / end line handles and the angle knob.
    final bends = getBendHandles(project, layer, globalFrame);
    for (var i = 0; i < bends.length; i++) {
      final h = bends[i];
      for (final (key, p) in [('start', h.startHandle), ('end', h.endHandle), ('angle', h.angleHandle)]) {
        final d = _dist(fp, p);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(
              family: 'bendLine', activeKey: '$i:$key', op: BendHandleDragOp.grab(project, layer, h, key, globalFrame, fp));
        }
      }
    }
    // Fill tab open: the gradient's glow points / line ends.
    if (glowHandlesVisible && layer.fill.active) {
      for (final h in getGlowHandles(project, layer, globalFrame)) {
        final d = _dist(fp, h.screen);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(family: 'glow', activeKey: h.key, op: GlowDragOp.grab(project, layer, h, globalFrame, fp));
        }
      }
    }
    // a text part open in the Text tab: grabbing inside its box moves it.
    if (best == null && selectedTextPart != null && layer.content.text != null) {
      final box = textPartBoxFrame(project, layer, globalFrame);
      if (box != null && pointInRing(fp, box)) {
        return ActiveDragInfo(
            family: 'textPart', activeKey: 'part', op: TextPartDragOp.grab(project, layer, selectedTextPart!, globalFrame, fp));
      }
    }
    // Origami: its fold lines' middle dots.
    if (origamiFoldsOnStage) {
      for (final f in origamiFoldLinesFrame(project, layer, globalFrame)) {
        final d = _dist(fp, f.mid);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(family: 'origami', activeKey: '${f.inst.id}:${f.key}', op: OrigamiFoldDragOp(layer, f.inst, f.key));
        }
      }
      for (final h in origamiDirectionHandlesFrame(project, layer, globalFrame)) {
        final d = _dist(fp, h.p);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(family: 'origami', activeKey: '${h.inst.id}:direction', op: OrigamiDirectionDragOp(layer, h.inst));
        }
      }
    }
    // Fill tab: a rect's / triangle's / polygon's rounding handles.
    if (cornerHandlesVisible && !isNodeLine(layer.content)) {
      for (final e in roundHandlesFrame(project, layer, globalFrame).entries) {
        final d = _dist(fp, e.value);
        if (d < bestDist) {
          bestDist = d;
          best = ActiveDragInfo(family: 'round', activeKey: e.key, op: RoundDragOp(layer, e.key));
        }
      }
    }
    if (layer.pendulum.enabled) {
      final h = getPendulumPivotHandleScreen(project, layer, globalFrame);
      final d = _dist(fp, h.screen);
      if (d < bestDist) {
        bestDist = d;
        best = ActiveDragInfo(family: 'pendulumPivot', activeKey: null, op: PendulumPivotDragOp.grab(project, layer, globalFrame, fp));
      }
      final w = getPendulumWeightHandleScreen(project, layer, globalFrame);
      final dw = _dist(fp, w.screen);
      if (dw < bestDist) {
        bestDist = dw;
        best = ActiveDragInfo(family: 'pendulumWeight', activeKey: null, op: PendulumWeightDragOp.grab(project, layer, globalFrame, fp));
      }
    }
    if (best != null) return best;

    // a vector line: its points (both ends; every point and the bezier
    // handles in the Line tab), then the line itself moves it. An open
    // line has no box handles.
    if (isNodeLine(layer.content)) {
      final handles = lineHandlesFrame(project, layer, globalFrame, editing: lineEditing, selected: lineSelectedPoint);
      String? bestKey;
      var bestLDist = handleRadius;
      for (final e in handles.entries) {
        final d = _dist(fp, e.value);
        // bezier handles win a tie with their point.
        if (d < bestLDist || (d == bestLDist && e.key[0] != 'n')) {
          bestLDist = d;
          bestKey = e.key;
        }
      }
      if (bestKey != null) {
        if (bestKey[0] == 'n') app.selectLinePoint(int.parse(bestKey.substring(1)));
        return ActiveDragInfo(family: 'line', activeKey: bestKey, op: LineHandleDragOp(layer, bestKey));
      }
      if (isOpenNodeLine(layer.content) && !layer.content.lineLocked) {
        final pts = lineFramePoints(project, layer, globalFrame);
        if (distToPolyline(fp, pts) < math.max(handleRadius, layer.content.lineWidth)) {
          return ActiveDragInfo(family: 'transformBox', activeKey: 'moveCorner', op: AnchorDragOp.grab(project, layer, globalFrame, fp));
        }
      }
    }
    final openLine = isOpenNodeLine(layer.content);

    // tier 1.5: transform box move/anchor handle - checked regardless
    // of corner-pin/mesh-warp (repositioning the anchor is more
    // fundamental than any one effect).
    final tb = getTransformBoxHandles(project, layer, globalFrame);
    if (getActiveMeshOrPinInstance(layer) != null) {
      // corner pin / mesh warp: anywhere inside the deformed shape moves it
      // (its centre can lie outside a caved-in shape).
      final outline = [
        for (final p in getContentOutline(layer.content, layer, globalFrame, project: project)) applyAffine(tb.mCanvas, p)
      ];
      if (outline.length >= 3 && pointInRing(fp, outline)) {
        return ActiveDragInfo(family: 'transformBox', activeKey: 'moveCorner', op: AnchorDragOp.grab(project, layer, globalFrame, fp));
      }
    } else if (!openLine && _dist(fp, tb.screen['moveCorner']!) < handleRadius) {
      return ActiveDragInfo(family: 'transformBox', activeKey: 'moveCorner', op: AnchorDragOp.grab(project, layer, globalFrame, fp));
    }

    // tier 1.6: scale/rotate/edge handles - only when corner-pin/mesh-
    // warp isn't already occupying this shape's corners.
    if (getActiveMeshOrPinInstance(layer) == null && !openLine) {
      // a tiny object keeps only its corner scale handle (see
      // crowdedTransformHandles) - and the same set is hidden on screen.
      final crowded = crowdedTransformHandles(tb, camera.radiusInFrameSpace(1));
      final tKeys = [
        for (final k in const ['top', 'bottom', 'left', 'right', 'scaleCorner', 'rotateCorner'])
          if (!crowded.contains(k) && (layer.content.shape != 'null' || k == 'scaleCorner')) k
      ];
      String? bestKey;
      var bestTDist = handleRadius;
      for (final k in tKeys) {
        final d = _dist(fp, tb.screen[k]!);
        if (d < bestTDist) {
          bestTDist = d;
          bestKey = k;
        }
      }
      if (bestKey == 'rotateCorner') {
        return ActiveDragInfo(family: 'transformBox', activeKey: 'rotateCorner', op: RotateDragOp.grab(project, layer, globalFrame, fp));
      } else if (bestKey != null) {
        // text: the side handles resize the text box (reflow) instead of
        // scaling; the corner handle still scales.
        final textBox = layer.content.shape == 'text' && bestKey != 'scaleCorner';
        if (layer.content.shape == 'null') {
          return ActiveDragInfo(family: 'transformBox', activeKey: bestKey, op: NullSizeDragOp(layer: layer));
        }
        return ActiveDragInfo(
            family: 'transformBox',
            activeKey: bestKey,
            op: textBox ? TextBoxDragOp(layer: layer, handle: bestKey) : ScaleDragOp(layer: layer, handle: bestKey));
      }
    }

    // tier 2: existing path stations - on a tie, the LATER keyframe
    // wins (it's drawn on top), so <= rather than <.
    final stations = getAnchorStationsScreen(project, layer, globalFrame);
    PathStation? bestStation;
    var bestSDist = handleRadius;
    for (final st in stations) {
      final d = _dist(fp, st.screen);
      if (d <= bestSDist) {
        bestSDist = d;
        bestStation = st;
      }
    }
    if (bestStation != null) {
      return ActiveDragInfo(family: 'path', activeKey: null, op: StationDragOp.grab(project, layer, bestStation.idx, globalFrame, fp));
    }

    // tier 4: the path's own body (drag every keyframe + default by a
    // uniform delta).
    final pathPts = samplePathScreen(project, layer, 60);
    if (pathPts.isNotEmpty && distToPolyline(fp, pathPts) < pathBodyRadius) {
      return ActiveDragInfo(family: 'path', activeKey: null, op: PathDragOp.grab(project, layer, globalFrame, fp));
    }

    return null;
  }

  void onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return; // an ignored (3rd+, or mid-drag 2nd) pointer
    _pointers[event.pointer] = event.localPosition;

    if (_activeDrag != null && event.pointer == _primaryPointerId) {
      final fp = camera.screenToFrame(event.localPosition);
      _refreshSnapRadii();
      _activeDrag!.op.apply(app.project, app.currentFrame, [fp.dx, fp.dy]);
      app.applyGroupTransform();
      if (_activeDrag!.op is ChromaPickDragOp) chromaPickScreen = event.localPosition;
      if (_activeDrag!.op is ChromaRegionDragOp || _activeDrag!.op is ChromaPickDragOp || _activeDrag!.op is PieceRectDragOp) {
        onNeedsRepaint(); // only the outline changes until the finger lifts
        return;
      }
      app.commitEdit();
      onNeedsRepaint();
      return;
    }

    if (_pinchA != null && _pinchB != null && _pointers.containsKey(_pinchA) && _pointers.containsKey(_pinchB)) {
      final a = _pointers[_pinchA]!, b = _pointers[_pinchB]!;
      final prevA = _pinchLastA!, prevB = _pinchLastB!;
      final oldDist = (prevA - prevB).distance;
      final newDist = (a - b).distance;
      final scaleDelta = oldDist > 1e-6 ? newDist / oldDist : 1.0;
      final oldMid = ui.Offset((prevA.dx + prevB.dx) / 2, (prevA.dy + prevB.dy) / 2);
      final newMid = ui.Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      // the twist of the two fingers (Settings: turn the stage).
      final turn = (b - a).direction - (prevB - prevA).direction;
      camera.applyScaleUpdate(
          scaleDelta: scaleDelta,
          focalPointDelta: newMid - oldMid,
          focalPoint: newMid,
          rotationDelta: (turn + math.pi) % (2 * math.pi) - math.pi);
      _pinchLastA = a;
      _pinchLastB = b;
      onNeedsRepaint();
      return;
    }

    if (marqueeA != null && event.pointer == _primaryPointerId) {
      marqueeB = event.localPosition;
      if ((event.localPosition - marqueeA!).distance > 8) _primaryMovedPastTapThreshold = true;
      onNeedsRepaint();
      return;
    }

    if (_primaryDownScreen != null && event.pointer == _primaryPointerId) {
      if (!_primaryMovedPastTapThreshold && (event.localPosition - _primaryDownScreen!).distance > 8) {
        _primaryMovedPastTapThreshold = true;
        // held still first, then dragged: the selection rectangle.
        final held = _primaryDownTime != null && event.timeStamp - _primaryDownTime! >= const Duration(milliseconds: 450);
        if (app.marqueeOnHold && held) {
          marqueeA = _primaryDownScreen;
          marqueeB = event.localPosition;
          onNeedsRepaint();
          return;
        }
      }
      // one finger anywhere off the handles moves the view.
      if (_primaryMovedPastTapThreshold) {
        camera.panBy(event.localDelta);
        onNeedsRepaint();
      }
    }
  }

  void onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);

    if (_activeDrag != null && event.pointer == _primaryPointerId) {
      final op = _activeDrag!.op;
      _activeDrag = null;
      app.endGroupTransform();
      _primaryPointerId = null;
      if (op is ChromaRegionDragOp) app.setChromaRegion(op.layer.id, op.points);
      if (op is ChromaPickDragOp && chromaTool == 'stagePick') {
        app.finishStageColorPick(op.framePoint);
      } else if (op is ChromaPickDragOp && op.framePoint != null) {
        // the same loupe picks the edge matte's colour (Masks tab).
        chromaTool == 'mattePick'
            ? app.pickMatteColorAt(op.layer.id, op.framePoint!)
            : app.pickChromaColorAt(op.layer.id, op.framePoint!);
      }
      if (op is PieceRectDragOp && op.a != null && op.b != null) app.detachPieceRect(op.layer.id, op.a!, op.b!);
      // a line's point moved: it turns about the middle of its points again.
      if (op is LineHandleDragOp && op.key.startsWith('n')) app.lineEdited(op.layer.id);
      chromaPickScreen = null;
      onNeedsRepaint();
      return;
    }

    if (event.pointer == _pinchA || event.pointer == _pinchB) {
      // pinch ends the moment either finger lifts - the other, if still
      // down, doesn't retroactively become a tap/drag candidate; it
      // needs its own fresh down event to start anything new.
      _pinchA = null;
      _pinchB = null;
      _pinchLastA = null;
      _pinchLastB = null;
      return;
    }

    if (marqueeA != null && event.pointer == _primaryPointerId && app.pendingPlaceShape != null) {
      final a = camera.screenToFrame(marqueeA!), b = camera.screenToFrame(marqueeB ?? marqueeA!);
      marqueeA = marqueeB = null;
      _primaryPointerId = null;
      _primaryDownScreen = null;
      _primaryMovedPastTapThreshold = false;
      app.placeShapeIn([a.dx, a.dy], [b.dx, b.dy]);
      onNeedsRepaint();
      return;
    }
    if (marqueeA != null && event.pointer == _primaryPointerId) {
      final a = marqueeA!, b = marqueeB ?? a;
      marqueeA = marqueeB = null;
      if (_primaryMovedPastTapThreshold) {
        final fa = camera.screenToFrame(a), fb = camera.screenToFrame(b);
        final fc = camera.screenToFrame(ui.Offset(a.dx, b.dy)), fd = camera.screenToFrame(ui.Offset(b.dx, a.dy));
        final xs = [fa.dx, fb.dx, fc.dx, fd.dx], ys = [fa.dy, fb.dy, fc.dy, fd.dy];
        app.selectInRect(xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max),
            add: app.stageMultiSelect);
        _primaryPointerId = null;
        _primaryDownScreen = null;
        _primaryMovedPastTapThreshold = false;
        onNeedsRepaint();
        return;
      }
      onNeedsRepaint();
    }

    if (event.pointer == _primaryPointerId && !_primaryMovedPastTapThreshold) {
      final long = _primaryDownTime != null && event.timeStamp - _primaryDownTime! >= const Duration(milliseconds: 450);
      if (!_regionTap(event.localPosition, long)) _handleTap(event.localPosition);
    }
    // no finger left: nothing of the eyedropper may stay on the stage.
    if (_pointers.isEmpty && chromaPickScreen != null) {
      chromaPickScreen = null;
      if (_activeDrag?.op is ChromaPickDragOp) _activeDrag = null;
      onNeedsRepaint();
    }
    // a second finger touching down and lifting during a drag froze the object
    // - its lift cleared the FIRST finger's id here, so the first finger's
    // moves no longer counted.
    if (event.pointer == _primaryPointerId) {
      _primaryPointerId = null;
      _primaryDownScreen = null;
      _primaryMovedPastTapThreshold = false;
    }
  }

  void onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    if (event.pointer == _primaryPointerId) {
      chromaPickScreen = null;
      marqueeA = marqueeB = null;
      _activeDrag = null;
      app.endGroupTransform();
      _primaryPointerId = null;
      _primaryDownScreen = null;
      onNeedsRepaint();
    }
    if (event.pointer == _pinchA || event.pointer == _pinchB) {
      _pinchA = null;
      _pinchB = null;
    }
  }

  /// tap-to-select: NOT a JS port (movement-core has no canvas-tap
  /// selection at all, only the layer panel) - a pre-existing mobile
  /// addition kept unaffected by hideHandles (that flag is about
  /// handles, not layer selection).
  Duration? _primaryDownTime;

  ui.Offset? _lastRegionTap;
  int _regionCycle = 0;
  String? _regionPrefer;

  /// With the regions shown (Masks tab): a tap picks the top region under
  /// the finger (of every layer with regions, top layer first); another
  /// tap at the same spot the next one down, round and round. A long press
  /// also says what it is. While a field asks for an area, only the
  /// selected layer's count.
  bool _regionTap(ui.Offset screenPos, bool long) {
    final picking = app.regionPick != null;
    if (!showRegionTints && !picking && regionsPanelOpen == 0) return false;
    final fp = camera.screenToFrame(screenPos);
    final p = [fp.dx, fp.dy];
    bool inside(List<List<List<double>>> rings) {
      var n = 0;
      for (final r in rings) {
        if (r.length >= 3 && pointInRing(p, r)) n++;
      }
      return n.isOdd;
    }

    final stack = <(Layer, int, int?)>[];
    for (final l in app.project.layers.reversed) {
      final mr = l.maskRegions;
      if (mr == null || !mr.enabled || mr.sources.isEmpty || l.hidden) continue;
      if (picking && l.id != app.selection.selectedLayer) continue;
      if (!getLayerStateAt(app.project, l.id, app.currentFrame).inRange) continue;
      final geo = maskRegionGeometry(app.project, l, app.currentFrame);
      if (geo == null) continue;
      final outerEmpty = regionOuterEmpty(l);
      for (final sig in ownedRegionSigs(l)) {
        if (sig == 0 && outerEmpty) continue;
        if (sig >= geo.length || !inside(geo[sig].rings)) continue;
        int? number;
        if (mr.numbered) {
          for (final (ep, piece) in regionEpisodesReady(app.project, l).piecesAt(app.currentFrame)) {
            if (ep.sig == sig && inside(piece)) number = ep.numberAt(app.currentFrame);
          }
        }
        stack.add((l, sig, number));
      }
    }
    if (stack.isEmpty) return false;
    final last = _lastRegionTap;
    final again = last != null && (screenPos - last).distance < 16;
    // the selected layer's own regions first: a tap picks in its own list
    // (tapping again on the spot goes on to the other layers' - in the
    // order of the first tap there).
    if (!again) _regionPrefer = app.selection.selectedLayer;
    final own = [for (final e in stack) if (e.$1.id == _regionPrefer) e];
    final others = [for (final e in stack) if (e.$1.id != _regionPrefer) e];
    stack
      ..clear()
      ..addAll(own)
      ..addAll(others);
    _regionCycle = again ? (_regionCycle + 1) % stack.length : 0;
    _lastRegionTap = screenPos;
    final (layer, sig, number) = stack[_regionCycle];
    // a field asked for an area: it gets this one.
    final pick = app.regionPick;
    if (pick != null) {
      pick(sig, number);
      app.startRegionPick(app.regionPickKey!, pick); // done picking
    }
    if (layer.id != app.selection.selectedLayer) app.selectLayer(layer.id);
    app.selectRegion(sig, number, _regionCycle);
    if (long) {
      app.stageNotice.value =
          '${regionInWords(app.project, layer.maskRegions!, sig)}${number == null ? '' : '  #$number'}';
    }
    onNeedsRepaint();
    return true;
  }

  void _handleTap(ui.Offset screenPos) {
    final fp = camera.screenToFrame(screenPos);
    // adding a line's points by tapping (Line tab).
    if (app.lineTapAdd) {
      final sel = findLayer(app.project, app.selection.selectedLayer);
      if (sel != null && isNodeLine(sel.content)) {
        app.lineTapAt([fp.dx, fp.dy]);
        return;
      }
    }
    if (chromaTool == 'pick' || chromaTool == 'mattePick') {
      final layer = findLayer(app.project, app.selection.selectedLayer);
      if (layer != null && chromaCapable(layer.content.shape)) {
        chromaTool == 'mattePick'
            ? app.pickMatteColorAt(layer.id, [fp.dx, fp.dy])
            : app.pickChromaColorAt(layer.id, [fp.dx, fp.dy]);
        return;
      }
    }
    for (final layer in app.project.layers.reversed) {
      if (layer.hidden || layer.locked || isCameraShape(layer.content.shape)) continue; // the camera: from the Stage tab; locked: not here
      if (layer.content.size[0] <= 0 && layer.content.size[1] <= 0) continue;
      final state = getLayerStateAt(app.project, layer.id, app.currentFrame);
      if (!state.inRange) continue;
      // a line: a tap near it (thin lines are hard to hit inside their box).
      if (isNodeLine(layer.content)) {
        final pts = lineFramePoints(app.project, layer, app.currentFrame);
        if (distToPolyline([fp.dx, fp.dy], pts) <= math.max(camera.radiusInFrameSpace(14), layer.content.lineWidth)) {
          _pick(layer.id);
          return;
        }
        if (!isFilledLine(layer.content)) continue;
      }
      final m = state.matrix;
      final mCanvas = [m[0], m[1], m[2], m[3], m[4] * stageSize.width, m[5] * stageSize.height];
      final localPt = applyAffine(invertAffine(mCanvas), [fp.dx, fp.dy]);
      // a detached piece (or what is left of its source) is hit only on
      // its own part.
      final bbox = pieceBoundingBox(layer);
      if (localPt[0] >= bbox.minX &&
          localPt[0] <= bbox.maxX &&
          localPt[1] >= bbox.minY &&
          localPt[1] <= bbox.maxY &&
          insidePieceClips(layer, localPt) &&
          _refOpaqueAt(layer, localPt)) {
        _pick(layer.id);
        return;
      }
    }
    // picking several (or children): a tap on nothing keeps what is picked.
    if (!app.stageMultiSelect && app.parentPickFor == null) app.selectLayer(null);
  }

  /// A tap on a layer: selects it - or, picking several, adds it to the
  /// selection (takes it out when it already is); picking a parent's
  /// children, in or out of them.
  void _pick(String id) {
    if (app.parentPickFor != null) {
      app.toggleParentPick(id);
      return;
    }
    app.stageMultiSelect ? app.toggleMultiSelect(id) : app.selectLayer(id);
  }

  /// A placed project covers its whole canvas - a tap selects it only
  /// where it draws something (a tap on its empty parts reaches the
  /// layers below).
  bool _refOpaqueAt(Layer layer, List<double> localPt) {
    final c = layer.content;
    if (c.shape != 'projectRef' || c.size[0] <= 0 || c.size[1] <= 0) return true;
    final u = (localPt[0] - (c.offset[0] - c.size[0] / 2)) / c.size[0];
    final v = (localPt[1] - (c.offset[1] - c.size[1] / 2)) / c.size[1];
    final a = app.renderer.alphaAtSync(layer, app.currentFrame, u, v);
    return a == null || a > 16;
  }

  static final Layer _pickDummy = createLayer('null');

  double _dist(List<double> a, List<double> b) => math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));

  /// converts AppState's screen-px snap sensitivity preferences into
  /// movement_core's frame-space snap*FrameRadius globals, at CURRENT
  /// zoom/letterboxing - the exact same "recompute fresh every move,
  /// never cache" pattern _magnetCapture already uses for handleRadius/
  /// pathBodyRadius via camera.radiusInFrameSpace. Called unconditionally
  /// before every drag-apply (cheap - 6 divisions); it doesn't compete
  /// with the magnet-capture tiers above at all, since AnchorDragOp/
  /// ScaleDragOp's own snapping math already runs unconditionally
  /// inside apply() regardless of which tier captured the drag.
  void _refreshSnapRadii() {
    snapEdgeToEdgeFrameRadius = camera.radiusInFrameSpace(app.snapSensitivityEdgeToEdgePx);
    snapCenterToCenterFrameRadius = camera.radiusInFrameSpace(app.snapSensitivityCenterToCenterPx);
    snapCornerToCornerFrameRadius = camera.radiusInFrameSpace(app.snapSensitivityCornerToCornerPx);
    snapEqualSizeFrameRadius = camera.radiusInFrameSpace(app.snapSensitivityEqualSizePx);
    snapGridFrameRadius = camera.radiusInFrameSpace(app.snapSensitivityGridPx);
    snapFrameBoundaryFrameRadius = camera.radiusInFrameSpace(app.snapSensitivityFrameBoundaryPx);
  }
}
