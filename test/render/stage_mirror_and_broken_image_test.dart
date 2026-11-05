import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/save_load.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

/// Stage mirror (whole frame, exports too) and the renderer's handling of
/// an image that fails to decode.
void main() {
  test('an exported frame is mirrored: a rect on the left lands on the right', () async {
    registerBuiltinEffects();
    final project = createDefaultProject()..layers.clear();
    final layer = createLayer('rect')
      ..color = '#ff0000'
      ..content.size = [10, 20];
    layer.transform.anchor.defaultValue = [0.125, 0.5]; // x = 5 of 40
    project.layers.add(layer);
    final renderer = CanvasRenderer()..setSize(40, 20);
    renderer.renderFrame(project, 0);

    Future<int> alphaAt(int x) async {
      final img = await renderer.captureFrame();
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return bytes.getUint8((10 * 40 + x) * 4 + 3);
    }

    expect(await alphaAt(3), 255);
    expect(await alphaAt(36), 0);
    renderer.mirrorX = true;
    expect(await alphaAt(3), 0);
    expect(await alphaAt(36), 255);
  });

  test('the stage camera maps frame points through the mirror, both ways', () {
    final cam = StageCamera()
      ..updateLayout(frame: const ui.Size(400, 200), viewport: const ui.Size(400, 200))
      ..mirrorX = true;
    final screen = cam.frameToScreen(const ui.Offset(50, 30));
    expect(screen.dx, closeTo(350, 1e-9));
    expect(cam.screenToFrame(screen), const ui.Offset(50, 30));
  });

  test('with the stage mirrored, a handle is grabbed where it is drawn (its mirrored spot)', () {
    final app = AppState();
    addTearDown(app.dispose);
    setStageSize(app.frameWidth, app.frameHeight);
    final layer = app.project.layers.last;
    app.selectLayer(layer.id);
    final cam = StageCamera()
      ..updateLayout(frame: ui.Size(app.frameWidth, app.frameHeight), viewport: ui.Size(app.frameWidth, app.frameHeight))
      ..mirrorX = true;
    final controller = StageGestureController(app: app, camera: cam, onNeedsRepaint: () {});
    final move = getTransformBoxHandles(app.project, layer, 0).screen['moveCorner']!;
    final onScreen = cam.frameToScreen(ui.Offset(move[0], move[1]));
    controller.onPointerDown(PointerDownEvent(pointer: 1, position: onScreen));
    expect(controller.activeDrag?.activeKey, 'moveCorner');
  });

  test('stage mirror is saved with the project', () async {
    final dir = Directory.systemTemp.createTempSync('mirror_save');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/p.json');
    await saveProjectToFile(file, createDefaultProject(), maxFrame: 10, playbackSpeed: 1, mirrorY: true);
    final data = await loadProjectFromFile(file);
    expect([data.mirrorX, data.mirrorY], [false, true]);
  });

  test('a broken image is decoded once, marked failed, and retried only on request', () async {
    final project = createDefaultProject()..layers.clear();
    final layer = createImageLayer(
        imageSourceType: 'embedded', imageData: 'bm90IGFuIGltYWdl', naturalWidth: 10, naturalHeight: 10);
    project.layers.add(layer);
    final renderer = CanvasRenderer()..setSize(40, 20);

    renderer.renderFrame(project, 0);
    for (var i = 0; i < 200 && !renderer.isImageFailed(layer.content); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(renderer.isImageFailed(layer.content), isTrue);
    expect(renderer.decodeAttempts, 1);

    renderer.renderFrame(project, 0);
    renderer.renderFrame(project, 0);
    expect(renderer.decodeAttempts, 1, reason: 'no retry on every render');

    renderer.retryImage(layer.content);
    renderer.renderFrame(project, 0);
    expect(renderer.decodeAttempts, 2);
  });
}
