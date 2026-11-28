import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/drawing/drawing_view.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

/// Drawing, the brush: strokes on the stage become vector lines.
void main() {
  setUpAll(registerBuiltinEffects);

  test('a stroke is thinned out, smooth, its ends thin; a vector line', () {
    setStageSize(480, 480);
    final drawn = [for (var i = 0; i <= 100; i++) [100.0 + i * 2, 200.0 + 30 * (i / 100) * (i / 100)]];
    final l = brushStrokeLayer(drawn, id: 'b', color: '#ff0000', width: 10, smooth: 0.6, taper: 0.5);
    final nodes = l.content.lineNodes!;
    expect(nodes.length, lessThan(20), reason: 'points thinned out');
    expect(nodes.length, greaterThanOrEqualTo(2));
    expect(nodes.skip(1).every((n) => n.kind == 'bezier'), isTrue, reason: 'smooth curves');
    expect(nodes.first.w! < 3 && nodes.last.w! < 3, isTrue, reason: 'thin ends');
    expect(nodes[nodes.length ~/ 2].w, closeTo(10, 1e-6));
    expect([l.content.shape, l.color, l.content.lineWidth], ['line', '#ff0000', 10]);
    // drawn where it was: its middle where the stroke's box is.
    final a = l.transform.anchor.defaultValue as List;
    expect(a[0] * 480, closeTo(200, 1));
    // a dot (no move) still makes a mark.
    final dot = brushStrokeLayer([[50.0, 50.0]], id: 'd', color: '#fff', width: 6);
    expect(dot.content.lineNodes!.length, 2);
  });

  test('on the stage: the finger draws; a stroke is one layer, one undo step', () {
    setStageSize(480, 480);
    final app = AppState()..setFrameSize(480, 480);
    app.project.layers.clear();
    app.setDrawTool('brush');
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final pts = [for (var i = 0; i <= 20; i++) camera.frameToScreen(Offset(100.0 + i * 10, 240.0 + (i % 5) * 4))];
    c.onPointerDown(PointerDownEvent(pointer: 1, position: pts.first));
    for (final p in pts.skip(1)) {
      c.onPointerMove(PointerMoveEvent(pointer: 1, position: p));
    }
    expect(app.brushStroke!.length, greaterThan(10));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: pts.last));
    expect(app.brushStroke, isNull);
    final l = app.project.layers.single;
    expect([l.content.shape, l.folder, app.selection.selectedLayer], ['line', 'Brush', l.id]);
    app.performUndo();
    expect(app.project.layers, isEmpty);
  });

  testWidgets('the Brush switch and its settings in Drawing', (tester) async {
    final app = AppState();
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DrawingView(app: app))));
    await tester.tap(find.byKey(const ValueKey('draw-brush')));
    await tester.pump();
    expect(app.drawTool, 'brush');
    expect(find.byKey(const ValueKey('brush-taper')), findsOneWidget);
  });

  test('a stroke draws where it was drawn', () async {
    setStageSize(200, 200);
    final drawn = [for (var i = 0; i <= 60; i++) [40.0 + i * 2, 100.0 + 40 * ((i - 30) / 30) * ((i - 30) / 30) - 40]];
    final l = brushStrokeLayer(drawn, id: 'b', color: '#ff0000', width: 16, smooth: 0.6, taper: 0.8);
    final r = CanvasRenderer()..setSize(200, 200);
    r.backgroundColor = null;
    clearStateCaches();
    r.renderFrame(Project(layers: [l]), 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    const dir = '/tmp/claude-0/-home-user-shiny/46cb87ef-9190-5dfc-8660-82b98c9b2e24/scratchpad/shots';
    if (Directory(dir).existsSync()) {
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/brush.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
    int alpha(int x, int y) => b.getUint8((y * 200 + x) * 4 + 3);
    expect(alpha(100, 60), greaterThan(200), reason: 'the bottom of the curve (i = 30): x 100, y 60');
    expect(alpha(100, 90), 0);
  });
}
