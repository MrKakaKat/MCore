import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Gradient fill: glows light the shape in their colour over its base
/// colour, fading to nothing at their radius, and never spill outside it.
void main() {
  const size = 200.0;
  setUpAll(registerBuiltinEffects);

  Future<Uint8List> render(Layer layer) async {
    final project = Project(layers: [layer]);
    final renderer = CanvasRenderer()..setSize(size, size);
    clearStateCaches();
    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  }

  List<int> px(Uint8List b, int x, int y) => b.sublist((y * size.toInt() + x) * 4, (y * size.toInt() + x) * 4 + 4);

  Layer square() {
    final l = createLayer('rect')
      ..id = 'sq'
      ..color = '#000000'
      ..content = Content(shape: 'rect', offset: [0, 0], size: [100, 100]);
    l.transform.anchor.defaultValue = [0.5, 0.5];
    return l;
  }

  test('a white point glow in the middle of a black square', () async {
    final l = square();
    addGlow(l, 'point'); // middle, radius half the side = 50 px
    final b = await render(l);
    expect(px(b, 100, 100)[0], greaterThan(245), reason: 'full at the centre');
    expect(px(b, 125, 100)[0], closeTo(255 * glowFalloff(0.5), 8), reason: 'half way out');
    expect(px(b, 52, 52)[0], lessThan(5), reason: 'nothing past the radius (corner)');
    expect(px(b, 52, 52)[3], 255, reason: 'the base colour is still there');
    expect(px(b, 40, 100)[3], 0, reason: 'never spills outside the shape');
  });

  test('a line glow: even along the line, fading across it', () async {
    final l = square();
    final g = addGlow(l, 'line', color: '#ff0000');
    g.radius.defaultValue = 0.2; // 20 px
    final b = await render(l);
    final along = [for (final x in [80, 100, 120]) px(b, x, 100)[0]];
    expect(along.every((v) => v > 240), isTrue, reason: '$along');
    expect(px(b, 100, 110)[0], closeTo(255 * glowFalloff(10.5 / 20), 8)); // pixel centre 10.5 px off the line
    expect(px(b, 100, 125)[0], lessThan(5));
    expect(px(b, 100, 100)[1], lessThan(5), reason: 'red, not white');
  });

  test('strength and switching the gradient off', () async {
    final l = square();
    final g = addGlow(l, 'point');
    g.strength.defaultValue = 0.5;
    expect(px(await render(l), 100, 100)[0], closeTo(128, 4));
    l.fill.gradient = false;
    expect(px(await render(l), 100, 100)[0], 0, reason: 'plain colour again');
  });

  test('the glow bends with the shape under a deforming effect', () async {
    final l = square();
    final g = addGlow(l, 'point');
    g.position.defaultValue = [0.5, 0.1];
    g.radius.defaultValue = 0.15;
    l.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', l));
    final b = await render(l);
    var bright = 0;
    for (var y = 50; y < 150; y++) {
      for (var x = 50; x < 150; x++) {
        if (px(b, x, y)[0] > 200) bright++;
      }
    }
    expect(bright, greaterThan(20), reason: 'still lit through the texture path');
  });
}
