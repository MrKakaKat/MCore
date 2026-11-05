import 'dart:convert';
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Audio layers: time like video (sourceIn), the waveform, the mixdown and
/// the WAV writer.
void main() {
  const sr = 1000; // a small sample rate keeps the numbers readable
  setUp(() {
    fps = 10;
    clearStateCaches();
  });
  tearDown(() => fps = 60);

  /// A clip whose left sample at index i is i (so the mix shows exactly
  /// which source sample landed where); right = -i.
  Int16List ramp(int frames) {
    final pcm = Int16List(frames * 2);
    for (var i = 0; i < frames; i++) {
      pcm[i * 2] = i;
      pcm[i * 2 + 1] = -i;
    }
    return pcm;
  }

  Layer clip({int start = 0, int duration = 20}) => createAudioLayer(path: '/a.wav', assetId: 'a1', durationSeconds: 2)
    ..startFrame = start
    ..durationFrames = duration;

  int left(Int16List mix, double seconds) => mix[(seconds * sr).round() * 2];

  test('a new audio layer is as long as the clip, has no size and a volume', () {
    fps = 60;
    final l = createAudioLayer(path: '/a.m4a', assetId: 'a1', durationSeconds: 2.5);
    expect(l.durationFrames, 150);
    expect(l.content.size, [0.0, 0.0]);
    expect(l.content.volume!.defaultValue, 1.0);
    expect(isTimedMedia('audio'), isTrue);
  });

  test('the mix places the clip at its start on the timeline, silent before and after', () {
    final p = Project(layers: [clip(start: 5, duration: 10)]); // 0.5 s .. 1.5 s
    final mix = mixTimeline(p, {'a1': ramp(2000)}, seconds: 2, sampleRate: sr);
    expect(mix.length, 2000 * 2);
    expect(left(mix, 0.4), 0);
    expect(left(mix, 0.5), 0, reason: 'source sample 0 at the start');
    expect(left(mix, 1.0), 500);
    expect(mix[(1.0 * sr).round() * 2 + 1], -500, reason: 'right channel too');
    expect(left(mix, 1.6), 0, reason: 'ends with the layer');
  });

  test('trim left and split continue the source exactly like video', () {
    final l = clip(start: 0, duration: 20);
    final p = Project(layers: [l]);
    // trim the start by 3 frames: the sound under the playhead stays put.
    LayerTrackDragOp.grab(l, LayerDragMode.trimLeft).apply(3);
    expect(l.content.sourceIn, closeTo(0.3, 1e-9));
    final trimmed = mixTimeline(p, {'a1': ramp(2000)}, seconds: 2, sampleRate: sr);
    expect(left(trimmed, 0.2), 0, reason: 'cut away');
    expect(left(trimmed, 0.3), 300);
    expect(left(trimmed, 1.0), 1000);

    // split at frame 10: both halves together sound the same as before.
    final right = splitLayer(p, l, 10, 'L_right')!;
    expect(right.content.sourceIn, closeTo(1.0, 1e-9));
    final split = mixTimeline(p, {'a1': ramp(2000)}, seconds: 2, sampleRate: sr);
    expect(split, trimmed);
  });

  test('loops repeat the clip; volume keys scale it; muted and hidden are silent', () {
    final l = clip(start: 0, duration: 5)..loopEnabled = true; // 0.5 s, repeating
    final p = Project(layers: [l]);
    var mix = mixTimeline(p, {'a1': ramp(2000)}, seconds: 2, sampleRate: sr);
    expect(left(mix, 0.2), 200);
    expect(left(mix, 0.7), 200, reason: 'second pass from the start');
    expect(left(mix, 1.7), 200);

    l.loopEnabled = false;
    l.durationFrames = 20;
    l.content.volume = track(1.0)
      ..keyframes = [Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 1.0)];
    l.content.volume!.keyframes.first.temporal = const Easing(0, 0, 1, 1);
    mix = mixTimeline(p, {'a1': ramp(2000)}, seconds: 2, sampleRate: sr);
    expect(left(mix, 0.5), closeTo(250, 30), reason: 'half way up the fade');
    expect(left(mix, 1.5), 1500);

    l.content.audioMuted = true;
    expect(mixTimeline(p, {'a1': ramp(2000)}, seconds: 2, sampleRate: sr).every((v) => v == 0), isTrue);
    l.content.audioMuted = false;
    l.hidden = true;
    expect(audibleLayers(p), isEmpty);
  });

  test('overlapping layers add up and clip at the 16-bit limit', () {
    final loud = Int16List.fromList(List.filled(4000, 30000));
    final p = Project(layers: [clip(), clip()]);
    final mix = mixTimeline(p, {'a1': loud}, seconds: 1, sampleRate: sr);
    expect(mix[100], 32767);
  });

  test('peaks: the loudest sample per window, 0..255', () {
    final pcm = Int16List(1000 * 2);
    pcm[2 * 300] = 32767; // one click at 0.3 s
    final peaks = computePeaks(pcm, sampleRate: 1000, perSecond: 10);
    expect(peaks.length, 10);
    expect(peaks[3], 255);
    expect(peaks[2], 0);
    expect(peakBetween(peaks, 0.25, 0.35, perSecond: 10), 1.0);
    expect(peakBetween(peaks, 0.5, 0.9, perSecond: 10), 0.0);
  });

  test('WAV: header and samples round-trip', () {
    final pcm = Int16List.fromList([1, -1, 300, -300]);
    final bytes = wavBytes(pcm, sampleRate: 44100);
    expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
    final b = ByteData.sublistView(bytes);
    expect(b.getUint32(24, Endian.little), 44100);
    expect(b.getUint16(22, Endian.little), 2);
    expect(pcmFromBytes(Uint8List.sublistView(bytes, 44)), pcm);
  });

  test('saved and loaded; old video files keep their in-point', () {
    final l = clip()..content.sourceIn = 1.25;
    l.content.audioMuted = true;
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.content.shape, 'audio');
    expect(back.content.sourceIn, 1.25);
    expect(back.content.audioAssetId, 'a1');
    expect(back.content.audioMuted, isTrue);
    expect(back.content.volume, isNotNull);
    final video = contentFromJson({'shape': 'video', 'offset': [0, 0], 'size': [1, 1], 'videoSourceIn': 2.5});
    expect(video.sourceIn, 2.5);
    expect(contentToJson(video)['videoSourceIn'], 2.5, reason: 'same key as before for video');
  });
}
