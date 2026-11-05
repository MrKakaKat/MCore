import 'dart:convert';
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  group('crc32', () {
    test("matches the standard test vector: '123456789' -> 0xCBF43926", () {
      final bytes = utf8.encode('123456789');
      expect(crc32(bytes), equals(0xCBF43926));
    });

    test('returns the identity value for an empty input', () {
      expect(crc32(Uint8List(0)), equals(0));
    });
  });

  group('buildZipParts', () {
    test('produces a local file header starting with the PK\\x03\\x04 signature', () {
      final data = Uint8List.fromList(utf8.encode('hello'));
      final parts = buildZipParts([ZipFile('a.txt', data)]);
      final dv = ByteData.sublistView(parts[0]);
      expect(dv.getUint32(0, Endian.little), equals(0x04034b50));
    });

    test('ends with the end-of-central-directory signature and correct file count', () {
      final data = Uint8List.fromList(utf8.encode('hello'));
      final parts = buildZipParts([ZipFile('a.txt', data), ZipFile('b.txt', data)]);
      final end = parts.last;
      final dv = ByteData.sublistView(end);
      expect(dv.getUint32(0, Endian.little), equals(0x06054b50));
      expect(dv.getUint16(8, Endian.little), equals(2)); // number of entries on this disk
      expect(dv.getUint16(10, Endian.little), equals(2)); // total number of entries
    });
  });
}
