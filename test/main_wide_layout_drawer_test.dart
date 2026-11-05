import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/main.dart';

/// Real, run coverage of the wide-layout endDrawer - make the tabs reachable
/// via a simple slide from the right, and remove the redundant icons). The
/// wide/ tablet layout branch is the default 800x600 test surface (>= the
/// 700px narrow/wide threshold in main.dart), so no custom viewport size is
/// needed here, unlike main_stage_tab_test.dart's narrow-layout tests.
void main() {
  testWidgets('wide layout shows the tune icon (no tune icon on narrow, which has its own tab rail already)', (tester) async {
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.tune), findsOneWidget);
  });

  testWidgets('narrow layout has NO tune icon at all - its own bottom sheet tab rail already covers everything', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.tune), findsNothing);
  });

  testWidgets('tapping the tune icon opens the endDrawer with only the tabs that have no fixed wide-layout column', (tester) async {
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(find.byType(Drawer), findsOneWidget);
    // the tab rail is a horizontal ListView.builder - it lazily builds
    // only what's currently within its own viewport, so the later chips
    // ('Stage'/'Snapping') aren't in the tree at all until scrolled into
    // view (same reason main_stage_tab_test.dart's own narrow-layout
    // test needs dragUntilVisible for 'Stage').
    final tabRail = find.descendant(of: find.byType(Drawer), matching: find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.horizontal));
    // Layers/Movement already have dedicated fixed columns in wide
    // layout (main.dart's own Row) - they must not be in the drawer.
    Finder inDrawer(String label) =>
        find.descendant(of: find.byType(Drawer), matching: find.widgetWithText(ChoiceChip, label));
    expect(inDrawer('Layers'), findsNothing);
    expect(inDrawer('Movement'), findsNothing);
    for (final label in ['Keyframes', 'Masks', 'Effects', 'Text', 'Crop', 'Chroma', 'Presets', 'Stage', 'Snapping', 'Settings']) {
      await tester.dragUntilVisible(inDrawer(label), tabRail, const Offset(-40, 0));
      expect(inDrawer(label), findsOneWidget, reason: label);
    }
    final count = tester.widgetList<ChoiceChip>(find.descendant(of: find.byType(Drawer), matching: find.byType(ChoiceChip))).length;
    expect(count, lessThanOrEqualTo(10));
  });

  testWidgets('the endDrawer\'s Stage tab shows the real StageSettingsView, same content as the narrow layout\'s own tab', (tester) async {
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    final tabRail = find.descendant(of: find.byType(Drawer), matching: find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.horizontal));
    await tester.dragUntilVisible(find.text('Stage'), tabRail, const Offset(-200, 0));
    await tester.ensureVisible(find.descendant(of: find.byType(Drawer), matching: find.text('Stage')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(Drawer), matching: find.text('Stage')));
    await tester.pumpAndSettle();

    expect(find.text('Frame aspect ratio'), findsOneWidget);
    expect(find.text('Show off-canvas content'), findsOneWidget);
  });
}
