/// The layer's centre (pivot): the point its position stands for and it
/// turns and scales round. Moved without moving the layer on the stage.
library;

import '../core/interpolation.dart';
import '../core/math.dart';
import '../core/state_cache.dart';
import '../geometry/shapes.dart' show shapeBoundingBox;
import '../ui_geometry/handles.dart' show toFrameMatrix;
import '../ui_geometry/snapping.dart' show frameDeltaToLocal;
import 'line_path.dart' show syncLineBox;
import 'project.dart';

/// Moves `layer`'s centre to content-local point `p` (its current centre
/// is 0, 0): its position keys move by where that point is at each key's
/// time, its content the other way - it stays where it is on the stage.
void setLayerPivot(Project project, Layer layer, List<double> p, int globalFrame) {
  if (p[0].abs() < 1e-9 && p[1].abs() < 1e-9) return;
  final anchor = layer.transform.anchor;
  // how far the centre goes, in position units, at local frame f.
  List<double> shiftAt(int f) {
    final g = layer.startFrame + f;
    final m = toFrameMatrix(getLayerStateAt(project, layer.id, g).matrix);
    final at = applyAffine(m, p), o = applyAffine(m, const [0, 0]);
    return frameDeltaToLocal(project, layer, g, o, [at[0] - o[0], at[1] - o[1]]);
  }

  final keyShifts = [for (final k in anchor.keyframes) shiftAt(k.frame)];
  final defShift = shiftAt(layerLocalFrame(layer, globalFrame).round());
  for (var i = 0; i < anchor.keyframes.length; i++) {
    final v = anchor.keyframes[i].value as List;
    anchor.keyframes[i].value = [(v[0] as num) + keyShifts[i][0], (v[1] as num) + keyShifts[i][1]];
  }
  final d = anchor.defaultValue as List;
  anchor.defaultValue = [(d[0] as num) + defShift[0], (d[1] as num) + defShift[1]];
  if (anchor.spatial) autoComputeTangents(anchor);
  // the content the other way.
  final c = layer.content;
  final nodes = c.lineNodes;
  if (nodes != null && c.shape == 'line') {
    for (final n in nodes) {
      n.x -= p[0];
      n.y -= p[1];
      final pt = n.posT;
      if (pt != null) {
        for (final k in pt.keyframes) {
          final v = k.value as List;
          k.value = [(v[0] as num) - p[0], (v[1] as num) - p[1]];
        }
        final dv = pt.defaultValue;
        if (dv is List) pt.defaultValue = [(dv[0] as num) - p[0], (dv[1] as num) - p[1]];
      }
    }
    syncLineBox(c);
  } else {
    c.offset = [c.offset[0] - p[0], c.offset[1] - p[1]];
  }
  clearStateCaches();
}

/// A point of the layer's box (content-local): `fx`, `fy` 0 (left / top)
/// .. 1 (right / bottom).
List<double> layerBoxPoint(Layer layer, double fx, double fy) {
  final b = shapeBoundingBox(layer.content);
  return [b.minX + (b.maxX - b.minX) * fx, b.minY + (b.maxY - b.minY) * fy];
}
