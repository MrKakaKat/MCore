import 'dart:convert';
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// 30x30: white outside, a black square ring (5..24), white inside it (10..19).
Uint8List nested() {
  const w = 30;
  final px = Uint8List(w * w * 4);
  for (var y = 0; y < w; y++) {
    for (var x = 0; x < w; x++) {
      final ring = x >= 5 && x < 25 && y >= 5 && y < 25 && !(x >= 10 && x < 20 && y >= 10 && y < 20);
      final v = ring ? 0 : 255;
      final o = (y * w + x) * 4;
      px[o] = v;
      px[o + 1] = v;
      px[o + 2] = v;
      px[o + 3] = 255;
    }
  }
  return px;
}

int alpha(Uint8List px, int x, int y) => px[(y * 30 + x) * 4 + 3];

void main() {
  ChromaKey white() => ChromaKey(enabled: true, color: '#ffffff', strength: 0.4, softness: 0);

  test('whole image: both whites go', () {
    final out = chromaKeyedCopy(nested(), 30, 30, white());
    expect([alpha(out, 1, 1), alpha(out, 15, 15), alpha(out, 7, 7)], [0, 0, 255]);
  });

  test('connected only: the white inside the black square stays', () {
    final k = white()
      ..contiguous = true
      ..seed = [0.02, 0.02];
    final out = chromaKeyedCopy(nested(), 30, 30, k);
    expect([alpha(out, 1, 1), alpha(out, 15, 15), alpha(out, 7, 7)], [0, 255, 255]);
    k.seed = [0.5, 0.5];
    final inner = chromaKeyedCopy(nested(), 30, 30, k);
    expect([alpha(inner, 1, 1), alpha(inner, 15, 15)], [255, 0], reason: 'picked inside: only the inside');
  });

  test('grow edge eats into the ring, invert keeps only the key, feather softens', () {
    final grown = chromaKeyedCopy(nested(), 30, 30, white()..expand = 2);
    expect(alpha(grown, 6, 15), 0, reason: '1 px into the ring');
    expect(alpha(grown, 7, 15), 255, reason: 'the middle of the ring stays');
    final inv = chromaKeyedCopy(nested(), 30, 30, white()..invert = true);
    expect([alpha(inv, 1, 1), alpha(inv, 7, 7)], [255, 0]);
    final soft = chromaKeyedCopy(nested(), 30, 30, white()..feather = 2);
    expect(alpha(soft, 5, 15), inExclusiveRange(0, 255));
  });

  test('contrast view: white kept, black removed', () {
    final m = chromaMatte(nested(), 30, 30, white());
    expect([m[(1 * 30 + 1) * 4], m[(7 * 30 + 7) * 4], m[(1 * 30 + 1) * 4 + 3]], [0, 255, 255]);
  });

  test('saved and copied; a submitted key keeps its settings for the next colour, only invert resets', () {
    final k = white()
      ..contiguous = true
      ..seed = [0.1, 0.2]
      ..expand = 3
      ..invert = true
      ..feather = 1;
    final back = chromaKeyFromJson(jsonDecode(jsonEncode(chromaKeyToJson(k))) as Map<String, dynamic>);
    expect([back.contiguous, back.seed, back.expand, back.invert, back.feather], [true, [0.1, 0.2], 3, true, 1]);
    expect(k.copy().expand, 3);
    submitChromaKey(k);
    expect([k.contiguous, k.expand, k.feather, k.invert, k.applied.single.expand, k.applied.single.invert],
        [true, 3, 1, false, 3, true]);
    expect(chromaCapable('compound'), isTrue);
  });
}
