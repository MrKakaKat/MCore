import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/project_history.dart';
import 'package:movement_mobile/io/project_store.dart';

String projectText(int layers, {String id = 'P1'}) => jsonEncode({
      'id': id,
      'name': 'p',
      'project': {
        'layers': [for (var i = 0; i < layers; i++) {'id': 'L$i'}]
      }
    });

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('history_test_'));
  tearDown(() async => root.delete(recursive: true));

  test('a version each time; the same text twice is one; the oldest go past the limit', () async {
    final h = await ProjectHistory.of(root, 'P1');
    for (var i = 1; i <= 4; i++) {
      await h.record(projectText(i), keepMain: 3);
    }
    expect(await h.record(projectText(4), keepMain: 3), isNull, reason: 'nothing changed');
    final again = await ProjectHistory.of(root, 'P1');
    expect(again.main.map((e) => e.layers), [4, 3, 2], reason: 'newest first, 3 kept');
    expect(Directory('${root.path}/history/P1').listSync().length, 4, reason: '3 versions + the index');
  });

  test('going back keeps what was there and the later versions; new ones go into a branch of 5', () async {
    final f = File('${root.path}/p.json')..writeAsStringSync(projectText(9));
    final h = await ProjectHistory.of(root, 'P1');
    for (var i = 1; i <= 3; i++) {
      await h.record(projectText(i));
    }
    final old = h.main.last; // 1 layer
    await h.restore(f, old, keepBranch: 2);
    expect(projectFileLayerCount(f.readAsStringSync()), 1, reason: 'the file is that version');
    expect(h.main.map((e) => e.layers), [9, 3, 2, 1], reason: 'what was there (9) kept, later ones too');
    expect(h.branchesFrom(old.id).length, 1);
    final b = h.active!;
    for (var i = 20; i <= 23; i++) {
      await h.record(projectText(i), keepBranch: 2);
    }
    expect(h.inBranch(b).map((e) => e.layers), [23, 22], reason: 'the branch keeps its newest 2');
    expect(h.main.length, 4, reason: 'the main line is untouched by the branch');
  });

  test('a copy of the project takes its versions along', () async {
    final store = ProjectStore(root);
    final f = File('${root.path}/projects/1.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(projectText(2));
    await (await ProjectHistory.of(root, 'P1')).record(projectText(1));
    final copy = await store.duplicate(f);
    final id = (jsonDecode(copy.readAsStringSync()) as Map)['id'] as String;
    expect(id, isNot('P1'));
    expect((await ProjectHistory.of(root, id)).main.single.layers, 1);
    // gone for good: its versions too.
    await store.delete(copy);
    expect(Directory('${root.path}/history/$id').existsSync(), isFalse);
  });
}
