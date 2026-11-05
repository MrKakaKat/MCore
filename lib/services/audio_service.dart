import 'dart:async';
import 'dart:io';


import 'native_media.dart';
import 'video_service.dart' show CancelToken;

/// A decoded sound: how long it is.
class DecodedAudio {
  final double durationSeconds;
  const DecodedAudio(this.durationSeconds);
}

class AudioImportCancelled implements Exception {
  @override
  String toString() => 'Audio import cancelled';
}

/// Decoding sound files - behind an interface for the same reason as
/// VideoService (the ffmpeg binding needs a device; tests use a fake).
abstract class AudioService {
  /// Decodes any audio file (or the sound of a video) into raw PCM at
  /// `outPcm`: 16-bit little-endian, audioSampleRate, stereo interleaved.
  /// `onProgress` gets 0..1; `cancel` stops it (throws
  /// AudioImportCancelled).
  Future<DecodedAudio> decodeToPcm(File source, File outPcm,
      {void Function(double fraction)? onProgress, CancelToken? cancel});

  /// Encodes decoded PCM (the format decodeToPcm writes) into a new source
  /// copy at `outputPath` - Opus. Used to rewrite a trimmed sound.
  Future<File> encodePcm(File pcm, String outputPath);
}

AudioService createAudioService() => NativeAudioService();
