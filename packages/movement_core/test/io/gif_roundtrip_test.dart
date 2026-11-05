import 'dart:math' as math;
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// A small GIF decoder (LZW, local tables, disposal 0-2, transparency):
/// what a viewer shows after each frame, RGBA.
List<Uint8List> decodeGif(Uint8List b) {
  var p = 6;
  int u16() => b[p++] | (b[p++] << 8);
  final w = u16(), h = u16();
  final packed = b[p++];
  p += 2;
  if (packed & 0x80 != 0) p += 3 * (1 << ((packed & 7) + 1));
  final canvas = Uint8List(w * h * 4);
  final frames = <Uint8List>[];
  var disposal = 0, transparent = -1;
  while (p < b.length) {
    final t = b[p++];
    if (t == 0x3B) break;
    if (t == 0x21) {
      final label = b[p++];
      if (label == 0xF9) {
        p++; // size
        final f = b[p++];
        disposal = (f >> 2) & 7;
        p += 2;
        final ti = b[p++];
        transparent = f & 1 == 1 ? ti : -1;
        p++;
      } else {
        while (b[p] != 0) {
          p += b[p] + 1;
        }
        p++;
      }
      continue;
    }
    expect(t, 0x2C);
    final x0 = u16(), y0 = u16(), fw = u16(), fh = u16();
    final ip = b[p++];
    final table = <int>[];
    if (ip & 0x80 != 0) {
      final n = 1 << ((ip & 7) + 1);
      for (var i = 0; i < n; i++) {
        table.add((b[p] << 16) | (b[p + 1] << 8) | b[p + 2]);
        p += 3;
      }
    }
    final minCode = b[p++];
    final data = <int>[];
    while (b[p] != 0) {
      final n = b[p++];
      data.addAll(b.sublist(p, p + n));
      p += n;
    }
    p++;
    // LZW decode.
    final clear = 1 << minCode, eoi = clear + 1;
    var size = minCode + 1;
    var dict = <List<int>>[];
    void reset() {
      dict = [for (var i = 0; i < clear; i++) [i], [], []];
      size = minCode + 1;
    }

    reset();
    final out = <int>[];
    var bitPos = 0;
    List<int>? prev;
    while (true) {
      var code = 0;
      for (var i = 0; i < size; i++) {
        final bit = (data[(bitPos + i) >> 3] >> ((bitPos + i) & 7)) & 1;
        code |= bit << i;
      }
      bitPos += size;
      if (code == clear) {
        reset();
        prev = null;
        continue;
      }
      if (code == eoi) break;
      List<int> entry;
      if (code < dict.length) {
        entry = dict[code];
        if (prev != null) dict.add([...prev, entry[0]]);
      } else {
        entry = [...prev!, prev[0]];
        dict.add(entry);
      }
      out.addAll(entry);
      prev = entry;
      if (dict.length == (1 << size) && size < 12) size++;
    }
    expect(out.length, fw * fh);
    for (var y = 0; y < fh; y++) {
      for (var x = 0; x < fw; x++) {
        final k = out[y * fw + x];
        if (k == transparent) continue;
        final q = ((y + y0) * w + x + x0) * 4;
        canvas[q] = (table[k] >> 16) & 0xFF;
        canvas[q + 1] = (table[k] >> 8) & 0xFF;
        canvas[q + 2] = table[k] & 0xFF;
        canvas[q + 3] = 255;
      }
    }
    frames.add(Uint8List.fromList(canvas));
    if (disposal == 2) {
      for (var y = 0; y < fh; y++) {
        for (var x = 0; x < fw; x++) {
          final q = ((y + y0) * w + x + x0) * 4;
          canvas.fillRange(q, q + 4, 0);
        }
      }
    }
  }
  return frames;
}

Uint8List _frame(int w, int h, int Function(int x, int y) rgb, {bool Function(int x, int y)? hole}) {
  final d = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4, c = rgb(x, y);
      d[i] = (c >> 16) & 0xFF;
      d[i + 1] = (c >> 8) & 0xFF;
      d[i + 2] = c & 0xFF;
      d[i + 3] = hole != null && hole(x, y) ? 0 : 255;
    }
  }
  return d;
}

void main() {
  test('few colours: every frame decodes exactly, moving content and all', () {
    const w = 40, h = 30;
    final frames = [
      for (var f = 0; f < 4; f++)
        _frame(w, h, (x, y) => (x >= 5 + f * 5 && x < 15 + f * 5 && y > 10 && y < 20) ? 0xFF0000 : 0x2040A0)
    ];
    final gif = encodeGif(frames: [for (final f in frames) GifFrame(width: w, height: h, rgba: f, delayCentiseconds: 4)]);
    final shown = decodeGif(gif);
    expect(shown, hasLength(4));
    for (var f = 0; f < 4; f++) {
      expect(shown[f], frames[f], reason: 'frame $f');
    }
  });

  test('an unchanged frame is a tiny one; a changed frame writes only its rectangle', () {
    const w = 64, h = 64;
    final a = _frame(w, h, (x, y) => 0x112233);
    final b = _frame(w, h, (x, y) => x == 10 && y == 10 ? 0xFFFFFF : 0x112233);
    final one = encodeGif(frames: [GifFrame(width: w, height: h, rgba: a, delayCentiseconds: 4)]);
    final gif = encodeGif(frames: [
      for (final f in [a, a, b]) GifFrame(width: w, height: h, rgba: f, delayCentiseconds: 4)
    ]);
    expect(gif.length - one.length, lessThan(80));
    final shown = decodeGif(gif);
    expect(shown[1], a);
    expect(shown[2], b);
  });

  test('many colours: a photo-like frame keeps close to its colours, with and without dithering', () {
    const w = 120, h = 80;
    final src = _frame(w, h, (x, y) => ((x * 2) << 16) | ((y * 3) << 8) | ((x + y) & 0xFF));
    for (final dither in [false, true]) {
      final sw = Stopwatch()..start();
      final gif = encodeGif(
          frames: [GifFrame(width: w, height: h, rgba: src, delayCentiseconds: 4)],
          options: GifOptions(dither: dither, maxColors: 64));
      sw.stop();
      final shown = decodeGif(gif).single;
      var err = 0.0;
      for (var i = 0; i < w * h * 4; i++) {
        if (i % 4 != 3) err += (shown[i] - src[i]).abs();
      }
      err /= w * h * 3;
      expect(err, lessThan(12), reason: 'dither $dither: average error $err');
    }
  });

  test('transparent frames: cropped to what they draw, cleared before the next', () {
    const w = 50, h = 50;
    Uint8List dot(int cx) => _frame(w, h, (x, y) => 0x00FF00, hole: (x, y) => (x - cx).abs() > 3 || (y - 25).abs() > 3);
    final gif = encodeGif(frames: [for (final cx in [10, 30]) GifFrame(width: w, height: h, rgba: dot(cx), delayCentiseconds: 4)]);
    final shown = decodeGif(gif);
    for (var f = 0; f < 2; f++) {
      final want = dot([10, 30][f]);
      for (var i = 3; i < want.length; i += 4) {
        expect(shown[f][i] > 0, want[i] > 0);
      }
    }
  });

  test('a big frame encodes quickly', () {
    const w = 720, h = 1280;
    final rnd = math.Random(1);
    final src = _frame(w, h, (x, y) => ((x * 255 ~/ w) << 16) | ((y * 255 ~/ h) << 8) | rnd.nextInt(40));
    final sw = Stopwatch()..start();
    final gif = encodeGif(frames: [
      GifFrame(width: w, height: h, rgba: src, delayCentiseconds: 4),
      GifFrame(width: w, height: h, rgba: src, delayCentiseconds: 4),
    ], options: GifOptions.quality(70));
    sw.stop();
    expect(decodeGif(gif), hasLength(2));
    expect(sw.elapsedMilliseconds, lessThan(4000), reason: 'took ${sw.elapsedMilliseconds} ms');
  });
}
