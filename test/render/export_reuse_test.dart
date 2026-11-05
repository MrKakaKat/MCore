import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  setUpAll(registerBuiltinEffects);

  test('export reuse: still layers drawn once give the very same frames', () async {
    final app = AppState()..setFrameSize(100, 100);
    app.project.layers.clear();
    final still = createLayer('rect')
      ..id = 'still'
      ..color = '#ff0000'
      ..content.size = [40, 40]
      ..transform.anchor.defaultValue = [0.3, 0.5];
    final moving = createLayer('circle')
      ..id = 'moving'
      ..color = '#00ff00'
      ..transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.2, 0.2]),
        Keyframe(frame: 20, value: [0.8, 0.8]),
      ]);
    final child = createLayer('rect')
      ..id = 'child'
      ..parentId = 'moving'
      ..content.size = [10, 10];
    app.project.layers.addAll([still, moving, child]);
    expect(layerIsStill(app.project, still), isTrue);
    expect(layerIsStill(app.project, moving), isFalse);
    expect(layerIsStill(app.project, child), isFalse, reason: 'its parent moves');

    Future<Uint8List> frame(int f) async {
      app.renderer.renderFrame(app.project, f);
      final img = await app.renderer.captureFrame();
      return (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
    }

    final plain = [for (final f in [0, 7, 20]) await frame(f)];
    app.renderer.beginExportReuse(app.project);
    final reused = [for (final f in [0, 7, 20]) await frame(f)];
    app.renderer.endExportReuse();
    for (var i = 0; i < 3; i++) {
      expect(reused[i], plain[i], reason: 'frame $i');
    }
  });
}
