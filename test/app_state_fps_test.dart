import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/export.dart';
import 'package:movement_mobile/io/save_load.dart';
import 'package:movement_mobile/ui/settings/settings_view.dart';

void main() {
  tearDown(() => fps = 60);

  test('setProjectFps re-times the project and the playhead, and clears undo', () {
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.transform.opacity.keyframes.add(Keyframe(frame: 60, value: 0.5));
    app.setFrame(60);
    app.pushUndo();
    app.setProjectFps(30);
    expect(fps, 30);
    expect(findLayer(app.project, layer.id)!.transform.opacity.keyframes.single.frame, 30);
    expect(app.currentFrame, 30);
    expect(app.maxFrame, 90, reason: 'the default 180-frame layers are 3 s');
    expect(app.undo.canUndo, isFalse);
  });

  test('the frame rate is saved with the project', () async {
    final dir = Directory.systemTemp.createTempSync('fps_save');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/p.json');
    await saveProjectToFile(file, Project(), maxFrame: 10, playbackSpeed: 1, projectFps: 24);
    expect((await loadProjectFromFile(file)).fps, 24);
    await saveProjectToFile(file, Project(), maxFrame: 10, playbackSpeed: 1);
    expect((await loadProjectFromFile(file)).fps, 60, reason: 'older files: 60');
  });

  test('exports sample the timeline by time', () {
    fps = 60;
    expect(exportFrameNumbers(0, 60, 30), [for (var i = 0; i <= 30; i++) i * 2]);
    fps = 24;
    expect(exportFrameNumbers(0, 24, 24).length, 25);
    expect(exportFrameNumbers(0, 24, 12), [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24]);
  });

  testWidgets('Settings: frame rate dropdown', (tester) async {
    final app = AppState();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsView(app: app))));
    expect(find.text('60 fps'), findsOneWidget);
    await tester.tap(find.text('60 fps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('24 fps').last);
    await tester.pumpAndSettle();
    expect(fps, 24);
    expect(find.text('24 fps'), findsOneWidget);
  });
}
