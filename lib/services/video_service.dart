import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Video import/export seam. Deliberately abstract because the ecosystem
/// underneath it is unstable right now: FFmpegKit (formerly the standard
/// choice for both Flutter and React Native) is officially retired, and its
/// successor isn't a normal pub.dev dependency - it requires vendoring a
/// self-built FFmpeg binary as a local path dependency. Rather than build
/// directly on top of something in flux, everything that needs video talks
/// to THIS interface. Swapping the stub for a real native-ffmpeg
/// implementation later means writing one new class, not touching any
/// calling code. Re-check the ecosystem's state before investing in that
/// implementation - this may have changed since this file was written.
/// Export progress: `phase` is a short user-facing label ("Preparing",
/// "Encoding"), `done` out of `total` frames.
typedef VideoProgress = void Function(String phase, int done, int total);

/// What a video import produced: the frames on disk (`<outDir>/000001.jpg`
/// or `.png`, 1-based), their constant frame rate, count and size (after
/// rotation and downscaling).
/// Settings > Video decoding for H.264 / H.265 imports: 'auto' (ffmpeg's
/// own choice), 'hardware' (the phone's decoder, software if it fails) or
/// 'software' (all cores).
String videoDecoder = 'auto';
const videoDecoders = ['auto', 'hardware', 'software'];

class ExtractedVideo {
  final double fps;
  final int frameCount;
  final int width;
  final int height;
  final bool alpha;

  /// The video's own picture size (the frames above may be scaled down to
  /// the project frame); the layer is made this size.
  final int? _sourceWidth, _sourceHeight;
  int get sourceWidth => _sourceWidth ?? width;
  int get sourceHeight => _sourceHeight ?? height;
  const ExtractedVideo(
      {required this.fps,
      required this.frameCount,
      required this.width,
      required this.height,
      required this.alpha,
      int? sourceWidth,
      int? sourceHeight})
      : _sourceWidth = sourceWidth,
        _sourceHeight = sourceHeight;
}

/// Cooperative cancellation for a long import.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in _listeners) {
      l();
    }
  }

  void onCancel(void Function() listener) => _listeners.add(listener);
}

class VideoImportCancelled implements Exception {
  @override
  String toString() => 'Video import cancelled';
}

/// File name of extracted frame `index` (0-based) inside the frame cache.
String videoFrameFileName(int index, {required bool alpha}) =>
    '${(index + 1).toString().padLeft(6, '0')}.${alpha ? 'png' : 'jpg'}';

abstract class VideoService {
  /// Whether this implementation can produce alpha-preserving video output.
  /// Check this before relying on transparency - silently producing an
  /// opaque result would be worse than refusing outright.
  bool get supportsAlphaChannel;

  /// Splits a video file into individual frame bitmaps at [fps]. Once this
  /// returns, the frames are ordinary in-memory images - everything
  /// downstream (the effect registries, the timeline) treats them exactly
  /// like any other imported image, no separate "video layer" code path.
  Future<List<ui.Image>> extractFrames(File videoFile, {required double fps});

  /// Extracts every frame of `source` once into `outDir` for a video
  /// layer: normalised to a constant frame rate (phone video is often
  /// variable), rotated upright from the file's rotation tag, scaled down
  /// to fit `maxWidth` x `maxHeight` (aspect kept). JPEG frames, or PNG
  /// when `alpha` is on (then VP9 WebM is decoded with libvpx so its
  /// transparency survives). `onProgress(done, total)`; `cancel` stops it
  /// (throws VideoImportCancelled). No audio.
  Future<ExtractedVideo> extractToCache(
    File source,
    Directory outDir, {
    required double maxWidth,
    required double maxHeight,
    bool alpha = false,
    void Function(int done, int total)? onProgress,
    CancelToken? cancel,
  });

  /// Encodes a sequence of already-rendered frames (e.g. via a Renderer's
  /// captureFrame, called once per frame) into a video file at [outputPath].
  /// Throws if alphaChannel is requested but supportsAlphaChannel is false,
  /// rather than silently flattening to an opaque background.
  ///
  /// [bitrateKbps] and [quality] - bitrate, quality, and frame-rate settings)
  /// are both optional and mutually exclusive in effect: an implementation
  /// that honors an explicit bitrate should prefer it over [quality] when both
  /// are given, since a bitrate target is a stronger, more specific request
  /// than a general quality dial. [quality] is a plain 0-100 scale (higher =
  /// better/larger), left unopinionated about which underlying codec knob it
  /// maps to - that's an implementation detail.
  ///
  /// [audioPath]: a sound track (WAV, as long as the video) muxed in as
  /// Opus - royalty-free like VP9, WebM's own audio codec.
  Future<File> encodeFrames(
    List<ui.Image> frames, {
    required double fps,
    required String outputPath,
    bool alphaChannel = false,
    int? bitrateKbps,
    int? quality,
    VideoProgress? onProgress,
    String? audioPath,
  });

  /// Whether this phone can encode H.264 in hardware (MediaCodec).
  Future<bool> hardwareH264Available() async => false;

  /// Streams frames straight into the encoder: `frameAt(i)` gives frame i
  /// as straight RGBA bytes (`width` x `height`), asked for one after the
  /// other while the encoder works on the ones before - no PNGs, no whole
  /// animation held in memory.
  /// `codec`: 'vp9' (WebM, royalty-free, transparency possible) or 'h264'
  /// (MP4 through the phone's own hardware encoder - fast, plays
  /// everywhere, no transparency). `speed`: 'quality' | 'balanced' |
  /// 'fast' (VP9 only; hardware H.264 is always fast).
  Future<File> encodeStream({
    required int width,
    required int height,
    required int frameCount,
    required Future<Uint8List> Function(int index) frameAt,
    required double fps,
    required String outputPath,
    String codec = 'vp9',
    String speed = 'balanced',
    bool alphaChannel = false,
    int? bitrateKbps,
    int? quality,
    VideoProgress? onProgress,
    String? audioPath,
    int audioKbps = 160,
  }) =>
      throw UnimplementedError('Video export is not available in this build.');

  /// Encodes an extracted frame sequence (`dir/000001.jpg`, ... or `.png`
  /// with transparency) into a new source copy at `outputPath` - VP9
  /// WebM, near-lossless, no sound. Used to rewrite a trimmed video.
  Future<File> encodeFrameSequence(Directory dir, {required double fps, required bool alpha, required String outputPath});
}

/// v1 default: no-op. Ships honest UnimplementedError messages rather than
/// pretending to support video - callers (UI code offering an "import MP4"
/// or "export video" button) should check for this and disable/hide that
/// path rather than let the error surface as a crash.
class StubVideoService extends VideoService {
  @override
  bool get supportsAlphaChannel => false;

  @override
  Future<List<ui.Image>> extractFrames(
    File videoFile, {
    required double fps,
  }) {
    throw UnimplementedError(
      'Video import is not available in this build.',
    );
  }

  @override
  Future<ExtractedVideo> extractToCache(File source, Directory outDir,
      {required double maxWidth,
      required double maxHeight,
      bool alpha = false,
      void Function(int done, int total)? onProgress,
      CancelToken? cancel}) {
    throw UnimplementedError('Video import is not available in this build.');
  }

  @override
  Future<File> encodeFrames(
    List<ui.Image> frames, {
    required double fps,
    required String outputPath,
    bool alphaChannel = false,
    int? bitrateKbps,
    int? quality,
    VideoProgress? onProgress,
    String? audioPath,
  }) {
    throw UnimplementedError(
      'Video export is not available in this build.',
    );
  }

  @override
  Future<File> encodeFrameSequence(Directory dir, {required double fps, required bool alpha, required String outputPath}) {
    throw UnimplementedError('Video encoding is not available in this build.');
  }
}
