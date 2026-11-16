/// Order on the stage, keyed: a layer jumps above or below others at its
/// keys (see `Layer.stackKeys`) - the draw order changes, the Layers list
/// stays as it is. Places are counted as the Layers list numbers them (1:
/// the bottom). A key is a border: before it the layer is at its own
/// place, from it at the key's.
library;

import 'project.dart';
import 'timeline_rows.dart' show timelineRows, timelineRowOf;

/// The place `l`'s keys put it at `globalFrame` (1: on top), or null:
/// no key yet (before its first one, or none).
int? stackPositionAt(Layer l, num globalFrame) {
  if (l.stackKeys.isEmpty) return null;
  final f = layerLocalFrame(l, globalFrame);
  int? out;
  var at = -1 << 30;
  for (final k in l.stackKeys) {
    if (k.frame <= f && k.frame >= at) {
      at = k.frame;
      out = k.position;
    }
  }
  return out;
}

/// A layer's place in the Layers list: its timeline row, counted from
/// the bottom (1: the bottom; layers sharing a row share it).
int listPlaceOf(Project project, Layer l) => timelineRowOf(project, l.id) + 1;

/// The layers in draw order at `globalFrame` (first drawn first, as in
/// `project.layers`): each at its place in the list - a keyed one at the
/// place its key says, under the layers already there (going from 5 to
/// 2 puts it behind the layers at 2, 3 and 4).
List<Layer> stackOrderAt(Project project, num globalFrame) {
  if (!project.layers.any((l) => l.stackKeys.isNotEmpty)) return project.layers;
  final rows = timelineRows(project);
  final level = <Layer, double>{};
  for (var r = 0; r < rows.length; r++) {
    for (final l in rows[r]) {
      level[l] = r + 1.0;
    }
  }
  var moved = false;
  for (final l in project.layers) {
    final p = stackPositionAt(l, globalFrame);
    if (p != null) {
      level[l] = p - 0.5;
      moved = true;
    }
  }
  if (!moved) return project.layers;
  final index = {for (var i = 0; i < project.layers.length; i++) project.layers[i]: i};
  return [...project.layers]..sort((a, b) {
      final c = (level[a] ?? 0).compareTo(level[b] ?? 0);
      return c != 0 ? c : index[a]!.compareTo(index[b]!);
    });
}

/// Where `l` stands at `globalFrame`, as the list counts (1: the bottom):
/// its key's place, else its own.
int stackPlaceOf(Project project, Layer l, num globalFrame) =>
    stackPositionAt(l, globalFrame) ?? listPlaceOf(project, l);

/// Sets (or replaces) `l`'s key at local frame `frame`.
void setStackKey(Layer l, int frame, int position) {
  l.stackKeys.removeWhere((k) => k.frame == frame);
  l.stackKeys
    ..add(StackKey(frame, position < 1 ? 1 : position))
    ..sort((a, b) => a.frame.compareTo(b.frame));
}
