import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:flutter/material.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/effects/effects_view.dart';

/// The Outline effect: a stroke along the layer's silhouette contour.
void main() {
  setUpAll(registerBuiltinEffects);

  List<int> at(ByteData px, int x, int y) => [for (var c = 0; c < 4; c++) px.getUint8((y * 100 + x) * 4 + c)];

  testWidgets('a transparent PNG: just outside its opaque part takes the stroke colour, far away stays clear',
      (tester) async {
    late List<int> png;
    await tester.runAsync(() async {
      // 20x20: a 10x10 opaque blue square in the middle, the rest clear.
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(5, 5, 10, 10), ui.Paint()..color = const ui.Color(0xFF0000FF));
      final img = await rec.endRecording().toImage(20, 20);
      png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    });
    final app = AppState()..setFrameSize(100, 100);
    app.project.layers.clear();
    app.renderer.backgroundColor = null;
    app.addImageLayer(imageSourceType: 'embedded', imageData: base64Encode(png), naturalWidth: 20, naturalHeight: 20);
    final image = app.project.layers.last
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final fx = createEffectInstance('outline', 'o1', image)..params['color'] = '#ff0000';
    (fx.params['width'] as Track).defaultValue = 6.0;
    image.effectStack.add(fx);

    late ByteData px;
    // decode, read the pixels back, extract (in an isolate), redraw - the
    // image work completes between frames, so pump while waiting.
    for (var i = 0; i < 300 && !(app.renderer.contours.computed > 0 && i > 5); i++) {
      await tester.runAsync(() async {
        app.renderer.renderFrame(app.project, 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
    }
    await tester.runAsync(() async {
      app.renderer.renderFrame(app.project, 0);
      final out = await app.renderer.captureFrame();
      px = (await out.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    });
    // the square covers 25..75 of the 100px frame.
    expect(at(px, 50, 50)[2], greaterThan(200), reason: 'the picture itself');
    expect(at(px, 50, 21), [255, 0, 0, 255], reason: 'just above its top edge: the stroke');
    expect(at(px, 21, 50), [255, 0, 0, 255], reason: 'just left of it');
    expect(at(px, 50, 5)[3], 0, reason: 'far away: still clear');
    expect(app.renderer.contours.stats().isolateLastMs, isNotNull, reason: 'the HUD shows the isolate time');
  });

  test('on a shape the outline is its exact geometry (no raster path)', () {
    final app = AppState();
    final rect = createLayer('rect')..content.size = [40, 20];
    final c = app.renderer.layerContour(app.project..layers.add(rect), rect, 0, const ContourParams());
    expect(c, isNotNull);
    expect(c!.rings.single.points, hasLength(4));
    expect(ringSignedArea(c.rings.single.points).abs(), closeTo(800, 1e-6));
  });

  test('cache: the same key twice is one extraction', () {
    final app = AppState();
    final circle = createLayer('circle');
    app.project.layers.add(circle);
    final before = app.renderer.contours.computed;
    app.renderer.layerContour(app.project, circle, 0, const ContourParams(offset: 3));
    app.renderer.layerContour(app.project, circle, 0, const ContourParams(offset: 3));
    expect(app.renderer.contours.computed - before, 1);
  });

  test('Outline moves no points: a shape with it stays off the warped-texture path', () {
    final rect = createLayer('rect');
    rect.effectStack.add(createEffectInstance('outline', 'o', rect));
    expect(rect.effectStack.any(isDeformingEffect), isFalse);
  });

  testWidgets('the Outline card (Effects tab): its colour, and Show contour turns the debug view on', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.effectStack.add(createEffectInstance('outline', 'o1', layer));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EffectsView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fx-type-Contour')), findsOneWidget, reason: 'its own type group');
    expect(find.byKey(const ValueKey('fx-color-o1-color')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('show-contour-${layer.id}')));
    await tester.pump();
    expect(app.contourDebugLayers, contains(layer.id));
  });

  testWidgets('the Contour tab: the contour view and Physics', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EffectsView(app: app, contour: true))));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('contour-show-${layer.id}')), findsOneWidget);
    expect(find.byKey(const ValueKey('physics-section')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('physics-collide')));
    await tester.pumpAndSettle();
    expect(layer.physics.collide, isTrue);
    expect(find.byKey(const ValueKey('physics-role')), findsOneWidget);
  });


  testWidgets('a picture on a green background with chroma key: the outline wraps the keyed subject, not the frame',
      (tester) async {
    late List<int> png;
    await tester.runAsync(() async {
      // 20x20 all green, a 10x10 blue square in the middle.
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 20, 20), ui.Paint()..color = const ui.Color(0xFF00FF00));
      canvas.drawRect(const ui.Rect.fromLTWH(5, 5, 10, 10), ui.Paint()..color = const ui.Color(0xFF0000FF));
      final img = await rec.endRecording().toImage(20, 20);
      png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    });
    final app = AppState()..setFrameSize(100, 100);
    app.project.layers.clear();
    app.renderer.backgroundColor = null;
    app.addImageLayer(imageSourceType: 'embedded', imageData: base64Encode(png), naturalWidth: 20, naturalHeight: 20);
    final image = app.project.layers.last
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    image.chromaKey
      ..enabled = true
      ..color = '#00ff00';
    final fx = createEffectInstance('outline', 'o1', image)..params['color'] = '#ff0000';
    (fx.params['width'] as Track).defaultValue = 6.0;
    image.effectStack.add(fx);

    late ByteData px;
    // decode, key, read the keyed pixels, extract, redraw - the image
    // work completes between frames, so pump while waiting.
    for (var i = 0; i < 300 && !(app.renderer.contours.computed > 0 && i > 5); i++) {
      await tester.runAsync(() async {
        app.renderer.renderFrame(app.project, 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
    }
    await tester.runAsync(() async {
      app.renderer.renderFrame(app.project, 0);
      final out = await app.renderer.captureFrame();
      px = (await out.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    });
    expect(at(px, 50, 50)[2], greaterThan(200), reason: 'the blue subject');
    expect(at(px, 50, 21), [255, 0, 0, 255], reason: 'just outside the keyed subject: the stroke');
    expect(at(px, 50, 5)[3], 0, reason: 'the keyed-out green stays clear - no stroke around the frame');
    expect(at(px, 2, 2)[3], 0);
  });

  test('crop: the contour runs along the cut', () {
    final app = AppState();
    final rect = createLayer('rect')
      ..content.offset = [0, 0]
      ..content.size = [40, 20]
      ..crop = [0, 0, 0.5, 0]; // the right half cut off
    app.project.layers.add(rect);
    final c = app.renderer.layerContour(app.project, rect, 0, const ContourParams())!;
    final xs = [for (final q in c.rings.single.points) q[0]];
    expect(xs.reduce((a, b) => a > b ? a : b), closeTo(0, 1e-6), reason: 'the cut at x = 0');
    expect(ringSignedArea(c.rings.single.points).abs(), closeTo(400, 1e-6));
    // mirrored, the kept half is the other one - on screen still the left.
    rect.mirrorX = true;
    final m = app.renderer.layerContour(app.project, rect, 0, const ContourParams())!;
    final mx = [for (final q in m.rings.single.points) q[0]];
    expect(mx.reduce((a, b) => a > b ? a : b), closeTo(0, 1e-6));
  });

  test('a deformed merged shape: the drawn contour follows the warp', () {
    final app = AppState();
    final shape = createLayer('rect')
      ..content.shape = 'compound'
      ..content.offset = [0, 0]
      ..content.size = [20, 20]
      ..content.contours = [
        [
          [-10.0, -10.0],
          [10.0, -10.0],
          [10.0, 10.0],
          [-10.0, 10.0],
        ]
      ];
    final sq = createEffectInstance('squeeze_axis', 'sq', shape);
    (sq.params['axisX'] as Track).defaultValue = 2.0;
    shape.effectStack.add(sq);
    app.project.layers.add(shape);
    final flat = app.renderer.layerContour(app.project, shape, 0, const ContourParams())!;
    final drawn = app.renderer.layerContourDrawn(app.project, shape, 0, const ContourParams())!;
    double width(Contour c) {
      final xs = [for (final q in c.rings.single.points) q[0]];
      return xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b);
    }

    expect(width(flat), closeTo(20, 1e-6));
    expect(width(drawn), closeTo(40, 0.5), reason: 'squeezed 2x wide, like the picture');
  });
}
