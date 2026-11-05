import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/project_store.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/ui/home/home_screen.dart';
import 'package:movement_mobile/ui/stage/stage_settings_dialog.dart';

/// Home screen (project list + New project dialog) and the canvas
/// background (Stage tab swatches + renderer fill).
void main() {
  late Directory tempDir;
  late ProjectStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('home_screen_test');
    store = ProjectStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  // real file IO doesn't advance inside the fake-async test zone.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  test('frameSizeFor keeps the short side and rounds to even numbers', () {
    expect(frameSizeFor(16, 9, 1080), equals((1920, 1080)));
    expect(frameSizeFor(9, 16, 720), equals((720, 1280)));
    expect(frameSizeFor(1, 1, 480), equals((480, 480)));
    expect(frameSizeFor(4, 5, 1080), equals((1080, 1350)));
  });

  testWidgets('empty store shows the empty-state hint', (tester) async {
    await tester.pumpWidget(MovementMobileApp(store: store));
    await settle(tester);
    expect(find.textContaining('No projects yet'), findsOneWidget);
  });

  testWidgets('existing projects are listed with name and resolution', (tester) async {
    await tester.runAsync(() => store.create('My clip', 1080, 1920));
    await tester.pumpWidget(MovementMobileApp(store: store));
    await settle(tester);

    expect(find.text('My clip'), findsOneWidget);
    expect(find.textContaining('1080 × 1920'), findsOneWidget);
  });

  testWidgets('New project dialog: aspect + resolution chips set the size', (tester) async {
    NewProjectSpec? spec;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => spec = await showNewProjectDialog(context, defaultName: 'X'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('1:1'), findsOneWidget, reason: 'square first');
    await tester.ensureVisible(find.text('9:16'));
    await tester.tap(find.text('9:16'));
    await tester.ensureVisible(find.text('720p'));
    await tester.tap(find.text('720p'));
    await tester.ensureVisible(find.text('30 fps'));
    await tester.tap(find.text('30 fps'));
    await tester.pump();
    expect(find.text('720 × 1280 px, 30 fps'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(spec!.name, equals('X'));
    expect(spec!.width, equals(720));
    expect(spec!.height, equals(1280));
    expect(spec!.fps, 30);
    expect(spec!.guide, isFalse);
  });

  testWidgets('an empty project opens in the editor without errors', (tester) async {
    final file = (await tester.runAsync(() => store.create('Empty', 1920, 1080)))!;
    final app = AppState();
    await tester.runAsync(() => app.openProject(file));

    await tester.pumpWidget(MovementMobileApp(appState: app));
    await tester.pumpAndSettle();

    expect(app.project.layers, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stage tab background swatches set AppState.background (transparent by default)', (tester) async {
    final app = AppState();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AnimatedBuilder(animation: app, builder: (_, __) => BackgroundPicker(app: app))),
    ));
    expect(app.background, isNull);

    await tester.tap(find.byTooltip('#FFFFFF'));
    await tester.pump();
    expect(app.background, equals(const Color(0xFFFFFFFF)));

    await tester.tap(find.byTooltip('Transparent'));
    await tester.pump();
    expect(app.background, isNull);
    app.dispose();
  });

  testWidgets('the renderer fills only the frame with the background; transparent leaves real alpha', (tester) async {
    final app = AppState();
    app.project = Project(layers: []);
    app.setFrameSize(8, 8);

    Future<ui.Color> pixel() async {
      app.renderer.renderFrame(app.project, 0);
      final image = (await tester.runAsync(() => app.renderer.captureFrame()))!;
      final data = (await tester.runAsync(() => image.toByteData()))!;
      return ui.Color.fromARGB(data.getUint8(3), data.getUint8(0), data.getUint8(1), data.getUint8(2));
    }

    expect((await pixel()).alpha, equals(0), reason: 'transparent: no fill at all');

    app.setBackground(const Color(0xFF336699));
    expect(await pixel(), equals(const Color(0xFF336699)));
    app.dispose();
  });
}
