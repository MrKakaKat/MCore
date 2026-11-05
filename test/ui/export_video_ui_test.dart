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
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ExportView(app: app)))));
    await tester.pumpAndSettle();
    return app;
  }

  String summary(WidgetTester tester) =>
      (tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('export-summary')), matching: find.byType(Text)))).data!;

  testWidgets('the project decides the format on open (no Auto button); settings stay folded', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('export-auto')), findsNothing);
    expect(find.text('Auto'), findsNothing);
    // the default project: short, small, no media - a GIF.
    expect(summary(tester), startsWith('GIF'));
    expect(find.text('Play in a loop'), findsNothing, reason: 'settings folded');
  });

  testWidgets('switching formats keeps the layout: only the summary changes', (tester) async {
    await pump(tester);
    final buttonTop = tester.getTopLeft(find.byKey(const ValueKey('export-go'))).dy;
    final summaryTop = tester.getTopLeft(find.byKey(const ValueKey('export-summary'))).dy;
    for (final k in ['image', 'video', 'gif']) {
      await tester.tap(find.byKey(ValueKey('export-kind-$k')));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const ValueKey('export-summary'))).dy, summaryTop);
      expect((tester.getTopLeft(find.byKey(const ValueKey('export-go'))).dy - buttonTop).abs(), lessThan(60),
          reason: 'a summary line and the video\'s file size field at most');
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
    await tester.tap(find.byKey(const ValueKey('export-settings')));
    await tester.pumpAndSettle();
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
