import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Crop and mirror, checked on real rendered pixels. A 40x20 frame with
/// one layer centred in it; content-local (0,0) is the frame centre.
void main() {
  Future<ByteDataReader> render(Layer layer) async {
    registerBuiltinEffects();
    final project = createDefaultProject()..layers.clear();
    project.layers.add(layer);
    final renderer = CanvasRenderer()..setSize(40, 20);
    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    return ByteDataReader((await image.toByteData(format: ui.ImageByteFormat.rawRgba))!, 40);
  }

  test('a cropped rect leaves the cut-off side transparent', () async {
    final layer = createLayer('rect')
      ..color = '#ff0000'
      ..content.size = [40, 20]
      ..crop = [0, 0, 0.5, 0]; // right half cut away
    final px = await render(layer);
    expect(px.alpha(5, 10), 255, reason: 'the left half still draws');
    expect(px.alpha(35, 10), 0, reason: 'the right half is cropped');
  });

  test('mirror flips the content about its own centre', () async {
    // a right triangle filling the left-bottom corner of its box
    // (polygon points are content-local).
    Layer tri() => createLayer('rect')
      ..color = '#00ff00'
      ..content = Content(shape: 'polygon', offset: [0, 0], size: [40, 20], points: [
        [-20, -10],
        [-20, 10],
        [20, 10],
      ]);
    final plain = await render(tri());
    expect(plain.alpha(2, 3), 255, reason: 'left edge column, near the top: inside');
    expect(plain.alpha(37, 3), 0, reason: 'right edge, near the top: outside');

    final flipped = await render(tri()..mirrorX = true);
    expect(flipped.alpha(2, 3), 0);
    expect(flipped.alpha(37, 3), 255);
  });
}

class ByteDataReader {
  final ByteData bytes;
  final int width;
  ByteDataReader(this.bytes, this.width);
  int alpha(int x, int y) => bytes.getUint8((y * width + x) * 4 + 3);
}
