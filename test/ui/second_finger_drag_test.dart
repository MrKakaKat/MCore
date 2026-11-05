import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

void main() {
  test('a second finger touching and lifting during a move does not freeze it', () {
    setStageSize(400, 400);
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final tb = getTransformBoxHandles(app.project, layer, 0);
    final grip = camera.frameToScreen(Offset(tb.screen['moveCorner']![0], tb.screen['moveCorner']![1]));

    c.onPointerDown(PointerDownEvent(pointer: 1, position: grip));
    expect(c.anyDragActive, isTrue);
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: grip + const Offset(10, 0)));
    final mid = (evaluateTrack(app.project, layer.transform.anchor, 0) as List<double>)[0];
    c.onPointerDown(PointerDownEvent(pointer: 2, position: grip + const Offset(100, 100)));
    c.onPointerMove(PointerMoveEvent(pointer: 2, position: grip + const Offset(120, 100)));
    c.onPointerUp(PointerUpEvent(pointer: 2, position: grip + const Offset(120, 100)));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: grip + const Offset(50, 0)));
    final after = (evaluateTrack(app.project, layer.transform.anchor, 0) as List<double>)[0];
    expect(after, greaterThan(mid + 0.05), reason: 'the first finger still moves it');
    c.onPointerUp(PointerUpEvent(pointer: 1, position: grip + const Offset(50, 0)));
    expect(c.anyDragActive, isFalse);
  });
}
