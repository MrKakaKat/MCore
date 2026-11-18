import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/export/export_dialog.dart';
import 'package:movement_mobile/ui/layer_panel/add_layer_dialog.dart';

void main() {
  testWidgets('saved straight into the chosen folder, then Done; only the picked layers go in', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('mcore_export_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final app = AppState()..exportDir = dir.path;
    final keep = app.project.layers.last;
    final hiddenBefore = {for (final l in app.project.layers) l.id: l.hidden};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExportView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('export-kind-svg')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey('export-layer-${keep.id}')));
    await tester.tap(find.byKey(ValueKey('export-layer-${keep.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('export-go')));
    for (var i = 0; i < 20 && find.byKey(const ValueKey('export-done')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('export-done')), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    final files = dir.listSync().whereType<File>().toList();
    expect(files, hasLength(1), reason: 'written straight into the folder');
    await tester.tap(find.byKey(const ValueKey('export-done-ok')));
    await tester.pumpAndSettle();
    expect({for (final l in app.project.layers) l.id: l.hidden}, hiddenBefore, reason: 'the others shown again');
  });

  testWidgets('audio has a window of its own in Add layer', (tester) async {
    final app = AppState();
    await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) => TextButton(onPressed: () => showAddLayerDialog(c, app), child: const Text('go')))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-audio')), findsOneWidget);
  });
}
