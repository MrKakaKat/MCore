import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/app_settings.dart';
import 'package:movement_mobile/io/project_store.dart';
import 'package:movement_mobile/ui/home/home_screen.dart';

void main() {
  testWidgets('outside folder marks: kept (green), the try failed (yellow); settings is a page of its own', (tester) async {
    late Directory dir;
    late ProjectStore store;
    late File a, b;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('home_marks_');
      store = ProjectStore(dir);
      a = await store.create('Kept', 200, 200);
      b = await store.create('Changed', 200, 200);
      await a.setLastModified(DateTime(2026, 1, 1));
      await b.setLastModified(DateTime(2026, 6, 1));
      AppSettings.instance = AppSettings(File('${dir.path}/app_settings.json'));
      await AppSettings.instance!.setValue('projectsFolder', '${dir.path}/no/such/folder');
      await AppSettings.instance!.setValue('projectsFolderSaved', DateTime(2026, 3, 1).millisecondsSinceEpoch);
    });
    addTearDown(() => AppSettings.instance = null);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(store: store)));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(ListTile).evaluate().length >= 2 && find.byWidgetPredicate((w) => w is Icon && w.color == Colors.amber).evaluate().isNotEmpty) break;
    }
    final metas = await tester.runAsync(store.list);
    final idA = metas!.firstWhere((m) => m.name == 'Kept').id, idB = metas.firstWhere((m) => m.name == 'Changed').id;
    expect(find.byKey(ValueKey('outside-kept-$idA')), findsOneWidget);
    expect(find.byKey(ValueKey('outside-failed-$idB')), findsOneWidget, reason: 'the folder is not there: the try failed');
    expect(AppSettings.instance!.projectsFolderError, isNotNull);
    // the menu: no AI items any more.
    await tester.tap(find.byKey(const ValueKey('home-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Prompt for AI...'), findsNothing);
    expect(find.text('Import from text...'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-settings-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-versionsKept-minus')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(AppSettings.instance!.versionsKept, 9);
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
