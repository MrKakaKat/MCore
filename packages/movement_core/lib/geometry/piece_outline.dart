/// The outline left after "Detach a piece" cuts (Layer.pieceClips): the
/// layer's own shape intersected with the inside of its `inside` cuts and
/// the outside of its `outside` cuts. The renderer clips the picture with
/// the cuts; this gives the same cut shape to everything else that works
/// with a layer's contour - its transform box, tapping it on the stage,
/// snapping to its corners.
library;

import 'dart:math' as math;

import '../model/project.dart';
import 'shapes.dart';

/// Whether a content-local point survives all of the layer's cuts.
bool insidePieceClips(Layer layer, List<double> p) {
  for (final c in layer.pieceClips) {
    if (pointInPolygon(p, c.points) != c.inside) return false;
  }
  return true;
}

/// Even-odd point-in-polygon test.
bool pointInPolygon(List<double> p, List<List<double>> poly) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) {
      inside = !inside;
    }
  }
  return inside;
}

/// The layer's own (undeformed) shape as a polygon, content-local.
List<List<double>> contentPolygon(Content c) {
  if (isRectLikeShape(c.shape)) {
    final b = shapeBoundingBox(c);
    return [
      [b.minX, b.minY],
      [b.maxX, b.minY],
      [b.maxX, b.maxY],
      [b.minX, b.maxY],
    ];
  }
  return shapePoints(c);
}

/// The corners of what is left of the layer after its cuts: its own
/// corners and the cuts' corners that lie in the kept part, and every
/// point where an edge of the shape crosses a cut (or two cuts cross).
/// The layer's own corners when it has no cuts.
List<List<double>> pieceOutlinePoints(Layer layer) {
  final subject = contentPolygon(layer.content);
  if (layer.pieceClips.isEmpty || subject.length < 3) return subject;
  final polys = [subject, for (final c in layer.pieceClips) if (c.points.length >= 3) c.points];
  var size = 0.0;
  for (final p in subject) {
    size = math.max(size, math.max(p[0].abs(), p[1].abs()));
  }
  final eps = 1e-7 * math.max(1.0, size);

  bool keeps(List<double> p) {
    if (!_insideOrOn(p, subject, true, eps)) return false;
    for (final c in layer.pieceClips) {
      if (c.points.length >= 3 && !_insideOrOn(p, c.points, c.inside, eps)) return false;
    }
    return true;
  }

  final candidates = <List<double>>[
    for (final poly in polys) ...poly,
  ];
  for (var i = 0; i < polys.length; i++) {
    for (var j = i + 1; j < polys.length; j++) {
      final a = polys[i], b = polys[j];
      for (var k = 0; k < a.length; k++) {
        for (var l = 0; l < b.length; l++) {
          final x = _segmentIntersection(a[k], a[(k + 1) % a.length], b[l], b[(l + 1) % b.length]);
          if (x != null) candidates.add(x);
        }
      }
    }
  }
  return [for (final p in candidates) if (keeps(p)) p];
}

/// The box around what is left of the layer after its cuts (its whole
/// box without cuts, or if nothing is left).
BoundingBox pieceBoundingBox(Layer layer) {
  if (layer.pieceClips.isEmpty) return shapeBoundingBox(layer.content);
  final pts = pieceOutlinePoints(layer);
  if (pts.isEmpty) return shapeBoundingBox(layer.content);
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pts) {
    minX = math.min(minX, p[0]);
    maxX = math.max(maxX, p[0]);
    minY = math.min(minY, p[1]);
    maxY = math.max(maxY, p[1]);
  }
  return BoundingBox(minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

/// Whether a content-local point is on the visible part of the layer:
/// inside its shape and kept by every cut.
bool insidePiece(Layer layer, List<double> p) {
  final poly = contentPolygon(layer.content);
  return (poly.length < 3 || pointInPolygon(p, poly)) && insidePieceClips(layer, p);
}

bool _insideOrOn(List<double> p, List<List<double>> poly, bool wantInside, double eps) {
  for (var i = 0; i < poly.length; i++) {
    if (_distToSegment(p, poly[i], poly[(i + 1) % poly.length]) <= eps) return true;
  }
  return pointInPolygon(p, poly) == wantInside;
}

double _distToSegment(List<double> p, List<double> a, List<double> b) {
  final dx = b[0] - a[0], dy = b[1] - a[1];
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0 ? 0.0 : ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
  t = t.clamp(0.0, 1.0);
  final x = a[0] + t * dx - p[0], y = a[1] + t * dy - p[1];
  return math.sqrt(x * x + y * y);
}

List<double>? _segmentIntersection(List<double> p1, List<double> p2, List<double> q1, List<double> q2) {
  final rx = p2[0] - p1[0], ry = p2[1] - p1[1];
  final sx = q2[0] - q1[0], sy = q2[1] - q1[1];
  final denom = rx * sy - ry * sx;
  if (denom.abs() < 1e-12) return null; // parallel
  final qpx = q1[0] - p1[0], qpy = q1[1] - p1[1];
  final t = (qpx * sy - qpy * sx) / denom;
  final u = (qpx * ry - qpy * rx) / denom;
  if (t < 0 || t > 1 || u < 0 || u > 1) return null;
  return [p1[0] + t * rx, p1[1] + t * ry];
}
