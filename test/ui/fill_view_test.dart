import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/color_row.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/fill/fill_view.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

/// Fill tab (plain colour / gradient glows), its stage handles, and the
/// foldable colour palettes.
void main() {
  late AppState app;
  late Layer l;
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    glowHandlesVisible = false;
    ParamEditor.resetModes(expanded: true);
    app = AppState();
    app.setFrameSize(200, 200);
    app.project.layers.clear();
    l = createLayer('rect')
      ..id = 'sq'
      ..name = 'rect_1'
      ..color = '#000000'
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(l);
    app.selectLayer('sq');
  });
  tearDown(() => glowHandlesVisible = false);

  Future<void> pump(WidgetTester tester) async {
    // tall: the shape style rows (corners, shadow) sit above the glows.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 1200, child: FillView(app: app)))));
    await tester.pumpAndSettle();
  }

  testWidgets('colour, gradient on, add / delete glows, one undo step each', (tester) async {
    await pump(tester);
    expect(glowHandlesVisible, isTrue, reason: 'handles show while the tab is open');

    // the palette starts folded: one swatch of the current colour.
    expect(find.byTooltip('custom colour'), findsNothing);
    await tester.tap(find.byTooltip('show the palette').first);
    await tester.pump();
    expect(find.byTooltip('custom colour'), findsOneWidget);
    await tester.tap(find.byWidgetPredicate((w) =>
        w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == const Color(0xFF7FC4A8)));
    await tester.pump();
    expect(l.color, '#7fc4a8');

    await tester.tap(find.byKey(const ValueKey('fill-gradient')));
    await tester.pump();
    expect(l.fill.gradient, isTrue);
    await tester.tap(find.byKey(const ValueKey('fill-add-point')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('fill-add-line')));
    await tester.pump();
    expect(l.fill.glows.map((g) => g.kind), ['point', 'line']);
    expect(find.text('Line 2'), findsOneWidget);

    await tester.ensureVisible(find.byTooltip('delete this glow').first);
    await tester.tap(find.byTooltip('delete this glow').first);
    await tester.pump();
    expect(l.fill.glows.single.kind, 'line');
    app.performUndo();
    await tester.pump();
    expect(findLayer(app.project, 'sq')!.fill.glows.length, 2);

    await tester.pumpWidget(const SizedBox());
    expect(glowHandlesVisible, isFalse, reason: 'closing the tab hides them');
  });

  testWidgets('images and text get an explanation instead', (tester) async {
    l.content = Content(shape: 'image', offset: [0, 0], size: [100, 100]);
    await pump(tester);
    expect(find.textContaining('vector shapes'), findsOneWidget);
  });

  test('a glow handle drags on the stage, one undo step', () {
    setStageSize(200, 200);
    app.renderer.setSize(200, 200);
    final g = addGlow(l, 'point');
    glowHandlesVisible = true;
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final a = camera.frameToScreen(const Offset(100, 100)), b = camera.frameToScreen(const Offset(125, 75));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: a));
    expect(c.activeDrag?.family, 'glow');
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: b));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: b));
    final p = g.position.defaultValue as List<double>;
    expect(p[0], closeTo(0.75, 1e-6));
    expect(p[1], closeTo(0.25, 1e-6));
    app.performUndo();
    expect(findLayer(app.project, 'sq')!.fill.glows.single.position.defaultValue, [0.5, 0.5]);
  });

  testWidgets('ColorRow folds and unfolds', (tester) async {
    String picked = '';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ColorRow(label: 'Colour', hex: '#123456', onPick: (c) => picked = c))));
    expect(find.text('#123456'), findsOneWidget);
    await tester.tap(find.byTooltip('show the palette').last);
    await tester.pump();
    expect(find.text('#123456'), findsNothing);
    await tester.tap(find.byTooltip('fold the palette'));
    await tester.pump();
    expect(find.text('#123456'), findsOneWidget);
    expect(picked, '');
  });
}
