/// One rule for "which value does an edit at this frame change", shared by
/// every stage drag and every parameter field all keyed parameters should
/// behave like the move tool).
///
/// - a keyframe exactly at the frame -> that keyframe;
/// - before the first / after the last keyframe -> that boundary keyframe
///   (`evaluateTrack` clamps to it there, so it's the value you see);
/// - strictly between two keyframes with no exact match -> nothing (same
///   as the move tool: editing inside the animation needs a keyframe);
/// - no keyframes at all -> the track's static `defaultValue`.
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import 'project.dart';

/// The animation layer edits of `trk` go to now (activeAnimLayer), or
/// null for the track's own keys.
AnimLayer? activeAnimLayerOf(Track trk) =>
    activeAnimLayer > 0 && trk.animLayers.length >= activeAnimLayer ? trk.animLayers[activeAnimLayer - 1] : null;

/// The track whose keys an edit goes to (see activeAnimLayerOf).
Track editTrackOf(Track trk) => activeAnimLayerOf(trk)?.track ?? trk;

/// The Keyframes tab's key mode: 'base' (keys go into the parameters' own
/// keys), 'order' (each pair of keys becomes a layer of its own: the first
/// key opens a range, the second closes it) or 'layers' (pick the layer
/// keys go into).
String keyMode = 'base';

/// The transform keys of animation layer `n` (1-based): their frames.
Set<int> animLayerKeyFrames(Layer layer, int n) => {
      for (final t in [layer.transform.anchor, layer.transform.rotation, layer.transform.scale, layer.transform.opacity])
        if (t.animLayers.length >= n) ...t.animLayers[n - 1].track.keyframes.map((k) => k.frame),
    };

/// Order keys: the layer still waiting for its second key (one key frame
/// so far), or null.
int? openOrderLayer(Layer layer) {
  for (var n = layer.transform.anchor.animLayers.length; n >= 1; n--) {
    if (animLayerKeyFrames(layer, n).length == 1) return n;
  }
  return null;
}

/// Order keys: the layer a key placed at `localFrame` goes into - the open
/// one (it closes), or a new one (it opens) - made the edited layer.
int orderKeyTarget(Layer layer, int localFrame) {
  final open = openOrderLayer(layer);
  if (open != null && !animLayerKeyFrames(layer, open).contains(localFrame)) {
    activeAnimLayer = open;
    return open;
  }
  activeAnimLayer = addTransformAnimLayer(layer);
  return activeAnimLayer;
}

/// Order keys: a closed range goes into an earlier layer it doesn't
/// overlap (so layers are reused instead of piling up); returns the layer
/// it is in now. Exactly the same movement: each part is offset by what
/// the other one holds there (see mergeAnimLayerInto).
int packOrderLayer(Layer layer, int n) {
  final mine = animLayerKeyFrames(layer, n);
  if (mine.length < 2) return n;
  final lo = mine.reduce(math.min), hi = mine.reduce(math.max);
  for (var m = 1; m < n; m++) {
    final other = animLayerKeyFrames(layer, m);
    if (other.isEmpty) continue;
    if (other.reduce(math.max) < lo || other.reduce(math.min) > hi) {
      mergeAnimLayerInto(layer, m, n);
      if (activeAnimLayer == n) activeAnimLayer = m;
      return m;
    }
  }
  return n;
}

/// Moves animation layer `from`'s keys into layer `into` (their key spans
/// must not overlap) and removes `from`, the movement unchanged: the
/// earlier part's keys take on what the later part holds before it
/// starts, the later part's keys what the earlier holds after it ends.
void mergeAnimLayerInto(Layer layer, int into, int from) {
  for (final t in [layer.transform.anchor, layer.transform.rotation, layer.transform.scale, layer.transform.opacity]) {
    if (t.animLayers.length < math.max(into, from)) continue;
    final a = t.animLayers[into - 1], b = t.animLayers[from - 1];
    final mul = a.multiply;
    dynamic shift(dynamic v, dynamic by) => combineValues(v is List ? List<double>.from(v) : v, by, mul);
    final ak = a.track.keyframes, bk = b.track.keyframes;
    final ad = a.track.defaultValue, bd = b.track.defaultValue;
    if (ak.isEmpty && bk.isEmpty) {
      a.track.defaultValue = shift(ad, bd);
    } else if (bk.isEmpty) {
      for (final k in ak) {
        k.value = shift(k.value, bd);
      }
    } else if (ak.isEmpty) {
      a.track.keyframes = [for (final k in bk) k..value = shift(k.value, ad)];
    } else {
      final aFirst = ak.first.frame < bk.first.frame;
      final early = aFirst ? ak : bk, late = aFirst ? bk : ak;
      final lateStart = late.first.value, earlyEnd = early.last.value;
      for (final k in early) {
        k.value = shift(k.value, lateStart);
      }
      for (final k in late) {
        k.value = shift(k.value, earlyEnd);
      }
      a.track.keyframes = [...early, ...late];
    }
    if (a.track.spatial) autoComputeTangents(a.track);
  }
  removeTransformAnimLayer(layer, from);
}

/// Adds an animation layer to each of `layer`'s transform tracks
/// (position and rotation add, scale and opacity multiply); returns its
/// number.
int addTransformAnimLayer(Layer layer) {
  final t = layer.transform;
  t.anchor.animLayers.add(AnimLayer(track: Track([0.0, 0.0])));
  t.rotation.animLayers.add(AnimLayer(track: Track(0.0)));
  t.scale.animLayers.add(AnimLayer(track: Track([1.0, 1.0]), multiply: true));
  t.opacity.animLayers.add(AnimLayer(track: Track(1.0), multiply: true));
  return t.anchor.animLayers.length;
}

/// Removes animation layer `n` (1-based) from `layer`'s transform tracks.
void removeTransformAnimLayer(Layer layer, int n) {
  for (final trk in [layer.transform.anchor, layer.transform.rotation, layer.transform.scale, layer.transform.opacity]) {
    if (trk.animLayers.length >= n) trk.animLayers.removeAt(n - 1);
  }
}

/// Switches animation layer `n` of `layer`'s transform on / off.
void setTransformAnimLayerEnabled(Layer layer, int n, bool on) {
  for (final trk in [layer.transform.anchor, layer.transform.rotation, layer.transform.scale, layer.transform.opacity]) {
    if (trk.animLayers.length >= n) trk.animLayers[n - 1].enabled = on;
  }
}

/// A layer-local frame for a global one, clamped to the layer's range.
/// On a loop repeat, the matching frame of the first pass.
int localFrameOf(Layer layer, int globalFrame) =>
    math.min(layer.durationFrames, math.max(0, loopedFrame(layer, globalFrame).round() - layer.startFrame));

Keyframe? keyframeAt(Track trk, int localFrame) {
  for (final k in trk.keyframes) {
    if (k.frame == localFrame) return k;
  }
  return null;
}

Keyframe? keyframeToEdit(Track trk, int localFrame) {
  final exact = keyframeAt(trk, localFrame);
  if (exact != null) return exact;
  final kfs = trk.keyframes;
  if (kfs.isEmpty) return null;
  if (localFrame < kfs.first.frame) return kfs.first;
  if (localFrame > kfs.last.frame) return kfs.last;
  return null;
}

/// The value an edit at `localFrame` starts from.
/// With an animation layer active it's the total (what setTrackValueAt
/// then takes back apart).
dynamic trackValueToEdit(Track trk, int localFrame) => activeAnimLayerOf(trk) != null
    ? evaluateTrack(null, trk, localFrame.toDouble())
    : keyframeToEdit(trk, localFrame)?.value ?? trk.defaultValue;

/// Writes `value` into whatever `keyframeToEdit` picks (or the static
/// default), re-deriving spatial tangents afterwards.
void setTrackValueAt(Track trk, int localFrame, dynamic value) {
  // an animation layer active: it takes what is needed for the total to
  // be `value`, the track's own keys and the other layers unchanged.
  final al = activeAnimLayerOf(trk);
  if (al != null) {
    final f = localFrame.toDouble();
    final others = combineAnimLayers(null, trk, evaluateTrackOwn(null, trk, f), f, null, al);
    setTrackValueAt(al.track, localFrame, residualValue(value, others, al.multiply));
    return;
  }
  final k = keyframeToEdit(trk, localFrame);
  if (k != null) {
    k.value = value;
  } else {
    trk.defaultValue = value;
  }
  if (trk.spatial) autoComputeTangents(trk);
}
