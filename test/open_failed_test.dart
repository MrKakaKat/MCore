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
}
