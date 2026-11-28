import 'dart:io';
import 'dart:math' as math;
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

  test('a stroke: straight pieces through the points, even width; smoothing made again after', () {
    setStageSize(480, 480);
    final drawn = [for (var i = 0; i <= 100; i++) [100.0 + i * 2, 200.0 + 30 * (i / 100) * (i / 100) + (i.isEven ? 3 : -3)]];
    final l = brushStrokeLayer(drawn, id: 'b', color: '#ff0000', width: 10, smooth: 0);
    final nodes = l.content.lineNodes!;
    expect(nodes.every((n) => n.kind == 'line' && n.w == null), isTrue, reason: 'plain pieces, one width: a light stroke');
    expect(lineNeedsShapedStroke(l.content), isFalse);
    expect([l.content.shape, l.color, l.content.lineWidth], ['line', '#ff0000', 10]);
    final a = l.transform.anchor.defaultValue as List;
    expect(a[0] * 480, closeTo(200, 1));
    final rough = nodes.length;
    // smoother afterwards: the wobble gone, fewer points.
    l.content.brushSmooth = 1;
    rebuildBrushLine(l.content);
    expect(l.content.lineNodes!.length, lessThan(rough));
    final back = layerFromJson(layerToJson(l));
    expect([back.content.brushRaw!.length, back.content.brushSmooth], [l.content.brushRaw!.length, 1]);
    // a dot (no move) still makes a mark.
    final dot = brushStrokeLayer([[50.0, 50.0]], id: 'd', color: '#fff', width: 6);
    expect(dot.content.lineNodes!.length, 2);
  });

  test('Line drawn with a finger: smooth curves, at most 40 points', () {
    setStageSize(480, 480);
    final drawn = [for (var i = 0; i <= 400; i++) [40.0 + i, 240.0 + 80 * math.sin(i / 25)]];
    final l = freehandLineLayer(drawn, id: 'f');
    expect(l.content.lineNodes!.length, lessThanOrEqualTo(40));
    expect(l.content.lineNodes!.skip(1).every((n) => n.kind == 'bezier'), isTrue);
    expect(l.content.brushRaw, isNull, reason: 'a line of its own, not a brush stroke');
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
    expect([l.content.shape, l.folder, app.selection.selectedLayer], ['line', null, l.id]);
    app.performUndo();
    expect(app.project.layers, isEmpty);
  });

  test('placing a line: a drag draws it with the finger; a tap still puts a point', () {
    setStageSize(480, 480);
    final app = AppState()..setFrameSize(480, 480);
    app.project.layers.clear();
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    app.startPlacing('line');
    final pts = [for (var i = 0; i <= 30; i++) camera.frameToScreen(Offset(60.0 + i * 10, 240.0 + 40 * math.sin(i / 5)))];
    c.onPointerDown(PointerDownEvent(pointer: 1, position: pts.first));
    for (final p in pts.skip(1)) {
      c.onPointerMove(PointerMoveEvent(pointer: 1, position: p));
    }
    c.onPointerUp(PointerUpEvent(pointer: 1, position: pts.last));
    final l = app.project.layers.single;
    expect([l.content.shape, app.pendingPlaceShape], ['line', null]);
    expect(l.content.lineNodes!.length, inInclusiveRange(3, 40));
    // a tap: the first point of a line put by taps.
    app.startPlacing('line');
    final t = camera.frameToScreen(const Offset(100, 100));
    c.onPointerDown(PointerDownEvent(pointer: 2, position: t));
    c.onPointerUp(PointerUpEvent(pointer: 2, position: t));
    expect(app.pendingLinePoint, isNotNull);
    expect(app.project.layers.length, 1);
  });

  test('old heavy strokes (curves with thin ends) are made light on opening', () {
    setStageSize(480, 480);
    final old = createLayer('line')
      ..folder = 'Brush'
      ..content.lineNodes = [
        LineNode(-50, 0)..w = 1,
        LineNode(0, 20, kind: 'bezier', hIn: [-10, 0], hOut: [10, 0])..w = 8,
        LineNode(50, 0, kind: 'bezier', hIn: [-10, 0])..w = 1,
      ];
    final keep = createLayer('line')..folder = 'Mine';
    final p = Project(layers: [old, keep]);
    expect(lightenOldBrushStrokes(p), 1);
    expect(old.content.lineNodes!.every((n) => n.w == null && n.kind == 'line'), isTrue);
    expect(old.content.brushRaw, isNotNull);
    expect(keep.content.brushRaw, isNull);
  });

  test('a second finger (zooming) drops the stroke just begun: nothing drawn', () {
    setStageSize(480, 480);
    final app = AppState()..setFrameSize(480, 480);
    app.project.layers.clear();
    app.setDrawTool('brush');
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final a = camera.frameToScreen(const Offset(100, 100)), b = camera.frameToScreen(const Offset(300, 300));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: a));
    expect(app.brushStroke, isNotNull);
    c.onPointerDown(PointerDownEvent(pointer: 2, position: b));
    expect(app.brushStroke, isNull, reason: 'it was a pinch');
    c.onPointerMove(PointerMoveEvent(pointer: 2, position: b + const Offset(30, 30)));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: a));
    c.onPointerUp(PointerUpEvent(pointer: 2, position: b + const Offset(30, 30)));
    expect(app.project.layers, isEmpty);
    expect(app.brushStroke, isNull);
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
    expect(find.byKey(const ValueKey('brush-smooth')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-taper')), findsNothing);
    // the picked layer's opacity; the old edge fade is gone.
    expect(find.byKey(const ValueKey('draw-edge-fade')), findsNothing);
    expect(find.byKey(const ValueKey('draw-opacity')), findsOneWidget);
    expect(find.byKey(const ValueKey('brush-soft')), findsOneWidget);
  });

  test('a stroke draws where it was drawn', () async {
    setStageSize(200, 200);
    final drawn = [for (var i = 0; i <= 60; i++) [40.0 + i * 2, 100.0 + 40 * ((i - 30) / 30) * ((i - 30) / 30) - 40]];
    final l = brushStrokeLayer(drawn, id: 'b', color: '#ff0000', width: 16, smooth: 0.6);
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

  test('soft edges: the stroke melts away at its edge (as a soft brush)', () async {
    setStageSize(200, 200);
    final drawn = [for (var i = 0; i <= 60; i++) [40.0 + i * 2, 100.0]];
    final l = brushStrokeLayer(drawn, id: 's', color: '#000000', width: 30, smooth: 0.3, soft: 1);
    final r = CanvasRenderer()..setSize(200, 200);
    r.backgroundColor = null;
    clearStateCaches();
    r.renderFrame(Project(layers: [l]), 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    const dir = '/tmp/claude-0/-home-user-shiny/46cb87ef-9190-5dfc-8660-82b98c9b2e24/scratchpad/shots';
    if (Directory(dir).existsSync()) {
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/soft.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
    int alpha(int x, int y) => b.getUint8((y * 200 + x) * 4 + 3);
    expect(alpha(100, 100), greaterThan(230), reason: 'solid in the middle');
    final edge = alpha(100, 115);
    expect(edge, inInclusiveRange(40, 200), reason: 'half-way at its edge: soft, not cut');
    expect(alpha(100, 125), greaterThan(0), reason: 'melting on past it');
    expect(alpha(100, 125), lessThan(edge));
    expect(layerFromJson(layerToJson(l)).content.brushSoft, 1);
  });
}
