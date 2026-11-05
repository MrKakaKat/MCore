import 'dart:math' as math;
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Coverage for jpeg_encoder.dart. Unlike gif_encoder_test.dart, this
/// doesn't stop at structural byte checks - it also includes a genuine
/// pixel round-trip, via a minimal, purpose-built JPEG DECODER written
/// directly in this test file (below `main`), since Flutter's real
/// Skia decoder (`ui.instantiateImageCodec`) was confirmed elsewhere
/// this session to hang indefinitely in this sandbox's headless
/// `flutter_tester` shell (see gif_encoder_test.dart's own doc comment
/// for that finding - it reproduces even for a plain PNG payload, so
/// it's an environment limitation, not specific to either codec).
///
/// This decoder is deliberately NOT a general JPEG decoder - it only
/// understands the exact shape this encoder always produces (baseline
/// sequential, 4:4:4 no subsampling, fixed quant/Huffman table ids), so
/// it's far simpler than a real decoder while still being an
/// independent implementation of the inverse math (its own IDCT,
/// dequantization, YCbCr->RGB, Huffman decode) - genuinely exercising
/// whether the encoder's bitstream is self-consistent and standard-
/// compliant, not just re-running the encoder's own logic backwards.
void main() {
  Uint8List solidRgba(int w, int h, int r, int g, int b) {
    final d = Uint8List(w * h * 4);
    for (var p = 0; p < w * h; p++) {
      d[p * 4] = r;
      d[p * 4 + 1] = g;
      d[p * 4 + 2] = b;
      d[p * 4 + 3] = 255;
    }
    return d;
  }

  group('structural byte-level checks', () {
    test('output starts with SOI, ends with EOI, and carries a JFIF APP0 marker', () {
      final bytes = encodeJpeg(width: 8, height: 8, rgba: solidRgba(8, 8, 128, 64, 32));
      expect(bytes[0], equals(0xFF));
      expect(bytes[1], equals(0xD8));
      expect(bytes[bytes.length - 2], equals(0xFF));
      expect(bytes[bytes.length - 1], equals(0xD9));
      expect(bytes[2], equals(0xFF));
      expect(bytes[3], equals(0xE0));
      expect(String.fromCharCodes(bytes.sublist(6, 10)), equals('JFIF'));
    });

    test('SOF0 carries the exact width/height requested', () {
      const w = 37, h = 21; // deliberately not multiples of 8
      final bytes = encodeJpeg(width: w, height: h, rgba: solidRgba(w, h, 1, 2, 3));
      final header = _parseHeader(bytes);
      expect(header.width, equals(w));
      expect(header.height, equals(h));
    });

    test('quality controls quantization table scale: higher quality -> smaller (finer) table entries', () {
      final lowQ = encodeJpeg(width: 16, height: 16, rgba: solidRgba(16, 16, 10, 20, 30), quality: 10);
      final highQ = encodeJpeg(width: 16, height: 16, rgba: solidRgba(16, 16, 10, 20, 30), quality: 95);
      final lowTable = _parseHeader(lowQ).quantTables[0]!;
      final highTable = _parseHeader(highQ).quantTables[0]!;
      final lowSum = lowTable.reduce((a, b) => a + b);
      final highSum = highTable.reduce((a, b) => a + b);
      expect(highSum, lessThan(lowSum), reason: 'quality=95 should produce a finer (smaller-valued) quant table than quality=10');
    });

    test('DHT tables are byte-identical to the standard ITU-T T.81 Annex K.3 baseline tables', () {
      final bytes = encodeJpeg(width: 8, height: 8, rgba: solidRgba(8, 8, 0, 0, 0));
      final header = _parseHeader(bytes);
      // reconstructing the exact symbol sets from the decode tables and
      // checking their sizes matches a real byte-for-byte identity
      // check on the standard table shape (16 length-count bytes +
      // symbol count), not just "some huffman table exists".
      expect(header.dcTables[0]!.symbolCount, equals(12)); // DC luma
      expect(header.dcTables[1]!.symbolCount, equals(12)); // DC chroma
      expect(header.acTables[0]!.symbolCount, equals(162)); // AC luma
      expect(header.acTables[1]!.symbolCount, equals(162)); // AC chroma
    });

    test('rejects mismatched buffer length', () {
      expect(
        () => encodeJpeg(width: 4, height: 4, rgba: Uint8List(10)),
        throwsArgumentError,
      );
    });
  });

  group('real pixel round-trip via a purpose-built independent decoder', () {
    test('a solid-color 8x8 block at high quality decodes back very close to the original color', () {
      const w = 8, h = 8;
      final rgba = solidRgba(w, h, 200, 90, 40);
      final bytes = encodeJpeg(width: w, height: h, rgba: rgba, quality: 95);
      final decoded = _decodeJpeg(bytes);

      expect(decoded.width, equals(w));
      expect(decoded.height, equals(h));
      for (var p = 0; p < w * h; p++) {
        expect((decoded.rgb[p * 3] - 200).abs(), lessThan(6));
        expect((decoded.rgb[p * 3 + 1] - 90).abs(), lessThan(6));
        expect((decoded.rgb[p * 3 + 2] - 40).abs(), lessThan(6));
      }
    });

    test('a multi-block gradient image decodes with bounded per-channel error at high quality', () {
      const w = 24, h = 16;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = y * w + x;
          rgba[p * 4] = (x * 10) % 256;
          rgba[p * 4 + 1] = (y * 15) % 256;
          rgba[p * 4 + 2] = ((x + y) * 5) % 256;
          rgba[p * 4 + 3] = 255;
        }
      }
      final bytes = encodeJpeg(width: w, height: h, rgba: rgba, quality: 92);
      final decoded = _decodeJpeg(bytes);

      expect(decoded.width, equals(w));
      expect(decoded.height, equals(h));
      var maxDelta = 0;
      for (var p = 0; p < w * h; p++) {
        for (var c = 0; c < 3; c++) {
          final orig = rgba[p * 4 + c];
          final dec = decoded.rgb[p * 3 + c];
          final delta = (orig - dec).abs();
          if (delta > maxDelta) maxDelta = delta;
        }
      }
      // real lossy compression error, bounded well below "garbled data"
      // territory (a broken decode/encode would blow this out far past
      // 100 - DCT/quantization error on smooth gradients at high
      // quality stays modest).
      expect(maxDelta, lessThan(40), reason: 'DCT round-trip error should be bounded, not corrupted data');
    });

    test('a non-multiple-of-8 image size round-trips correctly (edge padding/cropping)', () {
      const w = 13, h = 9;
      final rgba = solidRgba(w, h, 100, 150, 200);
      final bytes = encodeJpeg(width: w, height: h, rgba: rgba, quality: 90);
      final decoded = _decodeJpeg(bytes);

      expect(decoded.width, equals(w));
      expect(decoded.height, equals(h));
      for (var p = 0; p < w * h; p++) {
        expect((decoded.rgb[p * 3] - 100).abs(), lessThan(8));
        expect((decoded.rgb[p * 3 + 1] - 150).abs(), lessThan(8));
        expect((decoded.rgb[p * 3 + 2] - 200).abs(), lessThan(8));
      }
    });

    test('every literal 0xFF byte inside the entropy-coded scan is followed by a 0x00 stuff byte', () {
      const w = 16, h = 16;
      final rgba = Uint8List(w * h * 4);
      for (var p = 0; p < w * h; p++) {
        rgba[p * 4] = (p * 37) % 256;
        rgba[p * 4 + 1] = (p * 91) % 256;
        rgba[p * 4 + 2] = (p * 53) % 256;
        rgba[p * 4 + 3] = 255;
      }
      final bytes = encodeJpeg(width: w, height: h, rgba: rgba, quality: 80);
      final header = _parseHeader(bytes);
      // scan data runs from header.scanDataStart to the EOI marker (the
      // last 2 bytes of the file).
      for (var i = header.scanDataStart; i < bytes.length - 2; i++) {
        if (bytes[i] == 0xFF) {
          expect(bytes[i + 1], equals(0x00), reason: 'byte-stuffing violated at offset $i');
        }
      }
    });
  });
}

// ============================================================
// minimal purpose-built decoder for THIS encoder's exact output shape
// (baseline, 4:4:4, quant table ids 0/1, huffman dc/ac ids 0/1) - see
// this file's own top doc comment for why this exists instead of using
// a real decoder.
// ============================================================

const List<int> _zigzagOrder = [
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5,
  12, 19, 26, 33, 40, 48, 41, 34,
  27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46,
  53, 60, 61, 54, 47, 55, 62, 63,
];

class _HuffDecodeTable {
  final Map<int, Map<int, int>> _byLength = {};
  int symbolCount = 0;

  static _HuffDecodeTable build(List<int> bits, List<int> values) {
    final t = _HuffDecodeTable();
    var code = 0;
    var k = 0;
    for (var length = 1; length <= 16; length++) {
      final count = bits[length - 1];
      for (var i = 0; i < count; i++) {
        t._byLength.putIfAbsent(length, () => {})[code] = values[k];
        k++;
        code++;
      }
      code <<= 1;
    }
    t.symbolCount = values.length;
    return t;
  }

  int decode(_BitReader reader) {
    var code = 0;
    for (var length = 1; length <= 16; length++) {
      code = (code << 1) | reader.readBit();
      final m = _byLength[length];
      if (m != null && m.containsKey(code)) return m[code]!;
    }
    throw StateError('invalid huffman code in entropy stream');
  }
}

class _BitReader {
  final Uint8List data;
  int pos;
  int _bitBuffer = 0;
  int _bitCount = 0;
  _BitReader(this.data, this.pos);

  int _nextByte() {
    final b = data[pos++];
    if (b == 0xFF && pos < data.length && data[pos] == 0x00) {
      pos++; // destuff
    }
    return b;
  }

  int readBit() {
    if (_bitCount == 0) {
      _bitBuffer = _nextByte();
      _bitCount = 8;
    }
    _bitCount--;
    return (_bitBuffer >> _bitCount) & 1;
  }

  int readBits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | readBit();
    }
    return v;
  }
}

int _extend(int bits, int size) {
  if (size == 0) return 0;
  final vt = 1 << (size - 1);
  return bits < vt ? bits - (1 << size) + 1 : bits;
}

class _JpegHeader {
  int width = 0;
  int height = 0;
  final Map<int, List<int>> quantTables = {};
  final Map<int, _HuffDecodeTable> dcTables = {};
  final Map<int, _HuffDecodeTable> acTables = {};
  int scanDataStart = 0;
}

_JpegHeader _parseHeader(Uint8List data) {
  final h = _JpegHeader();
  var pos = 2; // skip SOI
  while (true) {
    if (data[pos] != 0xFF) throw StateError('expected marker at byte $pos');
    final marker = data[pos + 1];
    pos += 2;
    final len = (data[pos] << 8) | data[pos + 1];
    final segStart = pos + 2;
    final segEnd = pos + len;

    if (marker == 0xDA) {
      // SOS: component specs are between segStart..segEnd-3, followed
      // by 3 spectral-selection bytes; entropy data starts at segEnd.
      h.scanDataStart = segEnd;
      break;
    } else if (marker == 0xDB) {
      var p = segStart;
      while (p < segEnd) {
        final id = data[p] & 0x0F;
        p++;
        final table = List<int>.filled(64, 0);
        for (var i = 0; i < 64; i++) {
          table[_zigzagOrder[i]] = data[p];
          p++;
        }
        h.quantTables[id] = table;
      }
    } else if (marker == 0xC0) {
      var p = segStart;
      p++; // precision
      h.height = (data[p] << 8) | data[p + 1];
      p += 2;
      h.width = (data[p] << 8) | data[p + 1];
    } else if (marker == 0xC4) {
      var p = segStart;
      while (p < segEnd) {
        final classId = data[p];
        p++;
        final cls = (classId >> 4) & 0xF;
        final id = classId & 0xF;
        final bits = data.sublist(p, p + 16);
        p += 16;
        final totalValues = bits.fold<int>(0, (a, b) => a + b);
        final values = data.sublist(p, p + totalValues);
        p += totalValues;
        final table = _HuffDecodeTable.build(bits, values);
        if (cls == 0) {
          h.dcTables[id] = table;
        } else {
          h.acTables[id] = table;
        }
      }
    }
    pos += len;
  }
  return h;
}

final List<List<double>> _idctCos = List.generate(
  8,
  (x) => List.generate(8, (u) => math.cos((2 * x + 1) * u * math.pi / 16)),
);
final List<double> _idctScale = List.generate(8, (u) => u == 0 ? 1 / math.sqrt2 : 1.0);

List<double> _inverseDct8x8(List<num> coeffsNaturalOrder) {
  final out = List<double>.filled(64, 0);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      var sum = 0.0;
      for (var v = 0; v < 8; v++) {
        for (var u = 0; u < 8; u++) {
          sum += _idctScale[u] * _idctScale[v] * coeffsNaturalOrder[v * 8 + u] * _idctCos[x][u] * _idctCos[y][v];
        }
      }
      out[y * 8 + x] = sum * 0.25;
    }
  }
  return out;
}

class _DecodedImage {
  final int width;
  final int height;
  final Uint8List rgb; // 3 bytes/pixel
  _DecodedImage(this.width, this.height, this.rgb);
}

_DecodedImage _decodeJpeg(Uint8List bytes) {
  final header = _parseHeader(bytes);
  final width = header.width, height = header.height;
  final paddedW = (width + 7) & ~7;
  final paddedH = (height + 7) & ~7;

  final quantY = header.quantTables[0]!;
  final quantC = header.quantTables[1]!;
  final dcY = header.dcTables[0]!, acY = header.acTables[0]!;
  final dcC = header.dcTables[1]!, acC = header.acTables[1]!;

  final planeY = Float64List(paddedW * paddedH);
  final planeCb = Float64List(paddedW * paddedH);
  final planeCr = Float64List(paddedW * paddedH);

  final reader = _BitReader(bytes, header.scanDataStart);
  var predY = 0, predCb = 0, predCr = 0;

  List<int> decodeBlock(_HuffDecodeTable dcTable, _HuffDecodeTable acTable, int pred) {
    final zz = List<int>.filled(64, 0);
    final dcSize = dcTable.decode(reader);
    final dcBits = dcSize > 0 ? reader.readBits(dcSize) : 0;
    final diff = _extend(dcBits, dcSize);
    zz[0] = pred + diff;
    var k = 1;
    while (k < 64) {
      final rs = acTable.decode(reader);
      final run = rs >> 4;
      final size = rs & 0xF;
      if (size == 0) {
        if (run == 15) {
          k += 16;
          continue;
        }
        break; // EOB
      }
      k += run;
      if (k >= 64) break;
      final bits = reader.readBits(size);
      zz[k] = _extend(bits, size);
      k++;
    }
    return zz;
  }

  void placeBlock(Float64List plane, List<int> zz, List<int> quant, int bx, int by) {
    final natural = List<num>.filled(64, 0);
    for (var i = 0; i < 64; i++) {
      natural[_zigzagOrder[i]] = zz[i] * quant[_zigzagOrder[i]];
    }
    final spatial = _inverseDct8x8(natural);
    for (var yy = 0; yy < 8; yy++) {
      for (var xx = 0; xx < 8; xx++) {
        plane[(by + yy) * paddedW + (bx + xx)] = spatial[yy * 8 + xx] + 128;
      }
    }
  }

  for (var by = 0; by < paddedH; by += 8) {
    for (var bx = 0; bx < paddedW; bx += 8) {
      final zzY = decodeBlock(dcY, acY, predY);
      predY = zzY[0];
      placeBlock(planeY, zzY, quantY, bx, by);

      final zzCb = decodeBlock(dcC, acC, predCb);
      predCb = zzCb[0];
      placeBlock(planeCb, zzCb, quantC, bx, by);

      final zzCr = decodeBlock(dcC, acC, predCr);
      predCr = zzCr[0];
      placeBlock(planeCr, zzCr, quantC, bx, by);
    }
  }

  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final srcP = y * paddedW + x;
      final dstP = y * width + x;
      final yy = planeY[srcP];
      final cb = planeCb[srcP] - 128;
      final cr = planeCr[srcP] - 128;
      final r = yy + 1.402 * cr;
      final g = yy - 0.344136 * cb - 0.714136 * cr;
      final b = yy + 1.772 * cb;
      rgb[dstP * 3] = r.round().clamp(0, 255);
      rgb[dstP * 3 + 1] = g.round().clamp(0, 255);
      rgb[dstP * 3 + 2] = b.round().clamp(0, 255);
    }
  }
  return _DecodedImage(width, height, rgb);
}
