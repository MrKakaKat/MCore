/// Tools on picked keys (the Keys tab's selection) and on a layer's
/// parameters as a whole.
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../effects/geometry_effect_registry.dart' show effectRegistry;
import '../ui_geometry/keyframe_strip.dart' show visitLayerTracks, visitLayerTracksNamed;
import 'layer_detail.dart' show setTrackLoop;
import 'project.dart';
import 'track_edit.dart';

dynamic _copy(dynamic v) => v is List ? [for (final e in v) (e as num).toDouble()] : v;

Keyframe _cloneKey(Keyframe k, int frame) => Keyframe(
      frame: frame,
      value: _copy(k.value),
      temporal: k.temporal,
      spatialTangent: SpatialTangent(inTan: [...k.spatialTangent.inTan], outTan: [...k.spatialTangent.outTan]),
    );

/// The parameters keyed on at least two of `frames` (local), by name.
Map<String, Track> tracksKeyedOn(Layer layer, Set<int> frames) {
  final out = <String, Track>{};
  visitLayerTracksNamed(layer, (name, t) {
    if (t.keyframes.where((k) => !k.passive && frames.contains(k.frame)).length >= 2) out[name] = t;
  });
  return out;
}

/// Whether the picked keys (local frames) end on each of their
/// parameters' last key - they can loop to the end for real then.
bool pickedKeysEndLast(Layer layer, Set<int> frames) {
  final ts = tracksKeyedOn(layer, frames);
  if (ts.isEmpty) return false;
  final hi = frames.reduce(math.max);
  return ts.values.every((t) => t.keyframes.last.frame <= hi);
}

/// Loop of the picked keys (local frames): from the first of them on,
/// over and over to the layer's end - each parameter keyed there (they
/// have to be its last keys, see pickedKeysEndLast). False: they are not.
bool loopPickedKeys(Layer layer, Set<int> frames, {String mode = 'repeat'}) {
  if (!pickedKeysEndLast(layer, frames)) return false;
  final lo = frames.reduce(math.min);
  tracksKeyedOn(layer, frames).forEach((name, t) {
    setTrackLoop(t, name, on: true, mode: mode);
    t.loopFrom = lo <= t.keyframes.first.frame ? null : lo;
    t.loopEnd = null;
  });
  return true;
}

/// The picked keys (local frames, first to last) played `times` more
/// times right after themselves, as keys: each pass starts from the
/// first picked key's values again (one frame after the last), the keys
/// after them (every parameter's) moved later by as much, the layer
/// longer by as much. Returns how many frames were added (0: nothing to
/// repeat).
int repeatPickedKeys(Layer layer, Set<int> frames, int times) {
  if (times < 1 || frames.length < 2) return 0;
  final lo = frames.reduce(math.min), hi = frames.reduce(math.max);
  final period = hi - lo + 1;
  final ts = tracksKeyedOn(layer, frames);
  if (ts.isEmpty) return 0;
  final add = period * times;
  // every key after them: later by the passes.
  visitLayerTracks(layer, (t) {
    for (final k in t.keyframes) {
      if (k.frame > hi) k.frame += add;
    }
  });
  for (final t in ts.values) {
    final pass = [for (final k in t.keyframes) if (k.frame >= lo && k.frame <= hi && !k.passive) k];
    for (var n = 1; n <= times; n++) {
      for (final k in pass) {
        t.keyframes.add(_cloneKey(k, k.frame + n * period));
      }
    }
    t.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
    if (t.spatial) autoComputeTangents(t);
  }
  layer.durationFrames += add;
  return add;
}

/// Moves the picked keys (local frames) of the layer's own move, turn,
/// size and opacity into its animation layer `n` (1-based; null: a new
/// one): the object is where it was on each of those frames - their
/// values there become what that layer adds (or multiplies). Returns the
/// layer it went into (null: nothing to move).
int? movePickedKeysToAnimLayer(Project project, Layer layer, Set<int> frames, int? n) {
  final t = layer.transform;
  final tracks = [t.anchor, t.rotation, t.scale, t.opacity];
  if (!tracks.any((trk) => trk.keyframes.any((k) => frames.contains(k.frame)))) return null;
  var into = n;
  if (into == null || into < 1 || t.anchor.animLayers.length < into) into = addTransformAnimLayer(layer);
  for (final trk in tracks) {
    final moving = [for (final k in trk.keyframes) if (frames.contains(k.frame)) k];
    if (moving.isEmpty || trk.animLayers.length < into) continue;
    // what it showed on each of them (all its layers together).
    final total = {for (final k in moving) k.frame: _copy(evaluateTrack(project, trk, k.frame.toDouble(), layer))};
    trk.keyframes.removeWhere((k) => frames.contains(k.frame));
    if (trk.spatial) autoComputeTangents(trk);
    final al = trk.animLayers[into - 1];
    for (final k in moving) {
      final f = k.frame.toDouble();
      final others = combineAnimLayers(project, trk, evaluateTrackOwn(project, trk, f, layer), f, layer, al);
      final v = residualValue(total[k.frame], others, al.multiply);
      al.track.keyframes
        ..removeWhere((x) => x.frame == k.frame)
        ..add(Keyframe(frame: k.frame, value: _copy(v), temporal: k.temporal));
    }
    al.track.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
    if (al.track.spatial) autoComputeTangents(al.track);
  }
  return into;
}

bool _same(dynamic a, dynamic b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (((a[i] as num) - (b[i] as num)).abs() > 1e-9) return false;
    }
    return true;
  }
  if (a is num && b is num) return (a - b).abs() <= 1e-9;
  return a == b;
}

/// Takes the parameters and keys of `src` into `dst`, keeping all `dst`
/// has: its keys stay (keys of `src` come in on the frames it has none),
/// a value it set stays (one still as a new layer has it takes `src`'s);
/// effects it does not have come over as copies (`newId` for each), as do
/// a motion blur it has off and Match Colors. Returns what changed.
int takeParamsFrom(Layer dst, Layer src, {required String Function() newId}) {
  var changed = 0;
  // effects it does not have yet.
  for (final inst in src.effectStack) {
    if (dst.effectStack.any((i) => i.effectId == inst.effectId)) continue;
    if (!effectRegistry.containsKey(inst.effectId) && inst.effectId.isEmpty) continue;
    // a copy of its own (through a layer copy: tracks and all).
    final c = (cloneLayer(createLayer(dst.content.shape)..effectStack = [inst]).effectStack.single)..id = newId();
    final r = src.effectRanges[inst.id];
    if (r != null) dst.effectRanges[c.id] = [...r];
    dst.effectStack.add(c);
    changed++;
  }
  if (!dst.motionBlur.enabled && src.motionBlur.enabled) {
    final mb = src.motionBlur;
    dst.motionBlur = MotionBlur(enabled: true, shutterAngle: mb.shutterAngle, samples: mb.samples, sensitivity: mb.sensitivity);
    changed++;
  }
  for (final m in src.filters.matches) {
    dst.filters.matches.add(m.copy()..id = newId());
    changed++;
  }
  // the parameters, by name.
  final fresh = <String, Track>{};
  visitLayerTracksNamed(createLayer(dst.content.shape), (name, t) => fresh[name] = t);
  final mine = <String, Track>{};
  visitLayerTracksNamed(dst, (name, t) => mine[name] = t);
  visitLayerTracksNamed(src, (name, s) {
    final d = mine[name];
    if (d == null || identical(d, s)) return;
    if (s.keyframes.isEmpty) {
      // a value: only where it still has the one it started with.
      final start = fresh[name]?.defaultValue;
      if (d.keyframes.isEmpty && start != null && _same(d.defaultValue, start) && !_same(s.defaultValue, d.defaultValue)) {
        d.defaultValue = _copy(s.defaultValue);
        changed++;
      }
      return;
    }
    var added = false;
    for (final k in s.keyframes) {
      if (k.passive || d.keyframes.any((x) => x.frame == k.frame)) continue;
      d.keyframes.add(_cloneKey(k, k.frame));
      added = true;
      changed++;
    }
    if (added) {
      d.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
      if (d.spatial) autoComputeTangents(d);
    }
  });
  return changed;
}
