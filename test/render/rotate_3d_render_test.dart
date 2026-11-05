import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/render/canvas_renderer.dart';

/// 3D Rotate on real rendered pixels (40x20 frame, one layer centred).
void main() {
  setUpAll(registerBuiltinEffects);

  Future<ByteData> render(Layer layer) async {
    registerBuiltinEffects();
    final project = createDefaultProject()..layers.clear();
    project.layers.add(layer);
    final renderer = CanvasRenderer()..setSize(40, 20);
    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  }

  int px(ByteData b, int x, int y, int channel) => b.getUint8((y * 40 + x) * 4 + channel);

  EffectInstance turn(Layer layer, double angle, {double shading = 0.3}) {
    final inst = createEffectInstance('rotate_3d', 'fx_3d', layer);
    (inst.params['angle'] as Track).defaultValue = angle;
    (inst.params['perspective'] as Track).defaultValue = 0.0;
    (inst.params['shading'] as Track).defaultValue = shading;
    layer.effectStack.add(inst);
    return inst;
  }

  test('turned 60 degrees: half as wide, and darkened by the shading', () async {
    final layer = createLayer('rect')
      ..color = '#ffffff'
      ..content.size = [40, 20];
    turn(layer, 60, shading: 1);
    final b = await render(layer);
    expect(px(b, 20, 10, 3), 255, reason: 'the centre is still covered');
    expect(px(b, 2, 10, 3), 0, reason: 'the edges moved in - half the width');
    expect(px(b, 20, 10, 0), closeTo(128, 3), reason: 'brightness 1 - 1*(1 - cos 60) = 0.5');
  });

  test('turned 180 degrees about the vertical axis: the shape shows mirrored', () async {
    Layer tri() => createLayer('rect')
      ..color = '#00ff00'
      ..content = Content(shape: 'polygon', offset: [0, 0], size: [40, 20], points: [
        [-20, -10],
        [-20, 10],
        [20, 10],
      ]);
    final flipped = tri();
    turn(flipped, 180);
    final b = await render(flipped);
    expect(px(b, 2, 3, 3), lessThan(40), reason: 'left edge near the top: now outside');
    expect(px(b, 37, 3, 3), greaterThan(200), reason: 'right edge near the top: now inside');
  });
}
