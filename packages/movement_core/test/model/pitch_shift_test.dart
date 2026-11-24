import 'dart:math' as math;
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Zero crossings per second of the first channel: a pure tone's pitch.
double _pitchOf(Int16List pcm, int rate, {int channels = 2}) {
  final n = pcm.length ~/ channels;
  var crossings = 0;
  for (var i = 1 + n ~/ 4; i < n * 3 ~/ 4; i++) {
    final a = pcm[(i - 1) * channels], b = pcm[i * channels];
    if (a < 0 && b >= 0) crossings++;
  }
  return crossings / ((n / 2) / rate);
}

void main() {
  test('a tone an octave up: twice the pitch, the same length', () {
    const rate = 44100, hz = 220.0;
    final n = rate * 2;
    final pcm = Int16List(n * 2);
    for (var i = 0; i < n; i++) {
      final v = (math.sin(2 * math.pi * hz * i / rate) * 12000).round();
      pcm[i * 2] = v;
      pcm[i * 2 + 1] = v;
    }
    final up = pitchShift(pcm, 12);
    expect(up.length, pcm.length);
    expect(_pitchOf(up, rate), closeTo(hz * 2, hz * 0.06));
    final down = pitchShift(pcm, -5);
    expect(_pitchOf(down, rate), closeTo(hz * math.pow(2, -5 / 12), hz * 0.05));
    expect(identical(pitchShift(pcm, 0), pcm), isTrue);
  });

  test('pitch is saved with the layer', () {
    final l = createAudioLayer(path: '/a.wav', assetId: 'a', durationSeconds: 2)..content.audioPitch = -3.5;
    expect(layerFromJson(layerToJson(l)).content.audioPitch, -3.5);
    expect(cloneLayer(l).content.audioPitch, -3.5);
  });
}
