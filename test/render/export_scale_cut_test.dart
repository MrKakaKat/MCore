import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  test('outputScale renders the frame bigger (even sizes), the picture scaled with it', () async {
    setStageSize(100, 50);
    final l = createLayer('rect')
      ..color = '#ff0000'
      ..content.size = [20, 20]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final r = CanvasRenderer()..setSize(100, 50);
    r.backgroundColor = null;
    r.outputScale = 1620 / 50;
    expect(r.pixelHeight, 1620);
    expect(r.pixelWidth, 3240);
    r.renderFrame(Project(layers: [l]), 0);
    final img = await r.captureFrame();
    expect(img.width, 3240);
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    expect(b.getUint8((810 * 3240 + 1620) * 4), 255, reason: 'the middle is red');
  });

  test('stage cuts hole the layer only, not what is under it', () async {
    setStageSize(100, 100);
    final under = createLayer('rect')
      ..id = 'u'
      ..color = '#0000ff'
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final top = createLayer('rect')
      ..id = 't'
      ..color = '#ff0000'
      ..content.size = [60, 60]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final r = CanvasRenderer()..setSize(100, 100);
    r.stageCuts = (p, layer, f) =>
        layer.id == 't' ? [ui.Path()..addRect(const ui.Rect.fromLTWH(45, 45, 10, 10))] : const [];
    r.renderFrame(Project(layers: [under, top]), 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    List<int> px(int x, int y) => [for (var c = 0; c < 3; c++) b.getUint8((y * 100 + x) * 4 + c)];
    expect(px(50, 50), [0, 0, 255], reason: 'the hole shows the blue layer under it');
    expect(px(35, 35), [255, 0, 0]);
  });
}
