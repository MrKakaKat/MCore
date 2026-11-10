import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/color_row.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/layer_panel/layer_panel_view.dart';
import 'package:movement_mobile/ui/palettes/palettes_view.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

void main() {
  setUp(() => ParamEditor.resetModes(expanded: true));

  test('a locked layer is not picked by a tap on the stage, nor dragged', () {
    final app = AppState();
    app.project.layers.clear();
    final a = createLayer('rect')
      ..id = 'a'
      ..content.size = [200, 200]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(a);
    app.selectLayer(null);
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final mid = camera.frameToScreen(Offset(app.frameWidth / 2, app.frameHeight / 2));
    a.locked = true;
    c.onPointerDown(PointerDownEvent(pointer: 1, position: mid));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: mid));
    expect(app.selection.selectedLayer, isNull, reason: 'locked: not picked');
    a.locked = false;
    c.onPointerDown(PointerDownEvent(pointer: 2, position: mid));
    c.onPointerUp(PointerUpEvent(pointer: 2, position: mid));
    expect(app.selection.selectedLayer, 'a');
  });

  testWidgets('rotation ruler: angle stations; my own station added under it and used', (tester) async {
    double value = 10;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ParamEditor(
            prefKey: 'test.rotation',
            label: 'rotation',
            values: [value],
            scale: ParamScale.degrees,
            onEditStart: () {},
            onChanged: (v) => setState(() => value = v.first),
            onCommit: (v) => setState(() => value = v.first),
          ),
        ),
      ),
    ));
    // the stops: − field + in the middle, how many at the edge.
    expect(find.text('3 stops'), findsOneWidget, reason: 'the angle stops');
    await tester.enterText(find.byKey(const ValueKey('station-field-test.rotation')), '137');
    await tester.tap(find.byKey(const ValueKey('station-add-test.rotation')));
    await tester.pump();
    expect(ParamEditor.stations['test.rotation'], [0.0, 45.0, 90.0, 137.0]);
    expect(find.text('4 stops'), findsOneWidget);
    // a built-in one goes too (typed, then −).
    await tester.enterText(find.byKey(const ValueKey('station-field-test.rotation')), '45');
    await tester.tap(find.byKey(const ValueKey('station-remove-test.rotation')));
    await tester.pump();
    expect(ParamEditor.stations['test.rotation'], [0.0, 90.0, 137.0]);
  });

  testWidgets('Layers: rename, a folder that folds, lock from the menu', (tester) async {
    final app = AppState();
    final l = app.project.layers.last;
    app.renameLayer(l.id, 'Hero');
    app.setLayerFolder(l.id, 'Characters');
    app.toggleLocked(l.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 600, height: 700, child: LayerPanelView(app: app)))));
    await tester.pumpAndSettle();
    expect(find.text('Characters (1)'), findsOneWidget);
    expect(find.text('Hero'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('folder-Characters')));
    await tester.pumpAndSettle();
    expect(find.text('Hero'), findsNothing, reason: 'folded');
    expect(l.folder, 'Characters');
  });

  testWidgets('Palettes: copy one, a colour field pastes it into its swatches', (tester) async {
    final app = AppState();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 500, height: 700, child: PalettesView(app: app)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('palette-copy-1')));
    await tester.pump();
    expect(copiedPalette.value, app.palettes[1].colors);
    var picked = '';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ColorRow(label: 'Fill', hex: '#ffffff', onPick: (h) => picked = h, initiallyOpen: true))));
    await tester.tap(find.byKey(const ValueKey('palette-menu-Fill')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Paste palette'));
    await tester.pumpAndSettle();
    expect(fieldPalettes.value['Fill'], app.palettes[1].colors);
    await tester.tap(find.byWidgetPredicate((w) =>
        w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == const Color(0xFF2D1B4E)));
    expect(picked, '#2d1b4e');
  });
}
