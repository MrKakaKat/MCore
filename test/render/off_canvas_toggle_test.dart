import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Real, run coverage of CanvasRenderer.renderFrame's new `clipToFrame`
/// parameter (AppState.showOffCanvasContent's toggle -). Unlike
/// off_canvas_export_test.dart (which only ever exercises the DEFAULT,
/// always-clipped export path - the same guarantee PNG export must keep
/// regardless of this toggle), these tests capture the recorder's raw
/// `currentPicture` directly at a size LARGER than the frame, the only way to
/// actually observe content drawn beyond [0,width)x[0,height):
/// `captureFrame`/`Picture.toImage(w,h)` always maps the picture's own origin
/// to image pixel (0,0) and rasterizes only [0,w)x[0,h) of it, so a plain
/// export-sized capture can never show anything about content laid out in
/// POSITIVE space beyond the frame either way - the difference this toggle
/// makes only shows up once you capture a wider canvas than the nominal frame.
void main() {
  test(
      'clipToFrame=false actually paints a layer positioned beyond the frame edge; clipToFrame=true (the default) does not',
      () async {
    registerBuiltinEffects();
    final project = createDefaultProject();
    project.layers.clear();
    final renderer = CanvasRenderer();
    renderer.setSize(64, 40);

    final layer = createLayer('rect');
    layer.color = '#ff0000';
    // anchor at 1.5x frame width -> screen x=96, comfortably beyond the
    // 64px frame but still within the 3x-wide capture below (192px).
    layer.transform.anchor.defaultValue = [1.5, 0.5];
    project.layers.add(layer);

    Future<bool> offCanvasPixelPainted() async {
      final picture = renderer.currentPicture!;
      final image = await picture.toImage(192,
          120); // 3x width/height - matches the off-canvas cull rect's own multiplier
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      const x = 96,
          y = 20; // the layer's own anchor position in this wider capture (1.5*64, 0.5*40)
      const i = (y * 192 + x) * 4;
      return bytes.getUint8(i + 3) != 0; // alpha channel
    }

    renderer.renderFrame(project, 0, clipToFrame: false);
    expect(await offCanvasPixelPainted(), isTrue,
        reason: 'clipToFrame=false must let off-canvas content actually paint');

    renderer.renderFrame(project, 0); // default clipToFrame=true
    expect(await offCanvasPixelPainted(), isFalse,
        reason:
            'the default must stay clipped to the true frame - the same guarantee export always had');
  });

  test(
      'clipToFrame=false never changes what captureFrame() itself returns - export stays exactly frame-sized either way',
      () async {
    registerBuiltinEffects();
    final project = createDefaultProject();
    project.layers.clear();
    final renderer = CanvasRenderer();
    renderer.setSize(64, 40);
    final layer = createLayer('rect');
    layer.transform.anchor.defaultValue = [1.5, 0.5];
    project.layers.add(layer);

    renderer.renderFrame(project, 0, clipToFrame: false);
    final image = await renderer.captureFrame();
    expect(image.width, equals(64));
    expect(image.height, equals(40));
  });
}
