import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/io/project_store.dart';
import 'package:movement_mobile/io/save_load.dart';

/// The app closed while a project was being saved: it doesn't vanish.
void main() {
  late Directory dir;
  late ProjectStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('recover_');
    store = ProjectStore(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Project withLayers(int n) => Project(layers: [for (var i = 0; i < n; i++) createLayer('rect')..id = 'L$i'..name = 'L$i']);

  test('cut short after a save before it: the one before comes back', () async {
    final f = await store.create('Mine', 480, 480);
    await saveProjectToFile(f, withLayers(3), maxFrame: 60, playbackSpeed: 1, name: 'Mine');
    await saveProjectToFile(f, withLayers(4), maxFrame: 60, playbackSpeed: 1, name: 'Mine');
    final text = await f.readAsString();
    await f.writeAsString(text.substring(0, text.length ~/ 2));
    final metas = await store.list();
    expect(metas.single.name, 'Mine');
    expect((await loadProjectFromFile(metas.single.file)).project.layers.length, 3, reason: 'the last whole save');
  });

  test('cut short with nothing before it: what was written whole is read back', () async {
    final f = File('${dir.path}/projects/123.json');
    await f.parent.create(recursive: true);
    await saveProjectToFile(f, withLayers(5), maxFrame: 60, playbackSpeed: 1, name: 'Lost', keepBackup: false);
    final text = await f.readAsString();
    await f.writeAsString(text.substring(0, text.indexOf('"L3"')));
    final metas = await store.list();
    expect(metas.single.name, 'Lost (restored)');
    expect((await loadProjectFromFile(metas.single.file)).project.layers.length, greaterThanOrEqualTo(2));
    expect(await File('${f.path}.damaged').exists(), isTrue);
  });

  test('a deleted project does not come back from its side files', () async {
    final f = await store.create('Gone', 480, 480);
    await saveProjectToFile(f, withLayers(1), maxFrame: 60, playbackSpeed: 1, name: 'Gone');
    await store.delete(f);
    expect(await store.list(), isEmpty);
  });

  test('a file that cannot be read at all is listed as unreadable, not hidden', () async {
    final f = File('${dir.path}/projects/999.json');
    await f.parent.create(recursive: true);
    await f.writeAsString('');
    expect(await store.list(), isEmpty);
    expect(store.unreadable.single.size, 0);
  });
}
