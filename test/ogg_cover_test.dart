import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/ogg_cover.dart';

/// Builds a tiny Ogg Opus-like file: OpusHead, OpusTags, two audio pages.
Uint8List _ogg() {
  Uint8List page(int seq, int flags, int granule, Uint8List body) {
    final segs = <int>[];
    var left = body.length;
    while (left >= 255) {
      segs.add(255);
      left -= 255;
    }
    segs.add(left);
    final h = ByteData(27 + segs.length)
      ..setUint32(0, 0x4F676753)
      ..setUint8(5, flags)
      ..setInt64(6, granule, Endian.little)
      ..setUint32(14, 77, Endian.little)
      ..setUint32(18, seq, Endian.little)
      ..setUint8(26, segs.length);
    for (var i = 0; i < segs.length; i++) {
      h.setUint8(27 + i, segs[i]);
    }
    return Uint8List.fromList([...h.buffer.asUint8List(), ...body]);
  }

  final head = Uint8List.fromList([...ascii.encode('OpusHead'), 1, 2, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]);
  final tags = BytesBuilder()
    ..add(ascii.encode('OpusTags'))
    ..add([3, 0, 0, 0])
    ..add(ascii.encode('abc'))
    ..add([1, 0, 0, 0])
    ..add([5, 0, 0, 0])
    ..add(ascii.encode('A=one'));
  return Uint8List.fromList([
    ...page(0, 2, 0, head),
    ...page(1, 0, 0, tags.toBytes()),
    ...page(2, 0, 960, Uint8List.fromList(List.filled(300, 7))),
    ...page(3, 4, 1920, Uint8List.fromList(List.filled(10, 9))),
  ]);
}

void main() {
  test('the cover goes into the tags; the audio pages stay, renumbered after them', () {
    final png = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    final out = oggWithCover(_ogg(), png, width: 400, height: 400);
    expect(out.length, greaterThan(70000));
    final text = latin1.decode(out);
    expect(text.contains('METADATA_BLOCK_PICTURE='), isTrue);
    expect(text.contains('A=one'), isTrue, reason: 'the old comments stay');
    // pages: OggS count = head + 2 tag pages (70000 b64 > 65025) + 2 audio.
    expect(RegExp('OggS').allMatches(text).length, 5);
    // the last page's audio is intact and it still ends the stream.
    expect(out.sublist(out.length - 10), List.filled(10, 9));
    // what isn't ogg comes back as it was.
    final junk = Uint8List.fromList([1, 2, 3]);
    expect(identical(oggWithCover(junk, png), junk), isTrue);
  });
}
