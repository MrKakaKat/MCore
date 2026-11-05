/// Media references and "trim unused media": which imported videos and
/// sounds the project uses (live layers, undo history), and how to cut a
/// long source down to the parts its layers actually play.
///
/// A source is measured in its own units - frames of an extracted video,
/// samples of decoded sound. Layers play `sourceIn` .. `sourceIn +
/// duration` (loops replay the same stretch); the kept spans are those
/// stretches plus a margin, merged, and laid end to end in the trimmed
/// source. A layer's new `sourceIn` moves by whole units, so it reads
/// exactly the same frames / samples as before.
library;

import 'dart:math' as math;

import 'audio.dart';
import 'project.dart';
import 'video.dart' show loopExtendedVideos;

/// Video asset ids used by `layers`: video layers, and the video a sound
/// layer takes its sound from (its audioPath points into the videos).
Set<String> videoAssetIdsOf(Iterable<Layer> layers) => {
      for (final l in layers)
        if (l.content.videoAssetId != null) l.content.videoAssetId!,
      for (final l in layers)
        if (_videoOfSoundPath(l.content.audioPath) case final id?) id,
    };

/// Audio asset ids used by `layers`.
Set<String> audioAssetIdsOf(Iterable<Layer> layers) => {
      for (final l in layers)
        if (l.content.shape == 'audio' && l.content.audioAssetId != null) l.content.audioAssetId!,
    };

final _videoSoundPath = RegExp(r'/videos/([^/.]+)\.[^/]*$');

String? _videoOfSoundPath(String? path) => path == null ? null : _videoSoundPath.firstMatch(path)?.group(1);

/// One kept stretch of a source: units [start, end) of the old source,
/// placed at `offset` in the trimmed one.
class KeptSpan {
  final int start, end, offset;
  const KeptSpan(this.start, this.end, this.offset);
  int get length => end - start;

  @override
  String toString() => 'KeptSpan($start..$end -> $offset)';
}

/// The seconds of its source each layer plays: sourceIn .. sourceIn +
/// duration.
(double, double) usedSourceSeconds(Layer layer) =>
    (layer.content.sourceIn, layer.content.sourceIn + layer.durationFrames / fps);

/// The spans of a source (`totalUnits` long, `unitsPerSecond`) to keep
/// for the given used ranges (seconds), each widened by `marginSeconds`,
/// merged and placed end to end.
List<KeptSpan> keptSpans(Iterable<(double, double)> usedSeconds,
    {required double unitsPerSecond, required int totalUnits, double marginSeconds = 1}) {
  final raw = <(int, int)>[];
  for (final (from, to) in usedSeconds) {
    final s = ((from - marginSeconds) * unitsPerSecond + 1e-6).floor().clamp(0, totalUnits);
    final e = (((to + marginSeconds) * unitsPerSecond + 1e-6).floor() + 1).clamp(0, totalUnits);
    if (e > s) raw.add((s, e));
  }
  raw.sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final r in raw) {
    if (merged.isNotEmpty && r.$1 <= merged.last.$2) {
      merged[merged.length - 1] = (merged.last.$1, math.max(merged.last.$2, r.$2));
    } else {
      merged.add(r);
    }
  }
  var offset = 0;
  return [
    for (final (s, e) in merged) KeptSpan(s, e, (offset += e - s) - (e - s)),
  ];
}

int keptUnits(List<KeptSpan> spans) => spans.fold(0, (n, s) => n + s.length);

/// `sourceIn` in the trimmed source: moved by whole units with the span
/// it starts in (null if it isn't in any kept span).
double? remapSourceIn(double sourceIn, List<KeptSpan> spans, double unitsPerSecond) {
  final unit = (sourceIn * unitsPerSecond + 1e-6).floor();
  for (final s in spans) {
    if (unit >= s.start && unit < s.end) return sourceIn + (s.offset - s.start) / unitsPerSecond;
  }
  // before the first kept unit (a negative in-point) - held at the start.
  if (spans.isNotEmpty && unit < spans.first.start && spans.first.start == 0) return sourceIn;
  return null;
}

/// What trimming would keep of every video and sound the layers use:
/// asset id -> kept spans, only for assets where something is cut.
({Map<String, List<KeptSpan>> videos, Map<String, List<KeptSpan>> audios}) planMediaTrim(
  List<Layer> layers, {
  required Map<String, int> audioSamples,
  double marginSeconds = 1,
}) {
  final videoUse = <String, List<(double, double)>>{}, audioUse = <String, List<(double, double)>>{};
  final videoInfo = <String, Content>{};
  for (final l in layers) {
    final c = l.content;
    if (c.shape == 'video' && c.videoAssetId != null && (c.videoFps ?? 0) > 0 && (c.videoFrameCount ?? 0) > 0) {
      var used = usedSourceSeconds(l);
      // a looping video replays from its in-point to the clip's end.
      final end = c.videoFrameCount! / c.videoFps!;
      if (loopExtendedVideos && used.$2 > end) used = (used.$1, end);
      (videoUse[c.videoAssetId!] ??= []).add(used);
      videoInfo[c.videoAssetId!] = c;
    } else if (c.shape == 'audio' && c.audioAssetId != null && audioSamples.containsKey(c.audioAssetId)) {
      (audioUse[c.audioAssetId!] ??= []).add(usedSourceSeconds(l));
    }
  }
  final videos = <String, List<KeptSpan>>{}, audios = <String, List<KeptSpan>>{};
  videoUse.forEach((id, used) {
    final c = videoInfo[id]!;
    final total = c.videoFrameCount!;
    final spans = keptSpans(used, unitsPerSecond: c.videoFps!, totalUnits: total, marginSeconds: marginSeconds);
    if (spans.isNotEmpty && keptUnits(spans) < total) videos[id] = spans;
  });
  audioUse.forEach((id, used) {
    final total = audioSamples[id]!;
    final spans = keptSpans(used, unitsPerSecond: audioSampleRate.toDouble(), totalUnits: total, marginSeconds: marginSeconds);
    if (spans.isNotEmpty && keptUnits(spans) < total) audios[id] = spans;
  });
  return (videos: videos, audios: audios);
}
