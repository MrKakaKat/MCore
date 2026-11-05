import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';

void main() {
  late AppState app;
  late StageCamera camera;
  late StageGestureController c;
  late Layer layer;

  setUp(() {
    app = AppState();
    app.project.layers.clear();
    app.addLayer('line');
    layer = app.project.layers.single;
    camera = StageCamera();
    c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
  });

  Offset screen(String key) {
    final h = lineHandlesFrame(app.project, layer, 0, editing: lineEditing, selected: lineSelectedPoint)[key]!;
    return camera.frameToScreen(Offset(h[0], h[1]));
  }

  test("a line's end point drags; the line itself moves it", () {
    expect(app.selection.selectedLayer, layer.id);
    final before = [...layer.content.lineNodes!.last.x.toString().split('')];
    final start = screen('n1');
    c.onPointerDown(PointerDownEvent(pointer: 1, position: start));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: start + const Offset(30, 0)));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: start + const Offset(30, 0)));
    expect(layer.content.lineNodes!.last.x.toString().split(''), isNot(before), reason: 'the end point moved');

  });

  test('the stage paints a selected line\'s points (filled, curved and looped too) without failing', () async {
    final c2 = layer.content;
    setLineSideKind(c2, 0, 'after', 'bezier');
    c2.lineNodes!.add(LineNode(10, 60));
    closeLine(c2);
    for (final sel in [0, 1, 2, 5]) {
      lineSelectedPoint = sel;
      final rec = ui.PictureRecorder();
      paintStage(
        canvas: ui.Canvas(rec),
        size: const ui.Size(400, 400),
        contentPicture: null,
        frameWidth: 480,
        frameHeight: 480,
        project: app.project,
        selectedLayer: layer,
        globalFrame: 0,
        camera: camera,
        activeDrag: null,
      );
      rec.endRecording();
    }
    lineSelectedPoint = 0;
  });

  test('adding by tapping: each tap lengthens the line, Done ends it', () {
    lineSelectedPoint = 1;
    app.setLineTapAdd(true);
    final end = screen('n1');
    final tap = end + const Offset(40, 30);
    c.onPointerDown(PointerDownEvent(pointer: 7, position: tap));
    c.onPointerUp(PointerUpEvent(pointer: 7, position: tap));
    expect(layer.content.lineNodes, hasLength(3));
    expect(lineSelectedPoint, 2);
    // the new point sits where the finger was.
    final p = screen('n2');
    expect((p - tap).distance, lessThan(1e-6));
    app.setLineTapAdd(false);
    expect(app.lineTapAdd, isFalse);
  });
}
