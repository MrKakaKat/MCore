import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/io/save_load.dart';

/// Real, run round-trip coverage for save_load.dart - this logic was
/// already correct and tested-by-inspection, but never actually
/// exercised against a real file on disk before this round (it also
/// backs the new autosave feature, see app_state_autosave_test.dart).
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('save_load_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('saveProjectToFile then loadProjectFromFile round-trips maxFrame/playbackSpeed/selectedLayer and layers', () async {
    final project = createDefaultProject();
    final file = File('${tempDir.path}/project.json');

    await saveProjectToFile(file, project, maxFrame: 240, playbackSpeed: 1.5, selectedLayer: project.layers.first.id);

    final loaded = await loadProjectFromFile(file);

    expect(loaded.maxFrame, equals(240));
    expect(loaded.playbackSpeed, equals(1.5));
    expect(loaded.selectedLayer, equals(project.layers.first.id));
    expect(loaded.project.layers.map((l) => l.id).toList(), equals(project.layers.map((l) => l.id).toList()));
  });

  test('loadProjectFromFile rejects a file that is not a recognized project export', () async {
    final file = File('${tempDir.path}/not_a_project.json');
    await file.writeAsString('{"foo": "bar"}');

    expect(() => loadProjectFromFile(file), throwsFormatException);
  });

  test('timelineLength round-trips, and an older file without it loads as null', () async {
    final project = createDefaultProject();
    final file = File('${tempDir.path}/project.json');
    await saveProjectToFile(file, project, maxFrame: 240, playbackSpeed: 1, timelineLength: 240);
    expect((await loadProjectFromFile(file)).timelineLength, equals(240));

    await saveProjectToFile(file, project, maxFrame: 240, playbackSpeed: 1);
    expect((await loadProjectFromFile(file)).timelineLength, isNull);
  });
}
