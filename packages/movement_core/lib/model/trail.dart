/// Trail points (Drawing tab): a point that leaves a line behind it as it
/// moves on the stage - by its own keys, or carried by a parent. Whether
/// it is drawing is a keyed switch (stepped), so the trail can stop and
/// start again without hiding what is already drawn.
library;

import '../core/state_cache.dart';
import '../core/stage_size.dart';
import 'project.dart';

bool isTrailShape(String shape) => shape == 'trail';

/// A new trail point in the middle of the frame.
Layer createTrailLayer({double width = 6, String color = '#ffffff'}) {
  final l = createLayer('rect', size: 18)
    ..color = color
    ..name = niceLayerName('trail', layerCounter);
  l.content
    ..shape = 'trail'
    ..lineWidth = width
    ..trailOn = Track(1.0, false);
  return l;
}

/// Whether the point draws at local frame `f`: its last key at or before
/// `f` (no easing between keys), else its plain value.
bool trailDrawingAt(Content c, num f) {
  final t = c.trailOn;
  if (t == null) return true;
  Keyframe? last;
  for (final k in t.keyframes) {
    if (k.frame <= f && (last == null || k.frame >= last.frame)) last = k;
  }
  final v = last?.value ?? (t.keyframes.isEmpty ? t.defaultValue : _first(t).value);
  return (v as num) >= 0.5;
}

Keyframe _first(Track t) => t.keyframes.reduce((a, b) => a.frame <= b.frame ? a : b);

/// The trail up to `globalFrame`: the point's place on the frame (px) at
/// every frame since its layer began, in one line per stretch it was
/// drawing.
List<List<List<double>>> trailPolylines(Project project, Layer layer, int globalFrame) {
  final out = <List<List<double>>>[];
  final end = globalFrame < layer.startFrame + layer.durationFrames ? globalFrame : layer.startFrame + layer.durationFrames;
  List<List<double>>? run;
  for (var f = layer.startFrame; f <= end; f++) {
    if (!trailDrawingAt(layer.content, f - layer.startFrame)) {
      run = null;
      continue;
    }
    final m = getLayerStateAt(project, layer.id, f).matrix;
    final c = layer.content.offset;
    final p = [
      m[0] * c[0] + m[2] * c[1] + m[4] * stageSize.width,
      m[1] * c[0] + m[3] * c[1] + m[5] * stageSize.height,
    ];
    if (run == null) {
      run = [p];
      out.add(run);
    } else if ((p[0] - run.last[0]).abs() > 1e-6 || (p[1] - run.last[1]).abs() > 1e-6) {
      run.add(p);
    }
  }
  return out;
}
