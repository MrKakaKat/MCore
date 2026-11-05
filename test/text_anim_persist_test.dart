import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/project_store.dart';

void main() {
  test('text animators survive undo, redo and reopening the project', () async {
    final dir = Directory.systemTemp.createTempSync('anim_persist');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ProjectStore(dir);
    final file = await store.create('T', 400, 400);
    var app = AppState()..projectStore = store;
    await app.openProject(file);
    app.addTextLayer();
    final id = app.project.layers.last.id;
    app.addTextAnimator(id, 'Wave');
    app.pushUndo();
    findLayer(app.project, id)!.content.text!.animators.first.unit = 'word';
    app.commitEdit();
    app.performUndo();
    var t = findLayer(app.project, id)!.content.text!;
    expect(t.animators, hasLength(1));
    expect(t.animators.first.unit, 'char');
    app.performRedo();
    t = findLayer(app.project, id)!.content.text!;
    expect(t.animators.first.unit, 'word');
    expect(t.animators.first.range.offset.keyframes, isNotEmpty);
    await app.saveNow();
    app.dispose();
    app = AppState()..projectStore = store;
    await app.openProject(file);
    t = findLayer(app.project, id)!.content.text!;
    expect(t.animators.single.name, 'Wave');
    expect(t.animators.single.unit, 'word');
    expect(t.animators.single.range.offset.keyframes, isNotEmpty);
    app.dispose();
  });
}
