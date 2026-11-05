import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/text/text_view.dart';

/// Vector text layers: rendering, the text-box handles, conversion to a
/// shape on corner pin, and the Text tab.
void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });
  setUp(() {
    hideHandles = false;
    ParamEditor.resetModes(expanded: true);
  });

  Future<ByteDataReader> render(Project p, {double w = 200, double h = 100}) async {
    final r = CanvasRenderer()..setSize(w, h);
    r.renderFrame(p, 0);
    final img = await r.captureFrame();
    return ByteDataReader((await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!, w.round());
  }

  test('text renders white letters; the background block wraps the text', () async {
    final layer = createTextLayer(text: 'HH', fontSize: 60);
    final p = Project(layers: [layer]);
    var px = await render(p);
    // the middle of the first H's left stem is inked; the box corner isn't.
    var inked = 0;
    for (var x = 60; x < 140; x++) {
      if (px.alpha(x, 50) > 200) inked++;
    }
    expect(inked, greaterThan(5), reason: 'letters are drawn');
    expect(px.alpha(2, 2), 0);

    layer.content.text!.background
      ..enabled = true
      ..color = '#ff0000'
      ..opacity = 1;
    layer.content.size = [180, 80];
    px = await render(p);
    // the block hugs the text (padding 8): just above the letters it's
    // red, the box's corner isn't covered.
    final l = layoutText(layer.content.text!, const [0, 0], layer.content.size);
    final y = (50 - l.height / 2 - 4).round();
    expect(px.alpha(100, y), 255);
    expect(px.rgb(100, y), [255, 0, 0]);
    expect(px.alpha(12, 12), 0);
  });

  test('a converted text is a vector shape drawn with the text colour', () async {
    final layer = createTextLayer(text: 'HH', fontSize: 60);
    layer.content.text!.color = '#00ff00';
    convertTextToShape(layer);
    final px = await render(Project(layers: [layer]));
    var green = 0;
    for (var x = 60; x < 140; x++) {
      if (px.alpha(x, 50) > 200 && px.rgb(x, 50)[1] > 200 && px.rgb(x, 50)[0] < 60) green++;
    }
    expect(green, greaterThan(5));
  });

  group('stage handles', () {
    late AppState app;
    late StageCamera camera;
    late StageGestureController c;
    late Layer layer;

    setUp(() {
      app = AppState();
      app.project.layers.clear();
      app.addTextLayer();
      layer = app.project.layers.single;
      layer.content.size = [200, 60];
      camera = StageCamera();
      c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    });

    Offset screenOf(String key) {
      final h = getTransformBoxHandles(app.project, layer, 0).screen[key]!;
      return camera.frameToScreen(Offset(h[0], h[1]));
    }

    test('side handles resize the text box instead of scaling', () {
      final start = screenOf('right');
      c.onPointerDown(PointerDownEvent(pointer: 1, position: start));
      c.onPointerMove(PointerMoveEvent(pointer: 1, position: start - const Offset(60, 0)));
      c.onPointerUp(PointerUpEvent(pointer: 1, position: start - const Offset(60, 0)));
      final l = findLayer(app.project, layer.id)!;
      expect(l.content.size[0], lessThan(200));
      expect(l.transform.scale.defaultValue, [1.0, 1.0], reason: 'no scaling');
    });

    test('dragging a corner pin on text turns it into a shape; undo brings the text back', () {
      layer.effectStack.add(createEffectInstance('corner_pin', 'cp', layer));
      final tl = getCornerPinHandles(app.project, layer, layer.effectStack.single, 0).screen['tl']!;
      final start = camera.frameToScreen(Offset(tl[0], tl[1]));
      c.onPointerDown(PointerDownEvent(pointer: 1, position: start));
      c.onPointerMove(PointerMoveEvent(pointer: 1, position: start + const Offset(-10, -10)));
      c.onPointerUp(PointerUpEvent(pointer: 1, position: start + const Offset(-10, -10)));
      final l = findLayer(app.project, layer.id)!;
      expect(l.content.shape, 'compound');
      expect(l.content.size, [200, 60], reason: 'same box');
      app.performUndo();
      expect(findLayer(app.project, layer.id)!.content.shape, 'text');
    });
  });

  testWidgets('Text tab edits the selected text layer', (tester) async {
    final app = AppState();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 560, child: TextView(app: app)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add text'));
    await tester.pumpAndSettle();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    expect(layer.content.shape, 'text');

    await tester.enterText(find.byType(TextField).first, 'Привет');
    await tester.pump();
    expect(layer.content.text!.text, 'Привет');

    // alignment lives in the Box fold.
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    final box = find.byKey(const ValueKey('text-section-Box'));
    await tester.scrollUntilVisible(box, 150, scrollable: list);
    await tester.drag(list, const Offset(0, -150));
    await tester.pumpAndSettle();
    if (find.descendant(of: box, matching: find.byIcon(Icons.expand_more)).evaluate().isNotEmpty) {
      await tester.tap(box);
      await tester.pumpAndSettle();
    }
    await tester.dragUntilVisible(find.byTooltip('align left'), list, const Offset(0, -100));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('align left'));
    await tester.pump();
    expect(layer.content.text!.align, 'left');

    final section = find.byKey(const ValueKey('text-section-Shadow'));
    await tester.scrollUntilVisible(section, 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.tap(section);
    await tester.pump();
    await tester.ensureVisible(find.text('Shadow').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shadow').last);
    await tester.pump();
    expect(layer.content.text!.shadow.enabled, isTrue);
    expect(find.text('Offset'), findsOneWidget);

    app.performUndo();
    await tester.pump();
    expect(findLayer(app.project, layer.id)!.content.text!.shadow.enabled, isFalse);
  });
}

class ByteDataReader {
  final ByteData data;
  final int width;
  ByteDataReader(this.data, this.width);
  int alpha(int x, int y) => data.getUint8((y * width + x) * 4 + 3);
  List<int> rgb(int x, int y) => [for (var i = 0; i < 3; i++) data.getUint8((y * width + x) * 4 + i)];
}
