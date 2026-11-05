/// Timeline rows: several layers can share one row of the timeline as long as
/// they don't overlap in time). Layers of a row share a `rowId` and sit next
/// to each other in `project.layers`, so the row order on the timeline is the
/// paint order, as before.
library;

import 'dart:math' as math;

import 'layer_edit.dart' show splitLayer;
import 'layer_ops.dart' show Selection, deleteLayer;
import 'project.dart';

int _rowCounter = 0;

String newTimelineRowId() =>
    'R${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rowCounter++}';

/// Where the layer stops occupying its row: its end, or the end of its
/// loop repeats (far away for an endless loop).
int _end(Layer l) => layerVisibleEnd(l) ?? (1 << 40);

/// The layer's own end (one pass, no repeats).
int _ownEnd(Layer l) => l.startFrame + l.durationFrames;

bool _overlap(Layer a, Layer b) => a.startFrame < _end(b) && b.startFrame < _end(a);

/// The timeline's rows, top to bottom (= paint order, back to front). A
/// layer without a row id is a row of its own; a row's position is that
/// of its first layer.
List<List<Layer>> timelineRows(Project project) {
  final rows = <List<Layer>>[];
  final byId = <String, List<Layer>>{};
  for (final l in project.layers) {
    final id = l.rowId;
    if (id == null) {
      rows.add([l]);
    } else if (byId[id] != null) {
      byId[id]!.add(l);
    } else {
      rows.add(byId[id] = [l]);
    }
  }
  return rows;
}

/// Index of the row holding `layerId` (-1 if it isn't there).
int timelineRowOf(Project project, String layerId) =>
    timelineRows(project).indexWhere((r) => r.any((l) => l.id == layerId));

/// Writes `rows` back as the layer order and row ids: a row's layers
/// become adjacent, a one-layer row drops its id.
void _writeRows(Project project, List<List<Layer>> rows) {
  project.layers
    ..clear()
    ..addAll([for (final r in rows) ...r]);
  for (final r in rows) {
    if (r.length == 1) {
      r.single.rowId = null;
    } else {
      final id = r.map((l) => l.rowId).firstWhere((id) => id != null, orElse: () => null) ?? newTimelineRowId();
      for (final l in r) {
        l.rowId = id;
      }
    }
  }
}

/// Puts every row's layers next to each other (after an insert landed
/// between the layers of a row, say).
void normalizeTimelineRows(Project project) => _writeRows(project, timelineRows(project));

/// Whether `layer` fits into `row` without overlapping anyone there.
bool fitsInTimelineRow(List<Layer> row, Layer layer) =>
    row.every((o) => identical(o, layer) || !_overlap(o, layer));

/// How far `layer` may go in time without running into the other layers
/// of its row: its start can't go below `minStart`, its end past `maxEnd`
/// (null = no limit). Layers in `ignore` don't count (they move along).
({int minStart, int? maxEnd}) timelineRowLimits(Project project, Layer layer, {Set<Layer> ignore = const {}}) {
  final row = timelineRows(project).firstWhere((r) => r.contains(layer), orElse: () => [layer]);
  var minStart = 0;
  int? maxEnd;
  for (final o in row) {
    if (identical(o, layer) || ignore.contains(o)) continue;
    if (o.startFrame < layer.startFrame) {
      minStart = math.max(minStart, _end(o));
    } else {
      maxEnd = maxEnd == null ? o.startFrame : math.min(maxEnd, o.startFrame);
    }
  }
  return (minStart: minStart, maxEnd: maxEnd);
}

/// Moves `layerId` in the row list. `row` counts rows with the layer
/// already taken out; `join` puts it into that row (only if it fits
/// there - returns false otherwise), else it becomes a new row inserted
/// at that position.
bool placeLayerInTimelineRows(Project project, String layerId, int row, {required bool join}) {
  final layer = findLayer(project, layerId);
  if (layer == null) return false;
  final rows = timelineRows(project);
  for (final r in rows) {
    r.remove(layer);
  }
  rows.removeWhere((r) => r.isEmpty);
  if (join) {
    if (rows.isEmpty) return false;
    final target = rows[row.clamp(0, rows.length - 1)];
    if (!fitsInTimelineRow(target, layer)) return false;
    target
      ..add(layer)
      ..sort((a, b) => a.startFrame.compareTo(b.startFrame));
  } else {
    layer.rowId = null;
    rows.insert(row.clamp(0, rows.length), [layer]);
  }
  _writeRows(project, rows);
  return true;
}

/// Joins the row above (`up`) or below, if the layer fits there.
bool joinNeighbourTimelineRow(Project project, String layerId, {required bool up}) {
  final rows = timelineRows(project);
  final r = rows.indexWhere((row) => row.any((l) => l.id == layerId));
  if (r < 0) return false;
  final target = up ? r - 1 : r + 1;
  if (target < 0 || target >= rows.length) return false;
  final alone = rows[r].length == 1;
  // row indexes once the layer is taken out of its own row.
  return placeLayerInTimelineRows(project, layerId, alone && !up ? target - 1 : target, join: true);
}

/// Takes the layer out of a shared row into a row of its own, just below.
bool takeOwnTimelineRow(Project project, String layerId) {
  final rows = timelineRows(project);
  final r = rows.indexWhere((row) => row.any((l) => l.id == layerId));
  if (r < 0 || rows[r].length == 1) return false;
  return placeLayerInTimelineRows(project, layerId, r + 1, join: false);
}

/// The empty stretches between the layers of `row`: [start, end) frames.
List<(int, int)> timelineRowGaps(List<Layer> row) {
  final sorted = [...row]..sort((a, b) => a.startFrame.compareTo(b.startFrame));
  final gaps = <(int, int)>[];
  var reach = sorted.isEmpty ? 0 : _end(sorted.first);
  for (final l in sorted.skip(1)) {
    if (l.startFrame > reach) gaps.add((reach, l.startFrame));
    reach = math.max(reach, _end(l));
  }
  return gaps;
}

/// "Fill the gaps": `layerId` is cut so only its parts inside the gaps
/// of row `targetRow` remain ("–..–..–": it fills the dots), and those
/// parts join that row. Everything outside the gaps is removed. The kept
/// parts show what the layer showed at those times (a cut, not a move).
/// Returns the kept parts, or null when no gap overlaps the layer (then
/// nothing changes).
List<Layer>? fillTimelineRowGaps(Project project, Selection selection, String layerId, int targetRow,
    {required String Function() newLayerId, int globalFrame = 0}) {
  final layer = findLayer(project, layerId);
  final rows = timelineRows(project);
  if (layer == null || targetRow < 0 || targetRow >= rows.length) return null;
  final target = rows[targetRow].where((l) => !identical(l, layer)).toList();
  if (target.isEmpty) return null;
  final anchor = target.first; // identifies the row after re-sorting
  final kept = _keepOnly(project, selection, layer, timelineRowGaps(target),
      newLayerId: newLayerId, globalFrame: globalFrame);
  if (kept == null) return null;

  // the kept parts join the target row.
  final newRows = timelineRows(project);
  for (final r in newRows) {
    r.removeWhere(kept.contains);
  }
  newRows.removeWhere((r) => r.isEmpty);
  final row = newRows.firstWhere((r) => r.contains(anchor));
  row
    ..addAll(kept)
    ..sort((a, b) => a.startFrame.compareTo(b.startFrame));
  _writeRows(project, newRows);
  return kept;
}

/// The stretches of time the layers of `row` cover, merged: [start, end).
List<(int, int)> timelineRowSpans(List<Layer> row) {
  final sorted = [...row]..sort((a, b) => a.startFrame.compareTo(b.startFrame));
  final spans = <(int, int)>[];
  for (final l in sorted) {
    final s = l.startFrame, e = _end(l);
    if (spans.isNotEmpty && s <= spans.last.$2) {
      spans[spans.length - 1] = (spans.last.$1, math.max(spans.last.$2, e));
    } else {
      spans.add((s, e));
    }
  }
  return spans;
}

/// "Lay over a row": `layerId` is cut so it only exists where the layers
/// of row `targetRow` are (the row's gaps become its gaps) and the parts
/// go into one new row right after that row - drawn over it. The parts
/// keep the layer's timing (a cut, not a move); everything outside the
/// row's layers is removed, and a loop on the layer is switched off (the
/// parts already follow the row). Null when nothing overlaps.
List<Layer>? overlayTimelineRow(Project project, Selection selection, String layerId, int targetRow,
    {required String Function() newLayerId, int globalFrame = 0}) {
  final layer = findLayer(project, layerId);
  final rows = timelineRows(project);
  if (layer == null || targetRow < 0 || targetRow >= rows.length) return null;
  final target = rows[targetRow].where((l) => !identical(l, layer)).toList();
  if (target.isEmpty) return null;
  final anchor = target.first;
  layer.loopEnabled = false;
  final kept = _keepOnly(project, selection, layer, timelineRowSpans(target),
      newLayerId: newLayerId, globalFrame: globalFrame);
  if (kept == null) return null;

  final newRows = timelineRows(project);
  for (final r in newRows) {
    r.removeWhere(kept.contains);
  }
  newRows.removeWhere((r) => r.isEmpty);
  final at = newRows.indexWhere((r) => r.contains(anchor));
  newRows.insert(at + 1, [...kept]..sort((a, b) => a.startFrame.compareTo(b.startFrame)));
  _writeRows(project, newRows);
  return kept;
}

/// Cuts `layer` so only its parts inside `spans` remain (keeping their
/// timing); the rest is deleted. The kept parts, or null when no span
/// overlaps the layer (then nothing changes).
List<Layer>? _keepOnly(Project project, Selection selection, Layer layer, List<(int, int)> spans,
    {required String Function() newLayerId, required int globalFrame}) {
  final pieces = <(int, int)>[];
  for (final (gs, ge) in spans) {
    final s = math.max(gs, layer.startFrame), e = math.min(ge, _ownEnd(layer));
    if (e > s) pieces.add((s, e));
  }
  if (pieces.isEmpty) return null;

  // cut at every piece edge inside the layer.
  final cuts = <int>{for (final (s, e) in pieces) ...[s, e]}
      .where((f) => f > layer.startFrame && f < _ownEnd(layer))
      .toList()
    ..sort();
  final segments = [layer];
  for (final f in cuts) {
    final right = splitLayer(project, segments.last, f, newLayerId());
    if (right != null) segments.add(right);
  }
  final kept = <Layer>[];
  for (final seg in segments) {
    final keep = pieces.any((p) => p.$1 == seg.startFrame && p.$2 == _ownEnd(seg));
    if (keep) {
      kept.add(seg);
    } else {
      deleteLayer(project, selection, seg.id, globalFrame);
    }
  }
  return kept;
}
