import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/project_store.dart';
import 'package:movement_mobile/ui/home/home_screen.dart';

/// Deleted projects go to the trash for a week: restorable, then gone;
/// the trash can be emptied.
void main() {
  late Directory dir;
  late ProjectStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('trash_test');
    store = ProjectStore(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('to the trash, back again, and gone after a week', () async {
    final a = await store.create('A', 100, 100);
    final b = await store.create('B', 100, 100);
    final t0 = DateTime.now();
    await store.moveToTrash(a, now: t0);
    expect((await store.list()).map((m) => m.name), ['B']);
    var trash = await store.listTrash(now: t0);
    expect(trash.single.name, 'A');
    expect(trash.single.purgeAt!.difference(t0).inDays, 7);

    await store.restoreFromTrash(trash.single.file);
    expect((await store.list()).map((m) => m.name).toSet(), {'A', 'B'});
    expect(await store.listTrash(now: t0), isEmpty);

    await store.moveToTrash(b, now: t0);
    expect((await store.listTrash(now: t0.add(const Duration(days: 6)))).length, 1);
    expect(await store.listTrash(now: t0.add(const Duration(days: 7, minutes: 1))), isEmpty, reason: 'a week is up');
  });

  test('empty the trash', () async {
    await store.moveToTrash(await store.create('A', 100, 100));
    await store.moveToTrash(await store.create('B', 100, 100));
    expect((await store.listTrash()).length, 2);
    await store.emptyTrash();
    expect(await store.listTrash(), isEmpty);
  });

  testWidgets('trash screen: restore and empty', (tester) async {
    await tester.runAsync(() async {
      await store.moveToTrash(await store.create('A', 100, 100));
      await store.moveToTrash(await store.create('B', 100, 100));
    });
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: TrashScreen(store: store))));
    Future<void> settle() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump();
      }
    }

    await settle();
    expect(find.text('A'), findsOneWidget);
    expect(find.textContaining('Deleted in 7 days'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('trash-restore-0')));
    await settle();
    expect((await tester.runAsync(store.list))!.length, 1);
    await tester.tap(find.byKey(const ValueKey('trash-empty')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trash-confirm')));
    await settle();
    await settle();
    expect((await tester.runAsync(store.listTrash))!, isEmpty);
  });
}
