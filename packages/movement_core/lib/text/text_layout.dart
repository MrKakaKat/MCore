/// Vector text: the font registry, laying text out inside its box, and
/// turning a text layer into a plain vector shape.
///
/// Layout: paragraphs split on new lines; each wraps to the box width at
/// spaces, and a word wider than the box breaks between letters - so a
/// box narrowed down far enough stacks the text into a vertical column.
/// Letter spacing is added after every letter, kerning (GPOS/kern) between
/// letter pairs of the same font. The block is centred vertically in the
/// box; lines align left / centre / right. A character the chosen font
/// lacks falls back to the default font (Roboto).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/shapes.dart';
import '../model/project.dart';
import '../model/project_json.dart';
import 'open_type_font.dart';

const defaultFontId = 'roboto';

final Map<String, OpenTypeFont> _fonts = {};
final Map<String, String> _fontNames = {};
int _fontGeneration = 0;

/// Makes a font available to text layers under `id` (throws
/// FontFormatException for unreadable files). Returns it.
OpenTypeFont registerFont(String id, Uint8List bytes, {String? name}) {
  final font = OpenTypeFont.parse(bytes);
  _fonts[id] = font;
  _fontNames[id] = name ?? font.familyName;
  _fontGeneration++;
  _layoutCache.clear();
  return font;
}

/// Removes a loaded font (the default font stays). Text that used it falls
/// back to the default font. Returns whether it was there.
bool unregisterFont(String id) {
  if (id == defaultFontId || !_fonts.containsKey(id)) return false;
  _fonts.remove(id);
  _fontNames.remove(id);
  _fontGeneration++;
  _layoutCache.clear();
  return true;
}

/// id -> display name of every registered font, the default first.
Map<String, String> registeredFonts() => {
      if (_fontNames.containsKey(defaultFontId)) defaultFontId: _fontNames[defaultFontId]!,
      for (final e in _fontNames.entries)
        if (e.key != defaultFontId) e.key: e.value,
    };

/// The font for `id`, or the default font, or null if none is loaded.
OpenTypeFont? fontById(String? id) => _fonts[id] ?? _fonts[defaultFontId];

class TextLayout {
  /// The glyph outlines, content-local px (y down).
  final List<PathCmd> path;

  /// Letter styles' colours: the outlines of the letters in each colour
  /// (`plain` holds the rest, in the text's own colour). Without coloured
  /// letters `plain` is `path`.
  final List<PathCmd> plain;
  final Map<String, List<PathCmd>> colored;

  /// Width of the widest line and height of the block, px.
  final double width;
  final double height;
  final int lineCount;

  /// Every drawn letter, in order (text animators split the text into
  /// units from these).
  final List<GlyphBox> glyphs;
  const TextLayout(this.path, this.width, this.height, this.lineCount,
      {List<PathCmd>? plain, this.colored = const {}, this.glyphs = const []})
      : plain = plain ?? path;
}

/// One laid-out letter: where it sits and which commands of the layout's
/// path draw it.
class GlyphBox {
  /// Its code point index in the text (letter styles count the same way).
  final int index;
  final int rune;
  final int line;

  /// Left edge, advance, baseline, and the font's ascent / descent at its
  /// size (px, content-local).
  final double x, advance, baseline, ascent, descent;
  final double fontSize;

  /// Letter-style colour (null: the text's own).
  final String? color;

  /// path[cmdStart, cmdEnd) draw it.
  final int cmdStart, cmdEnd;
  final OpenTypeFont font;
  const GlyphBox({
    required this.index,
    required this.rune,
    required this.line,
    required this.x,
    required this.advance,
    required this.baseline,
    required this.ascent,
    required this.descent,
    required this.fontSize,
    required this.color,
    required this.cmdStart,
    required this.cmdEnd,
    required this.font,
  });
}

final Map<String, TextLayout> _layoutCache = {};

class _G {
  final OpenTypeFont font;
  final int gid;
  final int rune;

  /// Font size, colour (null: the text's) and baseline shift of this
  /// letter (letter styles).
  final double fs;
  final String? color;
  final double rise;
  final int index;

  /// The size it is drawn at (`fs`: the size it takes in the line - the
  /// text's own when its part keeps the others in place), and whether it
  /// grows from its middle height.
  final double drawFs;
  final bool fromMiddle;
  _G(this.font, this.gid, this.rune, this.fs, this.color, this.rise, this.index, {double? drawFs, this.fromMiddle = false})
      : drawFs = drawFs ?? fs;
}

/// Lays `spec` out in a box of `size` centred on `offset`.
TextLayout layoutText(TextSpec spec, List<double> offset, List<double> size) {
  final key = '$_fontGeneration|${jsonEncode(textSpecToJson(spec))}|$offset|$size|${spec.hidden.join(',')}';
  final cached = _layoutCache[key];
  if (cached != null) return cached;
  final result = _layout(spec, offset, size);
  if (_layoutCache.length > 128) _layoutCache.clear();
  _layoutCache[key] = result;
  return result;
}

TextLayout _layout(TextSpec spec, List<double> offset, List<double> size) {
  final main = fontById(spec.fontId);
  if (main == null || spec.text.isEmpty) return const TextLayout([], 0, 0, 0);
  final fallback = fontById(defaultFontId);
  final fs = spec.fontSize.clamp(0.1, 10000).toDouble();
  double gScale(_G g) => g.fs / g.font.unitsPerEm;

  _G glyphFor(int rune, int index) {
    var size = fs, rise = 0.0, keep = false, middle = false;
    String? color;
    var font = main;
    for (final sp in spec.spans) {
      if (!sp.covers(index)) continue;
      if (sp.size != null) {
        size = fs * sp.size!.clamp(0.01, 100);
        keep = sp.sizeKeepsOthers;
        middle = sp.sizeFromMiddle;
      }
      if (sp.color != null) color = sp.color;
      if (sp.rise != null) rise = sp.rise!;
      // a part's own font.
      if (sp.fontId != null) font = fontById(sp.fontId!) ?? font;
    }
    final f = font.hasGlyph(rune) || fallback == null || !fallback.hasGlyph(rune) ? font : fallback;
    return _G(f, f.glyphIndex(rune), rune, keep ? fs : size, color, rise, index, drawFs: size, fromMiddle: middle);
  }

  double advanceOf(_G g) => g.font.advance(g.gid) * gScale(g) + spec.letterSpacing;
  double kern(_G a, _G b) =>
      identical(a.font, b.font) && a.fs == b.fs ? a.font.kerning(a.gid, b.gid) * gScale(a) : 0;
  double runWidth(List<_G> run) {
    var w = 0.0;
    for (var i = 0; i < run.length; i++) {
      w += advanceOf(run[i]);
      if (i > 0) w += kern(run[i - 1], run[i]);
    }
    return w;
  }

  final maxW = math.max(1e-6, size[0]);
  final lines = <List<_G>>[];
  var index = 0; // letter index in the whole text (letter styles)
  for (final para in spec.text.split('\n')) {
    // tokens: runs of spaces and runs of non-spaces.
    final tokens = <List<_G>>[];
    for (final rune in para.runes) {
      final at = index++;
      final isSpace = rune == 0x20 || rune == 0x09;
      if (tokens.isEmpty || ((tokens.last.first.rune == 0x20 || tokens.last.first.rune == 0x09) != isSpace)) {
        tokens.add([]);
      }
      tokens.last.add(glyphFor(rune, at));
    }
    index++; // the line break
    var line = <_G>[];
    void flush() {
      // trailing spaces don't count.
      while (line.isNotEmpty && (line.last.rune == 0x20 || line.last.rune == 0x09)) {
        line.removeLast();
      }
      lines.add(line);
      line = [];
    }

    for (final tok in tokens) {
      final isSpace = tok.first.rune == 0x20 || tok.first.rune == 0x09;
      if (isSpace && line.isEmpty && lines.isNotEmpty && tokens.first != tok) continue; // no leading spaces after a wrap
      if (runWidth([...line, ...tok]) <= maxW || isSpace) {
        line.addAll(tok);
        continue;
      }
      if (line.isNotEmpty) flush();
      if (runWidth(tok) <= maxW) {
        line.addAll(tok);
        continue;
      }
      // a word wider than the box: break it between letters.
      for (final g in tok) {
        if (line.isNotEmpty && runWidth([...line, g]) > maxW) flush();
        line.add(g);
      }
    }
    flush();
  }

  // a line is as tall as its largest letter.
  double lineFs(List<_G> line) => line.isEmpty ? fs : line.map((g) => g.fs).reduce(math.max);
  final em = (main.ascender - main.descender) / main.unitsPerEm;
  final lineHeights = [
    for (final line in lines)
      (main.ascender - main.descender + main.lineGap) / main.unitsPerEm * lineFs(line) * spec.lineSpacing
  ];
  final blockH = lineHeights.fold(0.0, (a, b) => a + b);
  final top = offset[1] - blockH / 2;
  final path = <PathCmd>[];
  final plain = <PathCmd>[];
  final colored = <String, List<PathCmd>>{};
  final glyphs = <GlyphBox>[];
  var widest = 0.0;
  var lineTop = top;
  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    final w = runWidth(line) - (line.isEmpty ? 0 : spec.letterSpacing);
    widest = math.max(widest, w);
    final lfs = lineFs(line), lineHeight = lineHeights[li];
    final glyphHeight = em * lfs;
    final baseline = lineTop + (lineHeight - glyphHeight) / 2 + main.ascender / main.unitsPerEm * lfs;
    lineTop += lineHeight;
    var x = switch (spec.align) {
      'left' => offset[0] - size[0] / 2,
      'right' => offset[0] + size[0] / 2 - w,
      _ => offset[0] - w / 2,
    };
    for (var i = 0; i < line.length; i++) {
      final g = line[i];
      if (i > 0) x += kern(line[i - 1], g);
      final gs = g.drawFs / g.font.unitsPerEm;
      // drawn bigger than its place in the line: round its own middle.
      final gx = x + (g.font.advance(g.gid) * (gScale(g) - gs)) / 2;
      // from its middle height: the middle of its em box stays where the
      // text's own size would put it.
      final gy = baseline +
          g.rise +
          (g.fromMiddle ? (g.font.ascender + g.font.descender) / 2 / g.font.unitsPerEm * (g.drawFs - fs) : 0.0);
      final into = g.color == null ? plain : colored.putIfAbsent(g.color!, () => []);
      final from = path.length;
      for (final c in spec.hidden.contains(g.index) ? const <PathCmd>[] : g.font.glyphPath(g.gid)) {
        final t = c.transformed(gs, 0, 0, -gs, gx, gy);
        path.add(t);
        into.add(t);
      }
      glyphs.add(GlyphBox(
        index: g.index,
        rune: g.rune,
        line: li,
        x: gx,
        advance: g.font.advance(g.gid) * gs,
        baseline: gy,
        ascent: g.font.ascender * gs,
        descent: -g.font.descender * gs,
        fontSize: g.drawFs,
        color: g.color,
        cmdStart: from,
        cmdEnd: path.length,
        font: g.font,
      ));
      x += advanceOf(g);
    }
  }
  return TextLayout(path, widest, blockH, lines.length,
      plain: colored.isEmpty ? path : plain, colored: colored, glyphs: glyphs);
}

/// The box size that fits `spec`'s text without wrapping (plus a little
/// margin) - for new text layers and the Text tab's "fit box".
List<double> fitTextBox(TextSpec spec) {
  if (spec.groupsEnabled) spec = spec.copy()..text = parseTextGroups(spec.text, spec.groupChar).text;
  final l = layoutText(spec, const [0, 0], const [1e9, 1e9]);
  final m = spec.fontSize * 0.25;
  return [math.max(spec.fontSize, l.width + 2 * m), math.max(spec.fontSize, l.height + m)];
}

/// Auto box: the box that fits every text the layer shows (its keys'
/// too), so it doesn't jump from key to key.
List<double> fitTextBoxAll(TextSpec spec) {
  var w = 0.0, h = 0.0;
  for (final t in {spec.text, for (final k in spec.keys) k.value as String}) {
    final b = fitTextBox(spec.copy()..text = t);
    w = math.max(w, b[0]);
    h = math.max(h, b[1]);
  }
  return [w, h];
}

/// Turns a text layer into a plain vector shape ("compound": the letter
/// outlines, filled with the text colour) in the same box, so effects on
/// it keep their place. Stroke, shadow and background are not kept.
void convertTextToShape(Layer layer) {
  final c = layer.content;
  final spec = c.text;
  if (c.shape != 'text' || spec == null) return;
  final l = layoutText(spec, c.offset, c.size);
  layer.content = Content(
    shape: 'compound',
    offset: [...c.offset],
    size: [...c.size],
    contours: flattenPath(l.path),
  );
  layer.color = spec.color;
  layer.name = layer.name.startsWith('text') ? layer.name.replaceFirst('text', 'shape') : layer.name;
}

int _textCounter = 0;

/// A new text layer centred on the frame.
Layer createTextLayer({double fontSize = 48, String text = 'Text'}) {
  _textCounter++;
  final spec = TextSpec(text: text, fontSize: fontSize, autoBox: true);
  final box = fitTextBox(spec);
  return Layer(
    id: 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}t$_textCounter',
    name: 'text_$_textCounter',
    transform: Transform(
      anchor: track([0.5, 0.5], true),
      scale: track([1.0, 1.0]),
      rotation: track(0.0),
      opacity: track(1.0),
    ),
    content: Content(shape: 'text', offset: [0, 0], size: box, text: spec),
  );
}

/// Bounding box of a compound shape's outlines (for tests / tools).
BoundingBox contoursBounds(List<List<List<double>>> contours) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final c in contours) {
    for (final p in c) {
      x0 = math.min(x0, p[0]);
      x1 = math.max(x1, p[0]);
      y0 = math.min(y0, p[1]);
      y1 = math.max(y1, p[1]);
    }
  }
  return BoundingBox(minX: x0, maxX: x1, minY: y0, maxY: y1);
}
