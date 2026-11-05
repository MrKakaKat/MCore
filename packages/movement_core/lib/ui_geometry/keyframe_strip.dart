/// ============================================================
/// Port of movement-core/src/ui/timeline/keyframeStrip.js's DATA layer:
/// which global frames have any keyframe across a layer's keyframeable
/// tracks, selecting/copying/pasting keyframe groups.
///
/// One deliberate, disclosed deviation: JS's drag-to-retime isn't
/// actually implemented as a drag on the strip's own markers at all -
/// it's routed through the main scrub `<input type="range">`'s native
/// "input" events instead (see scrub.js's armDragViaScrub/
/// disarmDragViaScrub), specifically to sidestep unreliable pointer
/// capture on tiny DOM elements. That constraint doesn't apply here -
/// Flutter gives every widget, however small, the same reliable
/// pointer-capture stage_gesture_controller.dart already depends on for
/// handles far smaller than a keyframe marker needs to be - so
/// KeyframeGroupDragOp below implements a direct drag-the-marker
/// interaction instead of porting the arm-then-scrub workaround. Same
/// underlying mutation math either way (move every selected keyframe by
/// the same delta, re-sort, re-tangent spatial tracks).
///
/// Also found while porting: JS's visitLayerTracks visits `mk.radius`
/// on every mask in addition to `mk.feather` - this Dart port's own
/// Mask class (model/project.dart) has no `radius` field at all, only
/// `feather`. Not fixed here - masksSection.js itself hasn't been
/// ported to this app yet (see params_panel_view.dart's own doc
/// comment), so whether a `radius` track belongs on Mask is a
/// masks-section-scoped question, not this file's. Ported below using
/// only the fields that actually exist.
/// ============================================================
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../model/project.dart';
import '../model/line_path.dart' show LineNode;
import '../model/track_edit.dart' show editTrackOf, keyMode, orderKeyTarget, packOrderLayer;

/// visitLayerTracks with a short name per track (for lists).
void visitLayerTracksNamed(Layer layer, void Function(String name, Track track) fn) {
  for (final (name, trk) in [
    ('anchor', layer.transform.anchor),
    ('rotation', layer.transform.rotation),
    ('scale', layer.transform.scale),
    ('opacity', layer.transform.opacity),
  ]) {
    fn(name, trk);
    // its animation layers: "anchor +1", ...
    for (var i = 0; i < trk.animLayers.length; i++) {
      fn('$name +${i + 1}', trk.animLayers[i].track);
    }
  }
  fn('path', layer.transform.pathFollow.t);
  for (var i = 0; i < layer.masks.length; i++) {
    fn('mask ${i + 1} feather', layer.masks[i].feather);
  }
  final mr = layer.maskRegions;
  if (mr != null) {
    for (final e in mr.opacity.entries) {
      fn('mask region ${regionSignatureLabel(e.key, mr.sources.length)}', e.value);
    }
  }
  for (final inst in layer.effectStack) {
    for (final e in inst.params.entries) {
      if (e.value is Track) fn('${inst.effectId} ${e.key}', e.value as Track);
    }
  }
  fn('pendulum grip', layer.pendulum.pivotOffset);
  final volume = layer.content.volume;
  if (volume != null) fn('volume', volume);
  fn('negative', layer.filters.negative);
  fn('shadow echo fade', layer.fill.shadow.echoFade);
  final ts = layer.content.text?.shadow;
  if (ts != null) fn('text shadow echo fade', ts.echoFade);
  for (var i = 0; i < layer.fill.glows.length; i++) {
    final g = layer.fill.glows[i];
    fn('glow ${i + 1} position', g.position);
    if (g.kind == 'line') fn('glow ${i + 1} end', g.end);
    fn('glow ${i + 1} radius', g.radius);
    fn('glow ${i + 1} strength', g.strength);
  }
  final text = layer.content.text;
  if (text != null) {
    fn('text', text.textKeys);
    for (var i = 0; i < text.spans.length; i++) {
      final sp = text.spans[i];
      for (final (k, t) in [('move', sp.move), ('turn', sp.turn), ('scale', sp.scale), ('opacity', sp.opacity)]) {
        if (t != null) fn('text part ${i + 1} $k', t);
      }
    }
    for (var i = 0; i < text.animators.length; i++) {
      for (final e in text.animators[i].tracks.entries) {
        fn('text animator ${i + 1} ${e.key}', e.value);
      }
    }
  }
  final c = layer.content;
  if (c.lineTrimStart != null) fn('line start', c.lineTrimStart!);
  if (c.lineTrimEnd != null) fn('line end', c.lineTrimEnd!);
  final nodes = c.lineNodes;
  if (nodes != null) {
    for (var i = 0; i < nodes.length; i++) {
      fn('line amplitude ${i + 1}', nodes[i].ampT);
      fn('line waves ${i + 1}', nodes[i].wavesT);
      if (nodes[i].posT != null) fn('line point ${i + 1}', nodes[i].posT!);
      for (final e in nodes[i].keys.entries) {
        fn('line point ${i + 1} ${e.key}', e.value);
      }
    }
  }
}

/// visits every keyframeable track on a layer - the single shared
/// traversal "collect frame numbers for the strip" and "collect actual
/// keyframe objects for select/move/copy" both build on.
void visitLayerTracks(Layer layer, void Function(Track track) fn) {
  for (final trk in [layer.transform.anchor, layer.transform.rotation, layer.transform.scale, layer.transform.opacity]) {
    fn(trk);
    for (final a in trk.animLayers) {
      fn(a.track);
    }
  }
  fn(layer.transform.pathFollow.t);
  for (final mask in layer.masks) {
    fn(mask.feather);
  }
  for (final t in layer.maskRegions?.opacity.values ?? const <Track>[]) {
    fn(t);
  }
  for (final inst in layer.effectStack) {
    for (final param in inst.params.values) {
      if (param is Track) fn(param);
    }
  }
  fn(layer.pendulum.pivotOffset);
  final volume = layer.content.volume;
  if (volume != null) fn(volume);
  fn(layer.filters.negative);
  fn(layer.fill.shadow.echoFade);
  final ts = layer.content.text?.shadow;
  if (ts != null) fn(ts.echoFade);
  for (final g in layer.fill.glows) {
    fn(g.position);
    if (g.kind == 'line') fn(g.end);
    fn(g.radius);
    fn(g.strength);
  }
  final text = layer.content.text;
  if (text != null) {
    fn(text.textKeys);
    for (final sp in text.spans) {
      for (final t in [sp.move, sp.turn, sp.scale, sp.opacity]) {
        if (t != null) fn(t);
      }
    }
    for (final a in text.animators) {
      a.tracks.values.forEach(fn);
    }
  }
  final c = layer.content;
  if (c.lineTrimStart != null) fn(c.lineTrimStart!);
  if (c.lineTrimEnd != null) fn(c.lineTrimEnd!);
  for (final n in c.lineNodes ?? const <LineNode>[]) {
    fn(n.ampT);
    fn(n.wavesT);
    if (n.posT != null) fn(n.posT!);
    n.keys.values.forEach(fn);
  }
}

/// every keyframe frame across ALL of a layer's tracks, as GLOBAL frame
/// numbers (local frame + layer.startFrame), sorted and de-duplicated -
/// "quickly find keys" needs the whole picture, not just one
/// parameter's own path.
List<int> collectLayerKeyframeFrames(Layer layer) {
  final frames = <int>{};
  visitLayerTracks(layer, (trk) {
    for (final k in trk.keyframes) {
      frames.add(k.frame + layer.startFrame);
    }
  });
  final sorted = frames.toList()..sort();
  return sorted;
}

/// same as collectLayerKeyframeFrames, but skips any track the user has
/// marked `hidden` (a per-track DISPLAY toggle, see Track.hidden's own
/// doc comment) - used only by LayersTimelineView's diamond markers,
/// never by copy/paste or any other data operation, which must keep
/// operating on every keyframe regardless of this purely visual flag.
List<int> collectVisibleLayerKeyframeFrames(Layer layer) {
  final frames = <int>{};
  visitLayerTracks(layer, (trk) {
    if (trk.hidden) return;
    for (final k in trk.keyframes) {
      frames.add(k.frame + layer.startFrame);
    }
  });
  final sorted = frames.toList()..sort();
  return sorted;
}

/// one keyframe together with the track that owns it - the basis for
/// select/move/copy, which need to mutate/read the real keyframe
/// entries, not just know a frame number exists somewhere.
class TrackKeyframe {
  final Track track;
  final Keyframe keyframe;
  TrackKeyframe(this.track, this.keyframe);
}

/// every keyframe OBJECT (with its owning track) whose LOCAL frame is
/// in localFrames.
List<TrackKeyframe> collectKeyframesAtFrames(
    Layer layer, Set<int> localFrames) {
  final result = <TrackKeyframe>[];
  visitLayerTracks(layer, (trk) {
    for (final k in trk.keyframes) {
      if (localFrames.contains(k.frame)) result.add(TrackKeyframe(trk, k));
    }
  });
  return result;
}

/// one copied keyframe, relative to the earliest keyframe in the group
/// it was copied from - so pasting preserves the group's internal
/// spacing regardless of where the playhead is when you paste.
class _ClipboardItem {
  final Track track;
  final int relFrame;
  final dynamic value;
  final Easing temporal;
  final SpatialTangent spatialTangent;
  _ClipboardItem(
      {required this.track,
      required this.relFrame,
      required this.value,
      required this.temporal,
      required this.spatialTangent});
}

List<_ClipboardItem>? _clipboard;

/// copies the keyframe group at `selectedGlobalFrames` on `layer` -
/// stores direct track references, so paste only makes sense back onto
/// the SAME layer (a different layer has entirely different track
/// objects - there's no meaningful cross-layer target here, same as JS).
void copySelectedKeyframes(Layer layer, Set<int> selectedGlobalFrames) {
  if (selectedGlobalFrames.isEmpty) return;
  final localFrames =
      selectedGlobalFrames.map((gf) => gf - layer.startFrame).toSet();
  final items = collectKeyframesAtFrames(layer, localFrames);
  if (items.isEmpty) return;
  final minFrame = items.map((it) => it.keyframe.frame).reduce(math.min);
  _clipboard = [
    for (final it in items)
      _ClipboardItem(
        track: it.track,
        relFrame: it.keyframe.frame - minFrame,
        value: it.keyframe.value is List
            ? [...(it.keyframe.value as List<double>)]
            : it.keyframe.value,
        temporal: it.keyframe.temporal.copy(),
        spatialTangent: it.keyframe.spatialTangent.copy(),
      ),
  ];
}

/// pastes the clipboard at the CURRENT (local) frame - each item's
/// relFrame offset (captured at copy time) is added back on, so the
/// group's internal spacing survives regardless of where you paste it.
/// Returns the new selection (global frames), or null if there was
/// nothing to paste.
Set<int>? pasteKeyframes(Layer layer, int globalFrame) {
  final clip = _clipboard;
  if (clip == null || clip.isEmpty) return null;
  final localFrame = math.min(
      layer.durationFrames, math.max(0, globalFrame - layer.startFrame));
  final touchedTracks = <Track>{};
  final newFrames = <int>{};
  for (final item in clip) {
    final targetFrame = localFrame + item.relFrame;
    newFrames.add(targetFrame + layer.startFrame);
    final newValue =
        item.value is List ? [...(item.value as List<double>)] : item.value;
    final existing = item.track.keyframes
        .cast<Keyframe?>()
        .firstWhere((k) => k!.frame == targetFrame, orElse: () => null);
    if (existing != null) {
      existing.value = newValue;
      existing.temporal = item.temporal.copy();
      existing.spatialTangent = item.spatialTangent.copy();
    } else {
      item.track.keyframes.add(Keyframe(
          frame: targetFrame,
          value: newValue,
          temporal: item.temporal.copy(),
          spatialTangent: item.spatialTangent.copy()));
    }
    touchedTracks.add(item.track);
  }
  for (final trk in touchedTracks) {
    trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
    if (trk.spatial) autoComputeTangents(trk);
  }
  return newFrames;
}

/// direct drag-the-marker retiming (see this file's own header comment
/// for why this deviates from JS's arm-then-scrub workaround). `.grab`
/// captures every keyframe in the selected group plus its own starting
/// frame; `.apply` moves all of them by the same delta from the drag's
/// origin frame, clamped so no keyframe's LOCAL frame goes negative -
/// same clamp JS's own scrub-input handler applies.
/// Settings: keys may be dragged out of their layer's range (kept, shown
/// dimmed; the animation is cut off at the layer's end). Off: a drag of
/// keys inside the layer stops at its edges. Keys already outside move
/// freely either way.
bool keysMayLeaveLayer = false;

class KeyframeGroupDragOp {
  final List<({Track track, Keyframe keyframe, int startFrame})> items;
  final int originGlobalFrame;
  KeyframeGroupDragOp._(this.items, this.originGlobalFrame);

  factory KeyframeGroupDragOp.grab(
      Layer layer, Set<int> selectedGlobalFrames, int originGlobalFrame) {
    final localFrames =
        selectedGlobalFrames.map((gf) => gf - layer.startFrame).toSet();
    final items = [
      for (final tk in collectKeyframesAtFrames(layer, localFrames))
        (track: tk.track, keyframe: tk.keyframe, startFrame: tk.keyframe.frame),
    ];
    return KeyframeGroupDragOp._(items, originGlobalFrame);
  }

  /// returns the new selection (global frames) after moving every
  /// captured keyframe to reflect `currentGlobalFrame`'s delta from
  /// this drag's origin.
  Set<int> apply(Layer layer, int currentGlobalFrame) {
    // the group moves as one (spacing is preserved). Keys inside the layer
    // stop at its edges - unless keysMayLeaveLayer, or some of them are
    // already outside it (shortened layer): then only frame 0 of the
    // timeline stops them.
    var delta = currentGlobalFrame - originGlobalFrame;
    if (items.isNotEmpty) {
      final minStart = items.map((i) => i.startFrame).reduce(math.min);
      final maxStart = items.map((i) => i.startFrame).reduce(math.max);
      final anyOutside = minStart < 0 || maxStart > layer.durationFrames;
      if (keysMayLeaveLayer || anyOutside) {
        delta = math.max(delta, -(minStart + layer.startFrame));
      } else {
        delta = delta.clamp(-minStart, math.max(-minStart, layer.durationFrames - maxStart));
      }
    }
    final touchedTracks = <Track>{};
    for (final item in items) {
      item.keyframe.frame = item.startFrame + delta;
      touchedTracks.add(item.track);
    }
    for (final trk in touchedTracks) {
      trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
      if (trk.spatial) autoComputeTangents(trk);
    }
    return {for (final item in items) item.keyframe.frame + layer.startFrame};
  }

  /// On release: a moved key that landed on another key of the same track
  /// replaces it (a track never keeps two keys on one frame).
  void finish() {
    final moved = {for (final item in items) item.keyframe};
    final touched = {for (final item in items) item.track};
    for (final trk in touched) {
      final movedFrames = {
        for (final k in trk.keyframes)
          if (moved.contains(k)) k.frame
      };
      trk.keyframes.removeWhere(
          (k) => !moved.contains(k) && movedFrames.contains(k.frame));
      if (trk.spatial) autoComputeTangents(trk);
    }
  }
}

/// The tracks a "master key" records: every parameter currently affecting
/// the layer. Path-follow progress and the pendulum pivot only count while
/// their feature is on - keying a disabled feature would just add markers
/// that change nothing.
void visitActiveLayerTracks(Layer layer, void Function(Track track) fn) {
  // the transform: the keys edits go to now (an active animation layer).
  fn(editTrackOf(layer.transform.anchor));
  fn(editTrackOf(layer.transform.rotation));
  fn(editTrackOf(layer.transform.scale));
  fn(editTrackOf(layer.transform.opacity));
  if (layer.transform.pathFollow.enabled) fn(layer.transform.pathFollow.t);
  for (final mask in layer.masks) {
    fn(mask.feather);
  }
  for (final inst in layer.effectStack) {
    for (final param in inst.params.values) {
      if (param is Track) fn(param);
    }
  }
  if (layer.pendulum.enabled) fn(layer.pendulum.pivotOffset);
}

/// True when every active track already has a keyframe at `localFrame`.
bool allTracksKeyedAt(Layer layer, int localFrame) {
  var all = true;
  visitActiveLayerTracks(layer, (trk) {
    if (!trk.keyframes.any((k) => k.frame == localFrame)) all = false;
  });
  return all;
}

/// A master key's ease shared: every active parameter's key at
/// `localFrame` gets `easing`.
void shareEaseAtFrame(Layer layer, int localFrame, Easing easing) {
  visitActiveLayerTracks(layer, (trk) {
    for (final k in trk.keyframes) {
      if (k.frame == localFrame) k.temporal = easing;
    }
  });
}

/// "Master key": records every active parameter's current value as a
/// keyframe at `localFrame` (replacing any keyframe already there with the
/// same value it evaluates to, so nothing visibly jumps).
void keyAllTracks(Project project, Layer layer, int localFrame) {
  // order keys: this key opens a new range layer, or closes the open one.
  final order = keyMode == 'order';
  if (order) orderKeyTarget(layer, localFrame);
  visitActiveLayerTracks(layer, (trk) {
    final evaluated = evaluateTrackOwn(project, trk, localFrame.toDouble(), layer);
    // own copy - never alias another keyframe's/the default's list.
    final value = evaluated is List ? List<double>.from(evaluated) : evaluated;
    final existing = trk.keyframes.where((k) => k.frame == localFrame);
    if (existing.isNotEmpty) {
      existing.first.value = value;
    } else {
      trk.keyframes.add(Keyframe(
          frame: localFrame, value: value, temporal: newKeyEasing()));
      trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
    }
    if (trk.spatial) autoComputeTangents(trk);
  });
  // a closed range moves into an earlier layer it doesn't overlap.
  if (order && activeAnimLayer > 0) packOrderLayer(layer, activeAnimLayer);
}

/// Removes every active track's keyframe at `localFrame`.
void unkeyAllTracks(Layer layer, int localFrame) {
  visitActiveLayerTracks(layer, (trk) {
    trk.keyframes.removeWhere((k) => k.frame == localFrame);
    if (trk.spatial) autoComputeTangents(trk);
  });
}

/// The same curve played backwards: t -> 1 - p(1 - t).
Easing reversedEasing(Easing e) => Easing(1 - e.x2, 1 - e.y2, 1 - e.x1, 1 - e.y1,
    kind: switch (e.kind) { 'overshoot' => 'anticipate', 'anticipate' => 'overshoot', _ => e.kind },
    amount: e.amount,
    bounces: e.bounces);

/// "Reverse": appends a mirrored copy of the selected key cluster right
/// after its last key, so the animation plays forward and then back.
///
/// The pivot is the cluster's last key frame b (across every track, so
/// the tracks stay in sync); each selected key at f < b gets a copy at
/// 2b - f with the same value. A segment's easing lives on its later
/// key, so the copy of key j takes the reversed easing of the segment
/// that followed j - every segment plays exactly backwards. The layer is
/// lengthened if the copy runs past its end. Returns the new cluster's
/// frames (global) to select, or null when there's nothing to reverse.
Set<int>? reverseKeyframeCluster(Layer layer, Set<int> selectedGlobalFrames) {
  final localFrames = selectedGlobalFrames.map((gf) => gf - layer.startFrame).toSet();
  final picked = collectKeyframesAtFrames(layer, localFrames);
  if (picked.isEmpty) return null;
  final b = picked.map((p) => p.keyframe.frame).reduce(math.max);
  final byTrack = <Track, List<Keyframe>>{};
  for (final p in picked) {
    byTrack.putIfAbsent(p.track, () => []).add(p.keyframe);
  }
  final newFrames = <int>{};
  var maxFrame = b;
  for (final entry in byTrack.entries) {
    final trk = entry.key;
    final keys = entry.value..sort((x, y) => x.frame.compareTo(y.frame));
    final copies = <Keyframe>[];
    for (var j = 0; j < keys.length; j++) {
      final k = keys[j];
      if (k.frame == b) continue;
      final next = j + 1 < keys.length ? keys[j + 1] : null;
      copies.add(Keyframe(
        frame: 2 * b - k.frame,
        value: k.value is List ? List<double>.from(k.value as List) : k.value,
        temporal: next != null ? reversedEasing(next.temporal) : easingPresets['linear'],
      ));
    }
    for (final c in copies) {
      trk.keyframes.removeWhere((k) => k.frame == c.frame);
      trk.keyframes.add(c);
      newFrames.add(c.frame + layer.startFrame);
      maxFrame = math.max(maxFrame, c.frame);
    }
    trk.keyframes.sort((x, y) => x.frame.compareTo(y.frame));
    if (trk.spatial) autoComputeTangents(trk);
  }
  if (newFrames.isEmpty) return null;
  if (maxFrame > layer.durationFrames) layer.durationFrames = maxFrame;
  return newFrames;
}
