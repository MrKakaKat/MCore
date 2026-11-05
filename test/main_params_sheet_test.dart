import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/ui/layer_panel/layer_panel_view.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';

/// The narrow layout's tab sheet: three heights - closed (grabber and
/// chips), half open (under the timeline) and full (over the timeline).
void main() {
  Future<void> pumpNarrow(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();
  }

  final grabber = find.byKey(const ValueKey('sheet-grabber'));
  final sheet = find.byKey(const ValueKey('params-sheet'));
  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);
  double timelineTop(WidgetTester tester) => tester.getRect(find.byType(LayersTimelineView)).top;

  testWidgets('the head starts at the middle and never moves; the sheet lies over it', (tester) async {
    await pumpNarrow(tester);
    final top = tester.getRect(find.byKey(const ValueKey('timeline-section'))).top;
    expect(top, closeTo(400, 2), reason: 'the middle of the 800px screen');
    await tester.timedDrag(grabber, const Offset(0, -500), const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('timeline-section'))).top, top);
    await tester.fling(grabber, const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
    await tester.fling(grabber, const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('timeline-section'))).top, top, reason: 'closed: still in place');
  });

  testWidgets('a slow drag far up settles on full, covering the timeline', (tester) async {
    await pumpNarrow(tester);
    await tester.timedDrag(grabber, const Offset(0, -500), const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.getRect(grabber).top, lessThan(timelineTop(tester)));
  });

  testWidgets('a fast upward fling goes one step: half -> full', (tester) async {
    await pumpNarrow(tester);
    final half = tester.getRect(sheet).height;
    await tester.fling(grabber, const Offset(0, -60), 1500);
    await tester.pumpAndSettle();
    expect(tester.getRect(sheet).height, greaterThan(half + 100));
  });

  testWidgets('tapping the selected tab closes the sheet; picking a tab opens it half way', (tester) async {
    await pumpNarrow(tester);
    final half = tester.getRect(sheet).height;
    await tester.tap(chip('Layers'));
    await tester.pumpAndSettle();
    expect(find.byType(LayerPanelView), findsNothing, reason: 'no tab selected - no body');
    expect(tester.getRect(sheet).height, closeTo(64, 1), reason: 'only the grabber and the chip row stay visible');

    await tester.tap(chip('Movement'));
    await tester.pumpAndSettle();
    expect(find.byType(ParamsPanelView), findsOneWidget);
    expect(tester.getRect(sheet).height, closeTo(half, 1));
  });

  testWidgets('flinging the grabber down closes the sheet; dragging up brings back the tab', (tester) async {
    await pumpNarrow(tester);
    await tester.fling(grabber, const Offset(0, 100), 1500);
    await tester.pumpAndSettle();
    expect(find.byType(LayerPanelView), findsNothing);

    await tester.fling(grabber, const Offset(0, -60), 1500);
    await tester.pumpAndSettle();
    expect(find.byType(LayerPanelView), findsOneWidget);
  });

  testWidgets('the playhead line runs to the bottom of the head', (tester) async {
    await pumpNarrow(tester);
    final view = tester.getRect(find.byType(LayersTimelineView));
    final line = tester.getRect(find.byKey(const ValueKey('pinned-playhead')));
    expect(line.bottom, closeTo(view.bottom, 2));
  });

  testWidgets('half open covers half of the head; full covers exactly all of it', (tester) async {
    await pumpNarrow(tester);
    final head = tester.getRect(find.byKey(const ValueKey('timeline-section')));
    expect(tester.getRect(sheet).top, closeTo(head.center.dy, 2), reason: 'half open: the head\'s middle');
    await tester.timedDrag(grabber, const Offset(0, -500), const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.getRect(sheet).top, closeTo(head.top, 1), reason: 'not over the stage or its icons');
  });
}
