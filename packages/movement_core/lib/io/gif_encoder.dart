/// ============================================================
/// Hand-rolled GIF89a encoder - pure, no Flutter/dart:ui dependency,
/// same reasoning as zip.dart's own doc comment (stays testable with
/// plain `dart test`; movement_core has no dart:ui at all). Callers in
/// movement_mobile convert each rendered `ui.Image` to raw RGBA bytes
/// (`image.toByteData(format: ui.ImageByteFormat.rawRgba)`) and hand
/// those to `encodeGif` here.
///
/// No JS equivalent to port from - movement-core (Electron/desktop) never had
/// a GIF exporter; asked for one on mobile specifically (full GIF format
/// configuration).
///
/// Rewritten for speed and size slow, crashing, no size control):
/// - colours: an exact palette when a frame has few enough, otherwise
///   median cut over a 32x32x32 histogram (fast whatever the size) with a
///   lookup table for the nearest colour, optional Floyd-Steinberg
///   dithering;
/// - LZW over an integer hash table (the classic compress(1) scheme);
/// - between opaque frames only the changed rectangle is written, the
///   unchanged pixels in it left see-through ([GifOptions.lossy] lets
///   nearly-unchanged count as unchanged: smaller files);
/// - a transparent frame is cropped to what it draws.
///
/// Earlier notes:
/// - median-cut color quantization down to <=256 colors per frame
///   (each frame gets its OWN local color table, not a single global
///   one shared across the whole animation - simpler than a two-pass
///   global palette and still gives every frame its own accurate
///   colors, at the cost of a a few more bytes per frame for the local
///   table header)
/// - a reserved transparent index for any source pixel whose alpha is
///   below a threshold (matches how a rendered frame's own background
///   is transparent wherever nothing was drawn - GIF has no partial
///   alpha, so this is a hard threshold, not a blend)
/// - standard GIF LZW compression (variable code size, clear/end
///   codes, sub-block framing)
/// - the NETSCAPE2.0 application extension for looping
/// ============================================================
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// one already-rendered frame to encode - `rgba` is exactly
/// `width*height*4` bytes, straight (non-premultiplied) RGBA8888,
/// row-major top-to-bottom (matches `ui.ImageByteFormat.rawRgba`).
class GifFrame {
  final int width;
  final int height;
  final Uint8List rgba;
  final int delayCentiseconds; // GIF's own delay unit is 1/100s
  GifFrame({
    required this.width,
    required this.height,
    required this.rgba,
    required this.delayCentiseconds,
  });
}

/// alpha strictly below this is treated as fully transparent (mapped to
/// the palette's reserved transparent index) - GIF has no partial
/// alpha, so this is necessarily a hard cutoff, not a blend.
const int gifAlphaThreshold = 128;

/// How a GIF is encoded: the size / quality knobs.
class GifOptions {
  /// Colours per frame, 2..256 (fewer: smaller, more banding).
  final int maxColors;

  /// Floyd-Steinberg dithering (smoother gradients, a bigger file).
  final bool dither;

  /// Between frames, how different a pixel may be and still count as
  /// unchanged (0: exact; ~8 hardly visible; more: smaller, smearier).
  final int lossy;

  /// Write only what changed since the last frame.
  final bool optimize;

  const GifOptions({this.maxColors = 256, this.dither = false, this.lossy = 0, this.optimize = true});

  /// A single "quality" 0..100 (100 best): colours, dithering and the
  /// change tolerance together.
  factory GifOptions.quality(int q) {
    q = q.clamp(0, 100);
    return GifOptions(
      maxColors: q >= 80 ? 256 : (q >= 60 ? 128 : (q >= 40 ? 64 : (q >= 20 ? 32 : 16))),
      dither: q >= 50,
      lossy: q >= 95 ? 0 : ((100 - q) / 4).round(),
    );
  }
}

/// encodes `frames` (all must share the same width/height - the first
/// frame's size becomes the GIF's own logical screen size) into a
/// complete GIF89a byte stream. `loopCount` 0 means loop forever.
Uint8List encodeGif({required List<GifFrame> frames, int loopCount = 0, GifOptions options = const GifOptions()}) {
  if (frames.isEmpty) {
    throw ArgumentError('encodeGif requires at least one frame');
  }
  final sink = GifEncoderSink(loopCount: loopCount, options: options);
  for (final f in frames) {
    sink.addFrame(f);
  }
  return sink.finish();
}

/// Streaming encoder: each frame is written as soon as it is added, so
/// only about one frame's pixels are held at a time.
class GifEncoderSink {
  final int loopCount;
  final GifOptions options;
  final BytesBuilder _out = BytesBuilder(copy: false);
  bool _headerWritten = false;
  int? _width;
  int? _height;
  bool _finished = false;

  // what the viewer shows after the last opaque frame (0xRRGGBB per
  // pixel), or null when the last frame was transparent / none yet.
  Int32List? _shown;

  GifEncoderSink({this.loopCount = 0, this.options = const GifOptions()});

  void addFrame(GifFrame frame) {
    if (_finished) {
      throw StateError('GifEncoderSink.addFrame called after finish()');
    }
    if (!_headerWritten) {
      _width = frame.width;
      _height = frame.height;
      _writeHeader(_out, frame.width, frame.height, loopCount);
      _headerWritten = true;
    } else if (frame.width != _width || frame.height != _height) {
      throw ArgumentError('every GifFrame must share the same width/height as the first');
    }
    _shown = _writeFrame(_out, frame, options, _shown);
  }

  /// writes the trailer and returns the complete GIF89a byte stream.
  Uint8List finish() {
    if (!_headerWritten) {
      throw ArgumentError('encodeGif requires at least one frame');
    }
    _finished = true;
    _out.addByte(0x3B); // trailer
    return _out.takeBytes();
  }
}

void _writeHeader(BytesBuilder out, int width, int height, int loopCount) {
  out.add(_ascii('GIF89a'));
  out.add(_uint16le(width));
  out.add(_uint16le(height));
  out.addByte(0x00); // no global color table
  out.addByte(0x00);
  out.addByte(0x00);
  // NETSCAPE2.0: loop N times (0 = forever).
  out.addByte(0x21);
  out.addByte(0xFF);
  out.addByte(0x0B);
  out.add(_ascii('NETSCAPE2.0'));
  out.addByte(0x03);
  out.addByte(0x01);
  out.add(_uint16le(loopCount));
  out.addByte(0x00);
}

/// Writes one frame; returns what is shown afterwards (for the next
/// frame's difference), or null.
Int32List? _writeFrame(BytesBuilder out, GifFrame frame, GifOptions o, Int32List? shown) {
  final w = frame.width, h = frame.height, rgba = frame.rgba;
  final n = w * h;
  var anyTransparent = false;
  for (var p = 3; p < n * 4; p += 4) {
    if (rgba[p] < gifAlphaThreshold) {
      anyTransparent = true;
      break;
    }
  }
  // the part to write and which of its pixels are "keep what is there".
  var x0 = 0, y0 = 0, x1 = w - 1, y1 = h - 1;
  Uint8List? keep; // 1: unchanged (written see-through), full-frame index
  final diff = o.optimize && !anyTransparent && shown != null;
  if (diff) {
    keep = Uint8List(n);
    final tol = o.lossy * 3;
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = y * w + x, i = p * 4;
        final s = shown[p];
        final d = (rgba[i] - ((s >> 16) & 0xFF)).abs() + (rgba[i + 1] - ((s >> 8) & 0xFF)).abs() + (rgba[i + 2] - (s & 0xFF)).abs();
        if (d <= tol) {
          keep[p] = 1;
        } else {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) {
      // nothing changed: one see-through pixel keeps the timing.
      _writeGce(out, frame.delayCentiseconds, 1, 0);
      _writeImage(out, 0, 0, 1, 1, const [0, 0], Uint8List(1));
      return shown;
    }
    x0 = minX;
    y0 = minY;
    x1 = maxX;
    y1 = maxY;
  } else if (anyTransparent) {
    // only what it draws (the rest is cleared anyway).
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (rgba[(y * w + x) * 4 + 3] >= gifAlphaThreshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) {
      _writeGce(out, frame.delayCentiseconds, 2, 0);
      _writeImage(out, 0, 0, 1, 1, const [0, 0], Uint8List(1));
      return null;
    }
    x0 = minX;
    y0 = minY;
    x1 = maxX;
    y1 = maxY;
  }
  final bw = x1 - x0 + 1, bh = y1 - y0 + 1;
  bool clear(int p) => (keep != null && keep[p] == 1) || rgba[p * 4 + 3] < gifAlphaThreshold;
  final needsClear = anyTransparent || diff;

  // the palette, from the pixels written.
  final maxColors = (needsClear ? o.maxColors.clamp(2, 255) : o.maxColors.clamp(2, 256)).toInt();
  final exact = <int, int>{};
  var tooMany = false;
  for (var y = y0; y <= y1 && !tooMany; y++) {
    for (var x = x0; x <= x1; x++) {
      final p = y * w + x;
      if (clear(p)) continue;
      final i = p * 4;
      final rgb = (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
      if (!exact.containsKey(rgb)) {
        if (exact.length >= maxColors) {
          tooMany = true;
          break;
        }
        exact[rgb] = exact.length;
      }
    }
  }
  final List<int> palette;
  Int16List? lut;
  if (!tooMany) {
    palette = exact.keys.toList();
    if (palette.isEmpty) palette.add(0);
  } else {
    palette = _histogramPalette(rgba, w, x0, y0, x1, y1, clear, maxColors);
    lut = Int16List(32768)..fillRange(0, 32768, -1);
  }
  int? transparentIndex;
  if (needsClear) {
    transparentIndex = palette.length;
    palette.add(0);
  }
  int nearest(int r, int g, int b) {
    final key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
    final hit = lut![key];
    if (hit >= 0) return hit;
    var best = 0, bestD = 1 << 30;
    for (var k = 0; k < palette.length; k++) {
      if (k == transparentIndex) continue;
      final c = palette[k];
      final dr = ((c >> 16) & 0xFF) - r, dg = ((c >> 8) & 0xFF) - g, db = (c & 0xFF) - b;
      final d = dr * dr + dg * dg + db * db;
      if (d < bestD) {
        bestD = d;
        best = k;
      }
    }
    lut[key] = best;
    return best;
  }

  final indices = Uint8List(bw * bh);
  // dithering: the rounding error of each pixel spread to its neighbours.
  final dither = tooMany && o.dither;
  final errA = dither ? Int16List((bw + 2) * 3) : null, errB = dither ? Int16List((bw + 2) * 3) : null;
  var cur = errA, next = errB;
  for (var y = 0; y < bh; y++) {
    if (dither) next!.fillRange(0, next.length, 0);
    for (var x = 0; x < bw; x++) {
      final p = (y + y0) * w + (x + x0), i = p * 4;
      if (clear(p)) {
        indices[y * bw + x] = transparentIndex!;
        continue;
      }
      var r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      int k;
      if (!tooMany) {
        k = exact[(r << 16) | (g << 8) | b]!;
      } else if (dither) {
        final e = (x + 1) * 3;
        r = (r + cur![e] ~/ 16).clamp(0, 255);
        g = (g + cur[e + 1] ~/ 16).clamp(0, 255);
        b = (b + cur[e + 2] ~/ 16).clamp(0, 255);
        k = nearest(r, g, b);
        final c = palette[k];
        final er = r - ((c >> 16) & 0xFF), eg = g - ((c >> 8) & 0xFF), eb = b - (c & 0xFF);
        // 7 right, 3 down-left, 5 down, 1 down-right (sixteenths).
        cur[e + 3] += er * 7;
        cur[e + 4] += eg * 7;
        cur[e + 5] += eb * 7;
        next![e - 3] += er * 3;
        next[e - 2] += eg * 3;
        next[e - 1] += eb * 3;
        next[e] += er * 5;
        next[e + 1] += eg * 5;
        next[e + 2] += eb * 5;
        next[e + 3] += er;
        next[e + 4] += eg;
        next[e + 5] += eb;
      } else {
        k = nearest(r, g, b);
      }
      indices[y * bw + x] = k;
    }
    if (dither) {
      final t = cur;
      cur = next;
      next = t;
    }
  }

  _writeGce(out, frame.delayCentiseconds, anyTransparent ? 2 : (needsClear ? 1 : 0), transparentIndex);
  _writeImage(out, x0, y0, bw, bh, palette, indices);

  if (anyTransparent || !o.optimize) return null;
  // what is shown now.
  final now = shown ?? Int32List(n);
  for (var y = 0; y < bh; y++) {
    for (var x = 0; x < bw; x++) {
      final k = indices[y * bw + x];
      if (k == transparentIndex) continue;
      now[(y + y0) * w + (x + x0)] = palette[k];
    }
  }
  return now;
}

void _writeGce(BytesBuilder out, int delay, int disposal, int? transparentIndex) {
  out.addByte(0x21);
  out.addByte(0xF9);
  out.addByte(0x04);
  out.addByte((disposal << 2) | (transparentIndex != null ? 0x01 : 0x00));
  out.add(_uint16le(delay));
  out.addByte(transparentIndex ?? 0);
  out.addByte(0x00);
}

void _writeImage(BytesBuilder out, int x, int y, int w, int h, List<int> palette, Uint8List indices) {
  out.addByte(0x2C);
  out.add(_uint16le(x));
  out.add(_uint16le(y));
  out.add(_uint16le(w));
  out.add(_uint16le(h));
  final tableSizeBits = _colorTableSizeBits(palette.length);
  out.addByte(0x80 | tableSizeBits);
  _writeColorTable(out, palette, 1 << (tableSizeBits + 1));
  final minCodeSize = _lzwMinCodeSize(palette.length);
  out.addByte(minCodeSize);
  _writeSubBlocks(out, _lzwCompress(indices, minCodeSize));
}

int _colorTableSizeBits(int paletteLength) {
  var bits = 0;
  while ((1 << (bits + 1)) < paletteLength) {
    bits++;
  }
  return bits;
}

void _writeColorTable(BytesBuilder out, List<int> palette, int tableSize) {
  final t = Uint8List(tableSize * 3);
  for (var i = 0; i < palette.length && i < tableSize; i++) {
    final rgb = palette[i];
    t[i * 3] = (rgb >> 16) & 0xFF;
    t[i * 3 + 1] = (rgb >> 8) & 0xFF;
    t[i * 3 + 2] = rgb & 0xFF;
  }
  out.add(t);
}

void _writeSubBlocks(BytesBuilder out, Uint8List data) {
  var offset = 0;
  while (offset < data.length) {
    final chunkLen = math.min(255, data.length - offset);
    out.addByte(chunkLen);
    out.add(Uint8List.sublistView(data, offset, offset + chunkLen));
    offset += chunkLen;
  }
  out.addByte(0x00);
}

Uint8List _ascii(String s) => Uint8List.fromList(s.codeUnits);
Uint8List _uint16le(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

/// Median cut over a 32x32x32 histogram of the written pixels: the box
/// with the widest channel is split at its weighted median until there
/// are `maxColors`; each box becomes the average of its real colours.
List<int> _histogramPalette(
    Uint8List rgba, int w, int x0, int y0, int x1, int y1, bool Function(int) clear, int maxColors) {
  final count = Int32List(32768);
  final sr = Float64List(32768), sg = Float64List(32768), sb = Float64List(32768);
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final p = y * w + x;
      if (clear(p)) continue;
      final i = p * 4;
      final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
      final k = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      count[k]++;
      sr[k] += r;
      sg[k] += g;
      sb[k] += b;
    }
  }
  final bins = <int>[
    for (var k = 0; k < 32768; k++)
      if (count[k] > 0) k
  ];
  if (bins.isEmpty) return [0];
  int ch(int k, int c) => (k >> (10 - c * 5)) & 31;
  final boxes = <List<int>>[bins];
  while (boxes.length < maxColors) {
    var bi = -1, bc = 0, bestRange = 0;
    for (var b = 0; b < boxes.length; b++) {
      final box = boxes[b];
      if (box.length < 2) continue;
      for (var c = 0; c < 3; c++) {
        var lo = 31, hi = 0;
        for (final k in box) {
          final v = ch(k, c);
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        if (hi - lo > bestRange) {
          bestRange = hi - lo;
          bi = b;
          bc = c;
        }
      }
    }
    if (bi < 0) break;
    final box = boxes[bi]..sort((a, b) => ch(a, bc).compareTo(ch(b, bc)));
    var total = 0;
    for (final k in box) {
      total += count[k];
    }
    var acc = 0, mid = box.length ~/ 2;
    for (var i = 0; i < box.length; i++) {
      acc += count[box[i]];
      if (acc * 2 >= total) {
        mid = (i + 1).clamp(1, box.length - 1);
        break;
      }
    }
    boxes
      ..removeAt(bi)
      ..insert(bi, box.sublist(0, mid))
      ..insert(bi + 1, box.sublist(mid));
  }
  return [
    for (final box in boxes)
      () {
        var r = 0.0, g = 0.0, b = 0.0, t = 0;
        for (final k in box) {
          r += sr[k];
          g += sg[k];
          b += sb[k];
          t += count[k];
        }
        return ((r / t).round() << 16) | ((g / t).round() << 8) | (b / t).round();
      }()
  ];
}

int _lzwMinCodeSize(int paletteLength) {
  var bits = 2;
  while ((1 << bits) < paletteLength) {
    bits++;
  }
  return bits;
}

/// GIF LZW with the classic compress(1) open-addressing hash table:
/// variable code width from minCodeSize+1 up to 12 bits, a CLEAR code
/// when the table fills.
Uint8List _lzwCompress(Uint8List indices, int minCodeSize) {
  const bitsMax = 12, maxMaxCode = 1 << bitsMax, hsize = 5003;
  final htab = Int32List(hsize)..fillRange(0, hsize, -1);
  final codetab = Int32List(hsize);
  final initBits = minCodeSize + 1;
  final clearCode = 1 << minCodeSize, eofCode = clearCode + 1;
  var nBits = initBits;
  var maxCode = (1 << nBits) - 1;
  var freeEnt = clearCode + 2;
  var clearFlag = false;
  final out = BytesBuilder(copy: false);
  final buf = Uint8List(4096);
  var bufLen = 0;
  var acc = 0, accBits = 0;
  void emit(int code) {
    acc |= code << accBits;
    accBits += nBits;
    while (accBits >= 8) {
      buf[bufLen++] = acc & 0xFF;
      if (bufLen == buf.length) {
        out.add(Uint8List.fromList(buf));
        bufLen = 0;
      }
      acc >>= 8;
      accBits -= 8;
    }
    if (freeEnt > maxCode || clearFlag) {
      if (clearFlag) {
        nBits = initBits;
        maxCode = (1 << nBits) - 1;
        clearFlag = false;
      } else {
        nBits++;
        maxCode = nBits == bitsMax ? maxMaxCode : (1 << nBits) - 1;
      }
    }
    if (code == eofCode) {
      while (accBits > 0) {
        buf[bufLen++] = acc & 0xFF;
        if (bufLen == buf.length) {
          out.add(Uint8List.fromList(buf));
          bufLen = 0;
        }
        acc >>= 8;
        accBits -= 8;
      }
      accBits = 0;
    }
  }

  emit(clearCode);
  if (indices.isEmpty) {
    emit(eofCode);
    out.add(Uint8List.sublistView(buf, 0, bufLen));
    return out.takeBytes();
  }
  const hshift = 4;
  var ent = indices[0];
  outer:
  for (var p = 1; p < indices.length; p++) {
    final c = indices[p];
    final fcode = (c << bitsMax) + ent;
    var i = (c << hshift) ^ ent;
    if (htab[i] == fcode) {
      ent = codetab[i];
      continue;
    } else if (htab[i] >= 0) {
      final disp = i == 0 ? 1 : hsize - i;
      do {
        i -= disp;
        if (i < 0) i += hsize;
        if (htab[i] == fcode) {
          ent = codetab[i];
          continue outer;
        }
      } while (htab[i] >= 0);
    }
    emit(ent);
    ent = c;
    if (freeEnt < maxMaxCode) {
      codetab[i] = freeEnt++;
      htab[i] = fcode;
    } else {
      htab.fillRange(0, hsize, -1);
      freeEnt = clearCode + 2;
      clearFlag = true;
      emit(clearCode);
    }
  }
  emit(ent);
  emit(eofCode);
  out.add(Uint8List.sublistView(buf, 0, bufLen));
  return out.takeBytes();
}
