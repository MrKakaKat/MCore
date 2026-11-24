import 'dart:math' as math;
import 'dart:typed_data';

/// Sound made higher or lower by `semitones` without getting longer or
/// shorter: stretched in time first (overlapping pieces laid where they
/// fit best - WSOLA, the pitch kept), then played that much faster or
/// slower (the pitch moves, the length comes back). Interleaved 16-bit
/// PCM with `channels` channels in, the same length out.
Int16List pitchShift(Int16List pcm, double semitones, {int channels = 2}) {
  if (semitones.abs() < 1e-3 || pcm.length < channels * 4) return pcm;
  final ratio = math.pow(2, semitones / 12).toDouble();
  final frames = pcm.length ~/ channels;
  // mono guide for finding where pieces fit (all channels follow it).
  final mono = Float64List(frames);
  for (var i = 0; i < frames; i++) {
    var s = 0.0;
    for (var c = 0; c < channels; c++) {
      s += pcm[i * channels + c];
    }
    mono[i] = s / channels;
  }
  final stretched = _wsola(pcm, mono, frames, channels, ratio);
  // played `ratio` times as fast: back to the original length.
  final outFrames = frames;
  final sFrames = stretched.length ~/ channels;
  final out = Int16List(outFrames * channels);
  for (var i = 0; i < outFrames; i++) {
    final pos = i * ratio;
    final a = pos.floor();
    if (a >= sFrames) break;
    final b = math.min(a + 1, sFrames - 1);
    final f = pos - a;
    for (var c = 0; c < channels; c++) {
      final v = stretched[a * channels + c] * (1 - f) + stretched[b * channels + c] * f;
      out[i * channels + c] = v.round().clamp(-32768, 32767);
    }
  }
  return out;
}

/// Time-stretched by `ratio` (longer above 1), the pitch kept.
Float64List _wsola(Int16List pcm, Float64List mono, int frames, int channels, double ratio) {
  const win = 1024, hop = win ~/ 2, search = 160, step = 2, probe = 256;
  final outFrames = (frames * ratio).ceil() + win;
  final out = Float64List(outFrames * channels);
  final weight = Float64List(outFrames);
  final w = Float64List(win);
  for (var i = 0; i < win; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (win - 1));
  }
  // where the last piece would naturally go on (for the next to match).
  var prevEnd = 0;
  for (var o = 0; o + win < outFrames; o += hop) {
    final ideal = (o / ratio).round();
    if (ideal >= frames) break;
    // the piece near `ideal` that best continues the one before.
    var best = ideal;
    if (o > 0) {
      var bestScore = double.negativeInfinity;
      final lo = math.max(0, ideal - search), hi = math.min(frames - win, ideal + search);
      for (var cand = lo; cand <= hi; cand += step) {
        var score = 0.0;
        for (var k = 0; k < probe; k += 2) {
          final a = prevEnd + k, b = cand + k;
          if (a >= frames || b >= frames) break;
          score += mono[a] * mono[b];
        }
        if (score > bestScore) {
          bestScore = score;
          best = cand;
        }
      }
    }
    for (var i = 0; i < win; i++) {
      final src = best + i;
      if (src >= frames) break;
      final dst = o + i;
      for (var c = 0; c < channels; c++) {
        out[dst * channels + c] += pcm[src * channels + c] * w[i];
      }
      weight[dst] += w[i];
    }
    prevEnd = best + hop;
  }
  for (var i = 0; i < outFrames; i++) {
    final k = weight[i];
    if (k > 1e-6) {
      for (var c = 0; c < channels; c++) {
        out[i * channels + c] /= k;
      }
    }
  }
  return out;
}
