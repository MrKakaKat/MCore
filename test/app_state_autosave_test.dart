import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/project_store.dart';

/// Real, run coverage of per-project autosave (AppState.openProject +
/// saveNow/debounce) and the home screen's ProjectStore, against a real
/// temp directory.
void main() {
  late Directory tempDir;
  late ProjectStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_state_autosave_test');
    store = ProjectStore(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('a new project opens empty, at its chosen frame size, transparent', () async {
    final file = await store.create('Clip', 1920, 1080);
    final app = AppState();
    await app.openProject(file);

    expect(app.project.layers, isEmpty);
    expect(app.frameWidth, equals(1920));
    expect(app.frameHeight, equals(1080));
    expect(app.background, isNull);
    expect(app.projectName, equals('Clip'));
    app.dispose();
  });

  test('saveNow() round-trips edits, frame size, background and name through the project file', () async {
    final file = await store.create('A', 720, 1280);
    final seed = AppState();
    await seed.openProject(file);
    seed.addLayer('rect');
    seed.setMaxFrame(333);
    seed.setBackground(const Color(0xFF112233));
    await seed.saveNow();
    final layerIds = seed.project.layers.map((l) => l.id).toList();
    seed.dispose();

    final app = AppState();
    await app.openProject(file);
    expect(app.project.layers.map((l) => l.id).toList(), equals(layerIds));
    expect(app.maxFrame, equals(333));
    expect(app.frameWidth, equals(720));
    expect(app.frameHeight, equals(1280));
    expect(app.background, equals(const Color(0xFF112233)));
    expect(app.projectName, equals('A'));
    app.dispose();
  });

  test('a change after openProject debounce-writes the file on its own', () async {
    final file = await store.create('B', 480, 480);
    final app = AppState();
    await app.openProject(file);
    app.setMaxFrame(777);

    // the debounce is 1 real second.
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect((await file.readAsString()).contains('777'), isTrue);
    app.dispose();
  });

  test('a plain AppState() never writes anything', () async {
    final app = AppState();
    app.setMaxFrame(999);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await Directory('${tempDir.path}/projects').exists(), isFalse);
    app.dispose();
  });

  test('ProjectStore lists newest first, renames and deletes', () async {
    final a = await store.create('First', 480, 480);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final b = await store.create('Second', 1080, 1920);

    var list = await store.list();
    expect(list.map((m) => m.name).toList(), equals(['Second', 'First']));
    expect(list.first.frameWidth, equals(1080));
    expect(list.first.frameHeight, equals(1920));

    await store.rename(a, 'Renamed');
    await store.delete(b);
    list = await store.list();
    expect(list.map((m) => m.name).toList(), equals(['Renamed']));
  });

  test('the old single autosave.json becomes a regular project (nothing lost)', () async {
    final seed = AppState();
    final legacy = File('${tempDir.path}/autosave.json');
    await seed.openProject(legacy);
    seed.setMaxFrame(444);
    await seed.saveNow();
    seed.dispose();

    final list = await store.list();
    expect(list, hasLength(1));
    expect(await legacy.exists(), isFalse);

    final app = AppState();
    await app.openProject(list.single.file);
    expect(app.maxFrame, equals(444));
    app.dispose();
  });
}
