import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => fps = 60);

  Layer media(String shape, String id, {required double sourceIn, required int duration, double srcFps = 30, int count = 3000}) {
    final l = Layer(
      id: 'L_$id$sourceIn',
      name: id,
      durationFrames: duration,
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: shape == 'video'
          ? Content(shape: 'video', offset: [0, 0], size: [10, 10], videoAssetId: id, videoFps: srcFps, videoFrameCount: count)
          : Content(shape: 'audio', offset: [0, 0], size: [0, 0], audioAssetId: id, audioPath: '/a/$id.mp3'),
    );
    l.content.sourceIn = sourceIn;
    return l;
  }

  test('used ranges plus a margin, merged, laid end to end', () {
    final spans = keptSpans([(10.0, 12.0), (11.5, 13.0), (40.0, 41.0)], unitsPerSecond: 30, totalUnits: 3000);
    expect(spans.length, 2);
    expect([spans[0].start, spans[0].end, spans[0].offset], [270, 421, 0]);
    expect([spans[1].start, spans[1].end, spans[1].offset], [1170, 1261, 151]);
    expect(keptUnits(spans), 151 + 91);
  });

  test('ranges at the source ends are clamped', () {
    final spans = keptSpans([(0.2, 1.0), (98.5, 120.0)], unitsPerSecond: 30, totalUnits: 3000);
    expect(spans.first.start, 0);
    expect(spans.last.end, 3000);
  });

  test('every video frame and every sound sample a layer plays stays the same after the remap', () {
    final layers = [
      media('video', 'v', sourceIn: 12.37, duration: 150),
      media('video', 'v', sourceIn: 55.0, duration: 61),
      media('video', 'v', sourceIn: 13.1, duration: 30),
      media('audio', 'a', sourceIn: 3.3333, duration: 200),
      media('audio', 'a', sourceIn: 70.01, duration: 90),
    ];
    final plan = planMediaTrim(layers, audioSamples: {'a': 100 * audioSampleRate});
    final vSpans = plan.videos['v']!, aSpans = plan.audios['a']!;
    expect(vSpans.length, 2);
    expect(keptUnits(vSpans), lessThan(3000));

    for (final l in layers) {
      final c = l.content;
      final isVideo = c.shape == 'video';
      final spans = isVideo ? vSpans : aSpans;
      final ups = isVideo ? c.videoFps! : audioSampleRate.toDouble();
      final remapped = remapSourceIn(c.sourceIn, spans, ups)!;
      final trimmed = Content(
          shape: c.shape,
          offset: [0, 0],
          size: [0, 0],
          videoFps: c.videoFps,
          videoFrameCount: isVideo ? keptUnits(spans) : null)
        ..sourceIn = remapped;
      for (var local = 0; local <= l.durationFrames; local++) {
        if (isVideo) {
          final before = videoSourceFrame(c, local)!, after = videoSourceFrame(trimmed, local)!;
          final span = spans.firstWhere((s) => before >= s.start && before < s.end);
          expect(after, before - span.start + span.offset, reason: 'video frame at local $local');
        } else {
          for (final sub in [0.0, 0.25, 0.5, 0.75]) {
            int sample(double sourceIn) => ((sourceIn + (local + sub) / fps) * audioSampleRate + 1e-6).floor();
            final before = sample(c.sourceIn), after = sample(remapped);
            final span = spans.firstWhere((s) => before >= s.start && before < s.end);
            expect(after, before - span.start + span.offset, reason: 'sample at local $local+$sub');
          }
        }
      }
    }
  });

  test('nothing to cut: no plan for that asset', () {
    final plan = planMediaTrim([media('video', 'v', sourceIn: 0, duration: 200, count: 100)], audioSamples: {});
    expect(plan.videos, isEmpty);
  });

  test('media ids: video layers, the video a sound comes from, audio layers', () {
    final sound = media('audio', 'a1', sourceIn: 0, duration: 10);
    sound.content.audioPath = '/docs/videos/vXYZ.mp4';
    final layers = [media('video', 'v1', sourceIn: 0, duration: 10), sound];
    expect(videoAssetIdsOf(layers), {'v1', 'vXYZ'});
    expect(audioAssetIdsOf(layers), {'a1'});
  });

  test('undo history exposes its snapshots', () {
    final project = Project(layers: [media('video', 'v1', sourceIn: 0, duration: 10)]);
    final undo = UndoHistory();
    undo.pushUndoState(project);
    project.layers.clear();
    expect(undo.length, 1);
    expect(videoAssetIdsOf(undo.snapshots.expand((s) => s)), {'v1'});
    undo.clearHistory();
    expect(undo.snapshots, isEmpty);
  });
}
