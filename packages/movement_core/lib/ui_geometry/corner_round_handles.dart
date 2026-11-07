/// Stage handles for rounded corners (Fill tab open) and what the
/// rounding cuts off / adds, to show it.
///
/// - 'rr': the radius - on the first corner's edge where the curve starts;
///   drag it along the edge.
/// - 'rk': the shape - on the curve's middle; toward the corner sharper,
///   away from it flatter (0 cut straight, ~0.55 a circle, 1 sharp).
///
/// Rects use their top-left corner, triangles / polygons their first
/// point. Lines have their own ('r<i>' / 'k<i>', see line_path.dart).
library;

import 'dart:math' as math;

import '../core/math.dart' show applyAffine, invertAffine;
import '../geometry/shapes.dart';
import '../model/line_path.dart';
import '../model/project.dart';
import 'drag_ops.dart' show DragOp;
import 'handles.dart' show getTransformBoxHandles;
import 'snapping.dart' show SnapGuideLine;

/// The Fill tab is open: the selected shape's rounding handles show.
bool cornerHandlesVisible = false;

/// Snapping: a rounding being dragged takes the size of another object's
/// rounding (rects, polygons, line corners, text blocks) when close.
bool snapEqualRoundingEnabled = true;

/// Every other object's rounding radius, frame px.
List<double> otherRoundingRadiiFrame(Project project, Layer except, int globalFrame) {
  final out = <double>[];
  for (final l in project.layers) {
    if (identical(l, except) || l.hidden) continue;
    final m = getTransformBoxHandles(project, l, globalFrame).mCanvas;
    final k = math.sqrt((m[0] * m[3] - m[1] * m[2]).abs());
    final c = l.content;
    if (c.shape == 'rect' && l.fill.cornerRadius > 0) {
      out.add(cornerRadii(l, globalFrame, project: project).$1 * k);
    } else if (l.fill.cornerRadius > 0) {
      out.add(l.fill.cornerRadius * k);
    }
    for (final n in c.lineNodes ?? const <LineNode>[]) {
      if (n.round > 0) out.add(n.round * k);
    }
    final bg = c.text?.background;
    if (bg != null && bg.enabled && bg.radius > 0) out.add(bg.radius * k);
  }
  return out;
}

/// `r` (frame px) pulled onto another rounding's size, when close.
double snapRoundingFrame(Project project, Layer layer, int globalFrame, double r) {
  if (!snapEnabled || !snapEqualRoundingEnabled) return r;
  var best = r, bestD = snapEqualSizeFrameRadius;
  for (final o in otherRoundingRadiiFrame(project, layer, globalFrame)) {
    final d = (o - r).abs();
    if (d < bestD) {
      bestD = d;
      best = o;
    }
  }
  return best;
}

/// One rounded corner in content space: the corner, where the curve
/// starts and ends, and the radius / shape it was drawn with.
class RoundedCorner {
  final List<double> p, t1, t2;
  final double k;
  final bool adds; // an inward corner: the rounding adds to the shape
  RoundedCorner(this.p, this.t1, this.t2, this.k, {this.adds = false});

  List<double> get mid {
    final m = [(t1[0] + t2[0]) / 2, (t1[1] + t2[1]) / 2];
    return [m[0] + 0.75 * k * (p[0] - m[0]), m[1] + 0.75 * k * (p[1] - m[1])];
  }

  /// The part the rounding takes away (or, `adds`, fills in).
  List<List<double>> get region => [p, ...roundCornerCurve(t1, p, t2, k, steps: 12)];
}

bool _polyLike(String s) => s == 'triangle' || s == 'ngon' || s == 'polygon';

/// The layer's rounded corners (content space).
List<RoundedCorner> roundedCorners(Layer layer, int globalFrame, {Project? project}) {
  final c = layer.content, f = layer.fill;
  if (c.shape == 'rect' && f.cornerRadius > 0) {
    final (rx, ry) = cornerRadii(layer, globalFrame, project: project);
    final x0 = c.offset[0] - c.size[0] / 2, x1 = c.offset[0] + c.size[0] / 2;
    final y0 = c.offset[1] - c.size[1] / 2, y1 = c.offset[1] + c.size[1] / 2;
    final k = f.cornerShape;
    return [
      RoundedCorner([x0, y0], [x0, y0 + ry], [x0 + rx, y0], k),
      RoundedCorner([x1, y0], [x1 - rx, y0], [x1, y0 + ry], k),
      RoundedCorner([x1, y1], [x1, y1 - ry], [x1 - rx, y1], k),
      RoundedCorner([x0, y1], [x0 + rx, y1], [x0, y1 - ry], k),
    ];
  }
  if (_polyLike(c.shape) && (f.cornerRadius > 0 || f.outerRadius > 0)) {
    return _ringCorners(shapePoints(c), f.cornerRadius, f.outerRadius, f.cornerShape);
  }
  if (isNodeLine(c)) {
    final out = <RoundedCorner>[];
    final nodes = c.lineNodes!;
    for (var i = 0; i < nodes.length; i++) {
      final rc = lineCorner(c, i);
      if (rc != null && nodes[i].round > 0) out.add(rc);
    }
    return out;
  }
  return const [];
}

List<RoundedCorner> _ringCorners(List<List<double>> ring, double convex, double concave, double k) {
  final n = ring.length;
  if (n < 3) return const [];
  var area = 0.0;
  for (var i = 0; i < n; i++) {
    area += ring[i][0] * ring[(i + 1) % n][1] - ring[(i + 1) % n][0] * ring[i][1];
  }
  final out = <RoundedCorner>[];
  for (var i = 0; i < n; i++) {
    final a = ring[(i - 1 + n) % n], p = ring[i], b = ring[(i + 1) % n];
    final cross = (p[0] - a[0]) * (b[1] - p[1]) - (p[1] - a[1]) * (b[0] - p[0]);
    final convexHere = cross * area > 0;
    final r = convexHere ? convex : concave;
    final la = _d(a, p), lb = _d(b, p);
    if (r <= 0 || cross.abs() < 1e-9 || la < 1e-9 || lb < 1e-9) continue;
    final d = math.min(r, math.min(la, lb) / 2);
    out.add(RoundedCorner(p, _toward(p, a, d / la), _toward(p, b, d / lb), k, adds: !convexHere));
  }
  return out;
}

double _d(List<double> a, List<double> b) => math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));
List<double> _toward(List<double> p, List<double> q, double t) => [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t];

/// A line's corner at point `i` (content space) as it is rounded - or,
/// unrounded, where its handles start - or null at an open end.
RoundedCorner? lineCorner(Content c, int i) {
  final nodes = c.lineNodes!;
  final n = nodes.length;
  if (!c.lineClosed && (i <= 0 || i >= n - 1)) return null;
  final a = nodes[(i - 1 + n) % n], p = nodes[i], b = nodes[(i + 1) % n];
  final pa = [a.x, a.y], pp = [p.x, p.y], pb = [b.x, b.y];
  final la = _d(pa, pp), lb = _d(pb, pp);
  if (la < 1e-9 || lb < 1e-9) return null;
  // unrounded: the handle sits a little way along (drag it to round).
  final d = math.min(p.round > 0 ? p.round : math.min(12.0, math.min(la, lb) / 4), math.min(la, lb) / 2);
  return RoundedCorner(pp, _toward(pp, pa, d / la), _toward(pp, pb, d / lb), p.roundK);
}

/// The shape's shorter side on the frame, px (the rounding handles show
/// only once it is big enough on the screen).
double layerShortSideFrame(Project project, Layer layer, int globalFrame) {
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final c = layer.content;
  final sx = math.sqrt(m[0] * m[0] + m[1] * m[1]), sy = math.sqrt(m[2] * m[2] + m[3] * m[3]);
  return math.min(c.size[0].abs() * sx, c.size[1].abs() * sy);
}

/// The rounding handles of the selected shape (frame px), Fill tab open -
/// once its rounding is switched on, and at the first corner that rounds.
Map<String, List<double>> roundHandlesFrame(Project project, Layer layer, int globalFrame) {
  final c = layer.content;
  if (!layer.fill.roundingOn) return const {};
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  RoundedCorner? rc;
  if (c.shape == 'rect') {
    final (rx, _) = layer.fill.cornerRadius > 0 ? cornerRadii(layer, globalFrame, project: project) : (0.0, 0.0);
    final r = layer.fill.cornerRadius > 0 ? rx : math.min(12.0, math.min(c.size[0], c.size[1]) / 4);
    final (_, ry) = layer.fill.cornerRadius > 0 ? cornerRadii(layer, globalFrame, project: project) : (r, r);
    final i = layer.fill.cornersOn.indexWhere((on) => on);
    if (i < 0) return const {};
    // the corner, and which way its two sides run from it.
    final sxn = i == 0 || i == 3 ? 1.0 : -1.0, syn = i < 2 ? 1.0 : -1.0;
    final x0 = c.offset[0] - sxn * c.size[0] / 2, y0 = c.offset[1] - syn * c.size[1] / 2;
    rc = RoundedCorner([x0, y0], [x0, y0 + syn * ry], [x0 + sxn * r, y0], layer.fill.cornerShape);
  } else if (_polyLike(c.shape)) {
    final pts = shapePoints(c);
    if (pts.length < 3) return const {};
    final a = pts.last, p = pts.first, b = pts[1];
    final la = _d(a, p), lb = _d(b, p);
    final r = layer.fill.cornerRadius > 0 ? layer.fill.cornerRadius : math.min(12.0, math.min(la, lb) / 4);
    final d = math.min(r, math.min(la, lb) / 2);
    rc = RoundedCorner(p, _toward(p, a, d / la), _toward(p, b, d / lb), layer.fill.cornerShape);
  }
  if (rc == null) return const {};
  return {
    'rr': applyAffine(m, rc.t2),
    if (layer.fill.cornerRadius > 0) 'rk': applyAffine(m, rc.mid),
  };
}

/// What the rounding cuts off (and, `adds`, fills in), frame space.
List<({List<List<double>> ring, bool adds})> roundRegionsFrame(Project project, Layer layer, int globalFrame) {
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  return [
    for (final rc in roundedCorners(layer, globalFrame, project: project))
      (ring: [for (final p in rc.region) applyAffine(m, p)], adds: rc.adds)
  ];
}

/// Drags a rounding handle ('rr' radius / 'rk' shape) of a rect, triangle
/// or polygon.
class RoundDragOp implements DragOp {
  final Layer layer;
  final String key;
  RoundDragOp(this.layer, this.key);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final c = layer.content, f = layer.fill;
    final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
    final q = applyAffine(invertAffine(m), framePoint);
    List<double> p, toward;
    if (c.shape == 'rect') {
      // the handle's corner: the first that rounds.
      final i = math.max(0, f.cornersOn.indexWhere((on) => on));
      final sxn = i == 0 || i == 3 ? 1.0 : -1.0, syn = i < 2 ? 1.0 : -1.0;
      final x0 = c.offset[0] - sxn * c.size[0] / 2, y0 = c.offset[1] - syn * c.size[1] / 2;
      p = [x0, y0];
      toward = [x0 + sxn, y0];
    } else {
      final pts = shapePoints(c);
      if (pts.length < 3) return;
      p = pts.first;
      toward = pts[1];
    }
    final ex = toward[0] - p[0], ey = toward[1] - p[1];
    final el = math.sqrt(ex * ex + ey * ey);
    if (el < 1e-9) return;
    if (key == 'rr') {
      f.roundingOn = true;
      var along = math.max(0.0, ((q[0] - p[0]) * ex + (q[1] - p[1]) * ey) / el);
      // the same size as another rounding, when close (frame px).
      final k = math.sqrt((m[0] * m[3] - m[1] * m[2]).abs());
      if (k > 1e-9) along = snapRoundingFrame(project, layer, globalFrame, along * k) / k;
      if (c.shape == 'rect') {
        // the stored radius vs the drawn one (corners kept round when
        // scaled): measured with a radius of 1.
        final keep = f.cornerRadius;
        f.cornerRadius = 1;
        final (rx, _) = cornerRadii(layer, globalFrame, project: project);
        f.cornerRadius = keep;
        final maxR = math.min(c.size[0], c.size[1]).abs() / 2;
        f.cornerRadius = (rx <= 1e-9 ? along : along / rx).clamp(0.0, maxR);
      } else {
        f.cornerRadius = along;
      }
      return;
    }
    // the shape: how far the curve's middle is from the chord toward the
    // corner (0.75 k of the way).
    final rcs = roundedCorners(layer, globalFrame, project: project);
    if (rcs.isEmpty) return;
    final rc = c.shape == 'rect' ? rcs.first : rcs.firstWhere((r) => r.p[0] == p[0] && r.p[1] == p[1], orElse: () => rcs.first);
    final mx = (rc.t1[0] + rc.t2[0]) / 2, my = (rc.t1[1] + rc.t2[1]) / 2;
    final vx = rc.p[0] - mx, vy = rc.p[1] - my;
    final vl2 = vx * vx + vy * vy;
    if (vl2 < 1e-12) return;
    f.cornerShape = (((q[0] - mx) * vx + (q[1] - my) * vy) / vl2 / 0.75).clamp(0.0, 1.0);
  }
}
