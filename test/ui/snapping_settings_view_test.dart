import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/snapping_settings_dialog.dart';

/// Real, run widget-level coverage of SnappingSettingsView - every
/// toggle/slider reflects and mutates AppState/movement_core's plain
/// snap* globals correctly in both directions, same convention as
/// timeline_toolbar_test.dart. The underlying drag/paint behavior these
/// settings drive is unverified in this sandbox (needs a real device),
/// same as the rest of ui/stage/ - this file is only about the settings
/// widget's own wiring.
void main() {
  late AppState app;

  // these tests start from every category on (a new AppState is a new
  // project, with the default - all off - view settings).
  void categoriesOn() {
    snapEnabled = false;
    snapEdgeToEdgeEnabled = true;
    snapCenterToCenterEnabled = true;
    snapCenterHorizontalEnabled = true;
    snapCenterVerticalEnabled = true;
    snapCenterDiagonalEnabled = true;
    snapCenterLineEnabled = true;
    snapEqualSpacingEnabled = true;
    snapCornerToCornerEnabled = true;
    snapEqualSizeEnabled = true;
    snapGridEnabled = true;
    snapFrameBoundaryEnabled = true;
    snapGuidesVisible = true;
    snapSizeMeasurement = SnapSizeMeasurement.edgeGap;
    snapGridCols = 4;
    snapGridRows = 4;
    snapRotationEnabled = true;
    snapRotationHorizontalEnabled = true;
    snapRotationVerticalEnabled = true;
    snapRotationDiagonalEnabled = true;
    snapRotationMatchNearbyEnabled = true;
    snapRotationToleranceDeg = 5;
  }

  setUp(() {
    app = AppState();
    categoriesOn();
  });

  tearDown(categoriesOn);

  Future<void> pump(WidgetTester tester) async {
    // the full expanded panel (master+guide toggles, 7 category blocks,
    // several with their own sub-controls) is taller than the default
    // 800x600 test surface - a tall physical size keeps every row
    // actually hit-testable without needing per-widget scroll-into-view.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body:
                SingleChildScrollView(child: SnappingSettingsView(app: app)))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'master toggle flips snapEnabled both ways and reveals/hides the category list',
      (tester) async {
    await pump(tester);
    expect(snapEnabled, isFalse);
    expect(find.text('Edge to edge'), findsNothing);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(snapEnabled, isTrue);
    expect(find.text('Edge to edge'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(snapEnabled, isFalse);
    expect(find.text('Edge to edge'), findsNothing);
  });

  testWidgets('guide-visibility toggle flips snapGuidesVisible both ways',
      (tester) async {
    await pump(tester);
    expect(snapGuidesVisible, isTrue);

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(snapGuidesVisible, isFalse);

    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(snapGuidesVisible, isTrue);
  });

  testWidgets(
      'edge-to-edge toggle flips its own global and reveals/hides its sensitivity slider',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(snapEdgeToEdgeEnabled, isTrue);
    expect(find.text('sensitivity (px)'), findsWidgets);

    // the category label is a plain Text with no tap handler of its
    // own - only the Switch itself responds; index into the known
    // Switch order (master=0, guide=1, edge-to-edge=2) rather than
    // tapping the label.
    await tester.tap(find.byType(Switch).at(2));
    await tester.pumpAndSettle();
    expect(snapEdgeToEdgeEnabled, isFalse);
  });

  testWidgets(
      'the edge-to-edge sensitivity slider mutates AppState.snapSensitivityEdgeToEdgePx',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    final before = app.snapSensitivityEdgeToEdgePx;

    final slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(50, 0));
    await tester.pumpAndSettle();

    expect(app.snapSensitivityEdgeToEdgePx, isNot(equals(before)));
  });

  testWidgets(
      'center-to-center sub-toggles (horizontal/vertical/diagonal/any-angle line) each flip their own global',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(snapCenterHorizontalEnabled, isTrue);
    expect(snapCenterVerticalEnabled, isTrue);
    expect(snapCenterDiagonalEnabled, isTrue);
    expect(snapCenterLineEnabled, isTrue);

    // .first: Rotation's own chips share these exact bare labels now
    // (see the "strip degree suffixes" round) - this targets
    // Center-to-center's own chips specifically, which render first.
    await tester.tap(find.widgetWithText(FilterChip, 'Horizontal').first);
    await tester.pumpAndSettle();
    expect(snapCenterHorizontalEnabled, isFalse);
    expect(snapCenterVerticalEnabled, isTrue);
    expect(snapCenterDiagonalEnabled, isTrue);

    await tester.tap(find.widgetWithText(FilterChip, 'Vertical').first);
    await tester.pumpAndSettle();
    expect(snapCenterVerticalEnabled, isFalse);

    await tester.tap(find.widgetWithText(FilterChip, 'Any-angle line'));
    await tester.pumpAndSettle();
    expect(snapCenterLineEnabled, isFalse);
  });

  testWidgets(
      'equal spacing toggle flips snapEqualSpacingEnabled, independent of Any-angle line',
      (tester) async {
    // equal spacing must work on its own switch, whether or not Any-angle line
    // is separately on - decoupled.
    snapEnabled = true;
    await pump(tester);
    expect(snapEqualSpacingEnabled, isTrue);
    expect(find.text('Equal spacing'), findsOneWidget);

    // Switch order: master=0, guide=1, edge-to-edge=2, center-to-
    // center=3, equal-spacing=4 (the label itself has no tap handler).
    await tester.tap(find.byType(Switch).at(4));
    await tester.pumpAndSettle();
    expect(snapEqualSpacingEnabled, isFalse);

    // turning Any-angle line off must NOT disable/relabel the
    // Equal-spacing switch anymore.
    await tester.tap(find.widgetWithText(FilterChip, 'Any-angle line'));
    await tester.pumpAndSettle();
    expect(snapCenterLineEnabled, isFalse);
    expect(find.text('Equal spacing (needs Any-angle line)'), findsNothing);
    await tester.tap(find.byType(Switch).at(4));
    await tester.pumpAndSettle();
    expect(snapEqualSpacingEnabled, isTrue); // switch still works
  });

  testWidgets('equal-size measurement mode chips switch snapSizeMeasurement',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(snapSizeMeasurement, equals(SnapSizeMeasurement.edgeGap));

    await tester.tap(find.widgetWithText(ChoiceChip, 'Center distance'));
    await tester.pumpAndSettle();
    expect(snapSizeMeasurement, equals(SnapSizeMeasurement.centerDistance));

    await tester.tap(find.widgetWithText(ChoiceChip, 'Edge gap'));
    await tester.pumpAndSettle();
    expect(snapSizeMeasurement, equals(SnapSizeMeasurement.edgeGap));
  });

  testWidgets(
      'grid category is relabeled "Snap to grid lines" and has no cols/rows steppers of its own (moved to grid_settings_dialog.dart)',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(find.text('Snap to grid lines'), findsOneWidget);
    expect(find.text('Grid'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byIcon(Icons.remove), findsNothing);
  });

  testWidgets('frame/canvas boundary toggle flips snapFrameBoundaryEnabled',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(snapFrameBoundaryEnabled, isTrue);

    // Switch order: master=0, guide=1, edge-to-edge=2, center-to-
    // center=3, equal-spacing=4, corner-to-corner=5, equal-size=6,
    // grid=7, frame-boundary=8 (the label itself has no tap handler).
    await tester.tap(find.byType(Switch).at(8));
    await tester.pumpAndSettle();
    expect(snapFrameBoundaryEnabled, isFalse);
  });

  testWidgets(
      'rotation master toggle flips snapRotationEnabled and reveals its own sub-controls',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(find.text('Rotation'), findsOneWidget);
    // .last: bare labels now collide with Center-to-center's own chips
    // (see the "strip degree suffixes" round) - Rotation's own block
    // always renders after Center-to-center's in this dialog.
    expect(find.widgetWithText(FilterChip, 'Horizontal').last, findsOneWidget);
    expect(find.text('Match nearby rotation'), findsOneWidget);

    // Switch order continues: rotation=9.
    await tester.tap(find.byType(Switch).at(9));
    await tester.pumpAndSettle();
    expect(snapRotationEnabled, isFalse);
    // now only Center-to-center's own chip remains - Rotation's block
    // (and its own "Horizontal" chip) is gone.
    expect(find.widgetWithText(FilterChip, 'Horizontal'), findsOneWidget);
    expect(find.text('Match nearby rotation'), findsNothing);
  });

  testWidgets(
      'rotation sub-toggles (horizontal/vertical/diagonal) each flip their own global',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(snapRotationHorizontalEnabled, isTrue);
    expect(snapRotationVerticalEnabled, isTrue);
    expect(snapRotationDiagonalEnabled, isTrue);

    await tester.tap(find.widgetWithText(FilterChip, 'Horizontal').last);
    await tester.pumpAndSettle();
    expect(snapRotationHorizontalEnabled, isFalse);

    await tester.tap(find.widgetWithText(FilterChip, 'Vertical').last);
    await tester.pumpAndSettle();
    expect(snapRotationVerticalEnabled, isFalse);

    await tester.tap(find.widgetWithText(FilterChip, 'Diagonal').last);
    await tester.pumpAndSettle();
    expect(snapRotationDiagonalEnabled, isFalse);
  });

  testWidgets(
      'match nearby rotation switch flips snapRotationMatchNearbyEnabled',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(snapRotationMatchNearbyEnabled, isTrue);

    // Switch order: ...frame-boundary=8, rotation=9, match-nearby=10.
    await tester.tap(find.byType(Switch).at(10));
    await tester.pumpAndSettle();
    expect(snapRotationMatchNearbyEnabled, isFalse);
  });

  testWidgets(
      'rotation tolerance slider mutates snapRotationToleranceDeg directly (no AppState px-mirror)',
      (tester) async {
    snapEnabled = true;
    await pump(tester);
    expect(find.text('tolerance (°)'), findsOneWidget);
    final before = snapRotationToleranceDeg;

    final slider = find.descendant(
        of: find.ancestor(of: find.text('tolerance (°)'), matching: find.byType(Row)).first, matching: find.byType(Slider));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    await tester.drag(slider, const Offset(50, 0));
    await tester.pumpAndSettle();

    expect(snapRotationToleranceDeg, isNot(equals(before)));
  });
}
