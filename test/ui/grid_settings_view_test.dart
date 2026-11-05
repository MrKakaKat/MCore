import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/grid_settings_dialog.dart';

/// Real, run widget-level coverage of GridSettingsView - the grid
/// overlay's own visibility toggle + cols/rows steppers, moved here out
/// of the Snapping tab (see gridOverlayEnabled's own doc comment in
/// project.dart for the decoupling rationale). Fully independent of any
/// snap* global - this widget touches only gridOverlayEnabled/
/// snapGridCols/snapGridRows.
void main() {
  late AppState app;

  setUp(() {
    app = AppState();
  });

  tearDown(() {
    gridOverlayEnabled = false;
    snapGridCols = 4;
    snapGridRows = 4;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: GridSettingsView(app: app))));
    await tester.pumpAndSettle();
  }

  testWidgets('overlay toggle flips gridOverlayEnabled both ways and reveals/hides the cols/rows steppers', (tester) async {
    await pump(tester);
    expect(gridOverlayEnabled, isFalse);
    expect(find.byIcon(Icons.add), findsNothing);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(gridOverlayEnabled, isTrue);
    expect(find.byIcon(Icons.add), findsWidgets);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(gridOverlayEnabled, isFalse);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('cols/rows steppers increment and decrement snapGridCols/snapGridRows', (tester) async {
    gridOverlayEnabled = true;
    await pump(tester);
    expect(snapGridCols, equals(4));
    expect(snapGridRows, equals(4));

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(snapGridCols, equals(5));

    await tester.tap(find.byIcon(Icons.remove).first);
    await tester.pumpAndSettle();
    expect(snapGridCols, equals(4));

    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    expect(snapGridRows, equals(5));
  });
}
