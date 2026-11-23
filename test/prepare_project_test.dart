import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  testWidgets('a project with pictures gets them ready first: play waits, then works', (tester) async {
    final dir = Directory.systemTemp.createTempSync('prep_');
    final path = (await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 32, 32), ui.Paint()..color = const ui.Color(0xFFFF0000));
      final img = await rec.endRecording().toImage(32, 32);
      final b = await img.toByteData(format: ui.ImageByteFormat.png);
      return (File('${dir.path}/a.png')..writeAsBytesSync(b!.buffer.asUint8List())).path;
    }))!;
    final app = AppState();
    app.project.layers.add(createImageLayer(imageSourceType: 'file', imagePath: path, naturalWidth: 32, naturalHeight: 32)
      ..id = 'img'
      ..durationFrames = 60);
    await tester.runAsync(() async {
      final done = app.prepareProject();
      expect(app.preparing, isTrue);
      expect(app.playLoading, isTrue);
      app.togglePlay();
      expect(app.playing, isFalse); // play waits for it
      await done.timeout(const Duration(seconds: 20));
    });
    expect(app.preparing, isFalse);
    expect(app.renderer.busy, isFalse);
    app.togglePlay();
    expect(app.playing, isTrue);
    app.togglePlay();
    app.dispose();
    await tester.pump(const Duration(seconds: 3));
    dir.deleteSync(recursive: true);
  });

  test('skip: getting ready stops at once, play works', () {
    final app = AppState()
      ..project.layers.add(createImageLayer(imageSourceType: 'file', imagePath: '/nope.png', naturalWidth: 8, naturalHeight: 8)
        ..id = 'img');
    unawaited(app.prepareProject());
    expect(app.preparing, isTrue);
    app.skipPreparing();
    expect(app.preparing, isFalse);
    app.togglePlay();
    expect(app.playing, isTrue);
    app.togglePlay();
  });

  test('a cut layer joined again from the app: one layer, one undo step', () {
    final app = AppState();
    final id = app.selection.selectedLayer!;
    final n = app.project.layers.length;
    app.setFrame(findLayer(app.project, id)!.startFrame + 10);
    app.splitLayerAtPlayhead(id);
    expect(app.project.layers.length, n + 1);
    app.joinWithNext(id);
    expect(app.project.layers.length, n);
    app.performUndo();
    expect(app.project.layers.length, n + 1);
  });
}
