/// Order on the stage, keyed: a layer jumps above or below others at its
/// keys (see `Layer.stackKeys`) - the draw order changes, the Layers list
/// stays as it is.
library;

import 'project.dart';

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

/// The layers in draw order at `globalFrame` (first drawn first, as in
/// `project.layers`): the list's order, with every keyed layer moved to
/// its place (counted from the top).
List<Layer> stackOrderAt(Project project, num globalFrame) {
  if (!project.layers.any((l) => l.stackKeys.isNotEmpty)) return project.layers;
  final top = project.layers.reversed.toList(); // the Layers list: top first
  final moved = <(Layer, int)>[];
  for (final l in project.layers) {
    final p = stackPositionAt(l, globalFrame);
    if (p != null) moved.add((l, p));
  }
  if (moved.isEmpty) return project.layers;
  top.removeWhere((l) => moved.any((m) => identical(m.$1, l)));
  // the higher places first, so each lands where it asks to.
  moved.sort((a, b) => a.$2.compareTo(b.$2));
  for (final (l, p) in moved) {
    top.insert((p - 1).clamp(0, top.length), l);
  }
  return top.reversed.toList();
}

/// Where `l` stands on the stage at `globalFrame` (1: on top), among
/// all the layers.
int stackPlaceOf(Project project, Layer l, num globalFrame) {
  final order = stackOrderAt(project, globalFrame);
  return order.length - order.indexOf(l);
}

/// Sets (or replaces) `l`'s key at local frame `frame`.
void setStackKey(Layer l, int frame, int position) {
  l.stackKeys.removeWhere((k) => k.frame == frame);
  l.stackKeys
    ..add(StackKey(frame, position < 1 ? 1 : position))
    ..sort((a, b) => a.frame.compareTo(b.frame));
}
