import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/ui/timeline/timeline_drawer_row.dart';

/// Real, run coverage that toggling AppState.timelineDrawerExpanded via
/// TimelineToolbar's own caret button actually shows/hides
/// TimelineDrawerRow in the live app tree - main.dart's own layout has
/// no other AnimatedBuilder above this point listening to AppState, so
/// this proves the new wrapper added around the timeline section
/// actually reacts, not just that the two widgets compile together.
void main() {
  testWidgets('the drawer caret shows and hides TimelineDrawerRow in the real app tree', (tester) async {
    final app = MovementMobileApp();
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(app.appState.timelineDrawerExpanded, isFalse);
    expect(find.byType(TimelineDrawerRow), findsNothing);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pumpAndSettle();

    expect(app.appState.timelineDrawerExpanded, isTrue);
    expect(find.byType(TimelineDrawerRow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pumpAndSettle();

    expect(app.appState.timelineDrawerExpanded, isFalse);
    expect(find.byType(TimelineDrawerRow), findsNothing);
  });
}
