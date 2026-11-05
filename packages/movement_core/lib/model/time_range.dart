/// Timeline range selection (Timeline tab): a stretch of global frames;
/// the tab's range actions work on every layer it touches.
library;

import 'dart:math' as math;

import '../ui_geometry/keyframe_strip.dart' show visitLayerTracks, visitLayerTracksNamed;
import '../geometry/shapes.dart' show isTimedMedia;
import '../effects/geometry_effect_registry.dart' show createEffectInstance;
import 'layer_detail.dart' show setEffectRange;
import 'project.dart';

/// Layers that overlap global frames a..b.
List<Layer> layersInRange(Project project, int a, int b) => [
      for (final l in project.layers)
        if (l.startFrame <= b && l.startFrame + l.durationFrames >= a) l,
    ];

/// Shifts the layers touching a..b by `delta` frames (not before 0).
void shiftLayersInRange(Project project, int a, int b, int delta) {
  final layers = layersInRange(project, a, b);
  if (layers.isEmpty) return;
  final minStart = layers.map((l) => l.startFrame).reduce(math.min);
  final d = math.max(delta, -minStart);
  for (final l in layers) {
    l.startFrame += d;
  }
}

/// Adds effect `effectId` to every layer touching a..b, on only the part
/// of each layer inside the range; returns how many layers got it.
int addEffectInRange(Project project, int a, int b, String effectId, String Function() newId) {
  var n = 0;
  for (final l in layersInRange(project, a, b)) {
    final s = math.max(a, l.startFrame) - l.startFrame, e = math.min(b, l.startFrame + l.durationFrames) - l.startFrame;
    if (e <= s) continue;
    final inst = createEffectInstance(effectId, newId(), l);
    l.effectStack.add(inst);
    setEffectRange(l, inst.id, s, e);
    n++;
  }
  return n;
}

/// Masks every layer touching a..b (but the mask itself) by layer
/// `sourceId`; returns how many got it.
int addMaskInRange(Project project, int a, int b, String sourceId) {
  var n = 0;
  for (final l in layersInRange(project, a, b)) {
    if (l.id == sourceId || l.masks.any((m) => m.sourceLayerId == sourceId)) continue;
    // only inside the range, like an effect added there.
    final s = math.max(a, l.startFrame) - l.startFrame, e = math.min(b, l.startFrame + l.durationFrames) - l.startFrame;
    l.masks.add(Mask(sourceLayerId: sourceId, range: s <= 0 && e >= l.durationFrames ? null : [s, e]));
    n++;
  }
  return n;
}

/// Deletes every key at global frames a..b on the layers there; returns
/// how many.
int deleteKeysInRange(Project project, int a, int b) {
  var n = 0;
  for (final l in layersInRange(project, a, b)) {
    visitLayerTracks(l, (trk) {
      final before = trk.keyframes.length;
      trk.keyframes.removeWhere((k) => k.frame + l.startFrame >= a && k.frame + l.startFrame <= b);
      n += before - trk.keyframes.length;
    });
  }
  return n;
}

/// Trims the layers touching a..b to it (what is outside is cut off; the
/// content keeps its place in time, like a start trim on the timeline).
void trimLayersToRange(Project project, int a, int b) {
  for (final l in layersInRange(project, a, b)) {
    final start = math.max(l.startFrame, a), end = math.min(l.startFrame + l.durationFrames, b);
    if (end <= start) continue;
    final shift = start - l.startFrame;
    if (shift != 0) {
      visitLayerTracks(l, (trk) {
        for (final k in trk.keyframes) {
          k.frame -= shift;
        }
      });
      if (isTimedMedia(l.content.shape)) l.content.sourceIn += shift / fps;
    }
    l.startFrame = start;
    l.durationFrames = end - start;
  }
}

/// Moves the keys at global frames `globalFrames` from `from` to the same
/// parameters of `to`, at the same moments in time (keys of parameters
/// `to` doesn't have stay). Returns how many moved.
int moveKeysToLayer(Layer from, Layer to, Set<int> globalFrames) {
  final target = <String, Track>{};
  visitLayerTracksNamed(to, (name, trk) => target[name] = trk);
  var n = 0;
  visitLayerTracksNamed(from, (name, trk) {
    final dest = target[name];
    if (dest == null || identical(dest, trk)) return;
    final moving = [for (final k in trk.keyframes) if (globalFrames.contains(k.frame + from.startFrame)) k];
    for (final k in moving) {
      trk.keyframes.remove(k);
      final f = k.frame + from.startFrame - to.startFrame;
      dest.keyframes
        ..removeWhere((d) => d.frame == f)
        ..add(k..frame = f);
      n++;
    }
    dest.keyframes.sort((x, y) => x.frame.compareTo(y.frame));
  });
  return n;
}
