/// The timeline's detail rows under the focused layer: one thin line per
/// effect (its time range, editable) and the expanded key view (one row
/// per params tab, lines between keys showing where the animation runs).
library;

import 'dart:math' as math;

import '../ui_geometry/keyframe_strip.dart' show visitLayerTracksNamed;
import 'effect_panel.dart';
import 'project.dart';

/// One effect's time range (local frames, inclusive).
class EffectSpan {
  final String id, label;
  final int start, end;
  const EffectSpan(this.id, this.label, this.start, this.end);
}

const _motionLabels = {
  'motionBlur': 'motion blur',
  'wiggle': 'wiggle',
  'pendulum': 'pendulum',
  'swing': 'swing',
  'timeQuantize': 'time steps',
};

/// Every effect of the layer, in the Effects tab's order, with its range
/// (the whole layer when it has none).
List<EffectSpan> effectSpans(Layer layer) => [
      for (final id in effectPanelEntries(layer))
        () {
          final r = layer.effectRanges[id];
          final label = _motionLabels[id] ??
              layer.effectStack.where((i) => i.id == id).map((i) => i.effectId.replaceAll('_', ' ')).firstOrNull ??
              id;
          return EffectSpan(id, label, r?[0] ?? 0, r?[1] ?? layer.durationFrames);
        }()
    ];

/// Sets an effect's range (clamped to the layer, at least one frame);
/// a range covering the whole layer is stored as none.
void setEffectRange(Layer layer, String id, int start, int end) {
  final d = layer.durationFrames;
  var s = start.clamp(0, d), e = end.clamp(0, d);
  if (e < s) (s, e) = (e, s);
  if (e == s) e < d ? e++ : s--;
  if (s <= 0 && e >= d) {
    layer.effectRanges.remove(id);
  } else {
    layer.effectRanges[id] = [s, e];
  }
}

/// One mask's time (local frames, inclusive).
class MaskSpan {
  final int index, start, end;
  const MaskSpan(this.index, this.start, this.end);
}

/// Every mask of the layer with its time (the whole layer when it has
/// none).
List<MaskSpan> maskSpans(Layer layer) => [
      for (var i = 0; i < layer.masks.length; i++)
        MaskSpan(i, layer.masks[i].range?[0] ?? 0, layer.masks[i].range?[1] ?? layer.durationFrames),
    ];

/// Sets a mask's time (clamped to the layer, at least one frame); the
/// whole layer is stored as none.
void setMaskRange(Layer layer, int index, int start, int end) {
  final d = layer.durationFrames;
  var s = start.clamp(0, d), e = end.clamp(0, d);
  if (e < s) (s, e) = (e, s);
  if (e == s) e < d ? e++ : s--;
  layer.masks[index].range = s <= 0 && e >= d ? null : [s, e];
}

/// The expanded key view's rows, in this order (each with its own colour
/// and key shape in the UI); matches the params tab of the same name.
const keyDetailTabs = ['Movement', 'Effects', 'Masks', 'Figures', 'Filters', 'Audio', 'Text', 'Line'];

/// The row of an animation layer's keys in the expanded key view (each
/// layer its own row, so its spans are its own keys' - A..C and B..D, not
/// A..B, B..C, C..D of everything mixed).
String animLayerRow(int n) => 'Layer $n';

String keyDetailTabOf(String trackName) {
  final layered = RegExp(r' \+(\d+)$').firstMatch(trackName);
  if (layered != null) return animLayerRow(int.parse(layered.group(1)!));
  if (trackName.startsWith('mask ')) return 'Masks';
  if (trackName.startsWith('glow ')) return 'Figures';
  if (trackName == 'volume') return 'Audio';
  if (trackName == 'negative') return 'Filters';
  if (trackName == 'shadow echo fade') return 'Figures';
  if (trackName == 'text' || trackName.startsWith('text ')) return 'Text';
  if (trackName.startsWith('line ')) return 'Line';
  if (const {'anchor', 'rotation', 'scale', 'opacity', 'path'}.contains(trackName.split(' ').first)) return 'Movement';
  return 'Effects'; // effect params, the pendulum grip
}

/// Tab -> its keys' local frames (sorted, unique); tabs without keys are
/// left out.
Map<String, List<int>> keyDetailRows(Layer layer) {
  final out = <String, Set<int>>{};
  visitLayerTracksNamed(layer, (name, trk) {
    if (trk.keyframes.isEmpty) return;
    out.putIfAbsent(keyDetailTabOf(name), () => {}).addAll(trk.keyframes.map((k) => k.frame));
  });
  final layerRows = out.keys.where((k) => k.startsWith('Layer ')).toList()
    ..sort((a, b) => int.parse(a.substring(6)).compareTo(int.parse(b.substring(6))));
  return {
    for (final t in keyDetailTabs)
      if (out[t] != null) ...{
        t: (out[t]!.toList()..sort()),
        // the animation layers right under the Movement row.
        if (t == 'Movement')
          for (final r in layerRows) r: (out[r]!.toList()..sort()),
      },
    if (out['Movement'] == null)
      for (final r in layerRows) r: (out[r]!.toList()..sort()),
  };
}

/// One line of the expanded key view: between two consecutive keys of
/// ONE parameter (`track`) - an anchor keyed at A and D and a rotation at
/// B and C give A..D and B..C, never A..B or C..D.
class KeySpan {
  final String track;
  final int a, b;
  const KeySpan(this.track, this.a, this.b);
}

/// Every parameter's lines, per row (the rows of keyDetailRows).
Map<String, List<KeySpan>> keyDetailSpans(Layer layer) {
  final out = <String, List<KeySpan>>{};
  visitLayerTracksNamed(layer, (name, trk) {
    if (trk.keyframes.length < 2) return;
    final frames = trk.keyframes.map((k) => k.frame).toSet().toList()..sort();
    final row = out.putIfAbsent(keyDetailTabOf(name), () => []);
    for (var i = 0; i < frames.length - 1; i++) {
      row.add(KeySpan(name, frames[i], frames[i + 1]));
    }
  });
  return out;
}

/// Deletes the keys at local frames `a` and `b` (the two ends of a
/// selected line) - of that line's own parameter (`track`), or of every
/// parameter of the row without one.
void deleteKeyDetailSpan(Layer layer, String tab, int a, int b, {String? track}) {
  visitLayerTracksNamed(layer, (name, trk) {
    if (keyDetailTabOf(name) != tab) return;
    if (track != null && name != track) return;
    trk.keyframes.removeWhere((k) => k.frame == a || k.frame == b);
  });
}

/// Moves the keys of a selected line: the one at `a` by `da` and the one
/// at `b` by `db` (local frames) - of `track`, or of every parameter of
/// the row. A key never lands on or past its neighbour. Returns the new
/// ends.
(int, int) moveKeyDetailSpan(Layer layer, String tab, int a, int b, int da, int db, {String? track}) {
  // how far the ends may go: not onto the neighbouring keys (or each other).
  var minA = -(1 << 30), maxB = 1 << 30;
  visitLayerTracksNamed(layer, (name, trk) {
    if (keyDetailTabOf(name) != tab || (track != null && name != track)) return;
    for (final k in trk.keyframes) {
      if (k.frame < a) minA = math.max(minA, k.frame + 1);
      if (k.frame > b) maxB = math.min(maxB, k.frame - 1);
    }
  });
  var na = (a + da).clamp(minA, maxB), nb = (b + db).clamp(minA, maxB);
  if (da != db) {
    // one edge: it stays on its side of the other.
    if (da != 0) na = math.min(na, b - 1);
    if (db != 0) nb = math.max(nb, a + 1);
  } else {
    // the whole line: keeps its length.
    final d = (na - a).abs() < (nb - b).abs() ? na - a : nb - b;
    na = a + d;
    nb = b + d;
  }
  visitLayerTracksNamed(layer, (name, trk) {
    if (keyDetailTabOf(name) != tab || (track != null && name != track)) return;
    final ka = trk.keyframes.where((k) => k.frame == a).toList(), kb = trk.keyframes.where((k) => k.frame == b).toList();
    for (final k in ka) {
      k.frame = na;
    }
    for (final k in kb) {
      k.frame = nb;
    }
    trk.keyframes.sort((x, y) => x.frame.compareTo(y.frame));
  });
  return (na, nb);
}
