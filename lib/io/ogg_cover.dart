import 'dart:convert';
import 'dart:typed_data';

/// A picture put into an Ogg Opus file as its cover (the players' album
/// art): a METADATA_BLOCK_PICTURE comment in its OpusTags header. The
/// pages after the headers are copied as they are (only renumbered).
/// Returns the file unchanged when it isn't one this understands.
Uint8List oggWithCover(Uint8List ogg, Uint8List png, {int width = 0, int height = 0}) {
  try {
    final pages = _readPages(ogg);
    if (pages.length < 2) return ogg;
    // packets 0 (OpusHead) and 1 (OpusTags): the second may run over
    // several pages.
    final head = pages[0];
    if (!_startsWith(head.data, 'OpusHead')) return ogg;
    final tags = BytesBuilder();
    var i = 1;
    for (; i < pages.length; i++) {
      tags.add(pages[i].data);
      // the packet ends on a page whose last segment is under 255.
      final segs = pages[i].segments;
      if (segs.isNotEmpty && segs.last < 255) {
        i++;
        break;
      }
    }
    final oldTags = tags.toBytes();
    if (!_startsWith(oldTags, 'OpusTags')) return ogg;
    final newTags = _tagsWithPicture(oldTags, png, width, height);
    final out = BytesBuilder();
    var seq = 0;
    out.add(_page(head.serial, seq++, head.granule, head.flags, [head.data]));
    for (final p in _paginate(newTags)) {
      out.add(_page(head.serial, seq++, 0, p.continued ? 1 : 0, [p.data], lastComplete: p.last));
    }
    for (; i < pages.length; i++) {
      final p = pages[i];
      out.add(_rawPage(p, seq++));
    }
    return out.toBytes();
  } catch (_) {
    return ogg;
  }
}

class _Page {
  final int flags, granule, serial;
  final List<int> segments;
  final Uint8List data;
  _Page(this.flags, this.granule, this.serial, this.segments, this.data);
}

bool _startsWith(Uint8List b, String s) {
  if (b.length < s.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (b[i] != s.codeUnitAt(i)) return false;
  }
  return true;
}

List<_Page> _readPages(Uint8List b) {
  final out = <_Page>[];
  final bd = ByteData.sublistView(b);
  var at = 0;
  while (at + 27 <= b.length) {
    if (b[at] != 0x4F || b[at + 1] != 0x67 || b[at + 2] != 0x67 || b[at + 3] != 0x53) throw const FormatException('not ogg');
    final flags = b[at + 5];
    final granule = bd.getInt64(at + 6, Endian.little);
    final serial = bd.getUint32(at + 14, Endian.little);
    final n = b[at + 26];
    final segs = b.sublist(at + 27, at + 27 + n);
    final len = segs.fold<int>(0, (a, v) => a + v);
    final start = at + 27 + n;
    out.add(_Page(flags, granule, serial, segs, Uint8List.sublistView(b, start, start + len)));
    at = start + len;
  }
  return out;
}

/// The OpusTags packet with the picture added to its comments.
Uint8List _tagsWithPicture(Uint8List tags, Uint8List png, int w, int h) {
  final bd = ByteData.sublistView(tags);
  var at = 8;
  final vendorLen = bd.getUint32(at, Endian.little);
  at += 4;
  final vendor = tags.sublist(at, at + vendorLen);
  at += vendorLen;
  final count = bd.getUint32(at, Endian.little);
  at += 4;
  final comments = <Uint8List>[];
  for (var c = 0; c < count; c++) {
    final l = bd.getUint32(at, Endian.little);
    at += 4;
    final s = tags.sublist(at, at + l);
    at += l;
    // an older cover goes.
    if (!_startsWith(s, 'METADATA_BLOCK_PICTURE=')) comments.add(s);
  }
  final pic = BytesBuilder();
  void u32(int v) => pic.add([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]);
  const mime = 'image/png';
  u32(3); // front cover
  u32(mime.length);
  pic.add(ascii.encode(mime));
  u32(0); // no description
  u32(w);
  u32(h);
  u32(24);
  u32(0);
  u32(png.length);
  pic.add(png);
  comments.add(Uint8List.fromList(utf8.encode('METADATA_BLOCK_PICTURE=${base64.encode(pic.toBytes())}')));
  final out = BytesBuilder();
  void le32(int v) => out.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  out.add(ascii.encode('OpusTags'));
  le32(vendor.length);
  out.add(vendor);
  le32(comments.length);
  for (final c in comments) {
    le32(c.length);
    out.add(c);
  }
  return out.toBytes();
}

/// One packet laid over pages (at most 255 segments of 255 bytes each;
/// a packet filling its last page whole ends on an empty one).
Iterable<({Uint8List data, bool continued, bool last})> _paginate(Uint8List packet) sync* {
  const max = 255 * 255;
  var at = 0;
  var first = true;
  while (true) {
    final rem = packet.length - at;
    if (rem >= max) {
      yield (data: Uint8List.sublistView(packet, at, at + max), continued: !first, last: false);
      at += max;
      first = false;
      continue;
    }
    yield (data: Uint8List.sublistView(packet, at), continued: !first, last: true);
    break;
  }
}

Uint8List _page(int serial, int seq, int granule, int flags, List<Uint8List> parts, {bool lastComplete = true}) {
  final data = BytesBuilder();
  for (final p in parts) {
    data.add(p);
  }
  final body = data.toBytes();
  final segs = <int>[];
  var left = body.length;
  while (left >= 255) {
    segs.add(255);
    left -= 255;
  }
  if (lastComplete) segs.add(left);
  return _assemble(flags, granule, serial, seq, segs, body);
}

Uint8List _rawPage(_Page p, int seq) => _assemble(p.flags, p.granule, p.serial, seq, p.segments, p.data);

Uint8List _assemble(int flags, int granule, int serial, int seq, List<int> segs, Uint8List body) {
  final h = ByteData(27 + segs.length);
  h.setUint8(0, 0x4F);
  h.setUint8(1, 0x67);
  h.setUint8(2, 0x67);
  h.setUint8(3, 0x53);
  h.setUint8(4, 0);
  h.setUint8(5, flags);
  h.setInt64(6, granule, Endian.little);
  h.setUint32(14, serial, Endian.little);
  h.setUint32(18, seq, Endian.little);
  h.setUint32(22, 0, Endian.little);
  h.setUint8(26, segs.length);
  for (var i = 0; i < segs.length; i++) {
    h.setUint8(27 + i, segs[i]);
  }
  final page = Uint8List(h.lengthInBytes + body.length)
    ..setAll(0, h.buffer.asUint8List())
    ..setAll(h.lengthInBytes, body);
  final crc = _crc(page);
  ByteData.sublistView(page).setUint32(22, crc, Endian.little);
  return page;
}

final List<int> _table = () {
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var r = i << 24;
    for (var j = 0; j < 8; j++) {
      r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04C11DB7) : (r << 1);
      r &= 0xFFFFFFFF;
    }
    t[i] = r;
  }
  return t;
}();

int _crc(Uint8List b) {
  var c = 0;
  for (final v in b) {
    c = ((c << 8) & 0xFFFFFFFF) ^ _table[((c >> 24) & 255) ^ v];
  }
  return c;
}
