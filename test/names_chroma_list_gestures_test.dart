import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/chroma/chroma_view.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';

/// Layer names (first free number per type), the Chroma list of removed
/// colours, a second finger during the eyedropper, and taps on a focused
/// layer's edge columns.
void main() {
  late AppState app;

  setUp(() {
    fps = 60;
    chromaTool = 'none';
    ParamEditor.resetModes(expanded: true);
    app = AppState()..timelineCenterPlayheadEnabled = false;
  });
  tearDown(() => chromaTool = 'none');

  Layer imageLayer() => Layer(
        id: 'L_img',
        name: 'image_1',
        transform: Transform(
            anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
        content: Content(shape: 'image', offset: [0, 0], size: [200, 100]),
      );

  test('new layers take the first free number of their type', () {
    List<String> names() => [for (final l in app.project.layers) l.name];
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('rect');
    app.addLayer('rect');
    app.addLayer('circle');
    expect(names(), ['Rect 1', 'Rect 2', 'Rect 3', 'Circle 1']);
    app.deleteLayerById(app.project.layers[1].id);
    app.addLayer('rect');
    expect(names().last, 'Rect 2', reason: 'fills the gap instead of counting on to 4');
    for (final l in [...app.project.layers]) {
      app.deleteLayerById(l.id);
    }
    app.addLayer('rect');
    expect(names(), ['Rect 1'], reason: 'reset once they are all gone');
  });

  testWidgets('Chroma: submit a colour, hide it, delete it', (tester) async {
    final image = imageLayer();
    app.project.layers.add(image);
    app.selectLayer(image.id);
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 1900, child: ChromaView(app: app)))));
    await tester.pumpAndSettle();
    ButtonStyleButton submit() => tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('chroma-submit')));
    expect(submit().onPressed, isNull, reason: 'nothing keyed yet');

    app.editChromaKey(image.id, (c) => c
      ..enabled = true
      ..color = '#00ff00');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chroma-submit')));
    await tester.pump();
    final ck = findLayer(app.project, image.id)!.chromaKey;
    expect(ck.applied.single.color, '#00ff00');
    expect(ck.enabled, isFalse);
    expect(find.text('Removed colours'), findsOneWidget);

    await tester.tap(find.byTooltip('hide this colour'));
    await tester.pump();
    expect(findLayer(app.project, image.id)!.chromaKey.applied.single.enabled, isFalse);
    await tester.tap(find.byTooltip('delete this colour'));
    await tester.pump();
    expect(findLayer(app.project, image.id)!.chromaKey.applied, isEmpty);
    app.performUndo();
    expect(findLayer(app.project, image.id)!.chromaKey.applied.single.enabled, isFalse);
  });

  test('a second finger during the eyedropper drops the loupe and zooms instead', () {
    setStageSize(640, 400);
    app.renderer.setSize(640, 400);
    final image = imageLayer();
    app.project.layers.add(image);
    app.selectLayer(image.id);
    chromaTool = 'pick';
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final a = camera.frameToScreen(const Offset(300, 200));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: a));
    expect(c.chromaPickScreen, isNotNull);

    c.onPointerDown(PointerDownEvent(pointer: 2, position: a + const Offset(40, 0)));
    expect(c.chromaPickScreen, isNull, reason: 'the loupe goes away');
    expect(c.activeDrag, isNull);
    final before = camera.scale;
    c.onPointerMove(PointerMoveEvent(pointer: 2, position: a + const Offset(120, 0)));
    expect(camera.scale, greaterThan(before), reason: 'the two fingers zoom');
    c.onPointerUp(PointerUpEvent(pointer: 1, position: a));
    c.onPointerUp(PointerUpEvent(pointer: 2, position: a + const Offset(120, 0)));
    expect(findLayer(app.project, image.id)!.chromaKey.enabled, isFalse, reason: 'no colour was taken');
  });

  group('tapping a focused layer\'s edge column', () {
    Future<void> pump(WidgetTester tester) async {
      app.setFrame(170); // the playhead off to the side, clear of the lanes' middle and the start edge
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SizedBox(width: 600, height: 200, child: LayersTimelineView(app: app)))));
      await tester.pumpAndSettle();
    }

    Finder moveAreas() => find.byWidgetPredicate((w) => w is GestureDetector && w.onLongPressStart != null);
    final trimLeft = find.byKey(const ValueKey('trim-left'));

    testWidgets('a quick tap on it over the layer unfocuses the layer (no trim, no undo step)', (tester) async {
      await pump(tester);
      await tester.tap(moveAreas().at(1)); // focus the second layer
      await tester.pump();
      expect(trimLeft, findsOneWidget);
      final rowY = tester.getRect(moveAreas().first).center.dy;
      final layer = findLayer(app.project, app.selection.selectedLayer)!;
      final start = layer.startFrame, dur = layer.durationFrames;
      await tester.tapAt(Offset(tester.getRect(trimLeft).center.dx, rowY));
      await tester.pump();
      expect(trimLeft, findsNothing, reason: 'unfocused');
      expect([layer.startFrame, layer.durationFrames], [start, dur]);
    });

    testWidgets('with quick switch, a tap on it over another lane switches to that layer', (tester) async {
      app.layerQuickSwitchEnabled = true;
      final first = app.project.layers[0], second = app.project.layers[1];
      await pump(tester);
      await tester.tap(moveAreas().at(0)); // focus the first layer (row 0)
      await tester.pumpAndSettle(); // lanes below slide down under the action row
      // the dimmed second lane's quick-switch tap area (its row is below
      // the focused layer's action row).
      final dimmedLane = find.byWidgetPredicate((w) =>
          w is GestureDetector && w.onTap != null && w.onLongPressStart == null && w.behavior == HitTestBehavior.translucent);
      final row1 = tester.getRect(dimmedLane.first).center.dy;
      await tester.tapAt(Offset(tester.getRect(trimLeft).center.dx, row1)); // row 1, at frame 0
      await tester.pump();
      expect(app.selection.selectedLayer, second.id);
      expect(first.id, isNot(second.id));
    });

    testWidgets('pressing and sliding still trims', (tester) async {
      await pump(tester);
      await tester.tap(moveAreas().at(1));
      await tester.pump();
      final layer = findLayer(app.project, app.selection.selectedLayer)!;
      final end = layer.startFrame + layer.durationFrames;
      await tester.dragFrom(tester.getCenter(trimLeft), const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(layer.startFrame, greaterThan(0));
      expect(layer.startFrame + layer.durationFrames, end);
    });
  });
}
