/// Audio layers: a sound with no picture. Time maps exactly like video
/// (Content.sourceIn + the layer's own frame), so trim, split and loop
/// already behave; this file adds the pure parts around it - creating a
/// layer, the waveform, mixing every audio layer of the timeline into one
/// track and writing it as WAV.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/interpolation.dart';
import 'project.dart';

/// Decoded sound everywhere in the app: 16-bit PCM, stereo interleaved.
const audioSampleRate = 44100;
const audioChannels = 2;

/// Waveform resolution: one peak per 1/240 s (4 per frame at 60 fps).
const audioPeaksPerSecond = 240;

/// Seconds into the source a timed-media layer (video / audio) plays at
/// `localFrame`, its own frame at the project rate.
double mediaSourceTime(Content c, num localFrame) => c.sourceIn + localFrame / fps;

int _audioCounter = 0;

/// A new audio layer as long as the clip.
Layer createAudioLayer({required String path, required String assetId, required double durationSeconds}) {
  _audioCounter++;
  return Layer(
    id: 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}a$_audioCounter',
    name: niceLayerName('audio', _audioCounter),
    durationFrames: math.max(1, (durationSeconds * fps).round()),
    transform: Transform(
      anchor: track([0.5, 0.5], true),
      scale: track([1.0, 1.0]),
      rotation: track(0.0),
      opacity: track(1.0),
    ),
    content: Content(
      shape: 'audio',
      offset: [0, 0],
      size: [0, 0],
      audioPath: path,
      audioAssetId: assetId,
      audioDuration: durationSeconds,
      volume: track(1.0),
    ),
  );
}

/// Asset ids of every audio clip in the project.
Set<String> audioAssetIds(Project project) => {
      for (final l in project.layers)
        if (l.content.shape == 'audio' && l.content.audioAssetId != null) l.content.audioAssetId!
    };

/// Layers that are heard: audio, not hidden, not muted.
List<Layer> audibleLayers(Project project) => [
      for (final l in project.layers)
        if (l.content.shape == 'audio' && !l.hidden && !l.content.audioMuted && l.content.audioAssetId != null) l
    ];

/// The waveform of decoded PCM: per 1/`perSecond` s, the loudest sample
/// of either channel, 0..255.
Uint8List computePeaks(Int16List pcm, {int sampleRate = audioSampleRate, int channels = audioChannels, int perSecond = audioPeaksPerSecond}) {
  final frames = pcm.length ~/ channels;
  final window = sampleRate / perSecond;
  final n = (frames / window).ceil();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final a = (i * window).floor(), b = math.min(frames, ((i + 1) * window).floor());
    var peak = 0;
    for (var f = a; f < b; f++) {
      for (var c = 0; c < channels; c++) {
        final v = pcm[f * channels + c].abs();
        if (v > peak) peak = v;
      }
    }
    out[i] = (peak * 255 / 32768).round().clamp(0, 255);
  }
  return out;
}

/// Loudest waveform value (0..1) over source seconds [t0, t1).
double peakBetween(Uint8List peaks, double t0, double t1, {int perSecond = audioPeaksPerSecond}) {
  if (peaks.isEmpty) return 0;
  var a = (t0 * perSecond).floor(), b = (t1 * perSecond).ceil();
  if (b <= a) b = a + 1;
  a = a.clamp(0, peaks.length);
  b = b.clamp(0, peaks.length);
  var m = 0;
  for (var i = a; i < b; i++) {
    if (peaks[i] > m) m = peaks[i];
  }
  return m / 255;
}

/// Every audible layer of the project mixed into one stereo track that
/// starts at timeline frame 0 and lasts `seconds`: each layer at its place
/// on the timeline, from its in-point (sourceIn), repeating on its loops,
/// at its volume (keyframes interpolated between frames). `pcmByAsset`
/// holds each clip's decoded PCM (audioSampleRate, stereo interleaved);
/// a clip that isn't there is silent.
Int16List mixTimeline(Project project, Map<String, Int16List> pcmByAsset, {required double seconds, int sampleRate = audioSampleRate}) {
  const ch = audioChannels;
  final total = math.max(0, (seconds * sampleRate).round());
  final acc = Float64List(total * ch);
  for (final layer in audibleLayers(project)) {
    final pcm = pcmByAsset[layer.content.audioAssetId];
    if (pcm == null || pcm.isEmpty) continue;
    final srcFrames = pcm.length ~/ ch;
    final start = layer.startFrame;
    final visibleEnd = layerVisibleEnd(layer) ?? (seconds * fps).ceil();
    final first = math.max(0, (start / fps * sampleRate).ceil());
    final last = math.min(total, (visibleEnd / fps * sampleRate).ceil());
    if (last <= first) continue;

    // volume per global frame, interpolated between them per sample.
    final gains = <int, double>{};
    double gainAt(int globalFrame) => gains.putIfAbsent(globalFrame, () {
          final vol = layer.content.volume;
          if (vol == null) return 1.0;
          final local = (loopedFrame(layer, globalFrame) - start).clamp(0, layer.durationFrames).toDouble();
          return (evaluateTrack(project, vol, local, layer) as num).toDouble().clamp(0.0, 4.0);
        });

    for (var i = first; i < last; i++) {
      final g = i * fps / sampleRate; // global frame, fractional
      final local = loopedFrame(layer, g) - start;
      if (local < 0 || local >= layer.durationFrames) continue;
      final src = ((layer.content.sourceIn + local / fps) * sampleRate + 1e-6).floor();
      if (src < 0 || src >= srcFrames) continue;
      final gf = g.floor();
      final frac = g - gf;
      final gain = gainAt(gf) * (1 - frac) + gainAt(gf + 1) * frac;
      if (gain == 0) continue;
      for (var c = 0; c < ch; c++) {
        acc[i * ch + c] += pcm[src * ch + c] * gain;
      }
    }
  }
  final out = Int16List(acc.length);
  for (var i = 0; i < acc.length; i++) {
    out[i] = acc[i].round().clamp(-32768, 32767);
  }
  return out;
}

/// A playable WAV file of 16-bit PCM.
Uint8List wavBytes(Int16List pcm, {int sampleRate = audioSampleRate, int channels = audioChannels}) {
  final dataLen = pcm.length * 2;
  final b = ByteData(44 + dataLen);
  void str(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * channels * 2, Endian.little);
  b.setUint16(32, channels * 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    b.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Little-endian 16-bit PCM bytes (an ffmpeg `-f s16le` file) as samples.
Int16List pcmFromBytes(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  if (bytes.offsetInBytes % 2 == 0 && Endian.host == Endian.little) {
    return bytes.buffer.asInt16List(bytes.offsetInBytes, n);
  }
  final b = ByteData.sublistView(bytes);
  return Int16List.fromList([for (var i = 0; i < n; i++) b.getInt16(i * 2, Endian.little)]);
}
