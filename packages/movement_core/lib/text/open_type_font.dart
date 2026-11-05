/// A small, pure-Dart OpenType reader - just what vector text needs:
/// character -> glyph (cmap formats 4, 6 and 12), advance widths (hmtx),
/// vertical metrics (hhea), glyph outlines (TrueType `glyf` incl.
/// composite glyphs, and CFF Type 2 charstrings incl. local/global
/// subroutines and CID-keyed fonts) and pair kerning (GPOS 'kern'
/// lookups, pair adjustment formats 1 and 2, plus the old `kern` table).
/// No hinting, no shaping beyond kerning (ligatures, right-to-left and
/// complex scripts are out of scope).
///
/// Outlines come out in font units, y up, as a list of PathCmd.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One outline command: 'M' move, 'L' line, 'Q' quadratic, 'C' cubic,
/// 'Z' close. `p` holds the points' coordinates (x, y pairs).
class PathCmd {
  final String op;
  final List<double> p;
  const PathCmd(this.op, [this.p = const []]);

  PathCmd transformed(double a, double b, double c, double d, double e, double f) {
    final out = <double>[];
    for (var i = 0; i + 1 < p.length; i += 2) {
      final x = p[i], y = p[i + 1];
      out
        ..add(a * x + c * y + e)
        ..add(b * x + d * y + f);
    }
    return PathCmd(op, out);
  }
}

class FontFormatException implements Exception {
  final String message;
  FontFormatException(this.message);
  @override
  String toString() => 'FontFormatException: $message';
}

class _Reader {
  final ByteData d;
  _Reader(Uint8List bytes) : d = ByteData.sublistView(bytes);
  int u8(int o) => d.getUint8(o);
  int u16(int o) => d.getUint16(o);
  int i16(int o) => d.getInt16(o);
  int u32(int o) => d.getUint32(o);
  int i32(int o) => d.getInt32(o);
  String tag(int o) => String.fromCharCodes([u8(o), u8(o + 1), u8(o + 2), u8(o + 3)]);
  int get length => d.lengthInBytes;
}

class OpenTypeFont {
  final Uint8List bytes;
  final _Reader _r;
  final Map<String, int> _tables = {};
  late final int unitsPerEm;
  late final int ascender;
  late final int descender;
  late final int lineGap;
  late final int numGlyphs;
  late final int _numHMetrics;
  late final int _indexToLocFormat;
  late final String familyName;
  final Map<int, int> _cmap = {};
  final Map<int, List<PathCmd>> _glyphCache = {};
  final Map<int, double> _kernCache = {};
  _Cff? _cff;

  OpenTypeFont._(this.bytes) : _r = _Reader(bytes);

  /// Parses a .ttf / .otf (or the first font of a .ttc).
  factory OpenTypeFont.parse(Uint8List bytes) {
    final f = OpenTypeFont._(bytes);
    try {
      f._parse();
    } on FontFormatException {
      rethrow;
    } catch (e) {
      throw FontFormatException('unreadable font ($e)');
    }
    return f;
  }

  bool get isCff => _cff != null;

  void _parse() {
    if (_r.length < 12) throw FontFormatException('too short');
    var base = 0;
    if (_r.tag(0) == 'ttcf') base = _r.u32(12);
    final version = _r.u32(base);
    if (version != 0x00010000 && _r.tag(base) != 'OTTO' && _r.tag(base) != 'true') {
      throw FontFormatException('not a TrueType/OpenType font');
    }
    final numTables = _r.u16(base + 4);
    for (var i = 0; i < numTables; i++) {
      final rec = base + 12 + i * 16;
      _tables[_r.tag(rec)] = _r.u32(rec + 8);
    }
    for (final t in ['head', 'hhea', 'maxp', 'hmtx', 'cmap']) {
      if (!_tables.containsKey(t)) throw FontFormatException('missing $t table');
    }
    final head = _tables['head']!;
    unitsPerEm = _r.u16(head + 18);
    _indexToLocFormat = _r.i16(head + 50);
    final hhea = _tables['hhea']!;
    ascender = _r.i16(hhea + 4);
    descender = _r.i16(hhea + 6);
    lineGap = _r.i16(hhea + 8);
    _numHMetrics = _r.u16(hhea + 34);
    numGlyphs = _r.u16(_tables['maxp']! + 4);
    _parseCmap();
    if (_tables.containsKey('CFF ')) {
      _cff = _Cff(_r, _tables['CFF ']!);
    } else if (!_tables.containsKey('glyf') || !_tables.containsKey('loca')) {
      throw FontFormatException('no glyph outlines (CFF2 / bitmap fonts are not supported)');
    }
    familyName = _readName() ?? 'Font';
  }

  // ===== cmap =====

  void _parseCmap() {
    final cmap = _tables['cmap']!;
    final n = _r.u16(cmap + 2);
    int? best;
    var bestRank = -1;
    for (var i = 0; i < n; i++) {
      final rec = cmap + 4 + i * 8;
      final platform = _r.u16(rec), encoding = _r.u16(rec + 2);
      final off = cmap + _r.u32(rec + 4);
      final format = _r.u16(off);
      var rank = -1;
      if (platform == 3 && encoding == 10 && format == 12) rank = 4;
      if (platform == 0 && (encoding == 4 || encoding == 6) && format == 12) rank = 4;
      if (platform == 3 && encoding == 1 && format == 4) rank = 3;
      if (platform == 0 && format == 4) rank = 2;
      if (platform == 3 && encoding == 0 && format == 4) rank = 1; // symbol
      if (format == 6 && rank < 0) rank = 0;
      if (rank > bestRank) {
        bestRank = rank;
        best = off;
      }
    }
    if (best == null) throw FontFormatException('no usable cmap');
    final format = _r.u16(best);
    if (format == 4) {
      final segX2 = _r.u16(best + 6);
      final ends = best + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2;
      for (var s = 0; s < segX2 ~/ 2; s++) {
        final end = _r.u16(ends + s * 2), start = _r.u16(starts + s * 2);
        final delta = _r.i16(deltas + s * 2), rangeOffset = _r.u16(ranges + s * 2);
        for (var c = start; c <= end && c != 0xFFFF; c++) {
          int g;
          if (rangeOffset == 0) {
            g = (c + delta) & 0xFFFF;
          } else {
            final addr = ranges + s * 2 + rangeOffset + (c - start) * 2;
            g = _r.u16(addr);
            if (g != 0) g = (g + delta) & 0xFFFF;
          }
          if (g != 0) _cmap[c] = g;
        }
      }
    } else if (format == 12) {
      final groups = _r.u32(best + 12);
      for (var i = 0; i < groups; i++) {
        final g = best + 16 + i * 12;
        final start = _r.u32(g), end = _r.u32(g + 4), gid = _r.u32(g + 8);
        for (var c = start; c <= end; c++) {
          _cmap[c] = gid + (c - start);
        }
      }
    } else if (format == 6) {
      final first = _r.u16(best + 6), count = _r.u16(best + 8);
      for (var i = 0; i < count; i++) {
        final g = _r.u16(best + 10 + i * 2);
        if (g != 0) _cmap[first + i] = g;
      }
    } else {
      throw FontFormatException('cmap format $format is not supported');
    }
  }

  /// The glyph for a Unicode code point, 0 (.notdef) if the font lacks it.
  int glyphIndex(int codePoint) => _cmap[codePoint] ?? 0;

  bool hasGlyph(int codePoint) => _cmap.containsKey(codePoint);

  /// Advance width in font units.
  int advance(int gid) {
    final hmtx = _tables['hmtx']!;
    final i = gid < _numHMetrics ? gid : _numHMetrics - 1;
    return _r.u16(hmtx + i * 4);
  }

  // ===== name =====

  String? _readName() {
    final t = _tables['name'];
    if (t == null) return null;
    final count = _r.u16(t + 2), strings = t + _r.u16(t + 4);
    String? found;
    for (final wanted in [1, 4]) {
      for (var i = 0; i < count; i++) {
        final rec = t + 6 + i * 12;
        final platform = _r.u16(rec), nameId = _r.u16(rec + 6);
        if (nameId != wanted) continue;
        final len = _r.u16(rec + 8), off = strings + _r.u16(rec + 10);
        if (platform == 3 || platform == 0) {
          final units = [for (var k = 0; k + 1 < len; k += 2) _r.u16(off + k)];
          found = String.fromCharCodes(units);
        } else if (platform == 1) {
          found = latin1.decode(bytes.sublist(off, off + len), allowInvalid: true);
        }
        if (found != null && found.isNotEmpty) return found;
      }
    }
    return found;
  }

  // ===== outlines =====

  /// The glyph's outline, font units, y up.
  List<PathCmd> glyphPath(int gid) {
    if (gid < 0 || gid >= numGlyphs) return const [];
    return _glyphCache.putIfAbsent(gid, () {
      try {
        return _cff != null ? _cff!.glyph(gid) : _glyfPath(gid, 0);
      } catch (_) {
        return const <PathCmd>[]; // a broken glyph draws nothing
      }
    });
  }

  int _locaOffset(int gid) {
    final loca = _tables['loca']!;
    return _indexToLocFormat == 0 ? _r.u16(loca + gid * 2) * 2 : _r.u32(loca + gid * 4);
  }

  List<PathCmd> _glyfPath(int gid, int depth) {
    if (depth > 8) return const [];
    final start = _locaOffset(gid), end = _locaOffset(gid + 1);
    if (end <= start) return const []; // empty glyph (space)
    final g = _tables['glyf']! + start;
    final nContours = _r.i16(g);
    if (nContours >= 0) return _simpleGlyph(g, nContours);
    return _compositeGlyph(g, depth);
  }

  List<PathCmd> _simpleGlyph(int g, int nContours) {
    final endPts = [for (var i = 0; i < nContours; i++) _r.u16(g + 10 + i * 2)];
    if (endPts.isEmpty) return const [];
    final nPts = endPts.last + 1;
    var o = g + 10 + nContours * 2;
    o += 2 + _r.u16(o); // instructions
    final flags = <int>[];
    while (flags.length < nPts) {
      final f = _r.u8(o++);
      flags.add(f);
      if (f & 8 != 0) {
        var rep = _r.u8(o++);
        while (rep-- > 0) {
          flags.add(f);
        }
      }
    }
    final xs = List<int>.filled(nPts, 0), ys = List<int>.filled(nPts, 0);
    var v = 0;
    for (var i = 0; i < nPts; i++) {
      final f = flags[i];
      if (f & 2 != 0) {
        final dx = _r.u8(o++);
        v += (f & 16 != 0) ? dx : -dx;
      } else if (f & 16 == 0) {
        v += _r.i16(o);
        o += 2;
      }
      xs[i] = v;
    }
    v = 0;
    for (var i = 0; i < nPts; i++) {
      final f = flags[i];
      if (f & 4 != 0) {
        final dy = _r.u8(o++);
        v += (f & 32 != 0) ? dy : -dy;
      } else if (f & 32 == 0) {
        v += _r.i16(o);
        o += 2;
      }
      ys[i] = v;
    }
    final out = <PathCmd>[];
    var s = 0;
    for (final e in endPts) {
      _quadContour(out, [
        for (var i = s; i <= e; i++) (x: xs[i].toDouble(), y: ys[i].toDouble(), on: flags[i] & 1 != 0)
      ]);
      s = e + 1;
    }
    return out;
  }

  /// A TrueType contour (on/off-curve points, implied midpoints) as
  /// quadratic path commands.
  void _quadContour(List<PathCmd> out, List<({double x, double y, bool on})> pts) {
    if (pts.isEmpty) return;
    // start on an on-curve point (or the midpoint of the first two off ones).
    var startIdx = pts.indexWhere((p) => p.on);
    ({double x, double y}) start;
    List<({double x, double y, bool on})> seq;
    if (startIdx < 0) {
      start = (x: (pts[0].x + pts[1 % pts.length].x) / 2, y: (pts[0].y + pts[1 % pts.length].y) / 2);
      seq = [...pts];
    } else {
      start = (x: pts[startIdx].x, y: pts[startIdx].y);
      seq = [...pts.sublist(startIdx + 1), ...pts.sublist(0, startIdx)];
    }
    out.add(PathCmd('M', [start.x, start.y]));
    ({double x, double y})? ctrl;
    for (final p in [...seq, (x: start.x, y: start.y, on: true)]) {
      if (p.on) {
        if (ctrl != null) {
          out.add(PathCmd('Q', [ctrl.x, ctrl.y, p.x, p.y]));
          ctrl = null;
        } else {
          out.add(PathCmd('L', [p.x, p.y]));
        }
      } else {
        if (ctrl != null) {
          final mx = (ctrl.x + p.x) / 2, my = (ctrl.y + p.y) / 2;
          out.add(PathCmd('Q', [ctrl.x, ctrl.y, mx, my]));
        }
        ctrl = (x: p.x, y: p.y);
      }
    }
    out.add(const PathCmd('Z'));
  }

  List<PathCmd> _compositeGlyph(int g, int depth) {
    final out = <PathCmd>[];
    var o = g + 10;
    while (true) {
      final flags = _r.u16(o), glyph = _r.u16(o + 2);
      o += 4;
      double dx, dy;
      if (flags & 1 != 0) {
        dx = _r.i16(o).toDouble();
        dy = _r.i16(o + 2).toDouble();
        o += 4;
      } else {
        dx = _r.d.getInt8(o).toDouble();
        dy = _r.d.getInt8(o + 1).toDouble();
        o += 2;
      }
      if (flags & 2 == 0) {
        dx = 0; // point-matching anchors are not supported: place at origin
        dy = 0;
      }
      double a = 1, b = 0, c = 0, d = 1;
      double f2dot14(int off) => _r.i16(off) / 16384;
      if (flags & 8 != 0) {
        a = d = f2dot14(o);
        o += 2;
      } else if (flags & 0x40 != 0) {
        a = f2dot14(o);
        d = f2dot14(o + 2);
        o += 4;
      } else if (flags & 0x80 != 0) {
        a = f2dot14(o);
        b = f2dot14(o + 2);
        c = f2dot14(o + 4);
        d = f2dot14(o + 6);
        o += 8;
      }
      for (final cmd in _glyfPath(glyph, depth + 1)) {
        out.add(cmd.transformed(a, b, c, d, dx, dy));
      }
      if (flags & 0x20 == 0) break;
    }
    return out;
  }

  // ===== kerning =====

  /// Horizontal kerning between two glyphs, font units (usually negative).
  double kerning(int left, int right) {
    final key = left * 65536 + right;
    return _kernCache.putIfAbsent(key, () {
      try {
        return _gposKern(left, right) ?? _kernTable(left, right);
      } catch (_) {
        return 0.0;
      }
    });
  }

  List<int>? _kernSubtables;

  double? _gposKern(int left, int right) {
    final gpos = _tables['GPOS'];
    if (gpos == null) return null;
    _kernSubtables ??= _collectKernSubtables(gpos);
    if (_kernSubtables!.isEmpty) return null;
    for (final st in _kernSubtables!) {
      final v = _pairPos(st, left, right);
      if (v != null) return v;
    }
    return 0;
  }

  List<int> _collectKernSubtables(int gpos) {
    final featureList = gpos + _r.u16(gpos + 6), lookupList = gpos + _r.u16(gpos + 8);
    final lookups = <int>{};
    final nFeatures = _r.u16(featureList);
    for (var i = 0; i < nFeatures; i++) {
      final rec = featureList + 2 + i * 6;
      if (_r.tag(rec) != 'kern') continue;
      final feature = featureList + _r.u16(rec + 4);
      final n = _r.u16(feature + 2);
      for (var k = 0; k < n; k++) {
        lookups.add(_r.u16(feature + 4 + k * 2));
      }
    }
    final subtables = <int>[];
    for (final li in lookups.toList()..sort()) {
      final lookup = lookupList + _r.u16(lookupList + 2 + li * 2);
      final type = _r.u16(lookup);
      final n = _r.u16(lookup + 4);
      for (var k = 0; k < n; k++) {
        var st = lookup + _r.u16(lookup + 6 + k * 2);
        var stType = type;
        if (type == 9) {
          stType = _r.u16(st + 2);
          st = st + _r.u32(st + 4);
        }
        if (stType == 2) subtables.add(st);
      }
    }
    return subtables;
  }

  int _coverageIndex(int cov, int gid) {
    final format = _r.u16(cov);
    final n = _r.u16(cov + 2);
    if (format == 1) {
      var lo = 0, hi = n - 1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        final g = _r.u16(cov + 4 + mid * 2);
        if (g == gid) return mid;
        if (g < gid) {
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      return -1;
    }
    for (var i = 0; i < n; i++) {
      final r = cov + 4 + i * 6;
      final start = _r.u16(r), end = _r.u16(r + 2);
      if (gid >= start && gid <= end) return _r.u16(r + 4) + gid - start;
    }
    return -1;
  }

  int _classOf(int classDef, int gid) {
    final format = _r.u16(classDef);
    if (format == 1) {
      final start = _r.u16(classDef + 2), n = _r.u16(classDef + 4);
      final i = gid - start;
      return (i >= 0 && i < n) ? _r.u16(classDef + 6 + i * 2) : 0;
    }
    final n = _r.u16(classDef + 2);
    for (var i = 0; i < n; i++) {
      final r = classDef + 4 + i * 6;
      if (gid >= _r.u16(r) && gid <= _r.u16(r + 2)) return _r.u16(r + 4);
    }
    return 0;
  }

  int _valueSize(int format) {
    var n = 0;
    for (var f = format; f != 0; f >>= 1) {
      n += f & 1;
    }
    return n * 2;
  }

  /// XAdvance of a ValueRecord (0 if the format has none).
  double _xAdvance(int record, int format) {
    if (format & 4 == 0) return 0;
    var o = record;
    if (format & 1 != 0) o += 2;
    if (format & 2 != 0) o += 2;
    return _r.i16(o).toDouble();
  }

  double? _pairPos(int st, int left, int right) {
    final format = _r.u16(st);
    final covIndex = _coverageIndex(st + _r.u16(st + 2), left);
    if (covIndex < 0) return null;
    final vf1 = _r.u16(st + 4), vf2 = _r.u16(st + 6);
    final s1 = _valueSize(vf1), s2 = _valueSize(vf2);
    if (format == 1) {
      final pairSet = st + _r.u16(st + 10 + covIndex * 2);
      final n = _r.u16(pairSet);
      final recSize = 2 + s1 + s2;
      var lo = 0, hi = n - 1;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        final rec = pairSet + 2 + mid * recSize;
        final g = _r.u16(rec);
        if (g == right) return _xAdvance(rec + 2, vf1);
        if (g < right) {
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      return null;
    }
    if (format == 2) {
      final c1 = _classOf(st + _r.u16(st + 8), left);
      final c2 = _classOf(st + _r.u16(st + 10), right);
      final class2Count = _r.u16(st + 14);
      final rec = st + 16 + (c1 * class2Count + c2) * (s1 + s2);
      return _xAdvance(rec, vf1);
    }
    return null;
  }

  double _kernTable(int left, int right) {
    final t = _tables['kern'];
    if (t == null) return 0;
    final nTables = _r.u16(t + 2);
    var o = t + 4;
    for (var i = 0; i < nTables; i++) {
      final len = _r.u16(o + 2), coverage = _r.u16(o + 4);
      if ((coverage >> 8) == 0 && coverage & 1 != 0) {
        final n = _r.u16(o + 6);
        var lo = 0, hi = n - 1;
        final key = left * 65536 + right;
        while (lo <= hi) {
          final mid = (lo + hi) >> 1;
          final rec = o + 14 + mid * 6;
          final k = _r.u32(rec);
          if (k == key) return _r.i16(rec + 4).toDouble();
          if (k < key) {
            lo = mid + 1;
          } else {
            hi = mid - 1;
          }
        }
      }
      o += len;
    }
    return 0;
  }
}

// ===== CFF (Type 2 charstrings) =====

class _Index {
  final List<int> starts; // absolute offsets, count + 1 entries
  final int end;
  _Index(this.starts, this.end);
  int get count => starts.length - 1;
  (int, int) range(int i) => (starts[i], starts[i + 1]);
}

class _Cff {
  final _Reader r;
  final int base;
  late final _Index _charStrings;
  late final _Index _gsubrs;
  _Index? _subrs; // non-CID
  final List<_Index?> _fdSubrs = [];
  int? _fdSelect;
  late final int _nGlyphs;

  _Cff(this.r, this.base) {
    final hdrSize = r.u8(base + 2);
    final names = _readIndex(base + hdrSize);
    final topDicts = _readIndex(names.end);
    final strings = _readIndex(topDicts.end);
    _gsubrs = _readIndex(strings.end);
    final (ts, te) = topDicts.range(0);
    final top = _dict(ts, te);
    final cs = top[17];
    if (cs == null) throw FontFormatException('CFF without CharStrings');
    _charStrings = _readIndex(base + cs[0].toInt());
    _nGlyphs = _charStrings.count;
    final fdArray = top[1236], fdSelect = top[1237];
    if (fdArray != null && fdSelect != null) {
      final fds = _readIndex(base + fdArray[0].toInt());
      for (var i = 0; i < fds.count; i++) {
        final (a, b) = fds.range(i);
        _fdSubrs.add(_privateSubrs(_dict(a, b)[18]));
      }
      _fdSelect = base + fdSelect[0].toInt();
    } else {
      _subrs = _privateSubrs(top[18]);
    }
  }

  _Index? _privateSubrs(List<num>? priv) {
    if (priv == null || priv.length < 2) return null;
    final size = priv[0].toInt(), off = base + priv[1].toInt();
    final pd = _dict(off, off + size);
    final subrs = pd[19];
    return subrs == null ? null : _readIndex(off + subrs[0].toInt());
  }

  _Index _readIndex(int o) {
    final count = r.u16(o);
    if (count == 0) return _Index([o + 2], o + 2);
    final offSize = r.u8(o + 2);
    int off(int i) {
      var v = 0;
      for (var k = 0; k < offSize; k++) {
        v = (v << 8) | r.u8(o + 3 + i * offSize + k);
      }
      return v;
    }

    final dataStart = o + 3 + (count + 1) * offSize - 1;
    final starts = [for (var i = 0; i <= count; i++) dataStart + off(i)];
    return _Index(starts, starts.last);
  }

  /// A DICT as operator -> operands (two-byte operators as 1200 + b1).
  Map<int, List<num>> _dict(int start, int end) {
    final out = <int, List<num>>{};
    final ops = <num>[];
    var o = start;
    while (o < end) {
      final b0 = r.u8(o);
      if (b0 <= 21) {
        var key = b0;
        o++;
        if (b0 == 12) key = 1200 + r.u8(o++);
        out[key] = List.of(ops);
        ops.clear();
      } else if (b0 == 28) {
        ops.add(r.i16(o + 1));
        o += 3;
      } else if (b0 == 29) {
        ops.add(r.i32(o + 1));
        o += 5;
      } else if (b0 == 30) {
        // real number: nibbles until 0xf
        final sb = StringBuffer();
        o++;
        var done = false;
        while (!done) {
          final byte = r.u8(o++);
          for (final nib in [byte >> 4, byte & 0xF]) {
            if (nib == 0xF) {
              done = true;
              break;
            }
            sb.write(const ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.', 'E', 'E-', '', '-', ''][nib]);
          }
        }
        ops.add(double.tryParse(sb.toString()) ?? 0);
      } else if (b0 >= 32 && b0 <= 246) {
        ops.add(b0 - 139);
        o++;
      } else if (b0 >= 247 && b0 <= 250) {
        ops.add((b0 - 247) * 256 + r.u8(o + 1) + 108);
        o += 2;
      } else if (b0 >= 251 && b0 <= 254) {
        ops.add(-(b0 - 251) * 256 - r.u8(o + 1) - 108);
        o += 2;
      } else {
        o++;
      }
    }
    return out;
  }

  int _fdIndex(int gid) {
    final fs = _fdSelect;
    if (fs == null) return 0;
    final format = r.u8(fs);
    if (format == 0) return r.u8(fs + 1 + gid);
    if (format == 3) {
      final n = r.u16(fs + 1);
      for (var i = 0; i < n; i++) {
        final first = r.u16(fs + 3 + i * 3);
        final next = r.u16(fs + 3 + (i + 1) * 3);
        if (gid >= first && gid < next) return r.u8(fs + 3 + i * 3 + 2);
      }
    }
    return 0;
  }

  static int _bias(int count) => count < 1240 ? 107 : count < 33900 ? 1131 : 32768;

  List<PathCmd> glyph(int gid) {
    if (gid >= _nGlyphs) return const [];
    final subrs = _fdSelect != null ? (_fdSubrs.isEmpty ? null : _fdSubrs[_fdIndex(gid).clamp(0, _fdSubrs.length - 1)]) : _subrs;
    final st = _T2State();
    final (a, b) = _charStrings.range(gid);
    _run(a, b, st, subrs, 0);
    if (st.open) st.out.add(const PathCmd('Z'));
    return st.out;
  }

  /// Runs one charstring (or subroutine). Returns true on endchar.
  bool _run(int start, int end, _T2State s, _Index? subrs, int depth) {
    if (depth > 10) return true;
    final stack = s.stack;
    var o = start;
    void moveTo(double dx, double dy) {
      if (s.open) s.out.add(const PathCmd('Z'));
      s.x += dx;
      s.y += dy;
      s.out.add(PathCmd('M', [s.x, s.y]));
      s.open = true;
    }

    void lineTo(double dx, double dy) {
      s.x += dx;
      s.y += dy;
      s.out.add(PathCmd('L', [s.x, s.y]));
    }

    void curveTo(double dx1, double dy1, double dx2, double dy2, double dx3, double dy3) {
      final x1 = s.x + dx1, y1 = s.y + dy1;
      final x2 = x1 + dx2, y2 = y1 + dy2;
      s.x = x2 + dx3;
      s.y = y2 + dy3;
      s.out.add(PathCmd('C', [x1, y1, x2, y2, s.x, s.y]));
    }

    void stems() {
      // odd count: the first operand is the width.
      if (stack.length.isOdd && !s.widthSeen) stack.removeAt(0);
      s.widthSeen = true;
      s.nStems += stack.length ~/ 2;
      stack.clear();
    }

    void takeWidth(int expected) {
      if (!s.widthSeen && stack.length > expected) stack.removeAt(0);
      s.widthSeen = true;
    }

    while (o < end) {
      final b0 = r.u8(o);
      if (b0 == 28) {
        stack.add(r.i16(o + 1).toDouble());
        o += 3;
        continue;
      }
      if (b0 >= 32) {
        if (b0 <= 246) {
          stack.add((b0 - 139).toDouble());
          o++;
        } else if (b0 <= 250) {
          stack.add(((b0 - 247) * 256 + r.u8(o + 1) + 108).toDouble());
          o += 2;
        } else if (b0 <= 254) {
          stack.add((-(b0 - 251) * 256 - r.u8(o + 1) - 108).toDouble());
          o += 2;
        } else {
          stack.add(r.i32(o + 1) / 65536);
          o += 5;
        }
        continue;
      }
      o++;
      switch (b0) {
        case 1: // hstem
        case 3: // vstem
        case 18: // hstemhm
        case 23: // vstemhm
          stems();
        case 19: // hintmask
        case 20: // cntrmask
          stems();
          o += (s.nStems + 7) >> 3;
        case 21: // rmoveto
          takeWidth(2);
          moveTo(stack[0], stack[1]);
          stack.clear();
        case 22: // hmoveto
          takeWidth(1);
          moveTo(stack[0], 0);
          stack.clear();
        case 4: // vmoveto
          takeWidth(1);
          moveTo(0, stack[0]);
          stack.clear();
        case 5: // rlineto
          for (var i = 0; i + 1 < stack.length; i += 2) {
            lineTo(stack[i], stack[i + 1]);
          }
          stack.clear();
        case 6: // hlineto
        case 7: // vlineto
          var horizontal = b0 == 6;
          for (final v in stack) {
            horizontal ? lineTo(v, 0) : lineTo(0, v);
            horizontal = !horizontal;
          }
          stack.clear();
        case 8: // rrcurveto
          for (var i = 0; i + 5 < stack.length; i += 6) {
            curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]);
          }
          stack.clear();
        case 24: // rcurveline
          var i = 0;
          for (; i + 5 < stack.length - 2; i += 6) {
            curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]);
          }
          lineTo(stack[i], stack[i + 1]);
          stack.clear();
        case 25: // rlinecurve
          var i = 0;
          for (; i + 1 < stack.length - 6; i += 2) {
            lineTo(stack[i], stack[i + 1]);
          }
          curveTo(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]);
          stack.clear();
        case 26: // vvcurveto
          var i = 0;
          var dx1 = 0.0;
          if (stack.length.isOdd) dx1 = stack[i++];
          for (; i + 3 < stack.length; i += 4) {
            curveTo(dx1, stack[i], stack[i + 1], stack[i + 2], 0, stack[i + 3]);
            dx1 = 0;
          }
          stack.clear();
        case 27: // hhcurveto
          var i = 0;
          var dy1 = 0.0;
          if (stack.length.isOdd) dy1 = stack[i++];
          for (; i + 3 < stack.length; i += 4) {
            curveTo(stack[i], dy1, stack[i + 1], stack[i + 2], stack[i + 3], 0);
            dy1 = 0;
          }
          stack.clear();
        case 30: // vhcurveto
        case 31: // hvcurveto
          var horizontal = b0 == 31;
          var i = 0;
          while (i + 3 < stack.length) {
            final last = stack.length - i == 5;
            if (horizontal) {
              curveTo(stack[i], 0, stack[i + 1], stack[i + 2], last ? stack[i + 4] : 0, stack[i + 3]);
            } else {
              curveTo(0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], last ? stack[i + 4] : 0);
            }
            i += last ? 5 : 4;
            horizontal = !horizontal;
          }
          stack.clear();
        case 10: // callsubr
        case 29: // callgsubr
          final idx = subrs == null && b0 == 10 ? null : stack.removeLast().toInt();
          final table = b0 == 10 ? subrs : _gsubrs;
          if (table == null || idx == null) break;
          final i = idx + _bias(table.count);
          if (i < 0 || i >= table.count) break;
          final (a, bEnd) = table.range(i);
          if (_run(a, bEnd, s, subrs, depth + 1)) return true;
        case 11: // return
          return false;
        case 14: // endchar
          takeWidth(0);
          if (s.open) {
            s.out.add(const PathCmd('Z'));
            s.open = false;
          }
          return true;
        case 12:
          final b1 = r.u8(o++);
          _escape(b1, s, curveTo);
          stack.clear();
        default:
          stack.clear();
      }
    }
    return false;
  }

  void _escape(int op, _T2State s, void Function(double, double, double, double, double, double) curveTo) {
    final a = s.stack;
    switch (op) {
      case 35: // flex
        if (a.length >= 12) {
          curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
          curveTo(a[6], a[7], a[8], a[9], a[10], a[11]);
        }
      case 34: // hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6
        if (a.length >= 7) {
          curveTo(a[0], 0, a[1], a[2], a[3], 0);
          curveTo(a[4], 0, a[5], -a[2], a[6], 0);
        }
      case 36: // hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
        if (a.length >= 9) {
          curveTo(a[0], a[1], a[2], a[3], a[4], 0);
          curveTo(a[5], 0, a[6], a[7], a[8], -(a[1] + a[3] + a[7]));
        }
      case 37: // flex1: five dx/dy pairs + d6
        if (a.length >= 11) {
          final dx = a[0] + a[2] + a[4] + a[6] + a[8], dy = a[1] + a[3] + a[5] + a[7] + a[9];
          curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
          if (dx.abs() > dy.abs()) {
            curveTo(a[6], a[7], a[8], a[9], a[10], -dy);
          } else {
            curveTo(a[6], a[7], a[8], a[9], -dx, a[10]);
          }
        }
      default:
        break;
    }
  }
}

class _T2State {
  final List<double> stack = [];
  final List<PathCmd> out = [];
  double x = 0, y = 0;
  bool open = false;
  bool widthSeen = false;
  int nStems = 0;
}

/// Flattens an outline into closed polygons (curves split into
/// `segments` straight pieces).
List<List<List<double>>> flattenPath(List<PathCmd> cmds, {int segments = 8}) {
  final out = <List<List<double>>>[];
  List<List<double>>? cur;
  var x = 0.0, y = 0.0;
  for (final c in cmds) {
    switch (c.op) {
      case 'M':
        if (cur != null && cur.length > 2) out.add(cur);
        x = c.p[0];
        y = c.p[1];
        cur = [
          [x, y]
        ];
      case 'L':
        x = c.p[0];
        y = c.p[1];
        cur?.add([x, y]);
      case 'Q':
        for (var i = 1; i <= segments; i++) {
          final t = i / segments, mt = 1 - t;
          cur?.add([
            mt * mt * x + 2 * mt * t * c.p[0] + t * t * c.p[2],
            mt * mt * y + 2 * mt * t * c.p[1] + t * t * c.p[3],
          ]);
        }
        x = c.p[2];
        y = c.p[3];
      case 'C':
        for (var i = 1; i <= segments; i++) {
          final t = i / segments, mt = 1 - t;
          cur?.add([
            mt * mt * mt * x + 3 * mt * mt * t * c.p[0] + 3 * mt * t * t * c.p[2] + t * t * t * c.p[4],
            mt * mt * mt * y + 3 * mt * mt * t * c.p[1] + 3 * mt * t * t * c.p[3] + t * t * t * c.p[5],
          ]);
        }
        x = c.p[4];
        y = c.p[5];
      case 'Z':
        if (cur != null && cur.length > 2) {
          // drop the closing duplicate of the first point.
          final f = cur.first, l = cur.last;
          if ((f[0] - l[0]).abs() < 1e-9 && (f[1] - l[1]).abs() < 1e-9) cur.removeLast();
          out.add(cur);
        }
        cur = null;
    }
  }
  if (cur != null && cur.length > 2) out.add(cur);
  return out;
}
