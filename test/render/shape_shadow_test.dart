import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
void main() {
  test('a plain rect (no rounded corners) casts its shadow', () async {
    setStageSize(200, 200);
    final l = createLayer('rect')..content.size = [50, 50]..transform.anchor.defaultValue = [0.5, 0.5];
    l.fill.shadow..enabled = true..dx = 40..dy = 40..opacity = 1;
    final r = CanvasRenderer()..setSize(200, 200);
    r.backgroundColor = null;
    r.renderFrame(Project(layers: [l]), 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    expect(b.getUint8((140 * 200 + 140) * 4 + 3), greaterThan(200));
  });
}
