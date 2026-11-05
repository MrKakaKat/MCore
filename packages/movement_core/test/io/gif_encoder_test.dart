import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Structural/byte-level coverage for gif_encoder.dart that doesn't need
/// dart:ui (movement_core stays free of that dependency, same reasoning
/// as every other package:test suite here).
///
/// A real DECODE round-trip against Flutter's own Skia GIF decoder was
/// attempted in movement_mobile/test/ (via `ui.instantiateImageCodec`)
/// and had to be abandoned: in this sandbox's headless `flutter_tester`
/// shell, `instantiateImageCodec` hangs indefinitely and never
/// completes - confirmed with a plain PNG payload too (not GIF-
/// specific), so this is a real environment limitation, distinct from
/// the earlier-diagnosed "live CustomPainter instance" hang. Unlike
/// `pic.toImage()`/`image.toByteData()` (pure rasterization/pixel
/// read-back, used successfully throughout this project's other pixel
/// tests), `instantiateImageCodec` appears to depend on a codec
/// worker thread/isolate that never delivers its result here. This
/// file's structural checks (magic bytes, trailer, logical screen size,
/// NETSCAPE2.0 loop extension, transparency flag, per-frame graphic
/// control extension count, local color table sizing) are therefore the
/// only verification gif_encoder.dart has - a real device/desktop run
/// (per the user's own "write code now, test later" instruction for
/// this export/import round) is needed to confirm actual decodability
/// in a real GIF viewer.
void main() {
  Uint8List solidFrame(int w, int h, int r, int g, int b, {int a = 255}) {
    final d = Uint8List(w * h * 4);
    for (var p = 0; p < w * h; p++) {
      d[p * 4] = r;
      d[p * 4 + 1] = g;
      d[p * 4 + 2] = b;
      d[p * 4 + 3] = a;
    }
    return d;
  }

  test('encodeGif rejects an empty frame list', () {
    expect(() => encodeGif(frames: []), throwsArgumentError);
  });

  test('encodeGif rejects frames with mismatched dimensions', () {
    final f1 = GifFrame(width: 2, height: 2, rgba: solidFrame(2, 2, 255, 0, 0), delayCentiseconds: 10);
    final f2 = GifFrame(width: 3, height: 2, rgba: solidFrame(3, 2, 0, 255, 0), delayCentiseconds: 10);
    expect(() => encodeGif(frames: [f1, f2]), throwsArgumentError);
  });

  test('output starts with the GIF89a magic bytes, ends with the trailer, and carries the logical screen size', () {
    const w = 5, h = 7;
    final bytes = encodeGif(frames: [
      GifFrame(width: w, height: h, rgba: solidFrame(w, h, 10, 20, 30), delayCentiseconds: 4),
    ]);

    expect(String.fromCharCodes(bytes.sublist(0, 6)), equals('GIF89a'));
    expect(bytes.last, equals(0x3B));

    final screenW = bytes[6] | (bytes[7] << 8);
    final screenH = bytes[8] | (bytes[9] << 8);
    expect(screenW, equals(w));
    expect(screenH, equals(h));
  });

  test('carries the NETSCAPE2.0 application extension for looping', () {
    final bytes = encodeGif(
      frames: [GifFrame(width: 2, height: 2, rgba: solidFrame(2, 2, 1, 2, 3), delayCentiseconds: 1)],
      loopCount: 0,
    );
    final asString = String.fromCharCodes(bytes);
    expect(asString.contains('NETSCAPE2.0'), isTrue);
  });

  test('a single-color opaque frame quantizes to exactly one palette color (no needless splitting)', () {
    const w = 4, h = 4;
    final bytes = encodeGif(frames: [
      GifFrame(width: w, height: h, rgba: solidFrame(w, h, 200, 100, 50), delayCentiseconds: 10),
    ]);

    // logical screen descriptor (13 bytes) + app extension (19 bytes)
    // precede the first frame's graphic control extension.
    const gceStart = 13 + 19;
    expect(bytes[gceStart], equals(0x21));
    expect(bytes[gceStart + 1], equals(0xF9));
    final packed = bytes[gceStart + 3];
    expect(packed & 0x01, equals(0), reason: 'no transparency needed for a fully opaque frame');
    expect((packed >> 2) & 0x07, equals(0), reason: 'opaque frames fully cover the previous one - no disposal needed');

    const imageDescStart = gceStart + 8;
    expect(bytes[imageDescStart], equals(0x2C));
    final localTablePacked = bytes[imageDescStart + 9];
    expect(localTablePacked & 0x80, equals(0x80), reason: 'local color table flag must be set');
    final tableSizeBits = localTablePacked & 0x07;
    // one distinct color -> smallest possible table, 2 entries (bits=0).
    expect(tableSizeBits, equals(0));
  });

  test('a frame with any sub-threshold-alpha pixel sets the transparent color flag', () {
    const w = 2, h = 2;
    final rgba = solidFrame(w, h, 255, 0, 0);
    rgba[3] = 0; // pixel 0's alpha -> fully transparent
    final bytes = encodeGif(frames: [
      GifFrame(width: w, height: h, rgba: rgba, delayCentiseconds: 10),
    ]);

    const gceStart = 13 + 19;
    final packed = bytes[gceStart + 3];
    expect(packed & 0x01, equals(1), reason: 'transparent color flag must be set when a pixel is below the alpha threshold');
    expect((packed >> 2) & 0x07, equals(2),
        reason: 'disposal 2 (restore to background) - otherwise moving content leaves trails on a transparent GIF');
  });

  test('encoding several frames produces multiple image descriptors (0x2C) in the stream', () {
    const w = 2, h = 2;
    final bytes = encodeGif(frames: [
      GifFrame(width: w, height: h, rgba: solidFrame(w, h, 255, 0, 0), delayCentiseconds: 5),
      GifFrame(width: w, height: h, rgba: solidFrame(w, h, 0, 255, 0), delayCentiseconds: 5),
      GifFrame(width: w, height: h, rgba: solidFrame(w, h, 0, 0, 255), delayCentiseconds: 5),
    ]);

    final imageDescriptorCount = bytes.where((b) => b == 0x2C).length;
    // each frame's image descriptor byte (0x2C) is distinct from any
    // incidental 0x2C appearing inside compressed LZW data, so count via
    // the known fixed frame layout instead of a raw byte scan for the
    // structural pieces we can locate deterministically: 3 graphic
    // control extensions (0x21 0xF9) is the more reliable structural
    // signal here.
    final gceCount = _countSubsequence(bytes, [0x21, 0xF9]);
    expect(gceCount, equals(3));
    expect(imageDescriptorCount, greaterThanOrEqualTo(3));
  });

  test('median-cut quantization on a many-color gradient still produces a valid, decodable-shaped stream capped at 256 colors', () {
    const w = 16, h = 16;
    final rgba = Uint8List(w * h * 4);
    for (var p = 0; p < w * h; p++) {
      rgba[p * 4] = (p * 7) % 256;
      rgba[p * 4 + 1] = (p * 13) % 256;
      rgba[p * 4 + 2] = (p * 19) % 256;
      rgba[p * 4 + 3] = 255;
    }
    final bytes = encodeGif(frames: [
      GifFrame(width: w, height: h, rgba: rgba, delayCentiseconds: 10),
    ]);

    const gceStart = 13 + 19;
    const imageDescStart = gceStart + 8;
    final localTablePacked = bytes[imageDescStart + 9];
    final tableSizeBits = localTablePacked & 0x07;
    // 256 possible distinct colors in a 16x16 gradient like this exceed
    // the cap -> table must land at the max size (bits=7 -> 256 entries).
    expect(tableSizeBits, equals(7));
    expect(bytes.last, equals(0x3B));
  });

  group('GifEncoderSink', () {
    test('addFrame + finish produces byte-identical output to encodeGif given the same frames', () {
      const w = 4, h = 4;
      final frames = [
        GifFrame(width: w, height: h, rgba: solidFrame(w, h, 255, 0, 0), delayCentiseconds: 5),
        GifFrame(width: w, height: h, rgba: solidFrame(w, h, 0, 255, 0), delayCentiseconds: 5),
        GifFrame(width: w, height: h, rgba: solidFrame(w, h, 0, 0, 255), delayCentiseconds: 5),
      ];

      final viaBatch = encodeGif(frames: frames, loopCount: 3);

      final sink = GifEncoderSink(loopCount: 3);
      for (final f in frames) {
        sink.addFrame(f);
      }
      final viaSink = sink.finish();

      expect(viaSink, equals(viaBatch));
    });

    test('finish() before any addFrame throws, matching encodeGif\'s own empty-list rejection', () {
      final sink = GifEncoderSink();
      expect(() => sink.finish(), throwsArgumentError);
    });

    test('addFrame after finish() throws', () {
      const w = 2, h = 2;
      final sink = GifEncoderSink();
      sink.addFrame(GifFrame(width: w, height: h, rgba: solidFrame(w, h, 1, 2, 3), delayCentiseconds: 1));
      sink.finish();
      expect(
        () => sink.addFrame(GifFrame(width: w, height: h, rgba: solidFrame(w, h, 4, 5, 6), delayCentiseconds: 1)),
        throwsStateError,
      );
    });

    test('a mismatched-dimension frame added after the first throws ArgumentError', () {
      final sink = GifEncoderSink();
      sink.addFrame(GifFrame(width: 2, height: 2, rgba: solidFrame(2, 2, 255, 0, 0), delayCentiseconds: 10));
      expect(
        () => sink.addFrame(GifFrame(width: 3, height: 2, rgba: solidFrame(3, 2, 0, 255, 0), delayCentiseconds: 10)),
        throwsArgumentError,
      );
    });
  });
}

int _countSubsequence(Uint8List haystack, List<int> needle) {
  var count = 0;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) count++;
  }
  return count;
}
