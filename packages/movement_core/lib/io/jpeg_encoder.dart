/// ============================================================
/// Hand-rolled baseline JPEG (JFIF) encoder - pure, no Flutter/dart:ui
/// dependency, same reasoning as gif_encoder.dart's own doc comment
/// (dart:ui's toByteData only encodes PNG, never JPEG - so this is the
/// one still-frame export format that genuinely needs a hand-rolled
/// codec; PNG export needs no code here at all).
///
/// No JS equivalent to port from - movement-core (Electron/desktop) never had
/// a still-frame exporter with a format choice; asked for (jpg/png export of
/// the current playhead frame).
///
/// Implements standard baseline sequential JPEG (ITU-T T.81):
/// - RGB -> YCbCr (JFIF full-range) colorspace conversion
/// - 4:4:4 chroma sampling (no subsampling) - a deliberate
///   simplification: every component is sampled at full resolution,
///   trading a bit of extra file size for not having to implement
///   chroma downsampling/MCU interleaving math, and for keeping the
///   still-frame exporter closer to lossless at a given quality.
/// - 8x8 block DCT-II (direct/separable form, not a fast butterfly
///   algorithm - correctness over raw speed for a still-frame export
///   path that only ever runs once per export, not per video frame)
/// - the standard IJG quality-scaled luminance/chrominance quantization
///   tables (ITU-T T.81 Annex K.1's own base tables)
/// - the standard baseline Huffman tables (ITU-T T.81 Annex K.3) -
///   fixed tables, not a custom-optimized Huffman pass (matches what
///   every baseline JPEG encoder is allowed to ship without a
///   two-pass statistics gathering step)
/// ============================================================
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// encodes `rgba` (straight, non-premultiplied RGBA8888, row-major
/// top-to-bottom, exactly `width*height*4` bytes - matches
/// `ui.ImageByteFormat.rawRgba`) into a complete baseline JPEG/JFIF byte
/// stream. Alpha is ignored (JPEG has no alpha channel). `quality` is
/// the standard 1-100 IJG-style scale (higher = better/larger).
Uint8List encodeJpeg({required int width, required int height, required Uint8List rgba, int quality = 85}) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width and height must be positive');
  }
  if (rgba.length != width * height * 4) {
    throw ArgumentError('rgba must be exactly width*height*4 bytes');
  }
  final q = quality.clamp(1, 100);

  final lumaTable = _scaleQuantTable(_baseLumaTable, q);
  final chromaTable = _scaleQuantTable(_baseChromaTable, q);

  final (y, cb, cr) = _toYCbCr(width, height, rgba);

  final out = BytesBuilder();
  _writeSoi(out);
  _writeJfifHeader(out);
  _writeDqt(out, 0, lumaTable);
  _writeDqt(out, 1, chromaTable);
  _writeSof0(out, width, height);
  _writeDht(out, 0x00, _dcLumaBits, _dcLumaValues); // DC, table 0
  _writeDht(out, 0x10, _acLumaBits, _acLumaValues); // AC, table 0
  _writeDht(out, 0x01, _dcChromaBits, _dcChromaValues); // DC, table 1
  _writeDht(out, 0x11, _acChromaBits, _acChromaValues); // AC, table 1
  _writeSos(out);

  final dcLumaHuff = _HuffmanTable.build(_dcLumaBits, _dcLumaValues);
  final acLumaHuff = _HuffmanTable.build(_acLumaBits, _acLumaValues);
  final dcChromaHuff = _HuffmanTable.build(_dcChromaBits, _dcChromaValues);
  final acChromaHuff = _HuffmanTable.build(_acChromaBits, _acChromaValues);

  final paddedW = _roundUp8(width);
  final paddedH = _roundUp8(height);
  final bits = _BitWriter();
  var lastDcY = 0, lastDcCb = 0, lastDcCr = 0;

  for (var by = 0; by < paddedH; by += 8) {
    for (var bx = 0; bx < paddedW; bx += 8) {
      final yBlock = _extractBlock(y, width, height, bx, by);
      final cbBlock = _extractBlock(cb, width, height, bx, by);
      final crBlock = _extractBlock(cr, width, height, bx, by);

      lastDcY = _encodeBlock(bits, yBlock, lumaTable, dcLumaHuff, acLumaHuff, lastDcY);
      lastDcCb = _encodeBlock(bits, cbBlock, chromaTable, dcChromaHuff, acChromaHuff, lastDcCb);
      lastDcCr = _encodeBlock(bits, crBlock, chromaTable, dcChromaHuff, acChromaHuff, lastDcCr);
    }
  }
  out.add(bits.finishWithMarkerPadding());

  _writeEoi(out);
  return out.toBytes();
}

int _roundUp8(int v) => (v + 7) & ~7;

(Float64List, Float64List, Float64List) _toYCbCr(int width, int height, Uint8List rgba) {
  final n = width * height;
  final y = Float64List(n), cb = Float64List(n), cr = Float64List(n);
  for (var p = 0; p < n; p++) {
    final i = p * 4;
    final r = rgba[i].toDouble(), g = rgba[i + 1].toDouble(), b = rgba[i + 2].toDouble();
    y[p] = 0.299 * r + 0.587 * g + 0.114 * b;
    cb[p] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128;
    cr[p] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128;
  }
  return (y, cb, cr);
}

/// extracts an 8x8 block starting at (bx,by), clamping out-of-bounds
/// reads to the nearest valid source pixel (standard edge-replication
/// padding for the last partial block in each dimension).
Float64List _extractBlock(Float64List plane, int width, int height, int bx, int by) {
  final block = Float64List(64);
  for (var yy = 0; yy < 8; yy++) {
    final sy = (by + yy).clamp(0, height - 1);
    for (var xx = 0; xx < 8; xx++) {
      final sx = (bx + xx).clamp(0, width - 1);
      block[yy * 8 + xx] = plane[sy * width + sx];
    }
  }
  return block;
}

int _encodeBlock(
  _BitWriter bits,
  Float64List block,
  List<int> quantTable,
  _HuffmanTable dcHuff,
  _HuffmanTable acHuff,
  int lastDc,
) {
  final shifted = Float64List(64);
  for (var i = 0; i < 64; i++) {
    shifted[i] = block[i] - 128;
  }
  final dct = _forwardDct8x8(shifted);

  final quantized = List<int>.filled(64, 0);
  for (var i = 0; i < 64; i++) {
    quantized[i] = (dct[i] / quantTable[i]).round();
  }

  final zz = List<int>.filled(64, 0);
  for (var i = 0; i < 64; i++) {
    zz[i] = quantized[_zigzagOrder[i]];
  }

  // DC: differential-coded against the previous block of the same
  // component.
  final dcDiff = zz[0] - lastDc;
  _writeCategoryAndBits(bits, dcHuff, dcDiff);

  // AC: run-length of zeros + category/bits, ZRL (0xF0) for 16-zero
  // runs, EOB (0x00) once the rest of the block is all zeros.
  var run = 0;
  for (var k = 1; k < 64; k++) {
    final v = zz[k];
    if (v == 0) {
      run++;
      continue;
    }
    while (run > 15) {
      bits.writeCode(acHuff.codeFor(0xF0), acHuff.lengthFor(0xF0));
      run -= 16;
    }
    final size = _category(v);
    final symbol = (run << 4) | size;
    bits.writeCode(acHuff.codeFor(symbol), acHuff.lengthFor(symbol));
    bits.writeCode(_amplitudeBits(v, size), size);
    run = 0;
  }
  if (run > 0) {
    bits.writeCode(acHuff.codeFor(0x00), acHuff.lengthFor(0x00)); // EOB
  }

  return zz[0];
}

void _writeCategoryAndBits(_BitWriter bits, _HuffmanTable huff, int value) {
  final size = _category(value);
  bits.writeCode(huff.codeFor(size), huff.lengthFor(size));
  if (size > 0) {
    bits.writeCode(_amplitudeBits(value, size), size);
  }
}

int _category(int value) {
  var v = value.abs();
  var size = 0;
  while (v > 0) {
    v >>= 1;
    size++;
  }
  return size;
}

int _amplitudeBits(int value, int size) {
  if (size == 0) return 0;
  final mask = (1 << size) - 1;
  return value >= 0 ? (value & mask) : ((value - 1) & mask);
}

// ---- forward DCT (direct separable form) -------------------------------

final List<List<double>> _cosTable = List.generate(
  8,
  (x) => List.generate(8, (u) => math.cos((2 * x + 1) * u * math.pi / 16)),
);
final List<double> _dctScale = List.generate(8, (u) => u == 0 ? 1 / math.sqrt2 : 1.0);

Float64List _forwardDct8x8(Float64List block) {
  // rows: spatial -> frequency along x for each of the 8 rows.
  final temp = Float64List(64);
  for (var y = 0; y < 8; y++) {
    for (var u = 0; u < 8; u++) {
      var sum = 0.0;
      for (var x = 0; x < 8; x++) {
        sum += block[y * 8 + x] * _cosTable[x][u];
      }
      temp[y * 8 + u] = sum * _dctScale[u] * 0.5;
    }
  }
  // columns: frequency along y for each of the 8 (already-transformed) columns.
  final out = Float64List(64);
  for (var u = 0; u < 8; u++) {
    for (var v = 0; v < 8; v++) {
      var sum = 0.0;
      for (var y = 0; y < 8; y++) {
        sum += temp[y * 8 + u] * _cosTable[y][v];
      }
      out[v * 8 + u] = sum * _dctScale[v] * 0.5;
    }
  }
  return out;
}

// ---- quantization tables -------------------------------------------------

const List<int> _baseLumaTable = [
  16, 11, 10, 16, 24, 40, 51, 61, //
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101,
  72, 92, 95, 98, 112, 100, 103, 99,
];

const List<int> _baseChromaTable = [
  17, 18, 24, 47, 99, 99, 99, 99, //
  18, 21, 26, 66, 99, 99, 99, 99,
  24, 26, 56, 99, 99, 99, 99, 99,
  47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
];

/// the standard IJG quality->scale formula: quality<50 scales the base
/// table UP (more compression), quality>50 scales it DOWN (less
/// compression, closer to the base table's own values at quality=50).
List<int> _scaleQuantTable(List<int> base, int quality) {
  final scale = quality < 50 ? (5000 / quality) : (200 - quality * 2);
  return [
    for (final b in base) ((b * scale + 50) / 100).floor().clamp(1, 255),
  ];
}

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

// ---- standard baseline Huffman tables (ITU-T T.81 Annex K.3) -----------

const List<int> _dcLumaBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const List<int> _dcLumaValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

const List<int> _dcChromaBits = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const List<int> _dcChromaValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

const List<int> _acLumaBits = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D];
const List<int> _acLumaValues = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, //
  0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
  0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16,
  0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
  0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
  0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
  0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
  0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
  0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
  0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
  0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
  0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4,
  0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
  0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
  0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
  0xF9, 0xFA,
];

const List<int> _acChromaBits = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const List<int> _acChromaValues = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, //
  0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
  0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
  0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
  0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34,
  0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
  0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
  0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
  0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
  0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
  0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
  0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
  0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
  0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
  0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
  0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
  0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2,
  0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
  0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
  0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
  0xF9, 0xFA,
];

/// canonical Huffman code assignment from a JPEG-style bits/values pair
/// (ITU-T T.81 Annex C, "Generate_size_table"/"Generate_code_table").
class _HuffmanTable {
  final Map<int, int> _codeForSymbol = {};
  final Map<int, int> _lengthForSymbol = {};

  _HuffmanTable._();

  static _HuffmanTable build(List<int> bits, List<int> values) {
    final table = _HuffmanTable._();
    var code = 0;
    var k = 0;
    for (var length = 1; length <= 16; length++) {
      final countAtLength = bits[length - 1];
      for (var i = 0; i < countAtLength; i++) {
        table._codeForSymbol[values[k]] = code;
        table._lengthForSymbol[values[k]] = length;
        k++;
        code++;
      }
      code <<= 1;
    }
    return table;
  }

  int codeFor(int symbol) => _codeForSymbol[symbol]!;
  int lengthFor(int symbol) => _lengthForSymbol[symbol]!;
}

/// packs variable-width codes MSB-first into bytes (JPEG's own bit
/// order, the opposite of GIF's LSB-first packing), inserting a 0x00
/// stuff byte after every literal 0xFF byte in the entropy-coded data
/// (required so decoders never mistake compressed data for a marker).
class _BitWriter {
  final _bytes = BytesBuilder();
  int _bitBuffer = 0;
  int _bitCount = 0;

  void writeCode(int code, int length) {
    if (length == 0) return;
    _bitBuffer = (_bitBuffer << length) | (code & ((1 << length) - 1));
    _bitCount += length;
    while (_bitCount >= 8) {
      final byte = (_bitBuffer >> (_bitCount - 8)) & 0xFF;
      _emitByte(byte);
      _bitCount -= 8;
    }
  }

  void _emitByte(int byte) {
    _bytes.addByte(byte);
    if (byte == 0xFF) {
      _bytes.addByte(0x00);
    }
  }

  /// flushes any remaining partial byte, padding with 1-bits (the
  /// standard JPEG convention - a run of 1-bits can never accidentally
  /// decode as a valid shorter Huffman code plus extra data).
  Uint8List finishWithMarkerPadding() {
    if (_bitCount > 0) {
      final pad = 8 - _bitCount;
      final byte = ((_bitBuffer << pad) | ((1 << pad) - 1)) & 0xFF;
      _emitByte(byte);
      _bitCount = 0;
      _bitBuffer = 0;
    }
    return _bytes.toBytes();
  }
}

// ---- marker writers -------------------------------------------------------

void _writeSoi(BytesBuilder out) {
  out.addByte(0xFF);
  out.addByte(0xD8);
}

void _writeEoi(BytesBuilder out) {
  out.addByte(0xFF);
  out.addByte(0xD9);
}

void _writeJfifHeader(BytesBuilder out) {
  out.addByte(0xFF);
  out.addByte(0xE0);
  out.add(_uint16be(16)); // segment length, including these 2 bytes
  out.add('JFIF\x00'.codeUnits);
  out.addByte(1); // version major
  out.addByte(1); // version minor
  out.addByte(0); // density units: none
  out.add(_uint16be(1)); // x density
  out.add(_uint16be(1)); // y density
  out.addByte(0); // thumbnail width
  out.addByte(0); // thumbnail height
}

void _writeDqt(BytesBuilder out, int tableId, List<int> table) {
  out.addByte(0xFF);
  out.addByte(0xDB);
  out.add(_uint16be(2 + 1 + 64));
  out.addByte(tableId); // precision (0=8-bit) in high nibble, id in low nibble
  for (var i = 0; i < 64; i++) {
    out.addByte(table[_zigzagOrder[i]]);
  }
}

void _writeSof0(BytesBuilder out, int width, int height) {
  out.addByte(0xFF);
  out.addByte(0xC0);
  out.add(_uint16be(8 + 3 * 3));
  out.addByte(8); // sample precision
  out.add(_uint16be(height));
  out.add(_uint16be(width));
  out.addByte(3); // 3 components: Y, Cb, Cr
  // component id, sampling factors (1x1 - no subsampling), quant table id
  out.addByte(1);
  out.addByte(0x11);
  out.addByte(0);
  out.addByte(2);
  out.addByte(0x11);
  out.addByte(1);
  out.addByte(3);
  out.addByte(0x11);
  out.addByte(1);
}

void _writeDht(BytesBuilder out, int tableClassAndId, List<int> bits, List<int> values) {
  out.addByte(0xFF);
  out.addByte(0xC4);
  out.add(_uint16be(2 + 1 + 16 + values.length));
  out.addByte(tableClassAndId);
  out.add(Uint8List.fromList(bits));
  out.add(Uint8List.fromList(values));
}

void _writeSos(BytesBuilder out) {
  out.addByte(0xFF);
  out.addByte(0xDA);
  out.add(_uint16be(6 + 2 * 3));
  out.addByte(3); // 3 components
  out.addByte(1);
  out.addByte(0x00); // Y: DC table 0, AC table 0
  out.addByte(2);
  out.addByte(0x11); // Cb: DC table 1, AC table 1
  out.addByte(3);
  out.addByte(0x11); // Cr: DC table 1, AC table 1
  out.addByte(0); // spectral selection start
  out.addByte(63); // spectral selection end
  out.addByte(0); // successive approximation
}

Uint8List _uint16be(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.big);
