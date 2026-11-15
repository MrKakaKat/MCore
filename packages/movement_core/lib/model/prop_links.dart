/// Dependencies (PropLink): a layer's property following one property of
/// another layer - chains included (a source may follow another source).
/// Each link adds the source's change since the link was made,
/// scaled, so nothing jumps where the link starts.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/interpolation.dart' show evaluateTrack;
import '../core/stage_size.dart';
import '../core/state_cache.dart' show getLayerStateAt;
import 'extend_box.dart' show layerExtendAt;
import 'audio.dart' show mediaSourceTime, peakBetween;
import 'project.dart';

/// A property's own value (keys, before links) at `globalFrame`.
double _own(Project project, Layer l, String prop, num globalFrame) {
  final f = (globalFrame - l.startFrame).clamp(0, l.durationFrames).toDouble();
  switch (prop) {
    case 'x':
    case 'y':
      final a = evaluateTrack(project, l.transform.anchor, f, l) as List;
      return prop == 'x' ? (a[0] as num) * stageSize.width : (a[1] as num) * stageSize.height;
    case 'rotation':
      return (evaluateTrack(project, l.transform.rotation, f, l) as num).toDouble();
    case 'scaleX':
    case 'scaleY':
      final s = evaluateTrack(project, l.transform.scale, f, l) as List;
      return ((prop == 'scaleX' ? s[0] : s[1]) as num).toDouble();
    case 'scale':
      // the whole size: both sides together (their mean).
      final s = evaluateTrack(project, l.transform.scale, f, l) as List;
      return (((s[0] as num) + (s[1] as num)) / 2).toDouble();
    case 'opacity':
      return (evaluateTrack(project, l.transform.opacity, f, l) as num).toDouble();
    case 'growLeft':
    case 'growTop':
    case 'growRight':
    case 'growBottom':
      // a lengthened rect: how far that side has grown (px).
      return layerExtendAt(l, globalFrame)[const ['growLeft', 'growTop', 'growRight', 'growBottom'].indexOf(prop)];
  }
  return 0;
}

/// A grown side (px) read into a size property of `layer`: as the scale
/// that grows it by as many px (a picture following a lengthened rect
/// grows the same way). 1 for anything else.
double _growToScale(Layer layer, String from, String prop) {
  if (!from.startsWith('grow')) return 1;
  final axis = switch (prop) {
    'scaleLeft' || 'scaleRight' || 'scaleX' || 'scale.x' => 0,
    'scaleTop' || 'scaleBottom' || 'scaleY' || 'scale.y' => 1,
    _ => -1,
  };
  if (axis < 0) return 1;
  final size = layer.content.size[axis].abs();
  return size < 1e-9 ? 0 : 1 / size;
}

/// Whether a link on `to` acts on `prop`: its own name, or - the whole
/// size ('scale') - each of its sides ('scale.x', 'scale.y').
bool linkHits(String to, String prop) => to == prop || (to == 'scale' && (prop == 'scale.x' || prop == 'scale.y'));

/// A property's value with its links (what a layer linked to it sees).
///
/// Position and rotation are where the layer really is on the stage -
/// however it got there: its keys, its own links, a parent, a path, a
/// wiggle, a swing... (so B moved by A moves C linked to B, though neither
/// has a key). Scale and opacity: its own value with its links.
double linkedPropAt(Project project, Layer l, String prop, num globalFrame, [Set<String>? seen]) {
  if (prop == 'x' || prop == 'y' || prop == 'rotation') {
    try {
      final st = getLayerStateAt(project, l.id, globalFrame);
      if (prop == 'x') return st.matrix[4] * stageSize.width;
      if (prop == 'y') return st.matrix[5] * stageSize.height;
      return _worldRotation(project, l, globalFrame);
    } on _LinkLoop {
      // its motion needs the layer being worked out (it hangs on it): its
      // keys and links only.
    }
  }
  return _own(project, l, prop, globalFrame) + linkOffset(project, l, prop, globalFrame, seen);
}

/// How far `l` is turned on the stage: its own turn and its parents'.
double _worldRotation(Project project, Layer l, num globalFrame) {
  var r = 0.0;
  final seen = <String>{};
  Layer? at = l;
  while (at != null && seen.add(at.id)) {
    r += getLayerStateAt(project, at.id, globalFrame).rot;
    at = at.parentId == null || !at.inheritRotation ? null : findLayer(project, at.parentId);
  }
  return r;
}

/// Thrown when working out a layer's links needs that same layer again
/// (a source hanging on it): caught where the source is read.
class _LinkLoop implements Exception {
  const _LinkLoop();
}

/// The layers whose links are being worked out right now.
final Set<String> _linksWorking = {};

/// While true, links work at every frame (their from / until left out) -
/// for linkPreviewOutline.
bool _ignoreLinkRanges = false;

/// Whether one of `layer`'s links is outside its time at `globalFrame`.
bool linkOutOfRange(Layer layer, num globalFrame) => layer.links.any((k) =>
    k.enabled &&
    k.sourceId != null &&
    ((k.fromFrame != null && globalFrame < k.fromFrame!) || (k.untilFrame != null && globalFrame > k.untilFrame!)));

/// What `layer`'s links would add to `prop` at `globalFrame` if each
/// worked then (outside its time too), minus what they add now.
double linkOffsetIfWorking(Project project, Layer layer, String prop, num globalFrame) {
  _ignoreLinkRanges = true;
  final would = linkOffset(project, layer, prop, globalFrame);
  _ignoreLinkRanges = false;
  return would - linkOffset(project, layer, prop, globalFrame);
}

/// What `layer`'s links add to `prop` at `globalFrame` (0 without any).
double linkOffset(Project project, Layer layer, String prop, num globalFrame, [Set<String>? seen]) {
  if (layer.links.isEmpty) return 0;
  final s = seen ?? <String>{};
  if (!s.add(layer.id)) return 0; // a circle (refused when made)
  if (!_linksWorking.add(layer.id)) throw const _LinkLoop();
  try {
    return _linkSum(project, layer, prop, globalFrame, s);
  } finally {
    _linksWorking.remove(layer.id);
  }
}

double _linkSum(Project project, Layer layer, String prop, num globalFrame, Set<String> s) {
  final ignoreRange = _ignoreLinkRanges;
  var sum = 0.0;
  for (final k in layer.links) {
    if (!k.enabled || !linkHits(k.to, prop) || k.sourceId == null) continue;
    final src = findLayer(project, k.sourceId);
    if (src == null) continue;
    // its time: before it nothing, after it what it added at its end.
    num t = globalFrame;
    final a = ignoreRange ? null : k.fromFrame, b = ignoreRange ? null : k.untilFrame;
    if (a != null && t < a) {
      if (k.fromSound) continue;
      t = a;
    }
    if (b != null && t > b) {
      if (k.fromSound) continue;
      t = b;
    }
    // a sound: how loud it is now, between min and max.
    if (k.fromSound) {
      final level = soundLevelAt(src, t, smooth: k.smooth);
      sum += k.min + (k.max - k.min) * level;
      continue;
    }
    if (k.follows) {
      sum += k.factor * _followAmount(project, layer, k, src, t, s, prop);
      continue;
    }
    sum += k.factor * _change(project, layer, k, src, k.from, k.base, t, s) * _growToScale(layer, k.from, prop);
  }
  return sum;
}

/// How much `src`'s `prop` changed by `t` since the link's start: its set
/// start, else the base pinned when it was made, else the layer's start.
double _change(Project project, Layer layer, PropLink k, Layer src, String prop, double? base, num t, Set<String> seen) {
  final now = linkedPropAt(project, src, prop, t, {...seen});
  final a = _ignoreLinkRanges ? null : k.fromFrame;
  final then = a != null
      ? linkedPropAt(project, src, prop, a, {...seen})
      : base ?? linkedPropAt(project, src, prop, layer.startFrame, {...seen});
  return now - then;
}

/// A 'follow' link: how far what it follows has moved since the link's
/// start (px) - the source's place, or one of its size handles - along
/// `prop`'s own axis, in that property's units.
double _followAmount(Project project, Layer layer, PropLink k, Layer src, num t, Set<String> seen, String prop) {
  if (!followTargets.contains(k.to)) return _change(project, layer, k, src, k.from, k.base, t, seen);
  final now = linkFollowPoint(project, src, k.from, t, seen);
  final a = _ignoreLinkRanges ? null : k.fromFrame;
  final then = a != null
      ? linkFollowPoint(project, src, k.from, a, seen)
      : (k.base != null && k.baseY != null ? [k.base!, k.baseY!] : linkFollowPoint(project, src, k.from, layer.startFrame, seen));
  final dx = now[0] - then[0], dy = now[1] - then[1];
  if (prop == 'x') return dx;
  if (prop == 'y') return dy;
  final rot = _own(project, layer, 'rotation', t) * math.pi / 180;
  final c = math.cos(rot), sn = math.sin(rot);
  // the whole size: both scales by the same amount (as a linked pair of
  // rulers) - a followed size handle's move along its own side's way
  // (right / bottom out: grows; left / top out: grows too), the place's
  // move along the axis it moves on most.
  if (prop == 'scale.x' || prop == 'scale.y') {
    final alongX = dx * c + dy * sn, alongY = -dx * sn + dy * c;
    final w = layer.content.size[0], h = layer.content.size[1];
    final ux = w <= 0 ? 0.0 : alongX / w, uy = h <= 0 ? 0.0 : alongY / h;
    return switch (k.from) {
      'scaleRight' => ux,
      'scaleLeft' => -ux,
      'scaleBottom' => uy,
      'scaleTop' => -uy,
      _ => ux.abs() >= uy.abs() ? ux : uy,
    };
  }
  // a size handle: the way the side it moves grows (see linkMovedSide),
  // turned with the layer.
  final n = linkMovedSide(k.to);
  if (n == null) return 0;
  final nx = n[0] * c - n[1] * sn, ny = n[0] * sn + n[1] * c;
  final along = dx * nx + dy * ny;
  // a handle moves by (its scale change) x (the size on its axis).
  final size = n[0] != 0 ? layer.content.size[0] : layer.content.size[1];
  return size <= 0 ? 0 : along / size;
}

/// What a 'follow' link follows on its source (`from`): 'position' (or
/// any plain property): where the source is; 'scaleLeft' / 'scaleRight' /
/// 'scaleTop' / 'scaleBottom': that size handle of its box - the middle
/// of that side, as it moves and grows. Frame px.
List<double> linkFollowPoint(Project project, Layer src, String from, num t, [Set<String>? seen]) {
  final side = switch (from) {
    'scaleLeft' => const [-1.0, 0.0],
    'scaleRight' => const [1.0, 0.0],
    'scaleTop' => const [0.0, -1.0],
    'scaleBottom' => const [0.0, 1.0],
    _ => null,
  };
  if (side != null) {
    try {
      final m = getLayerStateAt(project, src.id, t).matrix;
      final c = src.content;
      final p = [c.offset[0] + side[0] * c.size[0] / 2, c.offset[1] + side[1] * c.size[1] / 2];
      return [
        (m[0] * p[0] + m[2] * p[1]) + m[4] * stageSize.width,
        (m[1] * p[0] + m[3] * p[1]) + m[5] * stageSize.height,
      ];
    } on _LinkLoop {
      // hangs on the layer being worked out: its place instead.
    }
  }
  return [linkedPropAt(project, src, 'x', t, {...?seen}), linkedPropAt(project, src, 'y', t, {...?seen})];
}

/// The side a size-handle link moves, as its outward direction in the
/// layer (x: -1 left / 1 right; y: -1 top / 1 bottom): 'scaleLeft' /
/// 'scaleRight' grow the left / right side; 'scaleBottom' holds the bottom
/// and moves the top, 'scaleTop' holds the top and moves the bottom. Null:
/// not a size handle.
List<double>? linkMovedSide(String to) => switch (to) {
      'scaleLeft' => const [-1.0, 0.0],
      'scaleRight' => const [1.0, 0.0],
      'scaleBottom' => const [0.0, -1.0],
      'scaleTop' => const [0.0, 1.0],
      _ => null,
    };

/// Pins `k`'s base to its source's value now, so the layer keeps its
/// place when the link is made and follows every change after.
void pinLinkBase(Project project, PropLink k, num globalFrame) {
  final src = findLayer(project, k.sourceId);
  if (k.follows) {
    final p = src == null ? null : linkFollowPoint(project, src, k.from, globalFrame);
    k.base = p?[0];
    k.baseY = p?[1];
    return;
  }
  k.base = src == null ? null : linkedPropAt(project, src, k.from, globalFrame);
}

/// Whether `layer` taking a property from `sourceId` would make layers
/// depend on each other in a circle.
bool linkWouldCycle(Project project, Layer layer, String sourceId) {
  final seen = <String>{};
  bool reaches(String id) {
    if (id == layer.id) return true;
    if (!seen.add(id)) return false;
    final l = findLayer(project, id);
    if (l == null) return false;
    // its links, and what it hangs on (a parent moves it).
    return l.links.any((k) => k.sourceId != null && reaches(k.sourceId!)) || (l.parentId != null && reaches(l.parentId!));
  }

  return reaches(sourceId);
}


/// The waveforms of imported sounds by asset id (set by the app; null:
/// none known - a sound link then does nothing).
Uint8List? Function(String assetId)? soundPeaksProvider;

/// How loud audio layer `l` is at `globalFrame`, 0..1 (0 outside its
/// time). `smooth` (0..1) averages over a longer stretch before it, so the
/// level follows the swell instead of every hit.
double soundLevelAt(Layer l, num globalFrame, {double smooth = 0}) {
  final id = l.content.audioAssetId;
  final peaks = id == null ? null : soundPeaksProvider?.call(id);
  if (peaks == null || peaks.isEmpty || l.hidden) return 0;
  final local = globalFrame - l.startFrame;
  if (local < 0 || local > l.durationFrames) return 0;
  final t = mediaSourceTime(l.content, local);
  final step = 1 / fps;
  // a window of a frame (none) up to about a second (full).
  final window = step + smooth.clamp(0.0, 1.0) * 1.0;
  final n = math.max(1, (window / step).round());
  var sum = 0.0, w = 0.0;
  for (var i = 0; i < n; i++) {
    final t1 = t - i * step;
    if (t1 < 0) break;
    // nearer moments count more.
    final weight = 1.0 - i / (n + 1);
    sum += peakBetween(peaks, t1, t1 + step) * weight;
    w += weight;
  }
  return w <= 0 ? 0 : (sum / w).clamp(0.0, 1.0);
}
