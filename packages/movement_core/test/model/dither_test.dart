import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Uint8List grey(int w, int h, int v) {
  final b = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    b[i * 4] = b[i * 4 + 1] = b[i * 4 + 2] = v;
    b[i * 4 + 3] = 255;
  }
  return b;
}

void main() {
  test('every kernel keeps a grey\'s brightness on average with two levels', () {
    for (final k in LayerFilters.ditherDiffusion) {
      final out = errorDiffuse(grey(32, 32, 64), 32, 32, kernel: k);
      final values = {for (var i = 0; i < 32 * 32; i++) out[i * 4]};
      expect(values.difference({0, 255}), isEmpty, reason: k);
      var white = 0;
      for (var i = 0; i < 32 * 32; i++) {
        if (out[i * 4] == 255) white++;
      }
      // a quarter grey: about a quarter white (Atkinson keeps less).
      expect(white / (32 * 32), closeTo(0.25, k == 'atkinson' ? 0.12 : 0.05), reason: k);
    }
  });

  test('palette: only its colours; clear pixels left alone; no bleed: plain rounding', () {
    final img = grey(16, 16, 120)..[3] = 0;
    final out = errorDiffuse(img, 16, 16, kernel: 'floyd', mode: 'palette', palette: [
      [0, 0, 255],
      [255, 255, 0]
    ]);
    for (var i = 1; i < 256; i++) {
      final c = [out[i * 4], out[i * 4 + 1], out[i * 4 + 2]];
      expect(c, anyOf(equals([0, 0, 255]), equals([255, 255, 0])));
    }
    expect(out[3], 0);
    final flat = errorDiffuse(grey(8, 8, 100), 8, 8, kernel: 'floyd', bleed: 0);
    expect({for (var i = 0; i < 64; i++) flat[i * 4]}, {0});
  });

  test('the new settings are saved', () {
    final f = LayerFilters()
      ..dither = true
      ..ditherPattern = 'atkinson'
      ..ditherOpacity = 0.4
      ..ditherAngle = 30
      ..ditherBleed = 0.7
      ..ditherSerpentine = false
      ..ditherPerceptual = true;
    final b = LayerFilters.fromJson(f.toJson());
    expect([b.ditherPattern, b.ditherOpacity, b.ditherAngle, b.ditherBleed, b.ditherSerpentine, b.ditherPerceptual],
        ['atkinson', 0.4, 30.0, 0.7, false, true]);
    expect(b.ditherDiffuses, isTrue);
  });
}
