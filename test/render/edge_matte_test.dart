import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// Edge matte "lighten": a white square on a black one (merged), over a
/// red background - the black is taken out, the white stays.
void main() {
  setUpAll(registerBuiltinEffects);

  test('lighten takes the black out of the picture', () async {
    final app = AppState()..setFrameSize(100, 100);
    app.project.layers.clear();
    app.renderer.backgroundColor = null;
    app.project.layers.add(createLayer('rect')
      ..id = 'bg'
      ..color = '#ff0000'
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5]);
    Layer sq(String id, String color, double size) => createLayer('rect')
      ..id = id
      ..color = color
      ..content.size = [size, size]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final shapes = [sq('k', '#000000', 80), sq('w', '#ffffff', 30)];
    app.project.layers.addAll(shapes);
    final m = mergeLayers(app.project, shapes, 'm', 0)!;
    m
      ..edgeMatte = true
      ..edgeMatteColor = '#000000'
      ..edgeMatteStrength = 1;
    final orig = app.renderer.onImageDecoded;
    for (var i = 0; i < 4; i++) {
      final ready = Completer<void>();
      app.renderer.onImageDecoded = () {
        orig?.call();
        if (!ready.isCompleted) ready.complete();
      };
      app.commitEdit();
      await ready.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    app.commitEdit();
    final out = await app.renderer.captureFrame();
    final px = (await out.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    List<int> at(int x, int y) => [for (var c = 0; c < 3; c++) px.getUint8((y * 100 + x) * 4 + c)];
    expect(at(20, 50), [255, 0, 0], reason: 'the black part is see-through');
    expect(at(50, 50), [255, 255, 255], reason: 'the white stays');
  });
}
