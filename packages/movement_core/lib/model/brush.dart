/// Drawing, the brush: a stroke drawn with the finger becomes a vector
/// line layer - its points thinned out, joined by smooth curves, its ends
/// tapering if asked - editable afterwards like any line.
library;

import 'dart:math' as math;

import '../core/stage_size.dart' show stageSize;
import 'line_path.dart' show LineNode, syncLineBox;
import 'project.dart';

double _segDist(List<double> p, List<double> a, List<double> b) {
  final dx = b[0] - a[0], dy = b[1] - a[1];
  final l2 = dx * dx + dy * dy;
  if (l2 == 0) return math.sqrt(math.pow(p[0] - a[0], 2) + math.pow(p[1] - a[1], 2));
  final t = (((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2).clamp(0.0, 1.0);
  final x = a[0] + t * dx, y = a[1] + t * dy;
  return math.sqrt(math.pow(p[0] - x, 2) + math.pow(p[1] - y, 2));
}

/// The points that matter (Ramer-Douglas-Peucker): none further than
/// `tol` px from the line through those kept.
List<List<double>> simplifyStroke(List<List<double>> pts, double tol) {
  if (pts.length < 3) return [for (final p in pts) [...p]];
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var far = -1.0, at = -1;
    for (var i = a + 1; i < b; i++) {
      final d = _segDist(pts[i], pts[a], pts[b]);
      if (d > far) {
        far = d;
        at = i;
      }
    }
    if (at > 0 && far > tol) {
      keep[at] = true;
      stack
        ..add((a, at))
        ..add((at, b));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) [...pts[i]]
  ];
}

/// A brush stroke (frame px points, as drawn) as a new line layer:
/// `width` px wide, `smooth` 0..1 (how much the hand's wobble is
/// smoothed out - and the curves made round), `taper` 0..1 (how much of
/// each end narrows to a point), `opacity`.
Layer brushStrokeLayer(List<List<double>> drawn,
    {required String id,
    required String color,
    double width = 6,
    double smooth = 0.5,
    double taper = 0,
    double opacity = 1,
    int startFrame = 0,
    int durationFrames = 180}) {
  var pts = [
    for (final p in drawn)
      if (p.length >= 2) [p[0], p[1]]
  ];
  if (pts.isEmpty) pts = [
    [0.0, 0.0]
  ];
  // a dot: a tiny line (round ends make it a dot).
  if (pts.length == 1 || pts.every((p) => (p[0] - pts.first[0]).abs() < 0.5 && (p[1] - pts.first[1]).abs() < 0.5)) {
    pts = [pts.first, [pts.first[0] + 0.5, pts.first[1]]];
  }
  final s = smooth.clamp(0.0, 1.0);
  pts = simplifyStroke(pts, 0.4 + s * 3.6);
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final p in pts) {
    x0 = math.min(x0, p[0]);
    y0 = math.min(y0, p[1]);
    x1 = math.max(x1, p[0]);
    y1 = math.max(y1, p[1]);
  }
  final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  // lengths along it (for the taper).
  final along = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    along.add(along.last + math.sqrt(math.pow(pts[i][0] - pts[i - 1][0], 2) + math.pow(pts[i][1] - pts[i - 1][1], 2)));
  }
  final total = along.last;
  final t = taper.clamp(0.0, 1.0) * total / 2;
  final nodes = <LineNode>[];
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i];
    // smooth curves through the points (Catmull-Rom), as round as asked.
    final prev = pts[math.max(0, i - 1)], next = pts[math.min(pts.length - 1, i + 1)];
    // (at the middle setting the usual Catmull-Rom sixth, rounder above)
    final k = s / 3;
    final hx = (next[0] - prev[0]) * k, hy = (next[1] - prev[1]) * k;
    final n = LineNode(p[0] - cx, p[1] - cy,
        kind: i == 0 || s <= 0 ? 'line' : 'bezier',
        hIn: i == 0 || s <= 0 ? [0, 0] : [-hx, -hy],
        hOut: i == pts.length - 1 || s <= 0 ? [0, 0] : [hx, hy]);
    if (t > 0) {
      final f = math.min(1.0, math.min(along[i], total - along[i]) / t);
      n.w = width * (0.08 + 0.92 * f);
    }
    nodes.add(n);
  }
  // the next point's curve needs this one's out handle (kind is the
  // segment arriving at a point).
  final layer = createLayer('line')
    ..id = id
    ..color = color
    ..startFrame = startFrame
    ..durationFrames = durationFrames;
  layer.content
    ..lineNodes = nodes
    ..lineWidth = width
    ..lineCap = 'round';
  syncLineBox(layer.content);
  layer.transform.anchor.defaultValue = [cx / stageSize.width, cy / stageSize.height];
  layer.transform.opacity.defaultValue = opacity.clamp(0.0, 1.0);
  return layer;
}
