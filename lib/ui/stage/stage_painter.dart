import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:movement_core/movement_core.dart';

import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../common/param_editor.dart' show stageRulerZoom, stageRulerZoomNotifier;
import 'stage_camera.dart';
import 'stage_gesture_controller.dart';

/// The actual Canvas drawing for the stage - handle GEOMETRY comes from
/// movement_core's ui_geometry/handles.dart (real-tested); this file
/// only turns that data into paint calls, plus the physical/visual
/// toggle gating and per-family sibling-hide logic the gesture spec
/// defines. Colors match movement-core/src/ui/stage/handles.js's own
/// palette 1:1 for the ported handle families; the parent-link
/// visualization (new, no JS equivalent) uses its own distinct color so
/// it never gets confused with any existing handle family.
///
/// Every radius/strokeWidth constant below is defined in FRAME space
/// but divided by the camera's current scale (`inv` throughout) before
/// use, so handles/lines stay a constant SIZE ON SCREEN regardless of
/// zoom - the same convention already applied to the frame outline's
/// stroke width. Without this, a handle would balloon into a huge blob
/// at high zoom and shrink to invisible at low zoom, since the whole
/// canvas this draws into is already scaled by canvas.scale(camera.
/// scale) once, up in paintStage(). Not explicitly specified by the
/// gesture spec (which only discusses TOUCH radius scaling, via
/// StageCamera.radiusInFrameSpace - a separate, already-correct
/// concern), but left unaddressed here would make every handle
/// unusable at any zoom level other than 1.0x, which is the normal
/// case this whole pan/zoom feature exists to move away from.
///
/// UNVERIFIED - needs dart:ui (Canvas/Paint), not available in this
/// sandbox.
const _transformBoxColor = ui.Color(0xFF7FC4A8);
const _rotateColor = ui.Color(0xFFE0D47F);
const _moveColor = ui.Color(0xFFD8D8D8);
const _cornerPinColor = ui.Color(0xFFE0A06A);
const _meshWarpColor = ui.Color(0xFFC9A8E0);
const _pendulumColor = ui.Color(0xFF8AC9A0);
const _deformGridColor = ui.Color(0xFF7FA0D8);
const _handleFill = ui.Color(0xFF151515);
const _pathLineColor = ui.Color(0xFF4A4A4A);
const _stationFill = ui.Color(0xFF151515);
const _stationStroke = ui.Color(0xFFD8D8D8);
const _frameOutlineColor = ui.Color(0x66FFFFFF);
const _parentLinkColor = ui.Color(0xFF5A9FD4);
// snapping (movement-mobile-snapping-spec.md): a warm red/magenta for
// transient drag guides - reads clearly against every existing family's
// cooler palette (parent-link blue, transform-box green, rotate yellow,
// corner-pin orange, mesh-warp purple). The grid overlay gets its own,
// deliberately faint color (a persistent reference underlay, not an
// attention-grabbing guide).
const _snapGuideColor = ui.Color(0xFFFF4D6D);
const _snapGridColor = ui.Color(0x33FFFFFF);
// crop handles (Crop tab): cyan, distinct from every other family.
const _cropColor = ui.Color(0xFF5FD4E0);
// 3D Rotate pivot + axis: pink, distinct from the pendulum's green.
const _rotate3dColor = ui.Color(0xFFE08AC4);

/// paints one full stage frame: camera transform, frame content picture,
/// visual layer, physical layer, frame outline - in that order. Called
/// from a CustomPainter.paint() in stage_view.dart (kept as a plain
/// function, not a CustomPainter subclass itself, so stage_view.dart's
/// own CustomPainter can own `shouldRepaint` against whatever fields it
/// actually cares about).
/// Set from AppState.cameraView: the stage shows the picture through the
/// camera, without handles.
bool cameraViewActive = false;

/// Settings: the transform box's outline also over a deforming effect's
/// grid (off: the grid alone outlines the shape).
bool showBoxOverEffectGrid = false;

/// Links (dependencies) drawn on the stage, purple; the Links tab's eye.
bool showPropLinks = true;
const _propLinkColor = ui.Color(0xFFB065F0);

void paintStage({
  required ui.Canvas canvas,
  required ui.Size size,
  required ui.Picture? contentPicture,
  required double frameWidth,
  required double frameHeight,
  required Project project,
  required Layer? selectedLayer,
  required int globalFrame,
  required StageCamera camera,
  required ActiveDragInfo? activeDrag,
  bool mirrorX = false,
  bool mirrorY = false,
  List<String> failedImageLayerIds = const [],
  ChromaLoupe? loupe,
  List<Layer> groupLayers = const [],
  List<({List<List<double>> points, bool hole})> contourOverlay = const [],
  List<PhysicsContact> physicsContacts = const [],
  List<List<List<double>>> projectOutlines = const [],
  List<List<List<double>>> hiddenLines = const [],
  List<(List<List<double>>, double)> unitOverlay = const [],
  CropLineOverlay? cropLine,
  List<List<double>>? mirrorLine,
}) {
  camera.mirrorX = mirrorX;
  camera.mirrorY = mirrorY;
  // keeps StageCamera's fit-to-viewport transform in sync with what's
  // ACTUALLY being painted right now - the one place this gets updated,
  // recomputed unconditionally every paint (never locked/cached the way
  // the old, buggy setSize()-from-layout call was). Safe to redo every
  // frame: this only ever affects how the FIXED frame (frameWidth x
  // frameHeight, never touched here) is letterboxed into `size`, not
  // the frame's own coordinate system. stage_gesture_controller.dart's
  // hit-testing reads this same camera between paints, which is safe
  // because a pointer can't generate events before the first paint has
  // already run at least once.
  camera.updateLayout(frame: ui.Size(frameWidth, frameHeight), viewport: size);

  // dragging a layer's active range away from the current playhead (via the
  // new layers- timeline move/trim, or simply scrubbing) made the CONTENT
  // correctly disappear (canvas_renderer.dart's own _drawLayer already checks
  // state.inRange) while its handles/path-visual/deformation-grid stayed
  // frozen at their last on-screen position, since none of that drawing below
  // ever checked inRange at all - the same latent gap the JS original has too,
  // just newly reachable now that a layer's range can change via direct
  // manipulation.
  final selectedInRange = selectedLayer != null &&
      getLayerStateAt(project, selectedLayer.id, globalFrame).inRange;

  canvas.drawRect(
      ui.Offset.zero & size, ui.Paint()..color = const ui.Color(0xFF1E1E1E));

  // frame-space multiplier that keeps on-screen sizes constant
  // regardless of BOTH the user's own pinch-zoom AND the fit-to-
  // viewport scale below - without the fitScale factor, handles would
  // balloon or shrink purely from rotating the device into a
  // differently-shaped viewport, even with the user's own zoom
  // untouched.
  final inv = 1 / (camera.scale * camera.fitScale);
  stageHandleScale = inv;
  // the parameter rulers go finer as the stage zooms in.
  stageRulerZoom = camera.scale;
  if (stageRulerZoomNotifier.value != camera.scale) {
    final z = camera.scale;
    SchedulerBinding.instance.addPostFrameCallback((_) => stageRulerZoomNotifier.value = z);
  }

  canvas.save();
  // Settings' stage turn: the whole view about the viewport centre.
  if (camera.viewRotation != 0) {
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(camera.viewRotation);
    canvas.translate(-size.width / 2, -size.height / 2);
  }
  canvas.translate(camera.pan.dx, camera.pan.dy);
  canvas.scale(camera.scale);
  // BoxFit.contain: letterboxes the fixed frame into the current
  // viewport - composes UNDER the user's own pan/zoom above, so pinch-
  // zoom still zooms in on the already-fitted frame rather than
  // fighting it.
  canvas.translate(camera.fitOffset.dx, camera.fitOffset.dy);
  canvas.scale(camera.fitScale);
  // stage mirror: everything below (content, overlays, handles) is drawn
  // flipped, matching StageCamera.mirrored.
  if (mirrorX || mirrorY) {
    canvas.translate(mirrorX ? frameWidth : 0, mirrorY ? frameHeight : 0);
    canvas.scale(mirrorX ? -1 : 1, mirrorY ? -1 : 1);
  }

  // one layer for the scene and its handles: a handle's see-through
  // inside (BlendMode.clear) cuts only this, not what's behind the stage.
  canvas.saveLayer(null, ui.Paint());
  if (contentPicture != null) canvas.drawPicture(contentPicture);
  // broken images: a red box with an X over each one (stage only, never
  // exported), so a missing picture doesn't just silently vanish.
  for (final id in failedImageLayerIds) {
    final layer = findLayer(project, id);
    if (layer == null || !getLayerStateAt(project, id, globalFrame).inRange) continue;
    _paintBrokenImage(canvas, project, layer, globalFrame, inv);
  }

  if (!hideVisualLayer) {
    // grid overlay: a persistent background reference, drawn early
    // (before parent-links/handles) - fully decoupled from Snapping (see
    // gridOverlayEnabled's own doc comment in project.dart): this is
    // ONLY whether the grid is visually drawn, independent of
    // snapEnabled/snapGridEnabled (whether drags snap TO it). You can
    // see a grid you never snap to, or snap to a grid you never see.
    // computeSnapGridLines never produces a line outside
    // [0,frameWidth]x[0,frameHeight] by construction, so no extra clip
    // is needed here.
    if (gridOverlayEnabled) {
      _paintSnapGrid(canvas, frameWidth, frameHeight, inv);
    }
    // rects' own grids (editor guides).
    final rectGrid = ui.Paint()
      ..color = const ui.Color(0x8829B6F6)
      ..strokeWidth = 1 * inv;
    for (final l in project.layers) {
      if (l.hidden || l.content.gridCols == null) continue;
      if (!getLayerStateAt(project, l.id, globalFrame).inRange) continue;
      for (final (a, b) in rectGridLinesFrame(project, l, globalFrame)) {
        canvas.drawLine(ui.Offset(a[0], a[1]), ui.Offset(b[0], b[1]), rectGrid);
      }
    }
    _paintParentLinks(canvas, project, globalFrame,
        computeParentLinkGeometry(project, globalFrame), inv);
    if (showPropLinks) _paintPropLinks(canvas, project, globalFrame, inv);
    final mrSel = selectedLayer?.maskRegions;
    if (selectedLayer != null && mrSel != null && mrSel.enabled && mrSel.sources.isNotEmpty) {
      // the panel open shows the picked one; the tints are the switch's
      // (and a pick's).
      if (showRegionTints || stageRegionPickActive || regionsPanelOpen > 0) {
        _paintRegionTints(canvas, project, selectedLayer, globalFrame, inv, tints: showRegionTints || stageRegionPickActive);
      }
      if (showFootprints) _paintFootprints(canvas, project, selectedLayer, globalFrame, inv);
    }
    if (showMaskViz && selectedLayer != null && selectedLayer.masks.isNotEmpty) {
      _paintMaskSteps(canvas, project, selectedLayer, globalFrame, inv);
    }
    // "Show contour": outers orange, holes cyan, points as dots.
    for (final r in contourOverlay) {
      final color = r.hole ? const ui.Color(0xFF4DD0E1) : const ui.Color(0xFFFF9800);
      canvas.drawPath(
          ui.Path()..addPolygon([for (final q in r.points) ui.Offset(q[0], q[1])], true),
          ui.Paint()
            ..color = color
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 1.5 * inv);
      // the points only while they're apart on screen (zoomed out they
      // would cover the outline).
      var len = 0.0;
      for (var i = 1; i < r.points.length; i++) {
        final a = r.points[i - 1], b = r.points[i];
        len += math.sqrt(math.pow(b[0] - a[0], 2) + math.pow(b[1] - a[1], 2));
      }
      final spacingPx = r.points.isEmpty ? 0 : len / r.points.length / inv;
      if (spacingPx >= 10) {
        final dot = ui.Paint()..color = color;
        for (final q in r.points) {
          canvas.drawCircle(ui.Offset(q[0], q[1]), 2 * inv, dot);
        }
      }
    }
    // physics contacts: the push's normal as an arrow from the contact
    // point (red where a pendulum swings into an Immovable).
    for (final c in physicsContacts) {
      final paint = ui.Paint()
        ..color = c.blocked ? const ui.Color(0xFFE53935) : const ui.Color(0xFFFFEB3B)
        ..strokeWidth = 2 * inv;
      final p0 = ui.Offset(c.point[0], c.point[1]);
      final p1 = p0 + ui.Offset(c.normal[0], c.normal[1]) * (24 * inv);
      canvas.drawLine(p0, p1, paint);
      final side = ui.Offset(-c.normal[1], c.normal[0]) * (5 * inv);
      final back = p1 - ui.Offset(c.normal[0], c.normal[1]) * (7 * inv);
      canvas.drawPath(ui.Path()..addPolygon([p1, back + side, back - side], true), paint);
      canvas.drawCircle(p0, 3 * inv, paint);
    }
    // placed projects (Stage settings): a blue box, its edges continued
    // dashed past the corners - it follows the layer's scale and turn.
    for (final q in projectOutlines) {
      _paintProjectOutline(canvas, q, inv);
    }
    // a text animator open: each unit tinted by its amount.
    for (final (box, a) in unitOverlay) {
      final path = ui.Path()..addPolygon([for (final p in box) ui.Offset(p[0], p[1])], true);
      canvas.drawPath(path, ui.Paint()..color = const ui.Color(0xFFFF9800).withOpacity(0.55 * a.clamp(0.0, 1.0)));
      canvas.drawPath(
          path,
          ui.Paint()
            ..color = const ui.Color(0x66FF9800)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = inv);
    }
    if (cropLine != null) _paintCropLine(canvas, cropLine, inv);
    if (mirrorLine != null) _paintMirrorLine(canvas, mirrorLine, inv);
    // invisible lines: a thin guide where each runs (editor only).
    for (final q in hiddenLines) {
      if (q.length < 2) continue;
      canvas.drawPath(
          ui.Path()..addPolygon([for (final p in q) ui.Offset(p[0], p[1])], false),
          ui.Paint()
            ..color = const ui.Color(0xCC4DD0E1)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 1.2 * inv);
    }
    // nulls: a hollow green point where each is (editor only).
    for (final l in project.layers) {
      if (l.content.shape != 'null' || l.hidden || !getLayerStateAt(project, l.id, globalFrame).inRange) continue;
      final p = applyAffine(getTransformBoxHandles(project, l, globalFrame).mCanvas, l.content.offset);
      canvas.drawCircle(
          ui.Offset(p[0], p[1]),
          4 * inv,
          ui.Paint()
            ..color = _transformBoxColor
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 1.5 * inv);
    }
    // snap guides: the transient line(s) for whichever candidate(s) are
    // currently winning during an active move/resize drag - reads
    // straight off the currently-held DragOp, so it clears automatically
    // the instant the drag ends (activeDrag itself is discarded on
    // pointer-up, see stage_gesture_controller.dart). Gating is
    // `!hideVisualLayer && snapGuidesVisible` - the spec's own "guide
    // lines only show when BOTH toggles are on" requirement, applied as
    // a plain AND rather than a replacement of the existing guard.
    if (snapGuidesVisible) {
      _paintSnapGuides(canvas, activeDrag, inv);
    }
    // (in camera view the scene is seen through the camera - the path and
    // effect guides are for the scene itself.)
    if (selectedLayer != null && selectedInRange && !cameraViewActive) {
      _paintPathVisual(canvas, project, selectedLayer, globalFrame, inv);
      // squeeze_axis/bend_arc (and any other vertex effect without its
      // own dedicated draggable handles) get a passive readout grid
      // here instead - see getEffectDeformationGridScreen's own doc
      // comment. Skipped when mesh_warp/corner_pin is active: those
      // already draw their OWN, more detailed (and draggable) grid in
      // the physical/handles layer below, and drawing both would just
      // double up on the same shape's outline.
      if (getCornerPinInstance(selectedLayer) == null &&
          getMeshWarpInstance(selectedLayer) == null) {
        _paintEffectDeformationGrid(
            canvas, project, selectedLayer, globalFrame, inv);
      }
      // bend v2: tinted static / carried zones and the two lines.
      _paintBendZones(canvas, project, selectedLayer, globalFrame, inv);
    }
  }

  // camera view: the scene outside the camera's frame shows too,
  // darkened - what the picture leaves out.
  if (cameraViewActive) {
    const big = 1e5;
    canvas.drawPath(
        ui.Path()
          ..fillType = ui.PathFillType.evenOdd
          ..addRect(const ui.Rect.fromLTRB(-big, -big, big, big))
          ..addRect(ui.Rect.fromLTWH(0, 0, frameWidth, frameHeight)),
        ui.Paint()..color = const ui.Color(0x99000000));
  }
  // frame outline: ALWAYS drawn - not gated by either toggle (the one
  // reference for what export actually captures, per the gesture
  // spec's addendum).
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, frameWidth, frameHeight),
    ui.Paint()
      ..color = _frameOutlineColor
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = inv,
  );

  // the stage camera's frame: what the picture will show.
  final cam = activeCamera(project);
  if (cam != null && !cameraViewActive) {
    final pts = cameraFrameCorners(project, cam, globalFrame);
    canvas.drawPath(
        ui.Path()..addPolygon([for (final p in pts) ui.Offset(p[0], p[1])], true),
        ui.Paint()
          ..color = const ui.Color(0xFFFFC107)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2 * inv);
  }
  // handles hidden: the open tab's own tools (crop box, gradient points,
  // chroma region) stay - hiding handles must not lock the tabs out.
  if (hideHandles && !cameraViewActive && selectedLayer != null && selectedInRange) {
    if (cropEditing || pieceInsets != null) {
      _paintCrop(canvas, project, selectedLayer, globalFrame, activeDrag, inv);
    } else if (glowHandlesVisible && selectedLayer.fill.active) {
      _paintGlowHandles(canvas, project, selectedLayer, globalFrame, activeDrag, inv);
    }
  }
  if (!hideHandles && !cameraViewActive && selectedLayer != null && selectedInRange) {
    // the layers selected with it: their boxes, moving along with it.
    for (final g in groupLayers) {
      if (getLayerStateAt(project, g.id, globalFrame).inRange) {
        _paintTransformBox(canvas, project, g, globalFrame, null, inv, hasDeform: false, outlineOnly: true);
        // its own move handle: it can be moved alone without leaving the
        // selection.
        if (!g.locked && getActiveMeshOrPinInstance(g) == null) {
          _paintMoveHandle(canvas, getTransformBoxHandles(project, g, globalFrame).screen['moveCorner']!, inv);
        }
      }
    }
    // a locked layer: its outline only, no handles.
    selectedLayer.locked
        ? _paintTransformBox(canvas, project, selectedLayer, globalFrame, null, inv, hasDeform: false, outlineOnly: true)
        : _paintHandles(canvas, project, selectedLayer, globalFrame, activeDrag, inv);
  }

  canvas.restore(); // the scene's layer
  canvas.restore();
  // screen space: the eyedropper loupe stays upright and finger-sized
  // whatever the zoom or stage mirror.
  if (loupe != null) paintChromaLoupe(canvas, loupe);
}

/// What the Chroma eyedropper loupe shows: `finger` (screen), the source
/// `image` with `center` = the picked pixel (image px), and the `color`
/// under the finger (null while the pixels are still being read).
class ChromaLoupe {
  final ui.Offset finger;
  final ui.Image? image;
  final ui.Offset center;
  final ui.Color? color;
  const ChromaLoupe({required this.finger, required this.image, required this.center, this.color});
}

/// Loupe radius and how far above the finger it floats (screen px), and
/// how many image pixels around the picked one it magnifies.
const double chromaLoupeRadius = 38;
const double chromaLoupeLift = 88;
const double chromaLoupeSourceRadius = 10;

void paintChromaLoupe(ui.Canvas canvas, ChromaLoupe loupe) {
  final c = loupe.finger - const ui.Offset(0, chromaLoupeLift);
  const r = chromaLoupeRadius;
  final circle = ui.Rect.fromCircle(center: c, radius: r);
  canvas.save();
  canvas.clipPath(ui.Path()..addOval(circle));
  canvas.drawRect(circle, ui.Paint()..color = const ui.Color(0xFF2A2A2A));
  final img = loupe.image;
  if (img != null) {
    const sr = chromaLoupeSourceRadius;
    canvas.drawImageRect(
        img,
        ui.Rect.fromCenter(center: loupe.center, width: sr * 2, height: sr * 2),
        circle,
        ui.Paint()..filterQuality = ui.FilterQuality.none); // crisp pixels
  }
  // the picked pixel, marked in the middle.
  const cell = r / chromaLoupeSourceRadius;
  canvas.drawRect(
      ui.Rect.fromCenter(center: c, width: cell, height: cell),
      ui.Paint()
        ..color = const ui.Color(0xFFFFFFFF)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1);
  canvas.restore();
  // ring in the colour under the finger, with a thin outline so it reads
  // on any background.
  final ringColor = loupe.color ?? const ui.Color(0xFF808080);
  canvas.drawCircle(
      c,
      r + 3,
      ui.Paint()
        ..color = ringColor
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 6);
  for (final rr in [r, r + 6.0]) {
    canvas.drawCircle(
        c,
        rr,
        ui.Paint()
          ..color = const ui.Color(0xAA000000)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1);
  }
  // the picked colour's code shows in the corner, after the layer's name
  // (stage_view).
}

/// Masks tab: how the selected layer's masks work, drawn on the stage.
bool showMaskViz = false;

/// Masks tab, Regions: every region tinted (hidden ones hatched).
bool showRegionTints = false;

/// Masks tab, Regions: the numbered pieces' footprints in orange - dashed
/// while the piece still grows, solid once it is gone.
bool showFootprints = false;

/// An area is being picked for a field: the areas show to tap them.
bool stageRegionPickActive = false;

/// The Masks tab shows a layer's Regions: its areas show on the stage and
/// a tap picks them (count of open panels).
int regionsPanelOpen = 0;

/// How far under the top region at the tapped spot the picked one lies
/// (0: the top one).
int stageSelectedRegionDepth = 0;

/// The region picked (set from AppState every paint).
int? stageSelectedRegionSig;
int? stageSelectedRegionNumber;
const _maskVizColors = [
  ui.Color(0xFF4DB6AC), ui.Color(0xFFFFB74D), ui.Color(0xFFBA68C8), ui.Color(0xFF64B5F6), ui.Color(0xFFE57373),
];

/// Per mask, in its colour: a wide outline round what it lets through, a
/// thin one round what it hides, a ring (a double line) round a mask that
/// changes nothing.
void _paintMaskSteps(ui.Canvas canvas, Project project, Layer layer, int globalFrame, double inv) {
  final steps = maskSteps(project, layer, globalFrame);
  ui.Path path(List<List<List<double>>> rings) {
    final p = ui.Path();
    for (final r in rings) {
      if (r.length >= 3) p.addPolygon([for (final q in r) ui.Offset(q[0], q[1])], true);
    }
    return p;
  }

  // outlines that lie on each other (masks over the same spot) stack
  // outward: each later one a step further out, so all stay visible.
  final level = <int>[];
  final bounds = <ui.Rect?>[];
  for (final st in steps) {
    final b = st.raster || st.source.isEmpty ? null : path(st.source).getBounds();
    var k = 0;
    for (var j = 0; j < bounds.length; j++) {
      final o = bounds[j];
      if (b != null && o != null && o.inflate(2 * inv).overlaps(b)) k = math.max(k, level[j] + 1);
    }
    level.add(k);
    bounds.add(b);
  }
  const gap = 5.0;
  // the furthest out first, so each nearer one sits on top.
  final order = [for (var i = 0; i < steps.length; i++) i]..sort((a, b) => level[b].compareTo(level[a]));
  for (final si in order) {
    final st = steps[si];
    final out = level[si] * gap;
    final color = _maskVizColors[st.index % _maskVizColors.length];
    // a picture source: no outline to show (nothing is written there).
    if (st.raster) continue;
    ui.Paint stroke(double w, ui.Color c) => ui.Paint()
      ..color = c
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = w * inv
      ..strokeJoin = ui.StrokeJoin.round;
    // a line `w` wide, pushed `out` px outside the shape (a stacked one).
    void edge(ui.Path p, double w, ui.Color c) {
      if (out <= 0) {
        canvas.drawPath(p, stroke(w, c));
        return;
      }
      canvas.save();
      final b = p.getBounds().inflate((out + w) * 2 * inv);
      canvas.clipPath(ui.Path.combine(ui.PathOperation.difference, ui.Path()..addRect(b), p));
      // from the edge out; the nearer ones, drawn after, cover its inner part.
      canvas.drawPath(p, stroke(2 * (out + w / 2), c));
      canvas.restore();
    }

    if (st.gained.isNotEmpty) {
      final p = path(st.gained);
      if (out <= 0) canvas.drawPath(p, ui.Paint()..color = color.withOpacity(0.12));
      edge(p, 4, color);
    }
    if (st.lost.isNotEmpty) edge(path(st.lost), 1, color);
    if (st.unchanged) {
      final p = path(st.source);
      edge(p, 6, color);
      if (out <= 0) canvas.drawPath(p, stroke(2.5, const ui.Color(0xCC000000)));
    }
  }
}

const _regionColors = [
  ui.Color(0xFF64B5F6), ui.Color(0xFFE57373), ui.Color(0xFF81C784), ui.Color(0xFFFFD54F),
  ui.Color(0xFFBA68C8), ui.Color(0xFF4DD0E1), ui.Color(0xFFFF8A65), ui.Color(0xFFA1887F),
];

/// A region's colour on the stage and in the list.
ui.Color regionColor(int sig) => _regionColors[sig % _regionColors.length];

ui.Path _ringsPath(List<List<List<double>>> rings) {
  final p = ui.Path()..fillType = ui.PathFillType.evenOdd;
  for (final r in rings) {
    if (r.length >= 3) p.addPolygon([for (final q in r) ui.Offset(q[0], q[1])], true);
  }
  return p;
}

/// The layer's own regions tinted in their colour; a hidden one (opacity
/// 0) hatched. The picked one is outlined - once per level it lies under
/// the top one at the tapped spot (1: the top, 2: the next...) - with its
/// owner layer's outline. The piece numbers are cut out of the picture.
void _paintRegionTints(ui.Canvas canvas, Project project, Layer layer, int globalFrame, double inv, {bool tints = true}) {
  final geo = maskRegionGeometry(project, layer, globalFrame);
  if (geo == null) return;
  final mr = layer.maskRegions!;
  final bake = regionEpisodesReady(project, layer);
  final owned = ownedRegionSigs(layer).toSet();
  final outerEmpty = regionOuterEmpty(layer);
  // a shape's Outer: the frame outside every shape (it has no pixels of
  // the layer, but it is where the shapes are not).
  if (tints && outerEmpty && owned.contains(0)) {
    var shapes = ui.Path();
    for (final g in geo) {
      if (g.sig != 0 && g.rings.isNotEmpty) shapes = ui.Path.combine(ui.PathOperation.union, shapes, _ringsPath(g.rings));
    }
    final frame = ui.Path()..addRect(ui.Rect.fromLTWH(0, 0, stageSize.width, stageSize.height));
    final outer = ui.Path.combine(ui.PathOperation.difference, frame, shapes);
    final color = regionColor(0);
    canvas.drawPath(outer, ui.Paint()..color = color.withOpacity(0.12));
    if (stageSelectedRegionSig == 0) {
      canvas.drawPath(
          outer,
          ui.Paint()
            ..color = color
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 3 * inv);
    }
  }
  for (final g in geo) {
    if (g.rings.isEmpty || !owned.contains(g.sig) || (g.sig == 0 && outerEmpty)) continue;
    final path = _ringsPath(g.rings);
    final color = regionColor(g.sig);
    final op = regionOpacityAt(project, layer, bake, g.sig, null, globalFrame);
    if (tints) canvas.drawPath(path, ui.Paint()..color = color.withOpacity(0.18));
    if (tints && op <= 0) {
      // hatched: diagonal lines clipped to it.
      canvas.save();
      canvas.clipPath(path);
      final b = path.getBounds();
      final step = 10 * inv;
      final hatch = ui.Paint()
        ..color = color.withOpacity(0.6)
        ..strokeWidth = inv;
      for (var x = b.left - b.height; x < b.right; x += step) {
        canvas.drawLine(ui.Offset(x, b.bottom), ui.Offset(x + b.height, b.top), hatch);
      }
      canvas.restore();
    }
    if (stageSelectedRegionSig == g.sig) {
      final sel = stageSelectedRegionNumber;
      final rings = sel == null
          ? g.rings
          : [
              for (final (ep, piece) in bake.piecesAt(globalFrame))
                if (ep.sig == g.sig && ep.numberAt(globalFrame) == sel) ...piece
            ];
      final p = _ringsPath(rings);
      // the owner layer's own outline, white and thin.
      final own = regionSourceRings(project, layer.id, globalFrame);
      if (own != null) {
        canvas.drawPath(
            _ringsPath(own),
            ui.Paint()
              ..color = const ui.Color(0xEEFFFFFF)
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = 4 * inv); // wider than the handles' box line on it
      }
      // depth: one ring per level, outermost first.
      for (var k = stageSelectedRegionDepth; k >= 0; k--) {
        canvas.drawPath(
            p,
            ui.Paint()
              ..color = k.isEven ? color : const ui.Color(0xFF151515)
              ..style = ui.PaintingStyle.stroke
              ..strokeJoin = ui.StrokeJoin.round
              ..strokeWidth = (3 + 5 * k) * inv);
      }
      if (stageSelectedRegionDepth.isOdd) {
        canvas.drawPath(p, ui.Paint()
          ..color = color
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 3 * inv);
      }
    }
  }
  // the numbers on their pieces, cut out of the picture (through them only
  // the stage shows, none of the layers below): drawn in a layer of their
  // own that takes itself out of what is under it - the text's own alpha,
  // not its glyph boxes.
  if (!mr.numbered) return;
  for (final (ep, piece) in bake.piecesAt(globalFrame)) {
    final n = ep.numberAt(globalFrame);
    if (n == null || !owned.contains(ep.sig)) continue;
    final b = _ringsPath(piece).getBounds();
    final text = (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 14 * inv))
          ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFFFFFFF), fontWeight: ui.FontWeight.w900))
          ..addText('#$n'))
        .build()
      ..layout(ui.ParagraphConstraints(width: 60 * inv));
    final at = ui.Offset(b.center.dx - text.maxIntrinsicWidth / 2, b.center.dy - text.height / 2);
    canvas.saveLayer(
        ui.Rect.fromLTWH(at.dx - 2 * inv, at.dy - 2 * inv, text.maxIntrinsicWidth + 4 * inv, text.height + 4 * inv),
        ui.Paint()..blendMode = ui.BlendMode.dstOut);
    canvas.drawParagraph(text, at);
    canvas.restore();
  }
}

/// The footprints (largest shape of each numbered piece) in orange, where
/// their pair is now: dashed while the piece still grows, solid once gone.
void _paintFootprints(ui.Canvas canvas, Project project, Layer layer, int globalFrame, double inv) {
  final mr = layer.maskRegions!;
  if (!mr.numbered) return;
  final bake = regionEpisodesReady(project, layer);
  const orange = ui.Color(0xFFFF9800);
  for (final fp in bake.footprints) {
    if (fp.owner.start > globalFrame) continue;
    final ownerIdx = (fp.sig & -fp.sig).bitLength - 1;
    if (ownerIdx >= mr.sources.length) continue;
    final m = toFrameMatrix(getLayerStateAt(project, mr.sources[ownerIdx], globalFrame).matrix);
    final paint = ui.Paint()
      ..color = orange
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2 * inv;
    for (final r in fp.local) {
      final pts = [for (final q in r) applyAffine(m, q)];
      if (pts.length < 2) continue;
      if (fp.openAt(globalFrame)) {
        // dashes along the ring.
        final dash = 6 * inv, gap = 4 * inv;
        var on = true, left = dash;
        for (var i = 0; i < pts.length; i++) {
          var a = ui.Offset(pts[i][0], pts[i][1]);
          final b = ui.Offset(pts[(i + 1) % pts.length][0], pts[(i + 1) % pts.length][1]);
          var seg = (b - a).distance;
          while (seg > 0) {
            final d = math.min(seg, left);
            final c = a + (b - a) / (b - a).distance * d;
            if (on) canvas.drawLine(a, c, paint);
            a = c;
            seg -= d;
            left -= d;
            if (left <= 1e-9) {
              on = !on;
              left = on ? dash : gap;
            }
          }
        }
      } else {
        canvas.drawPath(ui.Path()..addPolygon([for (final q in pts) ui.Offset(q[0], q[1])], true), paint);
      }
    }
    final c = applyAffine(m, fp.local.first.first);
    final text = (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 11 * inv))
          ..pushStyle(ui.TextStyle(color: orange))
          ..addText('#${fp.number}'))
        .build()
      ..layout(ui.ParagraphConstraints(width: 40 * inv));
    canvas.drawParagraph(text, ui.Offset(c[0] + 3 * inv, c[1] - 14 * inv));
  }
}

/// Each link: two lines from the source (two circles, one in the other)
/// to the follower (a hollow circle, bigger than parenting's), set apart
/// so they don't cover a parenting line between the same layers.
void _paintPropLinks(ui.Canvas canvas, Project project, int globalFrame, double inv) {
  final line = ui.Paint()
    ..color = _propLinkColor
    ..strokeWidth = inv;
  final ring = ui.Paint()
    ..color = _propLinkColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 * inv;
  ui.Offset at(LayerState st) => ui.Offset(st.matrix[4] * stageSize.width, st.matrix[5] * stageSize.height);
  for (final layer in project.layers) {
    for (final k in layer.links) {
      if (!k.enabled || k.sourceId == null) continue;
      final ts = getLayerStateAt(project, layer.id, globalFrame);
      final ss = getLayerStateAt(project, k.sourceId!, globalFrame);
      if (!ts.inRange || !ss.inRange) continue;
      final p = at(ss), c = at(ts);
      final d = c - p;
      final len = d.distance;
      if (len > 18 * inv) {
        final u = d / len;
        final n = ui.Offset(-u.dy, u.dx) * (3 * inv);
        final a = p + u * (9 * inv), b = c - u * (7 * inv);
        canvas.drawLine(a + n, b + n, line);
        canvas.drawLine(a - n, b - n, line);
      }
      canvas.drawCircle(p, 9 * inv, ring); // source: a circle in a circle
      canvas.drawCircle(p, 5 * inv, ring);
      canvas.drawCircle(c, 7 * inv, ring); // follower: a bigger hollow one
    }
  }
}

void _paintParentLinks(ui.Canvas canvas, Project project, int globalFrame,
    ParentLinkGeometry geo, double inv) {
  final linePaint = ui.Paint()
    ..color = _parentLinkColor
    ..strokeWidth = inv;
  final hollowPaint = ui.Paint()
    ..color = _parentLinkColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 * inv;
  final filledPaint = ui.Paint()..color = _parentLinkColor;

  // a link line stayed drawn even once its parent or child no longer "exists"
  // at the current frame (past its own startFrame+durationFrames window) - a
  // phantom pointing at nothing. computeParentLinkGeometry itself deliberately
  // stays unfiltered (a structural fact of the project, see its own doc
  // comment); the inRange check belongs here instead, same convention this
  // file's earlier stale-handles fix already established: AND it into the
  // existing !hideVisualLayer guard, never replace it. These are cache hits,
  // not new work - computeParentLinkGeometry already called getLayerStateAt
  // for these same (layerId, globalFrame) pairs to build
  // parentScreen/childScreen.
  for (final edge in geo.edges) {
    final parentInRange =
        getLayerStateAt(project, edge.parentLayerId, globalFrame).inRange;
    final childInRange =
        getLayerStateAt(project, edge.childLayerId, globalFrame).inRange;
    if (!parentInRange || !childInRange) continue;
    final p = ui.Offset(edge.parentScreen[0], edge.parentScreen[1]);
    final c = ui.Offset(edge.childScreen[0], edge.childScreen[1]);
    canvas.drawLine(p, c, linePaint);
    canvas.drawCircle(p, 4 * inv, hollowPaint); // parent end: hollow circle
    canvas.drawCircle(c, 3 * inv, filledPaint); // child end: filled dot
  }
  for (final root in geo.roots) {
    if (!getLayerStateAt(project, root.layerId, globalFrame).inRange) {
      continue;
    }
    final p = ui.Offset(root.screen[0], root.screen[1]);
    // terminal root marker: distinct from either edge-end glyph (a
    // ring around a filled center) - disambiguates "root with exactly
    // one child" from "plain leaf", both of which draw exactly one
    // line otherwise (see parent_link_geometry.dart's own doc comment).
    canvas.drawCircle(p, 6 * inv, hollowPaint);
    canvas.drawCircle(p, 2 * inv, filledPaint);
  }
}

void _paintSnapGrid(ui.Canvas canvas, double frameWidth, double frameHeight, double inv) {
  final paint = ui.Paint()
    ..color = _snapGridColor
    ..strokeWidth = inv;
  for (final line in computeSnapGridLines(frameWidth, frameHeight, snapGridCols, snapGridRows)) {
    canvas.drawLine(
        ui.Offset(line.a[0], line.a[1]), ui.Offset(line.b[0], line.b[1]), paint);
  }
}

void _paintSnapGuides(ui.Canvas canvas, ActiveDragInfo? activeDrag, double inv) {
  final guides = activeDrag?.op.snapGuides ?? const [];
  if (guides.isEmpty) return;
  final paint = ui.Paint()
    ..color = _snapGuideColor
    ..strokeWidth = inv;
  for (final g in guides) {
    final a = ui.Offset(g.a[0], g.a[1]);
    final b = ui.Offset(g.b[0], g.b[1]);
    canvas.drawLine(a, b, paint);
    // marks the target end - same convention _paintParentLinks already
    // uses for its own edge endpoints.
    canvas.drawCircle(b, 3 * inv, ui.Paint()..color = _snapGuideColor);
  }
}

void _paintPathVisual(ui.Canvas canvas, Project project, Layer layer,
    int globalFrame, double inv) {
  // with physics: the path and its stops are where the keys want it (the
  // push left out); the real, pushed path is drawn in green on top.
  final collide = layer.physics.collide;
  final wasSuspended = physicsSuspended;
  if (collide) {
    physicsSuspended = true;
    clearStateCaches();
  }
  final samples = samplePathScreen(project, layer, 60);
  final stations = getAnchorStationsScreen(project, layer, globalFrame);
  if (collide) {
    _paintPushedPath(canvas, project, layer, inv);
    physicsSuspended = wasSuspended;
    clearStateCaches();
  }
  if (samples.length >= 2) {
    final path = ui.Path()..moveTo(samples[0][0], samples[0][1]);
    for (var i = 1; i < samples.length; i++) {
      path.lineTo(samples[i][0], samples[i][1]);
    }
    canvas.drawPath(
      path,
      ui.Paint()
        ..color = _pathLineColor
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = inv,
    );
  }
  for (final st in stations) {
    final p = ui.Offset(st.screen[0], st.screen[1]);
    canvas.drawCircle(p, 4 * inv, ui.Paint()..color = _stationFill);
    canvas.drawCircle(
      p,
      4 * inv,
      ui.Paint()
        ..color = _stationStroke
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5 * inv,
    );
  }
}

const _pushedColor = ui.Color(0xFF66BB6A);

/// The pushed (real) path in green - the keyed one plus the physics
/// offset at each frame - and the layer's contour, green, where it really
/// ends up. Called with physics suspended (keyed poses).
void _paintPushedPath(ui.Canvas canvas, Project project, Layer layer, double inv) {
  final world = physicsWorldOf(project);
  final start = layer.startFrame, end = layer.startFrame + layer.durationFrames;
  final pts = <ui.Offset>[];
  const n = 60;
  for (var i = 0; i <= n; i++) {
    final f = start + ((end - start) * i / n).round();
    final m = toFrameMatrix(getLayerStateAt(project, layer.id, f).matrix);
    final off = world.completeOffsetAt(layer.id, f) ?? const [0.0, 0.0];
    pts.add(ui.Offset(m[4] + off[0], m[5] + off[1]));
  }
  final stroke = ui.Paint()
    ..color = _pushedColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 * inv;
  canvas.drawPath(ui.Path()..addPolygon(pts, false), stroke);
  // the contour where the layer really is at its end.
  final rings = world.rings(project, layer, end);
  if (rings == null) return;
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, end).matrix);
  final off = world.completeOffsetAt(layer.id, end) ?? const [0.0, 0.0];
  for (final r in rings) {
    canvas.drawPath(
        ui.Path()
          ..addPolygon([
            for (final q in r)
              ui.Offset(m[0] * q[0] + m[2] * q[1] + m[4] + off[0], m[1] * q[0] + m[3] * q[1] + m[5] + off[1])
          ], true),
        stroke);
  }
}

void _paintEffectDeformationGrid(ui.Canvas canvas, Project project, Layer layer,
    int globalFrame, double inv) {
  final grid = getEffectDeformationGridScreen(project, layer, globalFrame);
  if (grid == null) return;
  // 1.5x (not the bare 1x mesh_warp's own grid lines use) - this overlay
  // has no dots/handles to anchor on, purely thin lines, which are hard
  // to make out at all on a real high-DPI phone screen at just 1px.
  final linePaint = ui.Paint()
    ..color = _deformGridColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 * inv;
  for (var r = 0; r < grid.rows; r++) {
    final path = ui.Path();
    for (var c = 0; c < grid.cols; c++) {
      final p = grid.screen[r * grid.cols + c];
      c == 0 ? path.moveTo(p[0], p[1]) : path.lineTo(p[0], p[1]);
    }
    canvas.drawPath(path, linePaint);
  }
  for (var c = 0; c < grid.cols; c++) {
    final path = ui.Path();
    for (var r = 0; r < grid.rows; r++) {
      final p = grid.screen[r * grid.cols + c];
      r == 0 ? path.moveTo(p[0], p[1]) : path.lineTo(p[0], p[1]);
    }
    canvas.drawPath(path, linePaint);
  }
}

void _paintHandles(ui.Canvas canvas, Project project, Layer layer,
    int globalFrame, ActiveDragInfo? activeDrag, double inv) {
  if (isAudioShape(layer.content.shape)) return; // a sound has nothing on the stage
  if (isMediaShape(layer.content.shape)) {
    // the Chroma tab's stage tools own the stage while active.
    if (chromaTool != 'none') return;
  }
  final pieceOp = activeDrag?.op;
  if (pieceOp is PieceRectDragOp && pieceOp.a != null && pieceOp.b != null) {
    final r = ui.Rect.fromPoints(ui.Offset(pieceOp.a![0], pieceOp.a![1]), ui.Offset(pieceOp.b![0], pieceOp.b![1]));
    canvas.drawRect(r, ui.Paint()..color = const ui.Color(0x2200E5FF));
    canvas.drawRect(
        r,
        ui.Paint()
          ..color = const ui.Color(0xFF00E5FF)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5 * inv);
    return;
  }
  if (cropEditing || pieceInsets != null) {
    _paintCrop(canvas, project, layer, globalFrame, activeDrag, inv);
    return;
  }
  final cpInst = getCornerPinInstance(layer);
  final mwInst = getMeshWarpInstance(layer);

  if (cpInst != null) {
    _paintCornerPin(
        canvas, project, layer, cpInst, globalFrame, activeDrag, inv);
  }
  if (mwInst != null) {
    _paintMeshWarp(
        canvas, project, layer, mwInst, globalFrame, activeDrag, inv);
  }
  final r3d = getRotate3dInstance(layer);
  if (r3d != null) _paintRotate3dPivot(canvas, project, layer, r3d, globalFrame, inv);
  _paintBendHandles(canvas, project, layer, globalFrame, activeDrag, inv);
  if (glowHandlesVisible && layer.fill.active) _paintGlowHandles(canvas, project, layer, globalFrame, activeDrag, inv);
  if (layer.pendulum.enabled) {
    _paintPendulumPivot(canvas, project, layer, globalFrame, inv);
  }
  // a text part open in the Text tab: its box (drag it to move the part).
  final partBox = textPartBoxFrame(project, layer, globalFrame);
  if (partBox != null) {
    final path = ui.Path()..addPolygon([for (final q in partBox) ui.Offset(q[0], q[1])], true);
    canvas.drawPath(path, ui.Paint()..color = const ui.Color(0x22BA68C8));
    canvas.drawPath(
        path,
        ui.Paint()
          ..color = const ui.Color(0xFFBA68C8)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5 * inv);
  }
  // a rect being lengthened: what it gains (blue) and loses (red).
  final extendOp = activeDrag?.op;
  if (extendOp is ScaleDragOp && extendOp.extendStart != null && extendOp.layer == layer) {
    final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
    ui.Path box(List<double> b) {
      final pts = [
        [b[0], b[1]], [b[2], b[1]], [b[2], b[3]], [b[0], b[3]],
      ].map((p) => applyAffine(m, p)).toList();
      return ui.Path()..addPolygon([for (final p in pts) ui.Offset(p[0], p[1])], true);
    }

    final c = layer.content;
    final now = box([c.offset[0] - c.size[0] / 2, c.offset[1] - c.size[1] / 2, c.offset[0] + c.size[0] / 2, c.offset[1] + c.size[1] / 2]);
    final was = box(extendOp.extendStart!);
    canvas.drawPath(ui.Path.combine(ui.PathOperation.difference, now, was), ui.Paint()..color = const ui.Color(0x663D8BFF));
    canvas.drawPath(ui.Path.combine(ui.PathOperation.difference, was, now), ui.Paint()..color = const ui.Color(0x66FF4040));
  }
  // Origami: the fold lines (where a fold is, even before it folds), a
  // dot in each one's middle to drag it.
  if (origamiFoldsOnStage) {
    final line = ui.Paint()
      ..color = const ui.Color(0xCCFFD54F)
      ..strokeWidth = 1.5 * inv;
    // the lines stay on the paper: clipped to the shape as it is drawn
    // (every piece, folded flaps too) - past its edge they only confused.
    ui.Path? paper;
    final rings = layerBaseRings(project, layer, globalFrame);
    if (rings != null) {
      final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
      for (final r in rings) {
        if (r.length < 3) continue;
        final p = ui.Path()..addPolygon([for (final q in r) applyAffine(m, q)].map((q) => ui.Offset(q[0], q[1])).toList(), true);
        paper = paper == null ? p : ui.Path.combine(ui.PathOperation.union, paper, p);
      }
    }
    final folds = origamiFoldLinesFrame(project, layer, globalFrame);
    canvas.save();
    if (paper != null) {
      canvas.clipPath(paper);
    }
    for (final f in folds) {
      // dashed, along its points (it bends where it lies on a flap).
      final step = 8 * inv;
      var on = true, left = step;
      for (var i = 0; i + 1 < f.pts.length; i++) {
        var a = ui.Offset(f.pts[i][0], f.pts[i][1]);
        final b = ui.Offset(f.pts[i + 1][0], f.pts[i + 1][1]);
        var seg = (b - a).distance;
        while (seg > 1e-9) {
          final d = math.min(seg, left);
          final c = a + (b - a) / (b - a).distance * d;
          if (on) canvas.drawLine(a, c, line);
          a = c;
          seg -= d;
          left -= d;
          if (left <= 1e-9) {
            on = !on;
            left = step;
          }
        }
      }
    }
    canvas.restore();
    for (final f in folds) {
      final active = activeDrag?.family == 'origami' && activeDrag?.activeKey == '${f.inst.id}:${f.key}';
      canvas.drawCircle(ui.Offset(f.mid[0], f.mid[1]), 6 * inv, ui.Paint()..color = const ui.Color(0xFFFFD54F));
      if (!active) canvas.drawCircle(ui.Offset(f.mid[0], f.mid[1]), 3.5 * inv, ui.Paint()..color = const ui.Color(0xFF000000));
    }
    // at one end of the first fold: a turn handle (the folds' direction).
    for (final h in origamiDirectionHandlesFrame(project, layer, globalFrame)) {
      final active = activeDrag?.family == 'origami' && activeDrag?.activeKey == '${h.inst.id}:${h.n}:direction';
      final c = ui.Offset(h.p[0], h.p[1]);
      canvas.drawCircle(c, 6.5 * inv, ui.Paint()..color = const ui.Color(0xFFFFD54F));
      canvas.drawCircle(
          c,
          4 * inv,
          ui.Paint()
            ..color = const ui.Color(0xFF000000)
            ..style = active ? ui.PaintingStyle.fill : ui.PaintingStyle.stroke
            ..strokeWidth = 1.5 * inv);
    }
  }
  // rounded corners: what the rounding cuts off (red) or fills in
  // (green) - while the Fill tab is open, a line's corner in the Line tab,
  // or while a rounding handle is dragged.
  final rounding = activeDrag?.family == 'round' ||
      (activeDrag?.activeKey != null && (activeDrag!.activeKey!.startsWith('r') || activeDrag.activeKey!.startsWith('k')) && activeDrag.family == 'line');
  if (cornerHandlesVisible || rounding || (isNodeLine(layer.content) && lineEditing)) {
    for (final r in roundRegionsFrame(project, layer, globalFrame)) {
      final path = ui.Path()..addPolygon([for (final q in r.ring) ui.Offset(q[0], q[1])], true);
      canvas.drawPath(path, ui.Paint()..color = r.adds ? const ui.Color(0x6633CC66) : const ui.Color(0x66FF4040));
      canvas.drawPath(
          path,
          ui.Paint()
            ..color = r.adds ? const ui.Color(0xCC33CC66) : const ui.Color(0xCCFF4040)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 1 * inv);
    }
  }
  // only big enough on the screen to grab them apart from the box's own.
  if (cornerHandlesVisible && !isNodeLine(layer.content) && layerShortSideFrame(project, layer, globalFrame) / inv >= 140) {
    final rh = roundHandlesFrame(project, layer, globalFrame);
    final paint = ui.Paint()
      ..color = const ui.Color(0xFFFF8A65)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5 * inv;
    final fill = ui.Paint()..color = const ui.Color(0xFFFF8A65);
    for (final e in rh.entries) {
      _diamond(canvas, ui.Offset(e.value[0], e.value[1]), (e.key == 'rr' ? 6 : 4.5) * inv,
          activeDrag?.family == 'round' && activeDrag?.activeKey == e.key ? fill : paint);
    }
  }
  if (isNodeLine(layer.content)) _paintLineHandles(canvas, project, layer, globalFrame, activeDrag, inv);
  // a line with its point handles: no box.
  if (isOpenNodeLine(layer.content)) return;
  _paintTransformBox(canvas, project, layer, globalFrame, activeDrag, inv,
      hasDeform: cpInst != null || mwInst != null);
}

/// The stage's handle size factor (frame px per screen px), as last
/// painted.
double stageHandleScale = 1;

/// The holes a selected line's point handles cut from the line (frame
/// px): a hollow square's inside, and a gap ring around the filled one.
List<ui.Path> lineHandleCuts(Project project, Layer layer, int globalFrame, {String? activeKey}) {
  if (!isNodeLine(layer.content)) return const [];
  final inv = stageHandleScale;
  final h = lineHandlesFrame(project, layer, globalFrame, editing: lineEditing, selected: lineSelectedPoint);
  final out = <ui.Path>[];
  for (final e in h.entries) {
    if (e.key[0] != 'n') {
      // a bezier handle: like the points, but round - see-through inside,
      // or (dragged) filled with a gap round it.
      final c = ui.Offset(e.value[0], e.value[1]);
      out.add(activeKey == e.key
          ? (ui.Path()
            ..fillType = ui.PathFillType.evenOdd
            ..addOval(ui.Rect.fromCircle(center: c, radius: 7.5 * inv))
            ..addOval(ui.Rect.fromCircle(center: c, radius: 5 * inv)))
          : (ui.Path()..addOval(ui.Rect.fromCircle(center: c, radius: 4.25 * inv))));
      continue;
    }
    final i = int.parse(e.key.substring(1));
    final r = ui.Rect.fromCenter(center: ui.Offset(e.value[0], e.value[1]), width: 10 * inv, height: 10 * inv);
    final active = activeKey == e.key || (lineEditing && i == lineSelectedPoint);
    out.add(active
        ? (ui.Path()
          ..fillType = ui.PathFillType.evenOdd
          ..addRect(r.inflate(2.5 * inv))
          ..addRect(r))
        : (ui.Path()..addRect(r.deflate(0.75 * inv))));
  }
  return out;
}

/// A vector line's handles: its points as squares - hollow ones see-through
/// inside with an outline (the line stops at their edge), the selected
/// one filled (in the Line tab) - and bezier handles as dots on lines to
/// their point.
void _paintLineHandles(ui.Canvas canvas, Project project, Layer layer, int globalFrame, ActiveDragInfo? activeDrag,
    double inv) {
  final h = lineHandlesFrame(project, layer, globalFrame, editing: lineEditing, selected: lineSelectedPoint);
  // the line's own colour (opaque, so a faint line still shows them).
  final hex = (layer.color ?? '').replaceFirst('#', '');
  final v = hex.length >= 6 ? int.tryParse(hex.substring(0, 6), radix: 16) : null;
  final color = v == null ? _transformBoxColor : ui.Color(0xFF000000 | v);
  final stroke = ui.Paint()
    ..color = color
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 * inv;
  final fill = ui.Paint()..color = color;
  // the see-through parts (a hollow square's inside, the gap around the
  // filled one) are cut from the line itself by the renderer - see
  // lineHandleCuts.
  for (final e in h.entries) {
    final p = ui.Offset(e.value[0], e.value[1]);
    final i = int.parse(e.key.substring(1));
    if (e.key[0] == 'n') {
      final active = activeDrag?.activeKey == e.key || (lineEditing && i == lineSelectedPoint);
      final r = ui.Rect.fromCenter(center: p, width: 10 * inv, height: 10 * inv);
      if (active) {
        canvas.drawRect(r, fill);
      } else {
        canvas.drawRect(r, stroke);
      }
    } else {
      // a corner's rounding handles: a diamond (radius) and a small
      // diamond on the curve (shape).
      if (e.key[0] == 'r' || e.key[0] == 'k') {
        _diamond(canvas, p, (e.key[0] == 'r' ? 6 : 4.5) * inv, activeDrag?.activeKey == e.key ? fill : stroke);
        continue;
      }
      final n = h['n$i'];
      if (n != null) canvas.drawLine(ui.Offset(n[0], n[1]), p, stroke);
      if (activeDrag?.activeKey == e.key) {
        canvas.drawCircle(p, 5 * inv, fill);
      } else {
        canvas.drawCircle(p, 5 * inv, stroke);
      }
    }
  }
}


void _paintCrop(ui.Canvas canvas, Project project, Layer layer,
    int globalFrame, ActiveDragInfo? activeDrag, double inv) {
  // the piece rect (Detach a piece) when that tool is on, else the crop.
  final piece = !cropEditing && pieceInsets != null;
  final h = getCropHandles(project, layer, globalFrame, insets: piece ? pieceInsets : null);
  ui.Path outline(BoundingBox b) {
    final pts = [
      [b.minX, b.minY],
      [b.maxX, b.minY],
      [b.maxX, b.maxY],
      [b.minX, b.maxY],
    ].map((p) => applyAffine(h.mCanvas, p)).toList();
    return ui.Path()
      ..moveTo(pts[0][0], pts[0][1])
      ..lineTo(pts[1][0], pts[1][1])
      ..lineTo(pts[2][0], pts[2][1])
      ..lineTo(pts[3][0], pts[3][1])
      ..close();
  }

  // the full box, dimmed - where the crop can still grow to.
  canvas.drawPath(
      outline(h.full),
      ui.Paint()
        ..color = _cropColor.withOpacity(0.35)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = inv);
  canvas.drawPath(
      outline(h.crop),
      ui.Paint()
        ..color = _cropColor
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5 * inv);
  for (final e in h.screen.entries) {
    if (_isSiblingHidden(activeDrag, 'crop', e.key)) continue;
    final p = ui.Offset(e.value[0], e.value[1]);
    canvas.drawCircle(p, 7 * inv, ui.Paint()..color = _handleFill);
    canvas.drawCircle(
        p,
        7 * inv,
        ui.Paint()
          ..color = _cropColor
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2 * inv);
  }
}

void _paintBrokenImage(ui.Canvas canvas, Project project, Layer layer,
    int globalFrame, double inv) {
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  final b = shapeBoundingBox(layer.content);
  final corners = [
    [b.minX, b.minY],
    [b.maxX, b.minY],
    [b.maxX, b.maxY],
    [b.minX, b.maxY],
  ].map((p) => applyAffine(m, p)).map((p) => ui.Offset(p[0], p[1])).toList();
  final paint = ui.Paint()
    ..color = const ui.Color(0xFFE05A5A)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 2 * inv;
  canvas.drawPath(ui.Path()..addPolygon(corners, true), paint);
  canvas.drawLine(corners[0], corners[2], paint);
  canvas.drawLine(corners[1], corners[3], paint);
}

bool _isSiblingHidden(ActiveDragInfo? activeDrag, String family, String? key) {
  if (activeDrag == null || activeDrag.family != family) return false;
  return activeDrag.activeKey != key;
}

void _paintCornerPin(
    ui.Canvas canvas,
    Project project,
    Layer layer,
    EffectInstance inst,
    int globalFrame,
    ActiveDragInfo? activeDrag,
    double inv) {
  final h = getCornerPinHandles(project, layer, inst, globalFrame);
  final linePaint = ui.Paint()
    ..color = _cornerPinColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = inv;
  // the connecting outline is the "live-updating shape/mesh/outline"
  // the spec says stays visible throughout a drag - never hidden.
  final path = ui.Path();
  for (var i = 0; i < h.keys.length; i++) {
    final p = h.screen[h.keys[i]]!;
    i == 0 ? path.moveTo(p[0], p[1]) : path.lineTo(p[0], p[1]);
  }
  path.close();
  canvas.drawPath(path, linePaint);

  for (final k in h.keys) {
    if (_isSiblingHidden(activeDrag, 'cornerPin', k)) continue;
    final p = h.screen[k]!;
    canvas.drawCircle(
        ui.Offset(p[0], p[1]), 7 * inv, ui.Paint()..color = _handleFill);
    canvas.drawCircle(
      ui.Offset(p[0], p[1]),
      7 * inv,
      ui.Paint()
        ..color = _cornerPinColor
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2 * inv,
    );
  }
}

void _paintMeshWarp(
    ui.Canvas canvas,
    Project project,
    Layer layer,
    EffectInstance inst,
    int globalFrame,
    ActiveDragInfo? activeDrag,
    double inv) {
  final h = getMeshWarpHandles(project, layer, inst, globalFrame);
  final linePaint = ui.Paint()
    ..color = _meshWarpColor
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = inv;
  // grid lines: the "live-updating mesh" - always visible, never hidden.
  for (var r = 0; r < h.rows; r++) {
    final path = ui.Path();
    for (var c = 0; c < h.cols; c++) {
      final p = h.handles[r * h.cols + c].screen;
      c == 0 ? path.moveTo(p[0], p[1]) : path.lineTo(p[0], p[1]);
    }
    canvas.drawPath(path, linePaint);
  }
  for (var c = 0; c < h.cols; c++) {
    final path = ui.Path();
    for (var r = 0; r < h.rows; r++) {
      final p = h.handles[r * h.cols + c].screen;
      r == 0 ? path.moveTo(p[0], p[1]) : path.lineTo(p[0], p[1]);
    }
    canvas.drawPath(path, linePaint);
  }
  for (final entry in h.handles) {
    if (_isSiblingHidden(activeDrag, 'meshWarp', entry.key)) continue;
    final p = entry.screen;
    canvas.drawCircle(
        ui.Offset(p[0], p[1]), 4 * inv, ui.Paint()..color = _handleFill);
    canvas.drawCircle(
      ui.Offset(p[0], p[1]),
      4 * inv,
      ui.Paint()
        ..color = _meshWarpColor
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5 * inv,
    );
  }
}

const _bendStaticTint = ui.Color(0x334A90E2);
const _bendCarriedTint = ui.Color(0x33E2A94A);
const _bendLineColor = ui.Color(0xFF6FB7FF);

/// Bend v2 (visual): the static zone tinted blue, the carried zone amber,
/// and both lines - at their deformed places.
void _paintBendZones(ui.Canvas canvas, Project project, Layer layer, int globalFrame, double inv) {
  for (final h in getBendHandles(project, layer, globalFrame)) {
    ui.Path poly(List<List<double>> pts) {
      final path = ui.Path();
      for (var i = 0; i < pts.length; i++) {
        i == 0 ? path.moveTo(pts[i][0], pts[i][1]) : path.lineTo(pts[i][0], pts[i][1]);
      }
      return path..close();
    }

    canvas.drawPath(poly(h.staticZone), ui.Paint()..color = _bendStaticTint);
    canvas.drawPath(poly(h.carriedZone), ui.Paint()..color = _bendCarriedTint);
    final line = ui.Paint()
      ..color = _bendLineColor
      ..strokeWidth = 1.5 * inv;
    for (final l in [h.startLine, h.endLine]) {
      canvas.drawLine(ui.Offset(l[0][0], l[0][1]), ui.Offset(l[1][0], l[1][1]), line);
    }
  }
}

/// Bend v2 (physical): start / end line handles and the angle knob.
/// While one is dragged only it is shown.
void _paintBendHandles(
    ui.Canvas canvas, Project project, Layer layer, int globalFrame, ActiveDragInfo? activeDrag, double inv) {
  final dragging = activeDrag?.family == 'bendLine' ? activeDrag!.activeKey : null;
  final handles = getBendHandles(project, layer, globalFrame);
  for (var i = 0; i < handles.length; i++) {
    final h = handles[i];
    for (final (key, p) in [('start', h.startHandle), ('end', h.endHandle), ('angle', h.angleHandle)]) {
      if (dragging != null && dragging != '$i:$key') continue;
      final o = ui.Offset(p[0], p[1]);
      if (key == 'angle') {
        canvas.drawLine(ui.Offset(h.pivot[0], h.pivot[1]), o,
            ui.Paint()
              ..color = _bendLineColor.withOpacity(0.6)
              ..strokeWidth = inv);
      }
      final r = (key == 'angle' ? 5 : 6) * inv;
      canvas.drawCircle(o, r, ui.Paint()..color = _handleFill);
      canvas.drawCircle(
          o,
          r,
          ui.Paint()
            ..color = _bendLineColor
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 2 * inv);
    }
  }
}

/// Gradient fill glows (Fill tab open): each glow's reach as a thin
/// outline, a line glow's segment, and a handle in the glow's own colour
/// on each point / line end.
void _paintGlowHandles(ui.Canvas canvas, Project project, Layer layer, int globalFrame, ActiveDragInfo? activeDrag,
    double inv) {
  for (final s in evaluateGlows(project, layer, globalFrame)) {
    final hex = s.glow.color.replaceFirst('#', '');
    final color = ui.Color(0xFF000000 | (int.tryParse(hex, radix: 16) ?? 0xFFFFFF));
    final outline = glowOutline(project, layer, s, globalFrame);
    canvas.drawPath(
        ui.Path()..addPolygon([for (final p in outline) ui.Offset(p[0], p[1])], true),
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1 * inv
          ..color = const ui.Color(0x99FFFFFF));
    final hs = getGlowHandles(project, layer, globalFrame).where((h) => h.glow == s.glow).toList();
    // a line glow's segment, or a guided glow's guide (end to end).
    final ends = hs.where((h) => h.end != 'c').toList();
    if (ends.length == 2) {
      canvas.drawLine(ui.Offset(ends[0].screen[0], ends[0].screen[1]), ui.Offset(ends[1].screen[0], ends[1].screen[1]),
          ui.Paint()
            ..strokeWidth = 1.5 * inv
            ..color = const ui.Color(0xCCFFFFFF));
    }
    for (final h in hs) {
      final p = ui.Offset(h.screen[0], h.screen[1]);
      final active = activeDrag?.family == 'glow' && activeDrag?.activeKey == h.key;
      // a guided glow's ends: small white squares on the shape's edge.
      if (s.glow.kind == 'guided' && h.end != 'c') {
        canvas.drawRect(ui.Rect.fromCenter(center: p, width: 9 * inv, height: 9 * inv), ui.Paint()..color = const ui.Color(0xFFFFFFFF));
        continue;
      }
      canvas.drawCircle(p, (active ? 8 : 6) * inv, ui.Paint()..color = color);
      canvas.drawCircle(
          p,
          (active ? 8 : 6) * inv,
          ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 2 * inv
            ..color = const ui.Color(0xFFFFFFFF));
    }
  }
}

/// 3D Rotate's pivot: a handle with a line along the turn axis through
/// it, so both the pivot and the axis direction are visible.
void _paintRotate3dPivot(ui.Canvas canvas, Project project, Layer layer,
    EffectInstance inst, int globalFrame, double inv) {
  final h = getRotate3dPivotHandle(project, layer, inst, globalFrame);
  final p = ui.Offset(h.screen[0], h.screen[1]);
  final ax = h.axisScreen;
  final len = math.sqrt(ax[0] * ax[0] + ax[1] * ax[1]);
  final paint = ui.Paint()
    ..color = _rotate3dColor
    ..strokeWidth = 1.5 * inv;
  if (len > 0) {
    final d = ui.Offset(ax[0] / len, ax[1] / len) * (40 * inv);
    canvas.drawLine(p - d, p + d, paint);
  }
  canvas.drawCircle(p, 6 * inv, ui.Paint()..color = _handleFill);
  canvas.drawCircle(
      p,
      6 * inv,
      ui.Paint()
        ..color = _rotate3dColor
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2 * inv);
}

void _paintPendulumPivot(ui.Canvas canvas, Project project, Layer layer,
    int globalFrame, double inv) {
  // single handle, nothing to hide as a sibling - always shown in full
  // whenever pendulum is enabled and handles aren't globally hidden.
  final h = getPendulumPivotHandleScreen(project, layer, globalFrame);
  final p = ui.Offset(h.screen[0], h.screen[1]);
  // the weight: the line's other end, dashed-free thin line to it and a
  // filled dot.
  final w = getPendulumWeightHandleScreen(project, layer, globalFrame);
  final wp = ui.Offset(w.screen[0], w.screen[1]);
  canvas.drawLine(p, wp, ui.Paint()
    ..color = _pendulumColor.withOpacity(0.6)
    ..strokeWidth = 1 * inv);
  canvas.drawCircle(wp, 5 * inv, ui.Paint()..color = _pendulumColor);
  canvas.drawCircle(p, 6 * inv, ui.Paint()..color = _handleFill);
  canvas.drawCircle(
    p,
    6 * inv,
    ui.Paint()
      ..color = _pendulumColor
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2 * inv,
  );
  // crosshair, distinct from the move handle's own crosshair style -
  // no line to the object's anchor (confirmed against handles.js's
  // drawPendulumPivotHandle - it never draws one, see the plan's own
  // note on this).
  final crossPaint = ui.Paint()
    ..color = _pendulumColor
    ..strokeWidth = 2 * inv;
  canvas.drawLine(ui.Offset(p.dx - 9 * inv, p.dy),
      ui.Offset(p.dx + 9 * inv, p.dy), crossPaint);
  canvas.drawLine(ui.Offset(p.dx, p.dy - 9 * inv),
      ui.Offset(p.dx, p.dy + 9 * inv), crossPaint);
}

void _paintTransformBox(
  ui.Canvas canvas,
  Project project,
  Layer layer,
  int globalFrame,
  ActiveDragInfo? activeDrag,
  double inv, {
  required bool hasDeform,
  bool outlineOnly = false,
}) {
  final tb = getTransformBoxHandles(project, layer, globalFrame);
  final isNull = isNullLikeShape(layer.content.shape);

  if (!hasDeform) {
    final boxPath = ui.Path();
    const corners = ['tl', 'tr', 'br', 'bl'];
    for (var i = 0; i < corners.length; i++) {
      final p = tb.screen[corners[i]]!;
      i == 0 ? boxPath.moveTo(p[0], p[1]) : boxPath.lineTo(p[0], p[1]);
    }
    boxPath.close();
    // the shape's own outline - physical (tied to hideHandles, not the
    // visual toggle) per the gesture spec's own explicit exception, and
    // part of the "live-updating outline" that stays visible through a
    // drag - never gated by _isSiblingHidden.
    // a mirror's copy: its own (blue) outline shows instead - handles only.
    // under a deforming effect its grid shows the shape - the box line
    // only when asked for (Settings).
    final gridShown = layer.effectStack.any(isDeformingEffect) && !showBoxOverEffectGrid;
    if (!layer.mirrorProbe && !gridShown) {
      canvas.drawPath(
        boxPath,
        ui.Paint()
          ..color = _transformBoxColor
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = inv,
      );
    }
    // a layer selected along with the leading one: its outline only.
    if (outlineOnly) return;

    final isText = layer.content.shape == 'text';
    final crowded = crowdedTransformHandles(tb, inv);
    // a null: only its square, the size corner and the move corner.
    for (final k in [if (!isNull) ...['top', 'bottom', 'left', 'right']]) {
      if (_isSiblingHidden(activeDrag, 'transformBox', k) || crowded.contains(k)) continue;
      final p = tb.screen[k]!;
      if (isText) {
        // text: the side handles resize the text box - drawn as crop-
        // style bars along the edge instead of the scale dots.
        final a = tb.screen['tl']!;
        final b = tb.screen[k == 'top' || k == 'bottom' ? 'tr' : 'bl']!;
        final dx = b[0] - a[0], dy = b[1] - a[1];
        final len = math.sqrt(dx * dx + dy * dy);
        final ux = len == 0 ? 1.0 : dx / len, uy = len == 0 ? 0.0 : dy / len;
        final h = 8 * inv;
        canvas.drawLine(
            ui.Offset(p[0] - ux * h, p[1] - uy * h),
            ui.Offset(p[0] + ux * h, p[1] + uy * h),
            ui.Paint()
              ..color = _cropColor
              ..strokeWidth = 4 * inv
              ..strokeCap = ui.StrokeCap.round);
        continue;
      }
      canvas.drawCircle(
          ui.Offset(p[0], p[1]), 5 * inv, ui.Paint()..color = _handleFill);
      canvas.drawCircle(
        ui.Offset(p[0], p[1]),
        5 * inv,
        ui.Paint()
          ..color = _transformBoxColor
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5 * inv,
      );
    }
    if (!_isSiblingHidden(activeDrag, 'transformBox', 'scaleCorner')) {
      final sc = tb.screen['scaleCorner']!;
      canvas.drawCircle(
          ui.Offset(sc[0], sc[1]), 6 * inv, ui.Paint()..color = _handleFill);
      canvas.drawCircle(
        ui.Offset(sc[0], sc[1]),
        6 * inv,
        ui.Paint()
          ..color = _transformBoxColor
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2 * inv,
      );
    }
    if (!isNull && !_isSiblingHidden(activeDrag, 'transformBox', 'rotateCorner') && !crowded.contains('rotateCorner')) {
      final rc = tb.screen['rotateCorner']!;
      canvas.drawCircle(
          ui.Offset(rc[0], rc[1]), 6 * inv, ui.Paint()..color = _handleFill);
      canvas.drawCircle(
        ui.Offset(rc[0], rc[1]),
        6 * inv,
        ui.Paint()
          ..color = _rotateColor
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 2 * inv,
      );
    }
  }

  // anchor/move handle - shown regardless of corner-pin/mesh-warp.
  // corner pin / mesh warp: the whole shape moves it (no move handle).
  if (getActiveMeshOrPinInstance(layer) == null && !_isSiblingHidden(activeDrag, 'transformBox', 'moveCorner')) {
    _paintMoveHandle(canvas, tb.screen['moveCorner']!, inv);
  }
}

/// The anchor / move handle: a cross in a ring.
void _paintMoveHandle(ui.Canvas canvas, List<double> mvp, double inv) {
  {
    final p = ui.Offset(mvp[0], mvp[1]);
    final r = 6.0 * inv;
    final paint = ui.Paint()
      ..color = _moveColor
      ..strokeWidth = 1.5 * inv;
    canvas.drawLine(
        ui.Offset(p.dx - r, p.dy), ui.Offset(p.dx + r, p.dy), paint);
    canvas.drawLine(
        ui.Offset(p.dx, p.dy - r), ui.Offset(p.dx, p.dy + r), paint);
    canvas.drawCircle(
      p,
      r,
      ui.Paint()
        ..color = _moveColor
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5 * inv,
    );
  }
}

void _paintProjectOutline(ui.Canvas canvas, List<List<double>> q, double inv) {
  final paint = ui.Paint()
    ..color = const ui.Color(0xFF2F7DD1)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5 * inv;
  final pts = [for (final p in q) ui.Offset(p[0], p[1])];
  canvas.drawPath(ui.Path()..addPolygon(pts, true), paint);
  final dash = 6 * inv, gap = 5 * inv, reach = 40 * inv;
  for (var i = 0; i < 4; i++) {
    final a = pts[i], b = pts[(i + 1) % 4];
    final d = b - a;
    if (d.distance < 1e-6) continue;
    final dir = d / d.distance;
    for (final (from, sign) in [(b, 1.0), (a, -1.0)]) {
      for (var t = gap; t < reach; t += dash + gap) {
        canvas.drawLine(from + dir * (sign * t), from + dir * (sign * math.min(reach, t + dash)), paint);
      }
    }
  }
}

/// A diamond handle (rounding handles).
void _diamond(ui.Canvas canvas, ui.Offset c, double r, ui.Paint paint) {
  canvas.drawPath(
      ui.Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close(),
      paint);
}


/// Crop lines on the stage: the line (thin, orange like Collide's
/// contour, a small dot at each point) and the area it marks, tinted red
/// within the layer - the other side when inverted. Frame space.
typedef CropLineOverlay = ({
  List<List<double>> points,
  List<List<double>> outline,
  List<List<double>> area,
  bool invert,
  bool closed,
});

void _paintCropLine(ui.Canvas canvas, CropLineOverlay c, double inv) {
  ui.Path poly(List<List<double>> pts, bool close) =>
      ui.Path()..addPolygon([for (final p in pts) ui.Offset(p[0], p[1])], close);
  if (c.outline.length >= 3 && c.area.length >= 3) {
    final shape = poly(c.outline, true);
    final area = poly(c.area, true);
    final marked = ui.Path.combine(c.invert ? ui.PathOperation.difference : ui.PathOperation.intersect, shape, area);
    canvas.drawPath(marked, ui.Paint()..color = const ui.Color(0x55FF3D00));
  }
  const orange = ui.Color(0xFFFF9800);
  if (c.points.length >= 2) {
    canvas.drawPath(
        poly(c.points, c.closed),
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1 * inv
          ..color = orange);
  }
  final dot = ui.Paint()..color = orange;
  for (final p in c.points) {
    canvas.drawCircle(ui.Offset(p[0], p[1]), 2.2 * inv, dot);
  }
}


/// The mirror line: dashed through the whole frame's reach, its two ends
/// and its middle as handles.
void _paintMirrorLine(ui.Canvas canvas, List<List<double>> l, double inv) {
  const color = ui.Color(0xFF4DD0E1);
  final a = ui.Offset(l[0][0], l[0][1]), b = ui.Offset(l[1][0], l[1][1]);
  final d = b - a;
  if (d.distance > 1e-6) {
    final u = d / d.distance;
    const far = 1e4;
    // faint: the line carried on; solid: between its ends.
    canvas.drawLine(a - u * far, b + u * far, ui.Paint()
      ..color = color.withOpacity(0.35)
      ..strokeWidth = 1 * inv);
    canvas.drawLine(a, b, ui.Paint()
      ..color = color
      ..strokeWidth = 1.5 * inv);
  }
  final dot = ui.Paint()..color = color;
  canvas.drawCircle(a, 6 * inv, dot);
  canvas.drawCircle(b, 6 * inv, dot);
  canvas.drawRect(ui.Rect.fromCenter(center: (a + b) / 2, width: 10 * inv, height: 10 * inv), dot);
}
