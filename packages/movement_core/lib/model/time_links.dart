/// Timeline links: layers that move together in time. Linked layers share
/// a link id (Layer.linkId); moving one of them on the timeline - a drag,
/// "start to playhead", "move to frame" - shifts every layer of the group
/// by the same number of frames, so e.g. a video and its sound stay in
/// sync. Trimming stays per layer. Not a parent link: positions on the
/// stage are untouched.
library;

import 'dart:math' as math;

import 'project.dart';
import 'timeline_rows.dart' show timelineRowLimits;

int _linkCounter = 0;

String newTimeLinkId() => 'k${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_linkCounter++}';

/// `layer` and every layer linked to it (just `layer` when unlinked).
List<Layer> timeLinkGroup(Project project, Layer layer) {
  final id = layer.linkId;
  if (id == null) return [layer];
  final group = [for (final l in project.layers) if (l.linkId == id) l];
  return group.contains(layer) ? group : [layer, ...group];
}

bool areTimeLinked(Layer a, Layer b) => a.linkId != null && a.linkId == b.linkId;

/// Links `b` (and whatever it is already linked to) with `a`'s group.
void linkInTime(Project project, Layer a, Layer b) {
  if (identical(a, b) || areTimeLinked(a, b)) return;
  final id = a.linkId ?? b.linkId ?? newTimeLinkId();
  final old = b.linkId;
  for (final l in project.layers) {
    if (old != null && l.linkId == old) l.linkId = id;
  }
  a.linkId = id;
  b.linkId = id;
}

/// Takes `layer` out of its group; a group left with one layer dissolves.
void unlinkInTime(Project project, Layer layer) {
  final id = layer.linkId;
  if (id == null) return;
  layer.linkId = null;
  final rest = [for (final l in project.layers) if (l.linkId == id) l];
  if (rest.length == 1) rest.single.linkId = null;
}

/// A link left with a single layer (its partner was deleted) is no link:
/// clears it, so no lone link icon stays on the timeline.
void dissolveLonelyTimeLinks(Project project) {
  final counts = <String, int>{};
  for (final l in project.layers) {
    if (l.linkId != null) counts[l.linkId!] = (counts[l.linkId!] ?? 0) + 1;
  }
  for (final l in project.layers) {
    if (l.linkId != null && counts[l.linkId!]! < 2) l.linkId = null;
  }
}

/// How far the whole group can shift (frames): every layer stays at or
/// after frame 0 and between the layers of its row that aren't in the
/// group. `maxDelta` null = no limit.
({int minDelta, int? maxDelta}) timeLinkShiftLimits(Project project, List<Layer> group) {
  final ignore = group.toSet();
  var minDelta = -(1 << 30);
  int? maxDelta;
  for (final m in group) {
    final lim = timelineRowLimits(project, m, ignore: ignore);
    minDelta = math.max(minDelta, lim.minStart - m.startFrame);
    if (lim.maxEnd != null) {
      final d = lim.maxEnd! - (m.startFrame + m.durationFrames);
      maxDelta = maxDelta == null ? d : math.min(maxDelta, d);
    }
  }
  if (maxDelta != null && maxDelta < minDelta) maxDelta = minDelta;
  return (minDelta: minDelta, maxDelta: maxDelta);
}

/// Moves `layer`'s start toward `targetStart`, taking its linked layers
/// along (same shift, kept within their limits). Returns the shift made.
int shiftTimeLinked(Project project, Layer layer, int targetStart) {
  final group = timeLinkGroup(project, layer);
  final lim = timeLinkShiftLimits(project, group);
  var d = math.max(lim.minDelta, targetStart - layer.startFrame);
  if (lim.maxDelta != null) d = math.min(d, lim.maxDelta!);
  for (final m in group) {
    m.startFrame += d;
  }
  return d;
}
