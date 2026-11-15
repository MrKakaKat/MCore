/// Lengthening, keyed ("Size handles lengthen it"): a rect's box grows on
/// its sides by `transform.extend` [left, top, right, bottom] (px) - more
/// surface, its corners and outline as they are. The model keeps the
/// rect's own box; whatever draws or collides at a frame runs inside
/// [withExtendedBoxes], which lays each lengthened rect's box out for that
/// frame and puts the own box back after.
library;

import '../core/interpolation.dart' show evaluateTrack;
import 'project.dart';

/// Whether `l` is lengthened at all (a rect with an extend set or keyed).
bool hasExtend(Layer l) {
  if (l.content.shape != 'rect') return false;
  final t = l.transform.extend;
  return t.keyframes.isNotEmpty || (t.defaultValue as List).any((v) => (v as num) != 0);
}

/// How far `l` is lengthened at `globalFrame`: [left, top, right, bottom].
List<double> layerExtendAt(Layer l, num globalFrame) {
  if (!hasExtend(l)) return const [0, 0, 0, 0];
  final f = layerLocalFrame(l, globalFrame).clamp(0, l.durationFrames).toDouble();
  final v = (evaluateTrack(null, l.transform.extend, f, l) as List).cast<num>();
  return [for (var i = 0; i < 4; i++) i < v.length ? v[i].toDouble() : 0.0];
}

/// The box (offset, size) of `l`'s own box [ox, oy, w, h] lengthened by `e`.
(List<double>, List<double>) extendedBox(List<double> offset, List<double> size, List<double> e) {
  final minX = offset[0] - size[0] / 2 - e[0], maxX = offset[0] + size[0] / 2 + e[2];
  final minY = offset[1] - size[1] / 2 - e[1], maxY = offset[1] + size[1] / 2 + e[3];
  return ([(minX + maxX) / 2, (minY + maxY) / 2], [maxX - minX, maxY - minY]);
}

int _depth = 0;

/// Runs `fn` with every lengthened rect of `project` laid out as at
/// `globalFrame`; their own boxes come back after (an edit made inside to
/// such a box is kept, moved back by the lengthening).
T withExtendedBoxes<T>(Project project, num globalFrame, T Function() fn) {
  if (_depth > 0) return fn();
  final changed = <(Layer, List<double>, List<double>, List<double>, List<double>)>[];
  for (final l in project.layers) {
    if (!hasExtend(l)) continue;
    final e = layerExtendAt(l, globalFrame);
    if (e.every((v) => v == 0)) continue;
    final c = l.content;
    final (o, s) = extendedBox(c.offset, c.size, e);
    changed.add((l, [...c.offset], [...c.size], o, s));
    c
      ..offset = o
      ..size = s;
  }
  if (changed.isEmpty) return fn();
  _depth++;
  try {
    return fn();
  } finally {
    _depth--;
    for (final (l, o0, s0, o1, s1) in changed) {
      final c = l.content;
      bool same(List<double> a, List<double> b) => (a[0] - b[0]).abs() < 1e-9 && (a[1] - b[1]).abs() < 1e-9;
      if (same(c.offset, o1) && same(c.size, s1)) {
        c
          ..offset = o0
          ..size = s0;
      } else {
        c
          ..offset = [c.offset[0] - (o1[0] - o0[0]), c.offset[1] - (o1[1] - o0[1])]
          ..size = [c.size[0] - (s1[0] - s0[0]), c.size[1] - (s1[1] - s0[1])];
      }
    }
  }
}

/// Whether [withExtendedBoxes] is laying boxes out right now.
bool get extendedBoxesOut => _depth > 0;
