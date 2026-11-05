import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  test('an imported gradient rect: red at its left end, blue at its right; stop-opacity 0 is see-through', () async {
    setStageSize(200, 100);
    final r = importShapesFromSvg('''<svg><defs><linearGradient id="g">
      <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient>
      <linearGradient id="f" x2="0" y2="1"><stop offset="0" stop-color="#00ff00" stop-opacity="0"/>
      <stop offset="1" stop-color="#00ff00"/></linearGradient></defs>
      <rect x="0" y="0" width="200" height="50" fill="url(#g)"/>
      <rect x="0" y="50" width="200" height="50" fill="url(#f)"/></svg>''');
    final rd = CanvasRenderer()..setSize(200, 100);
    rd.backgroundColor = null;
    rd.renderFrame(Project(layers: r.layers), 0);
    final img = await rd.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    List<int> px(int x, int y) => [for (var c = 0; c < 4; c++) b.getUint8((y * 200 + x) * 4 + c)];
    final left = px(1, 25), right = px(198, 25);
    expect(left[0], greaterThan(240));
    expect(left[2], lessThan(15));
    expect(right[2], greaterThan(240));
    expect(right[0], lessThan(15));
    expect(px(100, 51)[3], lessThan(15), reason: 'transparent top of the second rect');
    expect(px(100, 98)[1], greaterThan(230));
  });
}
