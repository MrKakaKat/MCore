import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/app_settings.dart';
import 'package:movement_mobile/io/project_store.dart';

/// Settings switched on are kept: the project's view settings in the
/// project (not leaking into another one), the app's editing preferences
/// in app_settings.json.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('ui_state_'));
  tearDown(() async {
    AppSettings.instance = null;
    await dir.delete(recursive: true);
  });

  test('a project keeps its view settings; another project opens with the defaults', () async {
    final store = ProjectStore(dir);
    final fileA = await store.create('A', 480, 480);
    final fileB = await store.create('B', 480, 480);

    final a = AppState();
    await a.openProject(fileA);
    a.toggleShowOffCanvasContent();
    a.toggleHideHandles();
    snapEnabled = true;
    snapEdgeToEdgeEnabled = true;
    a.setSnapSensitivityEdgeToEdgePx(15);
    gridOverlayEnabled = true;
    await a.saveNow();
    a.dispose();

    final b = AppState();
    await b.openProject(fileB);
    expect([b.showOffCanvasContent, hideHandles, snapEnabled, gridOverlayEnabled], [false, false, false, false],
        reason: 'nothing leaks from project A');
    b.dispose();

    final again = AppState();
    await again.openProject(fileA);
    expect(again.showOffCanvasContent, isTrue);
    expect(hideHandles, isTrue);
    expect(snapEnabled, isTrue);
    expect(snapEdgeToEdgeEnabled, isTrue);
    expect(again.snapSensitivityEdgeToEdgePx, 15);
    expect(gridOverlayEnabled, isTrue);
    again.dispose();
    AppState().dispose(); // back to defaults for other tests
  });

  test('editing preferences are the app\'s: kept across projects and restarts', () async {
    AppSettings.instance = AppSettings(File('${dir.path}/app_settings.json'));
    final a = AppState();
    a.toggleTimelineCenterPlayhead();
    a.toggleKeyframeSelectKeepsPlayhead();
    // the settings file is written in the background: wait for it (a
    // loaded machine can take longer than a fixed delay).
    final file = File('${dir.path}/app_settings.json');
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // the write with the new value (an earlier one may still hold the old).
      if (file.existsSync() && file.readAsStringSync().replaceAll(' ', '').contains('"keySelectKeepsPlayhead":true')) {
        break;
      }
    }
    a.dispose();

    final restarted = AppSettings(File('${dir.path}/app_settings.json'));
    await restarted.load();
    AppSettings.instance = restarted;
    final b = AppState();
    expect(b.timelineCenterPlayheadEnabled, isTrue);
    expect(b.keyframeSelectKeepsPlayhead, isTrue);
    b.dispose();
  });
}
