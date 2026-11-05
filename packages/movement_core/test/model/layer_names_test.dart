import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _named(String name) => createLayer('rect')..name = name;

void main() {
  setUp(() => fps = 60);

  test('the first free number of a type; types count on their own', () {
    final p = Project(layers: [_named('Rect 1'), _named('Rect 3'), _named('Circle 1')]);
    expect(nextFreeLayerName(p, 'rect'), 'Rect 2', reason: 'the gap left by a deleted Rect 2 is reused');
    expect(nextFreeLayerName(p, 'circle'), 'Circle 2');
    expect(nextFreeLayerName(p, 'image'), 'Image 1');
    final l = _named('rect_17');
    nameNewLayer(p, l);
    expect(l.name, 'Rect 2');
    expect(nextFreeLayerName(Project(), 'rect'), 'Rect 1', reason: 'everything deleted: back to 1');
  });

  test('split pieces are numbered in order: Rect 1, Rect 1 2, Rect 1 3 - never Rect 1 2 2', () {
    final a = createLayer('rect')
      ..name = 'Rect 1'
      ..startFrame = 0
      ..durationFrames = 100;
    final p = Project(layers: [a]);
    final b = splitLayer(p, a, 50, 'b')!;
    expect(b.name, 'Rect 1 2');
    final c = splitLayer(p, b, 75, 'c')!;
    expect(c.name, 'Rect 1 3');
    final d = splitLayer(p, a, 25, 'd')!;
    expect(d.name, 'Rect 1 4');
    p.layers.remove(c);
    expect(splitLayer(p, d, 40, 'e')!.name, 'Rect 1 3', reason: 'a deleted piece number is reused');
    expect(layerFromJson(layerToJson(b)).splitRoot, 'Rect 1');
  });

  group('chroma: several colours', () {
    // three pixels: green, blue, red.
    Uint8List px() => Uint8List.fromList([0, 255, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255]);

    test('submitted colours stay removed; hidden ones come back', () {
      final ck = ChromaKey(enabled: true, color: '#00ff00');
      expect(submitChromaKey(ck), isTrue);
      expect(ck.enabled, isFalse, reason: 'the editor is free for the next colour');
      expect(ck.applied.single.color, '#00ff00');
      ck
        ..enabled = true
        ..color = '#0000ff';
      var out = chromaKeyedCopy(px(), 3, 1, ck);
      expect([out[3], out[7], out[11]], [0, 0, 255], reason: 'green (submitted) and blue (current) removed');
      expect(ck.active, isTrue);

      ck.applied.single.enabled = false; // hide green
      out = chromaKeyedCopy(px(), 3, 1, ck);
      expect([out[3], out[7], out[11]], [255, 0, 255]);
      expect(submitChromaKey(ChromaKey()), isFalse, reason: 'nothing to submit when the key is off');
    });

    test('the list is saved', () {
      final ck = ChromaKey(enabled: true, color: '#00ff00', scope: 'region', region: [
        [0.0, 0.0],
        [1.0, 0.0],
        [1.0, 1.0]
      ]);
      submitChromaKey(ck);
      final back = chromaKeyFromJson(chromaKeyToJson(ck));
      expect(back.applied.single.color, '#00ff00');
      expect(back.applied.single.region.length, 3);
      expect(back.enabled, isFalse);
    });
  });
}
