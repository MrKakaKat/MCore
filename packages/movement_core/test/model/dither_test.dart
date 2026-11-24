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

  test('two colours: the brightness laid between them; invert turns it over', () {
    final out = errorDiffuse(grey(16, 16, 128), 16, 16, kernel: 'floyd', mode: 'duo', dark: [128, 0, 0], light: [255, 255, 0]);
    for (var i = 0; i < 256; i++) {
      expect([out[i * 4], out[i * 4 + 1], out[i * 4 + 2]], anyOf(equals([128, 0, 0]), equals([255, 255, 0])));
    }
    final dark = errorDiffuse(grey(8, 8, 230), 8, 8, kernel: 'floyd', mode: 'duo', invert: 1);
    var black = 0;
    for (var i = 0; i < 64; i++) {
      if (dark[i * 4] == 0) black++;
    }
    expect(black, greaterThan(48), reason: 'a light grey turned over: mostly dark');
  });

  test('the 8x8 grid has every step once; opacity as dots keeps that share dithered', () {
    expect({for (var y = 0; y < 8; y++) for (var x = 0; x < 8; x++) (bayer8(x, y) * 64).floor()}.length, 64);
    final src = grey(16, 16, 128);
    final out = errorDiffuse(src, 16, 16, kernel: 'floyd', stippleOpacity: 0.25);
    var untouched = 0;
    for (var i = 0; i < 256; i++) {
      if (out[i * 4] == 128) untouched++;
    }
    expect(untouched, 192);
  });

  test('softness: in-between values blended near halfway, hard steps at 0', () {
    // a grey at 45% between the two levels, no error passed on: hard
    // rounds it down, soft gives a blend.
    final hard = errorDiffuse(grey(4, 4, 115), 4, 4, kernel: 'floyd', bleed: 0);
    final soft = errorDiffuse(grey(4, 4, 115), 4, 4, kernel: 'floyd', bleed: 0, softness: 1);
    expect(hard[0], 0);
    expect(soft[0], inInclusiveRange(80, 140));
    final pal = errorDiffuse(grey(4, 4, 115), 4, 4, kernel: 'floyd', bleed: 0, softness: 1, mode: 'palette');
    expect(pal[0], inInclusiveRange(80, 140), reason: 'between the black and the white of the palette');
  });

  test('only lighter: nothing comes out darker than it was', () {
    final out = errorDiffuse(grey(16, 16, 64), 16, 16, kernel: 'floyd', lightenOnly: true);
    final values = {for (var i = 0; i < 256; i++) out[i * 4]};
    expect(values.every((v) => v >= 64), isTrue);
    expect(values.any((v) => v > 64), isTrue, reason: 'some dots lighter');
  });

  test('pattern hold: the light end keeps its dots', () {
    double white(Uint8List o) => [for (var i = 0; i < 256; i++) o[i * 4]].where((v) => v == 255).length / 256;
    final plain = errorDiffuse(grey(16, 16, 230), 16, 16, kernel: 'floyd');
    final held = errorDiffuse(grey(16, 16, 230), 16, 16, kernel: 'floyd', hold: 1);
    expect(white(plain), greaterThan(0.85));
    expect(white(held), closeTo(0.45, 0.08));
  });
}
