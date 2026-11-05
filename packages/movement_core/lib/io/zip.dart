/// ============================================================
/// hand-rolled ZIP writer (STORE/no-compression - PNGs are already
/// compressed, so there's nothing to gain from deflate, and
/// implementing deflate from scratch isn't worth it here)
/// - pure, no Flutter/dart:ui dependency: stays testable with plain
///   `dart test`, same reasoning as movement-core/src/io/zip.js's own
///   split out of exportPng.js.
///
/// Ported from movement-core/src/io/zip.js. One real adaptation: JS's
/// bitwise operators work on 32-bit signed ints with `>>>` for unsigned
/// shifts; Dart's `int` doesn't wrap at 32 bits the same way, so `crc`
/// is kept explicitly in the 0..0xFFFFFFFF range throughout (never
/// negative), which makes a plain `>>` behave exactly like JS's `>>>`
/// on it - the algorithm itself is unchanged.
/// ============================================================
library;

import 'dart:convert';
import 'dart:typed_data';

// CRC32, standard polynomial 0xEDB88320 - verified against the known
// test vector "123456789" -> 0xCBF43926 (see test suite).
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var j = 0; j < 8; j++) {
      final mask = (crc & 1) == 1 ? 0xFFFFFFFF : 0;
      crc = (crc >> 1) ^ (0xEDB88320 & mask);
    }
  }
  return (~crc) & 0xFFFFFFFF;
}

class ZipFile {
  final String name;
  final Uint8List data;
  ZipFile(this.name, this.data);
}

/// builds a valid (if minimal) .zip as a list of byte-part Uint8Lists -
/// STORE method (no compression), one local header + data per file,
/// then a central directory, then the end-of-central-directory record.
/// returns the raw parts (not a single combined buffer) so callers can
/// concatenate or stream them as fits their platform.
List<Uint8List> buildZipParts(List<ZipFile> files) {
  final localParts = <Uint8List>[];
  final centralParts = <Uint8List>[];
  var offset = 0;

  for (final file in files) {
    final nameBytes = utf8.encode(file.name);
    final crc = crc32(file.data);
    final size = file.data.length;

    final local = Uint8List(30 + nameBytes.length);
    final dv = ByteData.sublistView(local);
    dv.setUint32(0, 0x04034b50, Endian.little);
    dv.setUint16(4, 20, Endian.little);
    dv.setUint16(6, 0, Endian.little);
    dv.setUint16(8, 0, Endian.little); // compression = 0 (store)
    dv.setUint16(10, 0, Endian.little);
    dv.setUint16(12, 0, Endian.little);
    dv.setUint32(14, crc, Endian.little);
    dv.setUint32(18, size, Endian.little);
    dv.setUint32(22, size, Endian.little);
    dv.setUint16(26, nameBytes.length, Endian.little);
    dv.setUint16(28, 0, Endian.little);
    local.setRange(30, 30 + nameBytes.length, nameBytes);

    localParts.add(local);
    localParts.add(file.data);

    final central = Uint8List(46 + nameBytes.length);
    final cdv = ByteData.sublistView(central);
    cdv.setUint32(0, 0x02014b50, Endian.little);
    cdv.setUint16(4, 20, Endian.little);
    cdv.setUint16(6, 20, Endian.little);
    cdv.setUint16(8, 0, Endian.little);
    cdv.setUint16(10, 0, Endian.little);
    cdv.setUint16(12, 0, Endian.little);
    cdv.setUint16(14, 0, Endian.little);
    cdv.setUint32(16, crc, Endian.little);
    cdv.setUint32(20, size, Endian.little);
    cdv.setUint32(24, size, Endian.little);
    cdv.setUint16(28, nameBytes.length, Endian.little);
    cdv.setUint16(30, 0, Endian.little);
    cdv.setUint16(32, 0, Endian.little);
    cdv.setUint16(34, 0, Endian.little);
    cdv.setUint16(36, 0, Endian.little);
    cdv.setUint32(38, 0, Endian.little);
    cdv.setUint32(42, offset, Endian.little);
    central.setRange(46, 46 + nameBytes.length, nameBytes);

    centralParts.add(central);
    offset += local.length + file.data.length;
  }

  final centralSize = centralParts.fold<int>(0, (s, p) => s + p.length);
  final centralOffset = offset;

  final end = Uint8List(22);
  final edv = ByteData.sublistView(end);
  edv.setUint32(0, 0x06054b50, Endian.little);
  edv.setUint16(4, 0, Endian.little);
  edv.setUint16(6, 0, Endian.little);
  edv.setUint16(8, files.length, Endian.little);
  edv.setUint16(10, files.length, Endian.little);
  edv.setUint32(12, centralSize, Endian.little);
  edv.setUint32(16, centralOffset, Endian.little);
  edv.setUint16(20, 0, Endian.little);

  return [...localParts, ...centralParts, end];
}
