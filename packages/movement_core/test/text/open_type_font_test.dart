import 'dart:io';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Reference values come from fontTools reading the same files.
List<double> _controlBounds(List<PathCmd> cmds) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final c in cmds) {
    for (var i = 0; i + 1 < c.p.length; i += 2) {
      x0 = math.min(x0, c.p[i]);
      x1 = math.max(x1, c.p[i]);
      y0 = math.min(y0, c.p[i + 1]);
      y1 = math.max(y1, c.p[i + 1]);
    }
  }
  return [x0, y0, x1, y1];
}

void main() {
  group('TrueType (Roboto)', () {
    final font = OpenTypeFont.parse(File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());

    test('metrics, cmap and advances', () {
      expect(font.familyName, 'Roboto');
      expect(font.isCff, isFalse);
      expect(font.unitsPerEm, 2048);
      expect([font.ascender, font.descender, font.lineGap], [1900, -500, 0]);
      expect(font.numGlyphs, 1326);
      expect(font.glyphIndex('A'.codeUnitAt(0)), 37);
      expect(font.glyphIndex('V'.codeUnitAt(0)), 58);
      expect(font.glyphIndex('o'.codeUnitAt(0)), 83);
      expect(font.glyphIndex('Ж'.codeUnitAt(0)), 218);
      expect(font.glyphIndex(' '.codeUnitAt(0)), 4);
      expect(font.glyphIndex(0x1F600), 0, reason: 'no emoji -> .notdef');
      expect(font.advance(37), 1336);
      expect(font.advance(218), 1859);
      expect(font.advance(4), 508);
    });

    test('simple glyph outlines', () {
      final o = font.glyphPath(83);
      expect(o.where((c) => c.op == 'Z').length, 2, reason: 'o has an outer and an inner contour');
      expect(_controlBounds(o), [92, -20, 1077, 1102]);
      final zhe = font.glyphPath(218);
      expect(zhe.first.op, 'M');
      expect(zhe.first.p, [586, 665]);
      expect(zhe[1].op, 'L');
      expect(zhe[1].p, [66, 1456]);
      expect(font.glyphPath(4), isEmpty, reason: 'space draws nothing');
    });

    test('composite glyphs place their components', () {
      expect(_controlBounds(font.glyphPath(703)), [93, -20, 1011, 1536]); // é
      expect(_controlBounds(font.glyphPath(672)), [29, 0, 1310, 1939]); // Å
    });

    test('GPOS pair kerning', () {
      expect(font.kerning(37, 58), -87); // A V
      expect(font.kerning(58, 83), -46); // V o
      expect(font.kerning(37, 37), 0);
    });
  });

  group('CFF (generated test font with subroutines and hints)', () {
    final font = OpenTypeFont.parse(File('test/fixtures/test_cff.otf').readAsBytesSync());

    test('reads the CFF outlines', () {
      expect(font.isCff, isTrue);
      expect(font.familyName, 'TestCFF');
      final a = font.glyphPath(font.glyphIndex(65));
      expect([for (final c in a) c.op], ['M', 'L', 'L', 'Z', 'M', 'L', 'L', 'Z']);
      expect(a[1].p, [300, 700]);
      expect(a[4].p, [200, 100]);

      final o = font.glyphPath(font.glyphIndex(79));
      expect([for (final c in o) c.op], ['M', 'C', 'C', 'C', 'C', 'Z']);
      expect(o[1].p, [466, 0, 600, 134, 600, 300]);
    });

    test('hint mask, local and global subroutines', () {
      final b = font.glyphPath(font.glyphIndex(66));
      expect([for (final c in b) c.op], ['M', 'L', 'L', 'L', 'C', 'Z']);
      expect(b[0].p, [50, 0]);
      expect(b[3].p, [50, 300]);
      expect(b[4].p, [50, 400, 150, 500, 250, 500]);
      expect(font.advance(font.glyphIndex(66)), 700);
    });
  });

  test('flattenPath turns curves into polygons, one per contour', () {
    final polys = flattenPath(const [
      PathCmd('M', [0, 0]),
      PathCmd('Q', [5, 10, 10, 0]),
      PathCmd('Z'),
    ], segments: 4);
    expect(polys.length, 1);
    expect(polys.single.length, 5);
    expect(polys.single[2], [5, 5]);
  });

  test('garbage is rejected with a readable error', () {
    expect(() => OpenTypeFont.parse(File('test/fixtures/js_reference_project.json').readAsBytesSync()),
        throwsA(isA<FontFormatException>()));
  });
}
