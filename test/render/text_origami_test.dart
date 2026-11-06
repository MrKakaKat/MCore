import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Future<int> _inked(Project p) async {
  final r = CanvasRenderer()..setSize(400, 400);
  r.renderFrame(p, 0);
  final img = await r.captureFrame();
  final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  var n = 0;
  for (var i = 3; i < b.lengthInBytes; i += 4) {
    if (b.getUint8(i) > 0) n++;
  }
  return n;
}

void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });

  for (final angle in [0.0, 30.0, 60.0, 120.0]) {
    test('a text with origami (angle $angle) still shows', () async {
      final plain = createTextLayer();
      final base = await _inked(Project(layers: [plain]));
      final l = createTextLayer();
      l.effectStack.add(EffectInstance(id: 'o', effectId: 'origami_fold', params: {'angle': track(angle)}));
      final n = await _inked(Project(layers: [l]));
      expect(n, greaterThan(base * 0.3), reason: 'plain $base, folded $n');
    });
  }
}
