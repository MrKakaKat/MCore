import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('a project file that does not load is never saved over', () async {
    final dir = Directory.systemTemp.createTempSync('open_fail_');
    try {
      final f = File('${dir.path}/p.json')..writeAsStringSync('{"version":1,"project":{"layers":[{"broken":');
      final before = f.readAsStringSync();
      final app = AppState();
      expect(await app.openProject(f), isFalse);
      expect(app.openError, isNotNull);
      app.addLayer('rect');
      await app.saveNow();
      expect(f.readAsStringSync(), before);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('saves asked for at once are written one after another, the last state kept', () async {
    final dir = Directory.systemTemp.createTempSync('save_twice_');
    try {
      final f = File('${dir.path}/p.json');
      final app = AppState();
      expect(await app.openProject(f), isTrue); // new: saved here from now on
      app.addLayer('rect');
      final a = app.saveNow();
      app.addLayer('circle');
      final b = app.saveNow();
      await Future.wait([a, b]);
      final again = AppState();
      expect(await again.openProject(f), isTrue);
      expect(again.project.layers.length, app.project.layers.length);
      expect(File('${f.path}.tmp').existsSync(), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
