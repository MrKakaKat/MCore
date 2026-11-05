import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  Uint8List px(List<List<int>> rgb) => Uint8List.fromList([for (final c in rgb) ...c, 255].isEmpty
      ? []
      : [for (final c in rgb) ...[...c, 255]]);

  test('lighten (black background): black goes, white stays, grey turns half see-through white', () {
    final p = px([[0, 0, 0], [255, 255, 255], [128, 128, 128], [255, 0, 0]]);
    colorToAlpha(p, 4, 1, [0, 0, 0], 1);
    expect(p[3], 0);
    expect(p.sublist(4, 8), [255, 255, 255, 255]);
    expect(p.sublist(8, 12), [255, 255, 255, 128]);
    expect(p.sublist(12, 16), [255, 0, 0, 255], reason: 'a pure colour keeps its full strength');
  });

  test('darken (white background): white goes, black stays', () {
    final p = px([[255, 255, 255], [0, 0, 0], [191, 191, 191]]);
    colorToAlpha(p, 3, 1, [255, 255, 255], 1);
    expect(p[3], 0);
    expect(p.sublist(4, 8), [0, 0, 0, 255]);
    expect(p[11], closeTo(64, 1));
  });

  test('strength scales it; zero leaves the picture alone', () {
    final half = px([[0, 0, 0]]);
    colorToAlpha(half, 1, 1, [0, 0, 0], 0.5);
    expect(half[3], closeTo(128, 1));
    final none = px([[0, 0, 0]]);
    colorToAlpha(none, 1, 1, [0, 0, 0], 0);
    expect(none[3], 255);
  });
}
