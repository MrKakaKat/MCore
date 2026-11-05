import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/ui/stage/stage_settings_dialog.dart';

/// Real, run coverage of two s fixed in the same round: (add the aspect-ratio
/// settings as a separate SECTION, not just a small icon-triggered dialog) and
/// (the top overlay icons ran off the screen edge). Both live in the
/// narrow/portrait layout branch of main.dart (_MobileParamsSheet /
/// _stageOverlayIcons), which needs a real narrow viewport to reach - the
/// default 800x600 test surface lands in the wide/tablet branch instead.
void main() {
  Future<void> pumpNarrow(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();
  }

  testWidgets('the mobile tab rail has a Stage tab showing StageSettingsView (aspect-ratio presets, off-canvas toggle)', (tester) async {
    await pumpNarrow(tester);

    // the tab rail is a horizontal ListView.builder - "Stage" is the
    // last of 6 chips and may not be built/visible without scrolling
    // the rail into view first. `find.byType(ListView)` alone is
    // ambiguous (the tab body panels use their own vertical ones too) -
    // the tab rail's own is the horizontal-scrolling ListView.
    final tabRail = find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.horizontal);
    await tester.dragUntilVisible(find.text('Stage'), tabRail, const Offset(-100, 0));
    await tester.ensureVisible(find.text('Stage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stage'));
    await tester.pumpAndSettle();

    expect(find.byType(StageSettingsView), findsOneWidget);
    expect(find.text('Frame aspect ratio'), findsOneWidget);
    // the preset picker moved to its own dialog - the tab itself now shows
    // only a "Choose preset." button (this project defaults to 1:1, so the
    // current-preset label reads that).
    expect(find.text('1:1 (square)'), findsOneWidget);
    expect(find.text('Show off-canvas content'), findsOneWidget);

    // the Background block now sits above it in the tab.
    await tester.ensureVisible(find.text('1:1 (square)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1:1 (square)'));
    await tester.pumpAndSettle();
    expect(find.text('Frame aspect ratio'), findsNWidgets(2)); // tab body + dialog title
    expect(find.text('16:9 (landscape)'), findsOneWidget);
  });

  testWidgets(
      'the Stage/Snapping top icons are gone (pure duplication of their own tabs) - only grid/export remain',
      (tester) async {
    await pumpNarrow(tester);

    // hideHandles/hideVisualLayer/grid/export - Stage settings and
    // Snapping no longer have their own top icon at all, narrow or wide.
    expect(find.byIcon(Icons.settings), findsNothing);
    expect(find.byIcon(Icons.grid_4x4_outlined), findsNothing);
    expect(find.byIcon(Icons.grid_4x4), findsNothing);
    expect(find.byIcon(Icons.window_outlined), findsOneWidget, reason: 'the grid overlay icon has no tab home and stays');
    expect(find.byIcon(Icons.ios_share), findsOneWidget, reason: 'export has no tab home and stays');
  });

  testWidgets('the stage overlay icons stay below a simulated top inset (status bar/notch), not flush against the raw screen edge', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.padding = const FakeViewPadding(top: 40); // simulate a status bar/notch
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();

    final iconTop = tester.getTopLeft(find.byIcon(Icons.touch_app)).dy;
    expect(iconTop, greaterThanOrEqualTo(40),
        reason: 'must sit below the simulated top inset - an AppBar used to reserve this space implicitly, SafeArea does it now');
  });
}
