import 'dart:typed_data';

import 'package:movement_core/effects/chroma_key.dart';
import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Chroma, connected only: a band along the edge of what was cut with a
/// key of its own.
void main() {
  // 40 x 40: green, a red square 10..29 with a 2 px olive fringe (8..9 and
  // 30..31), a green spot inside it (18..21) cut off from the outside.
  const w = 40, h = 40;
  Uint8List image() {
    final b = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        final inSq = x >= 10 && x < 30 && y >= 10 && y < 30;
        final inFringe = x >= 8 && x < 32 && y >= 8 && y < 32 && !inSq;
        final spot = x >= 18 && x < 22 && y >= 18 && y < 22;
        final c = spot ? [0, 255, 0] : inSq ? [255, 0, 0] : inFringe ? [110, 170, 0] : [0, 255, 0];
        b[o] = c[0];
        b[o + 1] = c[1];
        b[o + 2] = c[2];
        b[o + 3] = 255;
      }
    }
    return b;
  }

  ChromaKey key() => ChromaKey(enabled: true, color: '#00ff00', strength: 0.4, softness: 0.05)
    ..contiguous = true
    ..seed = [0.01, 0.01];

  test('the band takes the fringe; deeper in and the cut-off spot stay', () {
    final img = image();
    final plain = chromaKeepMap(img, w, h, key());
    expect(plain[0], 0, reason: 'background cut');
    expect(plain[9 * w + 20], greaterThan(0.5), reason: 'the fringe left by the main key');
    final banded = chromaKeepMap(img, w, h, key()
      ..edgeDepth = 3
      ..edgeStrength = 1
      ..edgeSoftness = 0.1);
    expect(banded[9 * w + 20], lessThan(0.1), reason: 'the fringe taken in the band');
    expect(banded[8 * w + 20], lessThan(0.1));
    expect(banded[20 * w + 20], 1, reason: 'the green spot inside: not connected, and too deep');
    expect(banded[15 * w + 15], 1, reason: 'red stays');
  });

  test('no edge from the connected key (it took nothing): the band does nothing', () {
    final img = image();
    final k = key()
      ..seed = [0.5, 0.3] // on the red: nothing of the key colour there
      ..edgeDepth = 5
      ..edgeStrength = 1;
    final m = chromaKeepMap(img, w, h, k);
    expect(m.every((v) => v == 1), isTrue);
  });

  test('saved and copied', () {
    final k = key()..edgeDepth = 4..edgeStrength = 0.7..edgeSoftness = 0.2;
    final j = chromaKeyFromJson(chromaKeyToJson(k));
    expect([j.edgeDepth, j.edgeStrength, j.edgeSoftness], [4, 0.7, 0.2]);
    expect(k.copy().edgeDepth, 4);
  });
}
