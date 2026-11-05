import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// The chroma key end to end through the renderer: a real decoded image,
/// keyed off-thread, drawn with the keyed pixels transparent. One image
/// decode only (this sandbox's flutter_tester hangs on a second one per
/// file - see app_state_image_layer_test.dart).
void main() {
  test('green half keyed out, red half kept', () async {
    // 8x4 source: left half pure green, right half pure red.
    final rec = ui.PictureRecorder();
    ui.Canvas(rec)
      ..drawRect(const ui.Rect.fromLTWH(0, 0, 4, 4), ui.Paint()..color = const ui.Color(0xFF00FF00))
      ..drawRect(const ui.Rect.fromLTWH(4, 0, 4, 4), ui.Paint()..color = const ui.Color(0xFFFF0000));
    final src = await rec.endRecording().toImage(8, 4);
    final png = (await src.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

    final layer = Layer(
      id: 'L_img',
      name: 'img',
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(
        shape: 'image',
        offset: [0, 0],
        size: [80, 40],
        imageSourceType: 'embedded',
        imageData: base64Encode(png),
        imageNaturalWidth: 8,
        imageNaturalHeight: 4,
      ),
      chromaKey: ChromaKey(enabled: true, color: '#00ff00', strength: 0.3, softness: 0.05),
    );
    final project = Project(layers: [layer]);
    final r = CanvasRenderer()..setSize(100, 100);
    var ready = Completer<void>();
    r.onImageDecoded = () {
      if (!ready.isCompleted) ready.complete();
    };

    r.renderFrame(project, 0); // starts the decode
    await ready.future.timeout(const Duration(seconds: 10));
    ready = Completer<void>();
    r.renderFrame(project, 0); // decoded -> starts keying
    await ready.future.timeout(const Duration(seconds: 10));
    r.renderFrame(project, 0); // keyed image drawn

    final img = await r.captureFrame();
    final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    int alphaAt(int x, int y) => bytes.getUint8((y * 100 + x) * 4 + 3);
    int redAt(int x, int y) => bytes.getUint8((y * 100 + x) * 4);
    // the image spans x 10..90, y 30..70; green is its left half.
    expect(alphaAt(25, 50), 0, reason: 'green keyed out');
    expect(alphaAt(75, 50), 255, reason: 'red kept');
    expect(redAt(75, 50), 255);
  });
}
