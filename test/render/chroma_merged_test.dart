import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// Chroma on a merged shape: a white square, a black one inside it and a
/// white one inside that - keyed as a picture of itself. "Connected only"
/// from the outer white leaves the inner white (not joined to it).
void main() {
  setUpAll(registerBuiltinEffects);

  Future<ByteData> run({required bool contiguous}) async {
    final app = AppState()..setFrameSize(100, 100);
    app.project.layers.clear();
    app.renderer.backgroundColor = null;
    app.project.layers.add(createLayer('rect')
      ..id = 'bg'
      ..color = '#ff0000'
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5]);
    Layer sq(String id, String color, double size) => createLayer('rect')
      ..id = id
      ..color = color
      ..content.size = [size, size]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final shapes = [sq('w1', '#ffffff', 80), sq('b', '#000000', 50), sq('w2', '#ffffff', 20)];
    app.project.layers.addAll(shapes);
    final merged = mergeLayers(app.project, shapes, 'm', 0)!;

    final orig = app.renderer.onImageDecoded;
    app.editChromaKey(merged.id, (ck) {
      ck
        ..enabled = true
        ..color = '#ffffff'
        ..strength = 0.3
        ..softness = 0
        ..contiguous = contiguous
        ..seed = [0.03, 0.5]; // on the outer white, near its left edge
    });
    for (var i = 0; i < 4; i++) {
      final ready = Completer<void>();
      app.renderer.onImageDecoded = () {
        orig?.call();
        if (!ready.isCompleted) ready.complete();
      };
      app.commitEdit();
      await ready.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    app.commitEdit();
    final out = await app.renderer.captureFrame();
    return (await out.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
  }

  List<int> at(ByteData px, int x, int y) => [for (var c = 0; c < 3; c++) px.getUint8((y * 100 + x) * 4 + c)];

  test('whole: both whites keyed (the red background shows), the black stays', () async {
    final px = await run(contiguous: false);
    expect(at(px, 15, 50), [255, 0, 0]);
    expect(at(px, 50, 50), [255, 0, 0]);
    expect(at(px, 30, 50), [0, 0, 0]);
  });

  test('connected only: the inner white stays', () async {
    final px = await run(contiguous: true);
    expect(at(px, 15, 50), [255, 0, 0]);
    expect(at(px, 50, 50), [255, 255, 255]);
    expect(at(px, 30, 50), [0, 0, 0]);
  });
}
