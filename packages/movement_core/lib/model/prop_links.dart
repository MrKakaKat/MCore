/// Dependencies (PropLink): a layer's property following one property of
/// another layer - chains included (a source may follow another source).
/// Each link adds the source's change since the link was made,
/// scaled, so nothing jumps where the link starts.
library;

import '../core/interpolation.dart' show evaluateTrack;
import '../core/stage_size.dart';
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
