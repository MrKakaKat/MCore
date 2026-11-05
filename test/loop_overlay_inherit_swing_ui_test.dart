import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/effects/effects_view.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';
import 'package:movement_mobile/ui/timeline/timeline_rows_view.dart';

/// Timeline tab loop + lay over, Movement tab inheritance chips, Swing in
/// the Effects list.
void main() {
  late AppState app;
  Layer make(String id, int start, int dur) => createLayer('rect')
    ..id = id
    ..name = id
    ..startFrame = start
    ..durationFrames = dur;

  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    ParamEditor.resetModes(expanded: true);
    app = AppState();
  });

  Future<void> pump(WidgetTester tester, Widget view) async {
    // the Timeline tab's general settings come first now: a tall view.
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 3000, child: view))));
    await tester.pumpAndSettle();
  }

  testWidgets('loop: on, until a frame, back to the end; one undo step each', (tester) async {
    final a = make('a', 0, 30);
    app.project.layers
      ..clear()
      ..add(a);
    app.selectLayer('a');
    await pump(tester, TimelineRowsView(app: app));
    await tester.tap(find.byKey(const ValueKey('loop-switch')));
    await tester.pump();
    expect([a.loopEnabled, a.loopUntil], [true, null]);
    await tester.tap(find.text('Until frame'));
    await tester.pump();
    expect(a.loopUntil, 60);
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('loop-until')), matching: find.byType(TextField)), '150');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(a.loopUntil, 150);
    expect(app.maxFrame, 150, reason: 'the timeline grows to the loop limit');
    app.performUndo();
    expect(findLayer(app.project, 'a')!.loopUntil, 60);
  });

  testWidgets('lay over a row', (tester) async {
    final a = make('a', 0, 10), b = make('b', 30, 10), x = make('x', 0, 60);
    app.project.layers
      ..clear()
      ..addAll([a, b, x]);
    app.placeLayerInRow('b', 0, join: true);
    app.selectLayer('x');
    await pump(tester, TimelineRowsView(app: app));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('overlay-row')), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('overlay-row')));
    await tester.pump();
    final rows = timelineRows(app.project);
    expect(rows.length, 2);
    expect([for (final l in rows[1]) (l.startFrame, l.durationFrames)], [(0, 10), (30, 10)]);
  });

  testWidgets('inheritance chips appear with a parent and switch parts off', (tester) async {
    final child = findLayer(app.project, 'L_child')!;
    app.selectLayer(child.id);
    await pump(tester, ParamsPanelView(app: app));
    expect(child.parentId, isNotNull);
    await tester.tap(find.widgetWithText(FilterChip, 'Rotation'));
    await tester.pump();
    expect(child.inheritRotation, isFalse);
    app.performUndo();
    expect(findLayer(app.project, child.id)!.inheritRotation, isTrue);
  });

  testWidgets('Swing is added from the effect list and edits its angles', (tester) async {
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    await pump(tester, EffectsView(app: app));
    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Swing').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ effect'));
    await tester.pumpAndSettle();
    expect(layer.swing.enabled, isTrue);
    expect(find.text('Max angle'), findsOneWidget);
    expect(find.text('Damping'), findsOneWidget);
  });
}
