import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

/// A 3D project's stage: a finger on a card moves it at its depth, off
/// the cards it turns the view; a tap picks the card.
void main() {
  setUpAll(registerBuiltinEffects);
  late AppState app;
  late StageCamera camera;
  late StageGestureController c;
  late Layer l;

  setUp(() {
    clearStateCaches();
    app = AppState();
    setStageSize(640, 400);
    app.frameWidth = 640;
    app.frameHeight = 400;
    app.renderer.setSize(640, 400);
    app.project.layers.clear();
    app.project.space3d = true;
    l = createLayer('rect')
      ..id = 'L'
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    l.transform.z.defaultValue = 200.0;
    app.project.layers.add(l);
    camera = StageCamera();
    c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
  });

  Offset screen(double x, double y) => camera.frameToScreen(Offset(x, y));

  test('a tap on the card picks it; off it, nothing', () {
    c.onPointerDown(PointerDownEvent(pointer: 1, position: screen(320, 200)));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: screen(320, 200)));
    expect(app.selection.selectedLayer, 'L');
    c.onPointerDown(PointerDownEvent(pointer: 2, position: screen(40, 40)));
    c.onPointerUp(PointerUpEvent(pointer: 2, position: screen(40, 40)));
    expect(app.selection.selectedLayer, isNull);
  });

  test('dragging the card moves it at its depth (farther: more than the finger); one undo', () {
    final start = screen(320, 200);
    c.onPointerDown(PointerDownEvent(pointer: 1, position: start));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: start + const Offset(30, 0)));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: start + const Offset(60, 0)));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: start + const Offset(60, 0)));
    final a = evaluateTrack(app.project, l.transform.anchor, 0.0, l) as List;
    final moved = ((a[0] as num) - 0.5) * 640;
    expect(moved, greaterThan(60), reason: 'behind the frame a finger moves it farther');
    expect((a[1] as num).toDouble(), closeTo(0.5, 1e-6));
    // the card is still under the finger.
    expect(app.card3dAt(380, 200)?.id, 'L');
    app.performUndo();
    final back = evaluateTrack(app.project, findLayer(app.project, 'L')!.transform.anchor, 0.0) as List;
    expect((back[0] as num).toDouble(), closeTo(0.5, 1e-6));
  });

  test('a drag off the cards turns the view; two fingers bring it nearer', () {
    c.onPointerDown(PointerDownEvent(pointer: 1, position: screen(40, 40)));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: screen(40, 40) + const Offset(50, 20)));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: screen(40, 40) + const Offset(100, 40)));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: screen(40, 40) + const Offset(100, 40)));
    expect(app.orbitYaw, isNot(0));
    expect(app.orbitPitch, greaterThan(0));
    final z0 = app.orbitZoom;
    c.onPointerDown(PointerDownEvent(pointer: 3, position: screen(200, 200)));
    c.onPointerDown(PointerDownEvent(pointer: 4, position: screen(300, 200)));
    c.onPointerMove(PointerMoveEvent(pointer: 4, position: screen(400, 200)));
    c.onPointerUp(PointerUpEvent(pointer: 4, position: screen(400, 200)));
    c.onPointerUp(PointerUpEvent(pointer: 3, position: screen(200, 200)));
    expect(app.orbitZoom, greaterThan(z0));
    app.resetOrbit();
    expect(app.orbitYaw, 0);
  });

  test('the camera set from the view, and the view taken back to it', () {
    app.orbitBy(30, 15);
    app.setCamera3HereFromView();
    final cam = app.project.camera!;
    app.resetOrbit();
    app.viewFromCamera3();
    final v = app.orbitCamera();
    for (var i = 0; i < 3; i++) {
      expect(v.eye[i], closeTo(cam.eye[i], 1e-6));
      expect(v.target[i], closeTo(cam.target[i], 1e-6));
    }
    app.performUndo();
    expect(app.project.camera, isNull);
  });
}
