import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/timeline/timeline_toolbar.dart';

void main() {
  testWidgets('the bottom field guide: dims, steps through its icons on taps, then is seen', (tester) async {
    final app = AppState()..guideBottomSeen = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: TimelineToolbar(app: app)))));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('tool-guide')), findsOneWidget);
    expect(find.text('Play / pause the animation.'), findsOneWidget);
    final seen = <String>{};
    for (var i = 0; i < bottomGuideSteps.length + 2 && find.byKey(const ValueKey('tool-guide-end')).evaluate().isEmpty; i++) {
      for (final (_, text) in bottomGuideSteps) {
        if (find.text(text).evaluate().isNotEmpty) seen.add(text);
      }
      await tester.tap(find.byKey(const ValueKey('tool-guide')));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(seen.length, bottomGuideSteps.length, reason: 'every icon shown: $seen');
    expect(find.byKey(const ValueKey('tool-guide-end')), findsOneWidget, reason: 'it ends saying where to see it again');
    await tester.tap(find.byKey(const ValueKey('tool-guide')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('tool-guide')), findsNothing);
    expect(app.guideBottomSeen, isTrue);
  });
}
