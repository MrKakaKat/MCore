/// Animation presets: only a layer's keyframed animation (not its other
/// settings), kept apart from the full parameter presets. Applying one
/// re-times the keys so the animation starts at the playhead.
///
/// Anchor and rotation are stored relative to their first key and added
/// to the target's own current value - the motion plays from wherever
/// the target object is, instead of teleporting it. Scale, opacity and
/// everything else are stored as-is.
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../effects/geometry_effect_registry.dart';
import '../ui_geometry/keyframe_strip.dart';
import 'project.dart';
import 'project_json.dart';

const _relativeTargets = {'anchor', 'rotation'};

/// Every keyframed track of `layer`, keyed by a name that can be found
/// again on another layer ('anchor', 'mask:0', 'effect:bend_arc#0:angle'...).
Map<String, Track> _namedTracks(Layer layer) {
  final out = <String, Track>{
    'anchor': layer.transform.anchor,
    'scale': layer.transform.scale,
    'rotation': layer.transform.rotation,
    'opacity': layer.transform.opacity,
    'pathFollow': layer.transform.pathFollow.t,
    'pendulumPivot': layer.pendulum.pivotOffset,
  };
  for (var i = 0; i < layer.masks.length; i++) {
    out['mask:$i'] = layer.masks[i].feather;
  }
  final seen = <String, int>{};
  for (final inst in layer.effectStack) {
    final n = seen[inst.effectId] = (seen[inst.effectId] ?? -1) + 1;
    inst.params.forEach((key, v) {
      if (v is Track) out['effect:${inst.effectId}#$n:$key'] = v;
    });
  }
  return out;
}

/// True when `layer` has any keyframes to save.
bool layerHasAnimation(Layer layer) {
  var any = false;
  visitLayerTracks(layer, (t) => any = any || t.keyframes.isNotEmpty);
  return any;
}

dynamic _sub(dynamic a, dynamic b) =>
    a is List ? [for (var i = 0; i < a.length; i++) (a[i] as double) - (b as List)[i]] : (a as double) - (b as double);
dynamic _add(dynamic a, dynamic b) =>
    a is List ? [for (var i = 0; i < a.length; i++) (a[i] as double) + ((b as List)[i] as num).toDouble()] : (a as double) + (b as num).toDouble();

/// The keyed animation of `layer`, frames counted from its earliest key.
Map<String, dynamic> animationPresetToJson(Layer layer) {
  final named = _namedTracks(layer)..removeWhere((_, t) => t.keyframes.isEmpty);
  if (named.isEmpty) return {'tracks': <dynamic>[]};
  final first = named.values.map((t) => t.keyframes.map((k) => k.frame).reduce(math.min)).reduce(math.min);
  return {
    'tracks': [
      for (final e in named.entries)
        {
          'target': e.key,
          'relative': _relativeTargets.contains(e.key),
          'keys': [
            for (final k in e.value.keyframes)
              {
                ...keyframeToJson(k),
                'frame': k.frame - first,
                if (_relativeTargets.contains(e.key)) 'value': _sub(k.value, e.value.keyframes.first.value),
              }
          ],
        }
    ],
  };
}

/// Applies an animation preset to `target`, its first key landing on
/// `localFrame`. Keys already inside the preset's time span are replaced
/// on the tracks it animates; an effect it animates that the target
/// doesn't have is added. The layer is lengthened to fit.
void applyAnimationPreset(Project project, Layer target, Map<String, dynamic> preset, int localFrame) {
  final tracks = (preset['tracks'] as List? ?? const []).cast<Map<String, dynamic>>();
  var lastFrame = localFrame;
  for (final t in tracks) {
    final name = t['target'] as String;
    final trk = _trackFor(target, name);
    if (trk == null) continue;
    final keys = [for (final k in (t['keys'] as List)) keyframeFromJson(k as Map<String, dynamic>)];
    if (keys.isEmpty) continue;
    final base = t['relative'] == true ? evaluateTrack(project, trk, localFrame.toDouble(), target) : null;
    final span = keys.map((k) => k.frame).reduce(math.max);
    trk.keyframes.removeWhere((k) => k.frame >= localFrame && k.frame <= localFrame + span);
    for (final k in keys) {
      k.frame += localFrame;
      if (base != null) k.value = _add(base, k.value);
      if (k.value is List) k.value = List<double>.from((k.value as List).map((v) => (v as num).toDouble()));
      trk.keyframes.add(k);
      lastFrame = math.max(lastFrame, k.frame);
    }
    trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
    if (trk.spatial) autoComputeTangents(trk);
  }
  if (lastFrame > target.durationFrames) target.durationFrames = lastFrame;
}

int _presetInstanceCounter = 0;

Track? _trackFor(Layer layer, String name) {
  final direct = _namedTracks(layer)[name];
  if (direct != null) return direct;
  final m = RegExp(r'^effect:([^#]+)#(\d+):(.+)$').firstMatch(name);
  if (m == null) return null; // a mask the target doesn't have
  final effectId = m.group(1)!, n = int.parse(m.group(2)!), param = m.group(3)!;
  if (!effectRegistry.containsKey(effectId)) return null;
  var have = layer.effectStack.where((i) => i.effectId == effectId).length;
  while (have <= n) {
    layer.effectStack.add(createEffectInstance(
        effectId, 'fx_${DateTime.now().microsecondsSinceEpoch}_${_presetInstanceCounter++}', layer));
    have++;
  }
  final inst = layer.effectStack.where((i) => i.effectId == effectId).elementAt(n);
  final v = inst.params[param];
  return v is Track ? v : null;
}
