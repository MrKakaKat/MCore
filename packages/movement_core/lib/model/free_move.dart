/// Keyframes tab, "Free move": the object is dragged along a path on the
/// stage; confirmed, the path becomes two keys - a new animation layer
/// (key layer) moving it from where it stands along that curve.
library;

import 'dart:math' as math;

import '../core/state_cache.dart';
import '../ui_geometry/drag_ops.dart' show anchorLocalFromScreen;
import 'project.dart';
import 'track_edit.dart';

/// The two inner control points of the cubic curve from `pts.first` to
/// `pts.last` closest to all of `pts` (least squares, points spread by
/// their distance along the stroke). Fewer than 3 points or a straight
/// stroke: the straight line's thirds.
List<List<double>> fitCubicInner(List<List<double>> pts) {
  final p0 = pts.first, p3 = pts.last;
  List<double> third(double k) => [p0[0] + (p3[0] - p0[0]) * k, p0[1] + (p3[1] - p0[1]) * k];
  if (pts.length < 3) return [third(1 / 3), third(2 / 3)];
  // chord-length parameters.
  final d = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    d.add(d.last + math.sqrt(math.pow(pts[i][0] - pts[i - 1][0], 2) + math.pow(pts[i][1] - pts[i - 1][1], 2)));
  }
  final total = d.last;
  if (total <= 1e-9) return [third(1 / 3), third(2 / 3)];
  // B(t) = b0 p0 + b1 p1 + b2 p2 + b3 p3: solve for p1, p2.
  var c11 = 0.0, c12 = 0.0, c22 = 0.0;
  final x1 = [0.0, 0.0], x2 = [0.0, 0.0];
  for (var i = 0; i < pts.length; i++) {
    final t = d[i] / total, u = 1 - t;
    final b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t;
    c11 += b1 * b1;
    c12 += b1 * b2;
    c22 += b2 * b2;
    for (var c = 0; c < 2; c++) {
      final r = pts[i][c] - b0 * p0[c] - b3 * p3[c];
      x1[c] += b1 * r;
      x2[c] += b2 * r;
    }
  }
  final det = c11 * c22 - c12 * c12;
  if (det.abs() < 1e-12) return [third(1 / 3), third(2 / 3)];
  return [
    [(x1[0] * c22 - x2[0] * c12) / det, (x1[1] * c22 - x2[1] * c12) / det],
    [(c11 * x2[0] - c12 * x1[0]) / det, (c11 * x2[1] - c12 * x1[1]) / det],
  ];
}

/// A new animation layer on `layer` moving it along `framePath` (frame
/// px, its first point where it stands) from `globalFrame` for `frames`
/// frames: two position keys, the curve in their handles. Returns the
/// layer's number (0: nothing to make).
int addFreeMoveLayer(Project project, Layer layer, List<List<double>> framePath, int globalFrame, int frames) {
  if (framePath.length < 2 || frames < 1) return 0;
  // in the position's own space (a parent's too), from the start.
  final local = [for (final p in framePath) anchorLocalFromScreen(project, layer, p[0], p[1], globalFrame)];
  final o = local.first;
  final rel = [
    for (final p in local) [p[0] - o[0], p[1] - o[1]]
  ];
  final end = rel.last;
  if (end[0].abs() < 1e-9 && end[1].abs() < 1e-9 && rel.every((p) => p[0].abs() < 1e-9 && p[1].abs() < 1e-9)) return 0;
  final inner = fitCubicInner(rel);
  final n = addTransformAnimLayer(layer);
  final trk = layer.transform.anchor.animLayers[n - 1].track..spatial = true;
  final f0 = layerLocalFrame(layer, globalFrame).round();
  final f1 = f0 + frames;
  trk.keyframes = [
    Keyframe(
        frame: f0,
        value: <double>[0.0, 0.0],
        temporal: newKeyEasing(),
        spatialTangent: SpatialTangent(inTan: [0, 0], outTan: [inner[0][0], inner[0][1]])),
    Keyframe(
        frame: f1,
        value: <double>[end[0], end[1]],
        temporal: newKeyEasing(),
        spatialTangent: SpatialTangent(inTan: [inner[1][0] - end[0], inner[1][1] - end[1]], outTan: [0, 0])),
  ];
  // its time reaches the second key.
  if (f1 > layer.durationFrames) layer.durationFrames = f1;
  clearStateCaches();
  return n;
}
