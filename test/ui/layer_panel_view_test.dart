import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/layer_panel/layer_panel_view.dart';
import 'package:movement_mobile/ui/timeline/timeline_rows_view.dart';

/// Real, run widget-level coverage of the Layers tab, including the new "go to
/// frame" field.
void main() {
  late AppState app;
  late Layer layer;

  setUp(() {
    app = AppState();
    app.maxFrame = 180;
    layer = findLayer(app.project, app.selection.selectedLayer)!;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LayerPanelView(app: app))));
    await tester.pumpAndSettle();
  }

  testWidgets('go-to-frame and timeline length are no longer rows here (they are in the timeline toolbar)', (tester) async {
    await pump(tester);
    expect(find.text('Go to frame:'), findsNothing);
    expect(find.text('Timeline length:'), findsNothing);
  });

  testWidgets('the layer list still shows every layer and responds to selection/hide as before', (tester) async {
    await pump(tester);

    expect(find.text(layer.name), findsOneWidget);

    await tester.tap(find.text(layer.name));
    await tester.pump();
    expect(app.selection.selectedLayer, equals(layer.id));
  });

  testWidgets('a layer\'s name Text has ellipsis overflow + a single line - a wide-layout\'s narrow column wrapped it character-by-character into what read as vertical text', (tester) async {
    await pump(tester);

    final nameText = tester.widget<Text>(find.text(layer.name));
    expect(nameText.overflow, equals(TextOverflow.ellipsis));
    expect(nameText.maxLines, equals(1));

    // the same fix also shrinks the 3 trailing IconButtons so the name
    // has more room in the first place - each must be compact (18px
    // icon, tight constraints), not the ~48px default tap target.
    for (final btn in tester.widgetList<IconButton>(find.byType(IconButton))) {
      expect(btn.iconSize, equals(18));
      expect(btn.visualDensity, equals(VisualDensity.compact));
    }
  });

  testWidgets('the move-layer-to-frame field (Timeline tab) moves the selected layer\'s startFrame', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelineRowsView(app: app))));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('move-layer-to-frame')), matching: find.byType(TextField)), '33');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(layer.startFrame, equals(33));
  });

  testWidgets('the "Add layer" button opens a picker that can add a rectangle (from the Shapes folder)', (tester) async {
    await pump(tester);
    final before = app.project.layers.length;

    await tester.tap(find.text('Add layer'));
    await tester.pumpAndSettle();
    expect(find.text('Import GIF...'), findsOneWidget);
    await tester.tap(find.text('Shapes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rectangle'));
    await tester.pumpAndSettle();

    expect(app.project.layers.length, equals(before + 1));
  });

  testWidgets('each layer row has its own duplicate and delete buttons', (tester) async {
    await pump(tester);
    final before = app.project.layers.length;

    await tester.tap(find.widgetWithIcon(IconButton, Icons.copy).first);
    await tester.pump();
    expect(app.project.layers.length, equals(before + 1));

    await tester.tap(find.widgetWithIcon(IconButton, Icons.delete).first);
    await tester.pump();
    expect(app.project.layers.length, equals(before));
  });

  testWidgets('the row menu copies one layer\'s parameters and pastes them into another', (tester) async {
    final other = app.project.layers.first;
    layer.transform.rotation.defaultValue = 77.0;
    await pump(tester);

    Future<void> menu(Layer l, String item) async {
      final row = find.ancestor(of: find.text(l.name), matching: find.byType(ListTile));
      await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.more_vert)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    await menu(layer, 'Copy parameters');
    expect(app.copiedLayerParams, isNotNull);
    await menu(other, 'Paste parameters');
    expect(findLayer(app.project, other.id)!.transform.rotation.defaultValue, 77.0);
  });
}
