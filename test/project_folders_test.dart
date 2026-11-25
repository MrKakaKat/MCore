import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/project_store.dart';

void main() {
  late Directory dir;
  late ProjectStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('folders_');
    store = ProjectStore(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('projects put into a folder, renamed, taken out, ungrouped', () async {
    final a = await store.create('A', 100, 100);
    final b = await store.create('B', 100, 100);
    final metas = await store.list();
    final ida = metas.firstWhere((m) => m.file.path == a.path).id, idb = metas.firstWhere((m) => m.file.path == b.path).id;
    await store.setFolder([ida, idb], 'Shots');
    expect(await store.folders(), {ida: 'Shots', idb: 'Shots'});
    await store.renameFolder('Shots', 'Scenes');
    expect((await store.folders()).values.toSet(), {'Scenes'});
    await store.setFolder([ida], null);
    expect(await store.folders(), {idb: 'Scenes'});
    await store.ungroupFolder('Scenes');
    expect(await store.folders(), isEmpty);
  });

  test('a new project has a timeline to work on (not a frame or two)', () async {
    final f = await store.create('New', 1080, 1080, fps: 30);
    final app = AppState();
    expect(await app.openProject(f), isTrue);
    expect(app.maxFrame, greaterThanOrEqualTo(89));
    app.addLayer('rect');
    expect(app.project.layers.single.durationFrames, greaterThan(60));
  });

  test('previous versions: an empty save puts the full one aside; a version restored', () async {
    final f = await store.create('P', 100, 100);
    final app = AppState();
    expect(await app.openProject(f), isTrue);
    app.addLayer('rect');
    app.addLayer('circle');
    await app.saveNow();
    expect(projectFileLayerCount(await f.readAsString()), 2);
    app.project.layers.clear();
    app.notifyListeners();
    await app.saveNow();
    expect(projectFileLayerCount(await f.readAsString()), 0);
    final versions = await store.versionsOf(f);
    final kept = versions.firstWhere((v) => v.label.startsWith('Before it was saved empty'));
    expect(kept.layers, 2);
    await store.restoreVersion(f, kept.file);
    expect(projectFileLayerCount(await f.readAsString()), 2);
    expect((await store.versionsOf(f)).any((v) => v.label.startsWith('Before the last restore') && v.layers == 0), isTrue);
  });
}
