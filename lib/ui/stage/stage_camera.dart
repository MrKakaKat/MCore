import 'dart:math' as math;
import 'dart:ui' as ui;

/// Pan/zoom state for the stage widget - NEW, no JS/desktop equivalent
/// (movement-mobile-gesture-spec.md's addendum: "neither movement_mobile
/// nor the JS/desktop version has any pan/zoom today"). Purely a
/// viewport concern: everything else (handles.dart, drag_ops.dart,
/// parent_link_geometry.dart, canvas_renderer.dart) works entirely in
/// FRAME space (the stageSize.width x stageSize.height convention) and
/// knows nothing about this camera. This class is the one place that
/// converts between raw on-screen/device pixels ("screen" space) and
/// that frame space.
///
/// Real device bug this fixes: the frame's own aspect ratio used to
/// drift with device rotation - the same anchor value produced a
/// DIFFERENT physical on-screen position in portrait vs landscape.
/// Root cause was stage_view.dart calling CanvasRenderer.setSize() (and
/// therefore setting the global stageSize) from the widget's OWN
/// layout size, so the project's coordinate system was silently
/// redefined to match whatever orientation happened to be current at
/// the moment it first got locked in. The actual fix lives in
/// app_state.dart (frame size is now a fixed constant, set once, never
/// touched by any widget) - but that alone isn't enough: without
/// something in the drawing/hit-testing path to make the FIXED frame
/// still fit whatever viewport size is actually available, either the
/// frame would get cropped/overflow on a differently-shaped viewport,
/// or (worse) someone would be tempted to reintroduce the same bug by
/// stretching the frame non-uniformly to fill the viewport, which
/// would distort it instead of just rotating a fixed rectangle.
///
/// The fix is a BoxFit.contain-style base transform (`fitScale`/
/// `fitOffset` below) - RECOMPUTED FRESH from `frameSize`/`viewportSize`
/// on every use, never cached/locked the way the old setSize() call
/// was. It letterboxes the fixed frame into whatever viewport is
/// currently available; the user's own pan/zoom (`pan`/`scale` fields)
/// composes on TOP of that letterboxed placement, in actual widget
/// pixels, exactly like before this fix - so existing pinch/pan
/// behavior is unaffected, only now it's zooming/panning a frame whose
/// own coordinate system never changes out from under it.
///
/// UNVERIFIED - needs dart:ui (Offset), not available in this sandbox.
/// Settings: two fingers also turn the stage view (like the pinch zoom;
/// only the view - nothing in the project turns).
bool stageRotateEnabled = false;

class StageCamera {
  /// The view's turn (radians) about the viewport centre, when
  /// stageRotateEnabled.
  double rotation = 0;
  /// It sticks to straight angles (within 4 degrees).
  double get viewRotation {
    if (!stageRotateEnabled) return 0;
    final q = (rotation / (math.pi / 2)).roundToDouble() * (math.pi / 2);
    return (rotation - q).abs() < 4 * math.pi / 180 ? q : rotation;
  }

  ui.Offset _turn(ui.Offset p, double a) {
    if (a == 0) return p;
    final c = ui.Offset(viewportSize.width / 2, viewportSize.height / 2);
    final d = p - c;
    final cs = math.cos(a), sn = math.sin(a);
    return c + ui.Offset(d.dx * cs - d.dy * sn, d.dx * sn + d.dy * cs);
  }

  ui.Offset _turnVec(ui.Offset v, double a) {
    if (a == 0) return v;
    final cs = math.cos(a), sn = math.sin(a);
    return ui.Offset(v.dx * cs - v.dy * sn, v.dx * sn + v.dy * cs);
  }

  ui.Offset pan;
  double scale;

  /// The farthest zoom-out: 1 = the whole frame just fits (the zoom lock in
  /// Settings - nothing beyond the frame's edge); lower lets you zoom out
  /// past it. Zooming in is free either way.
  double minScale;

  /// Settings, the zoom lock: the canvas's side edges stay on the screen's
  /// sides - it always fills the width, so it can't be zoomed out or moved
  /// sideways past its own left / right edge. Zooming in and moving up or
  /// down stay free.
  bool lockSides = false;
  StageCamera({this.pan = ui.Offset.zero, this.scale = 1, this.minScale = 0.1});

  /// Moves the view by `delta` (screen px), within the zoom lock.
  void panBy(ui.Offset delta) {
    pan += _turnVec(delta, -viewRotation);
    clampToLock();
  }

  /// Holds the view inside the zoom lock (no-op when it's off).
  void clampToLock() {
    if (!lockSides || viewRotation != 0 || frameSize.width <= 0 || viewportSize.width <= 0) return;
    final widthAt1 = frameSize.width * fitScale;
    final minS = viewportSize.width / widthAt1;
    if (scale < minS) {
      // keep the middle of the screen where it was.
      final c = ui.Offset(viewportSize.width / 2, viewportSize.height / 2);
      final f = screenToFrame(c);
      scale = minS;
      pan = c - _toFitted(f) * scale;
    }
    final left = fitOffset.dx * scale + pan.dx;
    final right = left + widthAt1 * scale;
    if (left > 0) pan = pan.translate(-left, 0);
    if (right < viewportSize.width) pan = pan.translate(viewportSize.width - right, 0);
  }

  /// the project's fixed frame size (stageSize.width/height) and the
  /// widget's CURRENT viewport size - both updated on every StageView
  /// build via `updateLayout`, unconditionally, no lock/guard of any
  /// kind. This is safe and cheap to redo every frame: unlike the old
  /// setSize()-from-layout bug, updating these two fields never touches
  /// the actual project/render resolution (CanvasRenderer's own
  /// _width/_height) - it only ever feeds the fit-transform below.
  ui.Size frameSize = ui.Size.zero;
  ui.Size viewportSize = ui.Size.zero;

  void updateLayout({required ui.Size frame, required ui.Size viewport}) {
    frameSize = frame;
    viewportSize = viewport;
  }

  /// BoxFit.contain scale factor mapping the fixed frame into the
  /// current viewport - 1.0 (no-op) until both sizes are known, so a
  /// not-yet-laid-out camera degrades to identity rather than NaN/Inf.
  double get fitScale {
    if (frameSize.width <= 0 || frameSize.height <= 0 || viewportSize.width <= 0 || viewportSize.height <= 0) return 1;
    return math.min(viewportSize.width / frameSize.width, viewportSize.height / frameSize.height);
  }

  /// the letterbox offset (top-left corner of the fitted frame within
  /// the viewport) at the current fitScale - centered, matching
  /// BoxFit.contain's own centering convention.
  ui.Offset get fitOffset {
    final s = fitScale;
    return ui.Offset((viewportSize.width - frameSize.width * s) / 2, (viewportSize.height - frameSize.height * s) / 2);
  }

  /// frame-space point -> its position in the letterboxed viewport,
  /// BEFORE the user's own pan/zoom - the fixed base every screen<->
  /// frame conversion below composes with.
  ui.Offset _toFitted(ui.Offset framePoint) => fitOffset + mirrored(framePoint) * fitScale;
  ui.Offset _fromFitted(ui.Offset fittedPoint) => mirrored((fittedPoint - fitOffset) / fitScale);

  /// Stage mirror (the Stage tab): the whole frame is shown flipped about
  /// its centre. Every frame<->screen conversion goes through
  /// `mirrored`, so handles and gestures line up with what's drawn;
  /// stage_painter applies the same flip to its canvas. Set every paint
  /// from AppState.
  bool mirrorX = false;
  bool mirrorY = false;

  /// A frame point flipped about the frame centre per mirrorX/mirrorY
  /// (its own inverse).
  ui.Offset mirrored(ui.Offset p) => ui.Offset(
      mirrorX ? frameSize.width - p.dx : p.dx, mirrorY ? frameSize.height - p.dy : p.dy);

  /// widget-local pointer position -> frame-space point. Deliberately
  /// NOT clamped to [0,stageSize.width]x[0,stageSize.height] - a handle
  /// (most commonly the pendulum pivot, whose offset can legitimately
  /// place it well outside the object's own bounds) has to stay
  /// reachable once panned/zoomed into view, and the underlying math
  /// (matFromTRS, affine composition) already has no problem with
  /// out-of-frame values - see the gesture spec addendum's "off-canvas
  /// interaction" section and drag_ops_test.dart's own finite-value
  /// regression coverage of that claim.
  ui.Offset screenToFrame(ui.Offset screenLocal) => _fromFitted((_turn(screenLocal, -viewRotation) - pan) / scale);

  ui.Offset frameToScreen(ui.Offset framePoint) => _turn(_toFitted(framePoint) * scale + pan, viewRotation);

  /// a fixed on-screen touch radius (e.g. 16 device px, matching JS's
  /// own hard-coded 16/8 hit-tolerance constants) converted into the
  /// equivalent FRAME-space radius at the current zoom AND the current
  /// fit scale - shrinks as you zoom in (or as the frame gets fitted
  /// larger into a bigger viewport), so the same finger width buys more
  /// precision against handles that are now more spread out in frame
  /// space. Per the gesture spec: "touch radius scales with the current
  /// zoom level, not fixed in screen pixels" - fitScale is just as much
  /// a part of "the current zoom level" as the user's own pinch scale.
  double radiusInFrameSpace(double baseScreenPx) => baseScreenPx / (scale * fitScale);

  /// applies ONE incremental pinch/pan step (called on every pointer-move
  /// while 2 fingers are down - see stage_gesture_controller.dart's own
  /// hand-rolled tracker, not Flutter's ScaleGestureRecognizer, whose
  /// `ScaleUpdateDetails.scale` is cumulative-since-gesture-start rather
  /// than incremental and would need different math entirely).
  /// `scaleDelta` is THIS step's distance ratio (newSpread/oldSpread,
  /// not since-gesture-start); `focalPoint` is the two-finger midpoint's
  /// position AFTER this step's move, `focalPointDelta` how far that
  /// midpoint moved during this step.
  ///
  /// Combines zoom-under-fingers and pan into one coherent update: the
  /// frame-space point that was under the midpoint BEFORE this step's
  /// move (focalPoint - focalPointDelta, at the OLD scale/pan) is placed
  /// under the midpoint's NEW position at the NEW scale - not simply
  /// re-anchored at the already-moved focalPoint, which would subtly
  /// mis-track the pinch center on every step it's compounded over.
  /// fitScale/fitOffset don't change mid-gesture (the viewport/frame
  /// size can't change while two fingers are actively pinching), so
  /// re-deriving `pan` only needs to account for the user's own scale.
  void applyScaleUpdate(
      {required double scaleDelta, required ui.Offset focalPointDelta, required ui.Offset focalPoint, double rotationDelta = 0}) {
    final oldFocal = focalPoint - focalPointDelta;
    final frameAtOldFocal = screenToFrame(oldFocal);
    // zooming in goes far (fine work on small things).
    scale = (scale * scaleDelta).clamp(minScale, 1000.0).toDouble();
    if (stageRotateEnabled && rotationDelta != 0) {
      rotation += rotationDelta;
    }
    pan = _turn(focalPoint, -viewRotation) - _toFitted(frameAtOldFocal) * scale;
    clampToLock();
  }

  void reset() {
    pan = ui.Offset.zero;
    scale = 1;
    rotation = 0;
  }
}
