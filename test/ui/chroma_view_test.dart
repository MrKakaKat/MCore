import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/chroma/chroma_view.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';

/// Chroma tab + its stage tools. The image layers here have no source
/// data, so nothing is decoded (see canvas_renderer.dart on this
/// sandbox's one-decode-per-file limit) - the pixel math itself is
/// covered by movement_core's chroma_key_test.dart.
void main() {
  late AppState app;
  late Layer image;

  setUp(() {
    chromaTool = 'none';
    ParamEditor.resetModes(expanded: true);
    app = AppState();
    image = Layer(
      id: 'L_img',
      name: 'img',
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'image', offset: [0, 0], size: [200, 100]),
    );
    app.project.layers.add(image);
  });
  tearDown(() => chromaTool = 'none');

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 900, child: ChromaView(app: app)))));
    await tester.pumpAndSettle();
  }

  testWidgets('non-image layers get an explanation', (tester) async {
    await pump(tester);
    expect(find.textContaining('images, videos and merged shapes'), findsOneWidget);
  });

  testWidgets('enable, strength and the eyedropper; no region tool any more', (tester) async {
    app.selectLayer(image.id);
    await pump(tester);

    await tester.tap(find.text('Chroma key'));
    await tester.pump();
    expect(findLayer(app.project, image.id)!.chromaKey.enabled, isTrue);

    await tester.drag(find.byType(Slider).first, const Offset(80, 0));
    await tester.pump();
    expect(findLayer(app.project, image.id)!.chromaKey.strength, greaterThan(0.4));

    await tester.tap(find.text('Pick on stage'));
    await tester.pump();
    expect(chromaTool, 'pick');

    expect(find.text('Inside region'), findsNothing, reason: 'removed');
    // leaving the tab switches the stage tool off.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(chromaTool, 'none');
  });

  test('eyedropper: press and slide shows the loupe finger position, lifting ends the pick', () {
    setStageSize(640, 400);
    app.renderer.setSize(640, 400);
    app.selectLayer(image.id);
    chromaTool = 'pick';
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final a = camera.frameToScreen(const Offset(300, 200)), b = camera.frameToScreen(const Offset(330, 210));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: a));
    expect(c.activeDrag?.op, isA<ChromaPickDragOp>());
    expect(c.chromaPickScreen, a);
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: b));
    expect(c.chromaPickScreen, b);
    expect((c.activeDrag!.op as ChromaPickDragOp).framePoint![0], closeTo(330, 1e-6));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: b));
    expect(c.activeDrag, isNull);
    expect(c.chromaPickScreen, isNull);
  });

  test('the loupe magnifies the source above the finger with a ring in the picked colour', () async {
    // 20x20 source: left half red, right half blue.
    final rec = ui.PictureRecorder();
    ui.Canvas(rec)
      ..drawRect(const Rect.fromLTWH(0, 0, 10, 20), Paint()..color = const Color(0xFFFF0000))
      ..drawRect(const Rect.fromLTWH(10, 0, 10, 20), Paint()..color = const Color(0xFF0000FF));
    final src = await rec.endRecording().toImage(20, 20);
    final out = ui.PictureRecorder();
    paintChromaLoupe(
        ui.Canvas(out),
        ChromaLoupe(finger: const Offset(140, 180), image: src, center: const Offset(10, 10), color: const Color(0xFF00FF00)));
    final img = await out.endRecording().toImage(200, 200);
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    List<int> at(int x, int y) => [for (var i = 0; i < 3; i++) px.getUint8((y * 200 + x) * 4 + i)];
    // loupe centre is 88 px above the finger: (140, 92).
    expect(at(120, 92), [255, 0, 0], reason: 'left of centre: the red half');
    expect(at(160, 92), [0, 0, 255], reason: 'right of centre: the blue half');
    expect(at(140, 92 - 41), [0, 255, 0], reason: 'the ring shows the picked colour');
    expect(px.getUint8((185 * 200 + 140) * 4 + 3), 0, reason: 'nothing under the finger');
    expect(at(14, 69), [0, 255, 0], reason: 'the colour also in the top-left corner');
  });
}
