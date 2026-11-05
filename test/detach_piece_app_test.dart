import 'dart:ui' as ui;


import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/crop/crop_view.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

/// Detach a piece: rendering, the stage rectangle tool, the Crop tab.
void main() {
  late AppState app;
  late Layer l;
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    pieceRectTool = false;
    ParamEditor.resetModes(expanded: true);
    app = AppState();
    app.setFrameSize(200, 200);
    app.project.layers.clear();
    l = createLayer('rect')
      ..id = 'sq'
      ..name = 'Rect 1'
      ..color = '#ffffff'
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(l);
    app.selectLayer('sq');
  });
  tearDown(() => pieceRectTool = false);

  Future<int Function(int, int)> alphaOf() async {
    app.renderer.renderFrame(app.project, 0);
    final img = await app.renderer.captureFrame();
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return (x, y) => px.getUint8((y * 200 + x) * 4 + 3);
  }

  test('after detaching nothing changes on screen; moving the piece leaves its hole in the original', () async {
    final piece = app.detachPieceRect('sq', [40, 40], [100, 160])!;
    expect(app.selection.selectedLayer, piece.id);
    var a = await alphaOf();
    expect([a(70, 100), a(130, 100)], [255, 255], reason: 'same picture as before');
    piece.transform.anchor.defaultValue = [0.5, 0.1]; // move the piece up out of the way
    a = await alphaOf();
    expect(a(70, 100), 0, reason: 'the original no longer has the left half');
    expect(a(130, 100), 255, reason: 'it keeps the right half');
    // the piece's origin is its own centre (recenter detached pieces): at
    // (0.5, 0.1) it is centred on (100, 20).
    expect(a(100, 20), 255, reason: 'the piece, moved');
    expect(a(70, 20), 0, reason: 'centred on its own middle, not the whole square\'s');
    app.performUndo();
    expect(app.project.layers.length, 1);
    expect(findLayer(app.project, 'sq')!.pieceClips, isEmpty);
  });

  test('the contour is cut too: tapping selects the part under the finger; outlines run along the cut', () async {
    setStageSize(200, 200);
    final piece = app.detachPieceRect('sq', [40, 40], [100, 160])!;
    app.selectLayer(null);
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    void tap(double x, double y) {
      final at = camera.frameToScreen(Offset(x, y));
      c.onPointerDown(PointerDownEvent(pointer: 7, position: at));
      c.onPointerUp(PointerUpEvent(pointer: 7, position: at));
    }

    tap(130, 100);
    expect(app.selection.selectedLayer, 'sq', reason: 'the piece (on top) no longer covers the half it left behind');
    app.selectLayer(null);
    tap(70, 100);
    expect(app.selection.selectedLayer, piece.id);

    l.renderMode = 'outline';
    piece.renderMode = 'outline';
    final a = await alphaOf();
    expect(a(100, 100), greaterThan(0), reason: 'an outline along the cut');
    expect(a(75, 100), 0, reason: 'inside stays empty');
    expect(a(100, 45), 0, reason: 'the cut line is drawn only across the shape');
    expect(a(50, 100), greaterThan(0), reason: 'the original outline is still there');
  });

  test('the stage rectangle tool: drag, lift, detached', () {
    setStageSize(200, 200);
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    app.togglePieceRectTool();
    final a = camera.frameToScreen(const Offset(60, 60)), b = camera.frameToScreen(const Offset(100, 100));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: a));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: b));
    expect(app.project.layers.length, 1, reason: 'nothing until the finger lifts');
    c.onPointerUp(PointerUpEvent(pointer: 1, position: b));
    expect(app.project.layers.length, 2);
    expect(pieceRectTool, isFalse, reason: 'one cut per use');
  });

  testWidgets('Crop tab: detach by the shape of another layer', (tester) async {
    final circle = createLayer('circle')
      ..id = 'c'
      ..name = 'Circle 1'
      ..content.offset = [0, 0]
      ..content.size = [40, 40]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(circle);
    app.selectLayer('sq');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 600, child: CropView(app: app)))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('piece-by-layer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('piece-by-layer')));
    await tester.pumpAndSettle();
    expect(app.project.layers.map((e) => e.name), ['Rect 1', 'Rect 1 part 1', 'Circle 1']);
    final piece = app.project.layers[1];
    expect(insidePieceClips(piece, [0, 0]), isTrue);
    expect(insidePieceClips(piece, [40, 0]), isFalse);
  });
}
