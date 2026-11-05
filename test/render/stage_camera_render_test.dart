import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('export sees the scene through the camera; the stage only in camera view', () async {
    final app = AppState()..setFrameSize(100, 100);
    app.project.layers.clear();
    app.renderer.backgroundColor = const ui.Color(0xFF000000);
    app.project.layers.add(createLayer('rect')
      ..id = 'r'
      ..color = '#ff0000'
      ..content.size = [20, 20]
      ..transform.anchor.defaultValue = [0.5, 0.5]);
    app.addStageCamera();
    final cam = activeCamera(app.project)!;
    cam.transform.anchor.defaultValue = [0.7, 0.5]; // 20 px right: the square shows 20 px left

    Future<List<int>> at(int x, int y) async {
      app.renderer.renderFrame(app.project, 0);
      final img = await app.renderer.captureFrame();
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      return [for (var c = 0; c < 3; c++) px.getUint8((y * 100 + x) * 4 + c)];
    }

    expect(await at(50, 50), [255, 0, 0], reason: 'the editor stage: the scene itself');
    app.setCameraView(true);
    expect(await at(30, 50), [255, 0, 0], reason: 'through the camera');
    expect(await at(55, 50), [0, 0, 0]);
    app.setCameraView(false);
    expect(app.renderer.useStageCamera, isFalse);
  });
}
