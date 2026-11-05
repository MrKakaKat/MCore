import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';

/// Real device bug this guards against: rotating the phone changed the
/// canvas's own coordinate system, not just how it's displayed - the
/// same anchor value produced a DIFFERENT physical on-screen position
/// in portrait vs landscape. Root cause was CanvasRenderer's frame size
/// getting set from the WIDGET's current layout (stage_view.dart), so
/// a rotation silently redefined the project's own proportions. The
/// fix makes the frame size a fixed constant (see AppState.frameWidth/
/// frameHeight) and gives StageCamera a proper BoxFit.contain fit layer
/// (fitScale/fitOffset) that's recomputed fresh from whatever viewport
/// is current, WITHOUT ever touching the frame's own size. This test
/// proves that claim directly: the same frame-space point must map to
/// the same PROPORTIONAL position within the letterboxed frame
/// regardless of the viewport's own shape.
void main() {
  const frame = ui.Size(640, 400); // matches AppState.frameWidth/frameHeight

  test('the frame\'s own center always lands at the center of its own letterboxed rect, in any viewport shape', () {
    for (final viewport in [
      const ui.Size(360, 800), // portrait phone
      const ui.Size(800, 360), // landscape phone
      const ui.Size(1200, 900), // wide tablet
      const ui.Size(400, 400), // square
    ]) {
      final camera = StageCamera();
      camera.updateLayout(frame: frame, viewport: viewport);

      const frameCenter = ui.Offset(320, 200); // frame's own center, in frame units
      final screenPos = camera.frameToScreen(frameCenter);

      // the letterboxed frame rect's own center, computed independently
      // via fitScale/fitOffset directly (not reusing frameToScreen's
      // own internals, so this doesn't just check the function agrees
      // with itself).
      final expectedCenter = ui.Offset(
        camera.fitOffset.dx + frame.width * camera.fitScale / 2,
        camera.fitOffset.dy + frame.height * camera.fitScale / 2,
      );

      expect(screenPos.dx, closeTo(expectedCenter.dx, 1e-9), reason: 'viewport $viewport');
      expect(screenPos.dy, closeTo(expectedCenter.dy, 1e-9), reason: 'viewport $viewport');
    }
  });

  test('a fixed anchor fraction maps to the same PROPORTIONAL position of the letterboxed frame across very differently shaped viewports', () {
    // simulates a layer whose anchor puts it at 70% across, 30% down the frame
    // - exactly the kind of value compared between a portrait and a landscape
    // screenshot.
    const anchorFrame = ui.Offset(0.7 * 640, 0.3 * 400);

    final portrait = StageCamera()..updateLayout(frame: frame, viewport: const ui.Size(360, 800));
    final landscape = StageCamera()..updateLayout(frame: frame, viewport: const ui.Size(800, 360));

    final portraitScreen = portrait.frameToScreen(anchorFrame);
    final landscapeScreen = landscape.frameToScreen(anchorFrame);

    // convert each screen position back into "fraction of the
    // letterboxed frame rect" terms - these must match exactly even
    // though the raw screen pixels differ wildly between the two
    // viewport shapes, and even though each camera's fitScale/fitOffset
    // are themselves totally different numbers.
    double fractionX(StageCamera cam, ui.Offset screen) => (screen.dx - cam.fitOffset.dx) / (frame.width * cam.fitScale);
    double fractionY(StageCamera cam, ui.Offset screen) => (screen.dy - cam.fitOffset.dy) / (frame.height * cam.fitScale);

    expect(fractionX(portrait, portraitScreen), closeTo(0.7, 1e-9));
    expect(fractionY(portrait, portraitScreen), closeTo(0.3, 1e-9));
    expect(fractionX(landscape, landscapeScreen), closeTo(0.7, 1e-9));
    expect(fractionY(landscape, landscapeScreen), closeTo(0.3, 1e-9));

    // and round-tripping screenToFrame recovers the exact same
    // frame-space point in both viewport shapes.
    expect(portrait.screenToFrame(portraitScreen).dx, closeTo(anchorFrame.dx, 1e-9));
    expect(portrait.screenToFrame(portraitScreen).dy, closeTo(anchorFrame.dy, 1e-9));
    expect(landscape.screenToFrame(landscapeScreen).dx, closeTo(anchorFrame.dx, 1e-9));
    expect(landscape.screenToFrame(landscapeScreen).dy, closeTo(anchorFrame.dy, 1e-9));
  });

  test('user pan/zoom composes on top of the fit, and still round-trips exactly, once a real viewport is set', () {
    final camera = StageCamera()
      ..updateLayout(frame: frame, viewport: const ui.Size(500, 900))
      ..pan = const ui.Offset(40, -15)
      ..scale = 1.8;

    const p = ui.Offset(123.4, 87.6);
    final screen = camera.frameToScreen(p);
    final back = camera.screenToFrame(screen);
    expect(back.dx, closeTo(p.dx, 1e-9));
    expect(back.dy, closeTo(p.dy, 1e-9));
  });

  test('applyScaleUpdate with focalPointDelta=zero at the viewport\'s own center produces a CENTERED zoom - matches stage_view.dart\'s own initial-zoom mechanism', () {
    // (by default, the frame extends a bit past the viewport's own borders) -
    // stage_view.dart applies exactly this call, once, on first layout, to get
    // that starting state. Reproduced directly here (not through the widget)
    // since StageCamera's own default scale (1.0) has to stay untouched for
    // the other tests in this file, which is exactly why stage_view.dart
    // doesn't just construct StageCamera(scale: 1.15) instead.
    final camera = StageCamera();
    const viewport = ui.Size(600, 400);
    camera.updateLayout(frame: frame, viewport: viewport);
    const center = ui.Offset(300, 200); // viewport.width/2, viewport.height/2

    camera.applyScaleUpdate(scaleDelta: 1.15, focalPointDelta: ui.Offset.zero, focalPoint: center);

    expect(camera.scale, closeTo(1.15, 1e-9));
    // the frame's own center must STILL land exactly on the viewport's
    // own center - a scale applied without this centering pan would
    // instead shift everything away from the screen origin (toward the
    // bottom-right), not just crop the edges symmetrically.
    const frameCenter = ui.Offset(320, 200);
    final screenPos = camera.frameToScreen(frameCenter);
    expect(screenPos.dx, closeTo(center.dx, 1e-9));
    expect(screenPos.dy, closeTo(center.dy, 1e-9));

    // and the frame's own CORNERS now fall OUTSIDE the viewport bounds - (the
    // frame extends past the borders), not just a plain re-fit.
    final topLeft = camera.frameToScreen(ui.Offset.zero);
    final bottomRight = camera.frameToScreen(const ui.Offset(640, 400));
    expect(topLeft.dx, lessThan(0));
    expect(topLeft.dy, lessThan(0));
    expect(bottomRight.dx, greaterThan(viewport.width));
    expect(bottomRight.dy, greaterThan(viewport.height));
  });

  test('with no layout ever set (frameSize/viewportSize still zero), the camera behaves exactly as pure identity pan/zoom - matches every pre-existing test that never calls updateLayout', () {
    final camera = StageCamera()
      ..pan = const ui.Offset(10, 20)
      ..scale = 2.0;
    expect(camera.fitScale, equals(1));
    expect(camera.fitOffset, equals(ui.Offset.zero));
    const p = ui.Offset(5, 6);
    expect(camera.frameToScreen(p), equals(p * 2.0 + const ui.Offset(10, 20)));
  });
}
