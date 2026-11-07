/// Dependencies (PropLink): a layer's property following one property of
/// another layer - chains included (a source may follow another source).
/// Each link adds the source's change since the link was made,
/// scaled, so nothing jumps where the link starts.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/interpolation.dart' show evaluateTrack;
import '../core/stage_size.dart';
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
    case 'opacity':
      return (evaluateTrack(project, l.transform.opacity, f, l) as num).toDouble();
  }
  return 0;
}

/// A property's value with its links (what a layer linked to it sees).
double linkedPropAt(Project project, Layer l, String prop, num globalFrame, [Set<String>? seen]) =>
    _own(project, l, prop, globalFrame) + linkOffset(project, l, prop, globalFrame, seen);

/// What `layer`'s links add to `prop` at `globalFrame` (0 without any).
double linkOffset(Project project, Layer layer, String prop, num globalFrame, [Set<String>? seen]) {
  if (layer.links.isEmpty) return 0;
  final s = seen ?? <String>{};
  if (!s.add(layer.id)) return 0; // a circle (refused when made)
  var sum = 0.0;
  for (final k in layer.links) {
    if (!k.enabled || k.to != prop || k.sourceId == null) continue;
    final src = findLayer(project, k.sourceId);
    if (src == null) continue;
    // a sound: how loud it is now, between min and max.
    if (k.fromSound) {
      final level = soundLevelAt(src, globalFrame, smooth: k.smooth);
      sum += k.min + (k.max - k.min) * level;
      continue;
    }
    final now = linkedPropAt(project, src, k.from, globalFrame, {...s});
    final then = k.base ?? linkedPropAt(project, src, k.from, layer.startFrame, {...s});
    sum += k.factor * (now - then);
  }
  return sum;
}

/// Pins `k`'s base to its source's value now, so the layer keeps its
/// place when the link is made and follows every change after.
void pinLinkBase(Project project, PropLink k, num globalFrame) {
  final src = findLayer(project, k.sourceId);
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
    return l.links.any((k) => k.sourceId != null && reaches(k.sourceId!));
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
