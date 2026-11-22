import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  test('edge glow in the own colours of the object: the halo outside it has its colour', () async {
    setStageSize(200, 200);
    clearStateCaches();
    final l = createLayer('rect')
      ..id = 'A'
      ..content.offset = [0, 0]
      ..content.size = [80, 80]
      ..color = '#ff0000';
    final g = createEffectInstance('edge_glow', 'g', null);
    g.params['colorFrom'] = 'edges';
    (g.params['radius'] as Track).defaultValue = 30.0;
    (g.params['strength'] as Track).defaultValue = 1.0;
    l.effectStack.add(g);
    final r = CanvasRenderer()
      ..setSize(200, 200)
      ..backgroundColor = const ui.Color(0xFF000000);
    r.renderFrame(Project(layers: [l]), 0);
    final img = await r.captureFrame();
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int at(int x, int y, int c) => px.getUint8((y * 200 + x) * 4 + c);
    // 8 px outside the right edge (x = 140 + 8): reddish, no blue / green.
    expect(at(148, 100, 0), greaterThan(40));
    expect(at(148, 100, 2), lessThan(10));
    expect(at(100, 100, 0), greaterThan(240), reason: 'the object itself as it was');
  });
}
