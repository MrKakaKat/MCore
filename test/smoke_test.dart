import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Feasibility spike, not permanent coverage - determines whether
/// `flutter test` can exercise real dart:ui (Canvas/Picture/toImage)
/// headlessly in this environment, or whether that's blocked the way
/// running an actual Flutter app is (no device/emulator). If this
/// passes, canvas_renderer.dart's actual renderFrame()/captureFrame()
/// and stage_gesture_controller.dart's pointer routing become
/// realistically testable for the first time this session.
void main() {
  test('flutter test can rasterize a real Picture headlessly via toImage()', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, 20, 10));
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 20, 10), ui.Paint()..color = const ui.Color(0xFFFF0000));
    final picture = recorder.endRecording();

    final image = await picture.toImage(20, 10);
    expect(image.width, equals(20));
    expect(image.height, equals(10));

    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);
    // first pixel should be opaque red (0xFFFF0000 in RGBA byte order: R,G,B,A)
    expect(bytes!.getUint8(0), equals(0xFF)); // R
    expect(bytes.getUint8(1), equals(0x00)); // G
    expect(bytes.getUint8(2), equals(0x00)); // B
    expect(bytes.getUint8(3), equals(0xFF)); // A
  });
}
