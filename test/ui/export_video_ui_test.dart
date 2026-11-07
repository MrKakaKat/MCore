import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/export/export_dialog.dart';

void main() {
  Future<AppState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExportView(app: app))));
    await tester.pumpAndSettle();
    return app;
  }

  String summary(WidgetTester tester) =>
      (tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('export-summary')), matching: find.byType(Text)))).data!;

  testWidgets('the project decides the format on open (no Auto button); its settings are open', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('export-auto')), findsNothing);
    expect(find.text('Auto'), findsNothing);
    // the default project: short, small, no media - a GIF.
    expect(summary(tester), startsWith('GIF'));
    expect(find.text('Play in a loop'), findsOneWidget, reason: 'settings shown');
    // each format says what it is for.
    expect(find.text('A short looping animation, no sound'), findsOneWidget);
  });

  testWidgets('switching formats keeps the layout: the summary and Export stay put', (tester) async {
    await pump(tester);
    final buttonTop = tester.getTopLeft(find.byKey(const ValueKey('export-go'))).dy;
    final summaryTop = tester.getTopLeft(find.byKey(const ValueKey('export-summary'))).dy;
    for (final k in ['image', 'video', 'gif']) {
      await tester.tap(find.byKey(ValueKey('export-kind-$k')));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const ValueKey('export-summary'))).dy, summaryTop);
      expect(tester.getTopLeft(find.byKey(const ValueKey('export-go'))).dy, buttonTop, reason: 'at the bottom');
    }
  });

  testWidgets('video: file type, quality in Mbit/s, length and file estimate; no alpha / speed options', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('export-kind-video')));
    await tester.pumpAndSettle();
    expect(summary(tester), contains('Length:'));
    expect(summary(tester), contains('px'));
    expect(summary(tester), isNot(contains('File: about')), reason: 'in its own field');
    expect(find.descendant(of: find.byKey(const ValueKey('export-file-size')), matching: find.textContaining('File: about')),
        findsOneWidget);
    expect(find.text('WebM (VP9)'), findsOneWidget);
    expect(find.text('MP4 (H.264)'), findsOneWidget);
    expect(find.text('Encoding speed'), findsNothing);
    expect(find.text('Transparent background'), findsNothing);
    final before = summary(tester);
    await tester.tap(find.byKey(const ValueKey('quality-low')));
    await tester.pump();
    expect(summary(tester), isNot(before), reason: 'lower quality: smaller file');
  });
}
