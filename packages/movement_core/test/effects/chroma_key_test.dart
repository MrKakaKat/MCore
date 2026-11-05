import 'dart:convert';
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// 4x1 image: green, near-green, red, white - all opaque.
Uint8List _strip() => Uint8List.fromList([
      0, 255, 0, 255, //
      30, 220, 40, 255, //
      255, 0, 0, 255, //
      255, 255, 255, 255,
    ]);

void main() {
  test('keys the key colour out, leaves far colours alone', () {
    final px = _strip();
    applyChromaKey(px, 4, 1, key: [0, 255, 0], strength: 0.5, softness: 0.1);
    expect(px[3], 0, reason: 'exact key -> transparent');
    expect(px[7], 0, reason: 'close to the key -> transparent at this strength');
    expect(px[11], 255, reason: 'red stays');
    expect(px[15], 255, reason: 'white stays');
    expect(px.sublist(8, 11), [255, 0, 0], reason: 'colour bytes untouched');
  });

  test('strength decides how close counts; softness gives a partial edge', () {
    final weak = _strip();
    applyChromaKey(weak, 4, 1, key: [0, 255, 0], strength: 0.0, softness: 0.0);
    expect(weak[3], 0);
    expect(weak[7], 255, reason: 'zero strength keys only the exact colour');

    final soft = _strip();
    final d = chromaDistance([30, 220, 40], [0, 255, 0]);
    // put the near-green pixel inside the soft band.
    applyChromaKey(soft, 4, 1, key: [0, 255, 0], strength: d, softness: 0.5);
    expect(soft[7], allOf(greaterThan(0), lessThan(255)));
  });

  test('a grey key works through the brightness term', () {
    final px = Uint8List.fromList([128, 128, 128, 255, 250, 250, 250, 255]);
    applyChromaKey(px, 2, 1, key: [128, 128, 128], strength: 0.1, softness: 0.05);
    expect(px[3], 0);
    expect(px[7], 255);
  });


  test('eyedropper averages the 3x3 neighbourhood', () {
    final px = _strip();
    expect(sampleRgb(px, 4, 1, 0.9, 0.5), [255, 128, 128]);
    expect(rgbHex(0, 255, 0), '#00ff00');
    expect(parseRgbHex('#00FF00'), [0, 255, 0]);
  });

  test('uv mapping follows the mirror; JSON round-trip', () {
    final l = Layer(
      id: 'L',
      name: 'img',
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'image', offset: [0, 0], size: [100, 50]),
    );
    expect(contentLocalToImageUv(l, [-50, -25]), [0, 0]);
    l.mirrorX = true;
    expect(contentLocalToImageUv(l, [-50, -25]), [1, 0]);
    expect(imageUvToContentLocal(l, [1, 0]), [-50, -25]);

    l.chromaKey = ChromaKey(enabled: true, color: '#112233', scope: 'region', region: [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]);
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.chromaKey.color, '#112233');
    expect(back.chromaKey.scope, 'region');
    expect(back.chromaKey.region[1], [0.3, 0.4]);
  });
}
