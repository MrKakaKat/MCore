import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/project_store.dart';

/// Project references (model/project_ref.dart) in the app: ids and
/// revisions in the project files, a reference showing its source's
/// latest save, the "updated" badge, cycles refused, Show in context.
void main() {
  late Directory tempDir;
  late ProjectStore store;

  setUp(() {
    registerBuiltinEffects();
    tempDir = Directory.systemTemp.createTempSync('project_ref_app_test');
    store = ProjectStore(tempDir);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<AppState> open(File file) async {
    final app = AppState()..projectStore = store;
    await app.openProject(file);
    return app;
  }

  Future<String> idOf(File file) async => (jsonDecode(await file.readAsString()) as Map)['id'] as String;
  Future<int> revisionOf(File file) async => (jsonDecode(await file.readAsString()) as Map)['revision'] as int;

  Future<List<int>> pixelAt(AppState app, int x, int y) async {
    app.setFrame(app.currentFrame); // a fresh render
    final image = await app.renderer.captureFrame();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final i = (y * image.width + x) * 4;
    return [for (var k = 0; k < 4; k++) bytes.getUint8(i + k)];
  }

  test('a project id survives rename and save; a duplicate gets a new one; the revision counts changed saves', () async {
    final file = await store.create('A', 200, 100);
    final id = await idOf(file);
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    await store.rename(file, 'A2');
    expect(await idOf(file), id);
    final app = await open(file);
    final r0 = await revisionOf(file);
    app.addLayer('rect');
    await app.saveNow();
    expect(await idOf(file), id);
    expect(await revisionOf(file), r0 + 1);
    // nothing changed since: the revision and the file's date stay (the
    // project keeps its place in the list).
    final date = await file.lastModified();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await app.saveNow();
    expect(await revisionOf(file), r0 + 1);
    expect(await file.lastModified(), date);
    app.addLayer('circle');
    await app.saveNow();
    expect(await revisionOf(file), r0 + 2);
    app.dispose();
    final copy = await store.duplicate(file);
    expect(await idOf(copy), isNot(id));
    expect(await revisionOf(copy), 0);
  });

  test('files saved before ids get one on first load, kept from then on', () async {
    final file = await store.create('Old', 100, 100);
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>..remove('id');
    await file.writeAsString(jsonEncode(data));
    final metas = await store.list();
    final id = metas.single.id;
    expect(await idOf(file), id);
    expect((await store.list()).single.id, id);
  });

  test('edit A, save, open B: B shows the change and the "updated" badge', () async {
    final a = await store.create('A', 100, 100);
    final b = await store.create('B', 100, 100);
    final aId = await idOf(a);

    var app = await open(a);
    app.setBackground(const ui.Color(0xFFFF0000));
    await app.saveNow();
    app.dispose();

    app = await open(b);
    expect(await app.addProjectRef(aId), isNull);
    final ref = app.project.layers.single;
    expect(ref.content.shape, 'projectRef');
    expect(ref.content.size, [100, 100]);
    expect(app.refUpdatedLayer(ref), isFalse);
    expect(await pixelAt(app, 50, 50), [255, 0, 0, 255]);
    await app.saveNow();
    app.dispose();

    app = await open(a);
    app.setBackground(const ui.Color(0xFF00FF00));
    await app.saveNow();
    app.dispose();

    app = await open(b);
    final again = app.project.layers.single;
    expect(app.refUpdatedLayer(again), isTrue, reason: 'A was saved since B last saw it');
    expect(await pixelAt(app, 50, 50), [0, 255, 0, 255]);
    app.acknowledgeRefUpdate(again.id);
    expect(app.refUpdatedLayer(again), isFalse);
    app.dispose();
  });

  test('A may not take B when B already shows A; a deleted source is a placeholder', () async {
    final a = await store.create('A', 100, 100);
    final b = await store.create('B', 100, 100);
    final aId = await idOf(a), bId = await idOf(b);
    var app = await open(b);
    await app.addProjectRef(aId);
    await app.saveNow();
    app.dispose();

    app = await open(a);
    expect(await app.addProjectRef(bId), refCycleMessage);
    expect(await app.addProjectRef(aId), refCycleMessage, reason: 'itself');
    expect(app.project.layers, isEmpty);
    app.dispose();

    await store.delete(a);
    app = await open(b);
    final ref = app.project.layers.single;
    expect(app.renderer.refPlaceholder(ref), 'Project not found');
    app.dispose();
  });

  test('unlink keeps a frozen copy: later saves of the source no longer show', () async {
    final a = await store.create('A', 100, 100);
    final b = await store.create('B', 100, 100);
    final aId = await idOf(a);
    var app = await open(a);
    app.setBackground(const ui.Color(0xFFFF0000));
    await app.saveNow();
    app.dispose();

    app = await open(b);
    await app.addProjectRef(aId);
    final ref = app.project.layers.single;
    await app.unlinkProjectRefLayer(ref.id);
    expect(ref.content.refEmbedded, isNotNull);
    await app.saveNow();
    app.performUndo();
    expect(app.project.layers.single.content.refEmbedded, isNull, reason: 'one undo step');
    app.performRedo();
    await app.saveNow();
    app.dispose();

    app = await open(a);
    app.setBackground(const ui.Color(0xFF00FF00));
    await app.saveNow();
    app.dispose();

    app = await open(b);
    expect(await pixelAt(app, 50, 50), [255, 0, 0, 255]);
    app.dispose();
  });

  test('show in context: the host is drawn behind with this project\'s unsaved state', () async {
    final a = await store.create('A', 100, 100);
    final b = await store.create('B', 200, 200);
    final aId = await idOf(a), bId = await idOf(b);

    var app = await open(b);
    app.setBackground(const ui.Color(0xFF0000FF));
    // B's left half red, under the reference.
    app.addLayer('rect');
    final half = app.project.layers.last
      ..color = '#ff0000'
      ..transform.anchor.defaultValue = [0.25, 0.5];
    half.content
      ..offset = [0, 0]
      ..size = [100, 200];
    await app.addProjectRef(aId);
    await app.saveNow();
    app.dispose();

    app = await open(a);
    app.addLayer('rect'); // unsaved
    await app.showInContext(bId);
    expect(app.contextInstances, hasLength(1));
    app.setContextLook(opacity: 1, resolution: 1);
    final px = await pixelAt(app, 90, 5);
    expect(px[2], greaterThan(200), reason: 'B\'s blue background, behind A\'s transparent frame');
    // A (100 px) sits on all of B (200 px): A's x 25 is B's x 50 (red),
    // A's x 75 is B's x 150 (blue).
    expect(await pixelAt(app, 25, 50), [255, 0, 0, 255]);
    expect(await pixelAt(app, 75, 50), [0, 0, 255, 255]);
    final live = app.contextSourceOf(app.projectId)!;
    expect(identical(live.project, app.project), isTrue);
    expect(live.project.layers, hasLength(1), reason: 'the unsaved rect is in what B draws');

    app.setContextVisible(false);
    expect((await pixelAt(app, 2, 2))[3], 0, reason: 'hidden: A alone, transparent');
    app.hideContext();
    app.dispose();
  });
}
