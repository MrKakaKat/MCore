import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:movement_core/movement_core.dart' show audioChannels, audioSampleRate;

import 'audio_service.dart';
import 'video_service.dart';

/// Video and sound through Android's own media stack (MediaExtractor /
/// MediaMetadataRetriever / MediaCodec / MediaMuxer - see MediaPlugin.kt):
/// nothing bundled, so the app carries no ffmpeg. GIFs are read by
/// Flutter's own decoder.
///
/// What Android's codecs can't do: VP9 with an alpha channel (exports
/// are opaque; transparent WebM imports lose their transparency), and
/// Opus sound in WebM before Android 10 (such a WebM has no sound).
class NativeMedia {
  NativeMedia._();

  // the progress handler, set on first use (not at start: plain tests
  // build an AppState without a Flutter binding).
  bool _listening = false;
  void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final a = call.arguments as Map;
        _progress[a['job']]?.call(a['done'] as int, a['total'] as int);
      }
    });
  }
  static final NativeMedia instance = NativeMedia._();

  final MethodChannel _channel = const MethodChannel('mcore/media');
  final Map<String, void Function(int done, int total)> _progress = {};
  var _jobs = 0;

  String _job() => 'job${_jobs++}';

  Future<T?> call<T>(String method, [Map<String, Object?>? args]) => _channel.invokeMethod<T>(method, args);

  /// Runs a job with progress and cancel; `CancelledError` when cancelled.
  Future<T?> job<T>(String method, Map<String, Object?> args,
      {void Function(int done, int total)? onProgress, CancelToken? cancel}) async {
    _listen();
    final id = _job();
    if (onProgress != null) _progress[id] = onProgress;
    cancel?.onCancel(() => _channel.invokeMethod('cancel', {'job': id}));
    try {
      return await _channel.invokeMethod<T>(method, {...args, 'job': id});
    } finally {
      _progress.remove(id);
    }
  }

  Future<bool> encoderAvailable(String mime) async =>
      (await _channel.invokeMethod<bool>('encoderAvailable', {'mime': mime})) ?? false;
}

class NativeVideoService extends VideoService {
  NativeMedia get _m => NativeMedia.instance;

  @override
  bool get supportsAlphaChannel => false;

  @override
  Future<bool> hardwareH264Available() => _m.encoderAvailable('video/avc');

  /// VP9 export needs a VP9 encoder (most phones from Android 7 on).
  Future<bool> vp9Available() => _m.encoderAvailable('video/x-vnd.on2.vp9');

  @override
  Future<List<ui.Image>> extractFrames(File videoFile, {required double fps}) =>
      throw UnimplementedError('extractToCache reads the frames');

  @override
  Future<File> encodeFrames(List<ui.Image> frames,
          {required double fps,
          required String outputPath,
          bool alphaChannel = false,
          int? bitrateKbps,
          int? quality,
          VideoProgress? onProgress,
          String? audioPath}) =>
      throw UnimplementedError('encodeStream encodes the frames');

  @override
  Future<ExtractedVideo> extractToCache(File source, Directory outDir,
      {required double maxWidth,
      required double maxHeight,
      bool alpha = false,
      void Function(int done, int total)? onProgress,
      CancelToken? cancel}) async {
    await outDir.create(recursive: true);
    if (source.path.toLowerCase().endsWith('.gif')) return _gif(source, outDir, maxWidth, maxHeight, onProgress, cancel);
    final info = await _m.call<Map>('probe', {'path': source.path});
    if (info == null || info['hasVideo'] != true) throw StateError('This file has no video.');
    final probed = (info['fps'] as num?)?.toDouble() ?? 0;
    final fps = (probed > 0 ? probed : 30).round().clamp(1, 60).toDouble();
    try {
      final r = await _m.job<Map>('extractFrames',
          {'path': source.path, 'outDir': outDir.path, 'fps': fps, 'maxWidth': maxWidth, 'maxHeight': maxHeight},
          onProgress: onProgress, cancel: cancel);
      if (cancel?.isCancelled ?? false) throw VideoImportCancelled();
      return ExtractedVideo(
        fps: fps,
        frameCount: r!['count'] as int,
        width: r['width'] as int,
        height: r['height'] as int,
        // Android's decoders give no alpha: imported frames are opaque.
        alpha: false,
        sourceWidth: math.max(r['sourceWidth'] as int, r['width'] as int),
        sourceHeight: math.max(r['sourceHeight'] as int, r['height'] as int),
      );
    } on PlatformException {
      if (cancel?.isCancelled ?? false) {
        await outDir.delete(recursive: true).catchError((_) => outDir);
        throw VideoImportCancelled();
      }
      rethrow;
    }
  }

  /// A GIF through Flutter's own decoder: each frame repeated for as long
  /// as it shows, at the GIF's own pace (max 60 fps), as PNGs (it can be
  /// transparent).
  Future<ExtractedVideo> _gif(File source, Directory outDir, double maxW, double maxH,
      void Function(int done, int total)? onProgress, CancelToken? cancel) async {
    final bytes = await source.readAsBytes();
    final probe = await ui.instantiateImageCodec(bytes);
    final n = probe.frameCount;
    final shortest = <int>[];
    for (var i = 0; i < n; i++) {
      final f = await probe.getNextFrame();
      shortest.add(f.duration.inMilliseconds <= 0 ? 100 : f.duration.inMilliseconds);
      f.image.dispose();
    }
    probe.dispose();
    final fps = (1000 / shortest.reduce(math.min)).round().clamp(1, 60).toDouble();
    final first = await ui.instantiateImageCodec(bytes);
    final f0 = await first.getNextFrame();
    final k = math.min(1.0, math.min(maxW / f0.image.width, maxH / f0.image.height));
    final w = math.max(2, (f0.image.width * k / 2).round() * 2), h = math.max(2, (f0.image.height * k / 2).round() * 2);
    final srcW = f0.image.width, srcH = f0.image.height;
    f0.image.dispose();
    first.dispose();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: w, targetHeight: h);
    final total = shortest.fold<int>(0, (s, d) => s + math.max(1, (d * fps / 1000).round()));
    var written = 0;
    for (var i = 0; i < n; i++) {
      if (cancel?.isCancelled ?? false) {
        await outDir.delete(recursive: true).catchError((_) => outDir);
        throw VideoImportCancelled();
      }
      final f = await codec.getNextFrame();
      final png = (await f.image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      f.image.dispose();
      final repeat = math.max(1, (shortest[i] * fps / 1000).round());
      for (var r = 0; r < repeat; r++) {
        await File('${outDir.path}/${videoFrameFileName(written, alpha: true)}').writeAsBytes(png);
        written++;
        onProgress?.call(written, total);
      }
    }
    codec.dispose();
    return ExtractedVideo(
        fps: fps, frameCount: written, width: w, height: h, alpha: true, sourceWidth: srcW, sourceHeight: srcH);
  }

  @override
  Future<File> encodeFrameSequence(Directory dir, {required double fps, required bool alpha, required String outputPath}) async {
    final vp9 = await vp9Available();
    final path = vp9 ? outputPath : '${outputPath.substring(0, outputPath.lastIndexOf('.'))}.mp4';
    final out = await _m.call<String>('encodeImages', {'dir': dir.path, 'fps': fps, 'path': path, 'codec': vp9 ? 'vp9' : 'h264'});
    return File(out ?? path);
  }

  @override
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
  }) async {
    if (frameCount <= 0) throw ArgumentError('encodeStream needs at least one frame');
    // the encoders want even sides.
    final w = width ~/ 2 * 2, h = height ~/ 2 * 2;
    final kbps = bitrateKbps ?? ((quality ?? 80) / 100 * w * h * fps * 0.15 / 1000).round().clamp(800, 40000);
    final id = 'enc${DateTime.now().microsecondsSinceEpoch}';
    await _m.call('beginEncode', {
      'id': id,
      'path': outputPath,
      'codec': codec,
      'width': w,
      'height': h,
      'fps': fps,
      'bitrateKbps': kbps,
      'audioPcm': audioPath,
      'rate': audioSampleRate,
      'channels': audioChannels,
    });
    try {
      for (var i = 0; i < frameCount; i++) {
        var rgba = await frameAt(i);
        if (w != width || h != height) rgba = _crop(rgba, width, w, h);
        await _m.call('encodeFrame', {'id': id, 'rgba': rgba});
        onProgress?.call('Drawing', i + 1, frameCount);
      }
      onProgress?.call('Encoding', frameCount, frameCount);
      return File((await _m.call<String>('finishEncode', {'id': id})) ?? outputPath);
    } catch (_) {
      await _m.call('abortEncode', {'id': id}).catchError((_) => null);
      rethrow;
    }
  }

  static Uint8List _crop(Uint8List rgba, int stride, int w, int h) {
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      out.setRange(y * w * 4, (y + 1) * w * 4, rgba, y * stride * 4);
    }
    return out;
  }
}

class NativeAudioService implements AudioService {
  NativeMedia get _m => NativeMedia.instance;

  @override
  Future<DecodedAudio> decodeToPcm(File source, File outPcm,
      {void Function(double fraction)? onProgress, CancelToken? cancel}) async {
    await outPcm.parent.create(recursive: true);
    try {
      final seconds = await _m.job<double>(
          'decodeAudio', {'path': source.path, 'out': outPcm.path, 'rate': audioSampleRate, 'channels': audioChannels},
          onProgress: onProgress == null ? null : (d, t) => onProgress(t == 0 ? 0 : (d / t).clamp(0.0, 1.0)),
          cancel: cancel);
      return DecodedAudio(seconds ?? 0);
    } on PlatformException catch (e) {
      if (cancel?.isCancelled ?? false) {
        if (await outPcm.exists()) await outPcm.delete();
        throw AudioImportCancelled();
      }
      throw StateError(e.message ?? 'Could not read this sound.');
    }
  }

  /// Opus in Ogg (Android 10+), else AAC in .m4a - the file actually
  /// written is returned.
  @override
  Future<File> encodePcm(File pcm, String outputPath) async {
    final path = await _m.call<String>(
        'encodeAudioFile', {'pcm': pcm.path, 'path': outputPath, 'rate': audioSampleRate, 'channels': audioChannels});
    return File(path ?? outputPath);
  }
}
