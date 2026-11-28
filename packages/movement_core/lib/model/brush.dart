/// Drawing, the brush: a stroke drawn with the finger becomes a vector
/// line layer - its points thinned out, joined by smooth curves, its ends
/// tapering if asked - editable afterwards like any line.
library;

import 'dart:math' as math;

import '../core/stage_size.dart' show stageSize;
import 'line_path.dart' show LineNode, syncLineBox, sampleLine;
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

List<List<double>> _thin(List<List<double>> drawn, double minStep) {
  final out = <List<double>>[];
  for (final p in drawn) {
    if (p.length < 2) continue;
    if (out.isEmpty || (p[0] - out.last[0]).abs() + (p[1] - out.last[1]).abs() >= minStep) out.add([p[0], p[1]]);
  }
  if (out.isEmpty) return out;
  // a dot: a tiny line (round ends make it a dot).
  if (out.length == 1) out.add([out.first[0] + 0.5, out.first[1]]);
  return out;
}

({double cx, double cy}) _middle(List<List<double>> pts) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final p in pts) {
    x0 = math.min(x0, p[0]);
    y0 = math.min(y0, p[1]);
    x1 = math.max(x1, p[0]);
    y1 = math.max(y1, p[1]);
  }
  return (cx: (x0 + x1) / 2, cy: (y0 + y1) / 2);
}

/// `pts` smoothed by `smooth` 0..1: the hand's wobble averaged out (its
/// ends where they were), then the corners rounded (Chaikin).
List<List<double>> smoothStroke(List<List<double>> pts, double smooth) {
  final s = smooth.clamp(0.0, 1.0);
  if (pts.length < 3 || s <= 0) return [for (final p in pts) [...p]];
  var cur = [for (final p in pts) [...p]];
  final r = (s * 6).round();
  for (var pass = 0; pass < 2 && r > 0; pass++) {
    final next = <List<double>>[];
    for (var i = 0; i < cur.length; i++) {
      if (i == 0 || i == cur.length - 1) {
        next.add([...cur[i]]);
        continue;
      }
      final k = math.min(r, math.min(i, cur.length - 1 - i));
      var x = 0.0, y = 0.0;
      for (var j = i - k; j <= i + k; j++) {
        x += cur[j][0];
        y += cur[j][1];
      }
      next.add([x / (2 * k + 1), y / (2 * k + 1)]);
    }
    cur = next;
  }
  for (var it = 0; it < (s * 3).round(); it++) {
    final next = <List<double>>[cur.first];
    for (var i = 0; i + 1 < cur.length; i++) {
      final a = cur[i], b = cur[i + 1];
      next.add([a[0] * 0.75 + b[0] * 0.25, a[1] * 0.75 + b[1] * 0.25]);
      next.add([a[0] * 0.25 + b[0] * 0.75, a[1] * 0.25 + b[1] * 0.75]);
    }
    next.add(cur.last);
    cur = next;
  }
  return cur;
}

/// A brush stroke's line points made again from what was drawn
/// (`brushRaw`) at its smoothing (`brushSmooth`): straight pieces between
/// close points - drawn as one plain stroke (light, like a trail).
void rebuildBrushLine(Content c) {
  final raw = c.brushRaw;
  if (raw == null || raw.isEmpty) return;
  final pts = simplifyStroke(smoothStroke(raw, c.brushSmooth), 0.35);
  c.lineNodes = [for (final p in pts) LineNode(p[0], p[1])];
  syncLineBox(c);
}

/// A brush stroke (frame px points, as drawn) as a new layer: a plain
/// line `width` px wide through the points (smoothed by `smooth`, which
/// can be changed afterwards - see rebuildBrushLine), `opacity`.
Layer brushStrokeLayer(List<List<double>> drawn,
    {required String id,
    required String color,
    double width = 6,
    double smooth = 0.5,
    double opacity = 1,
    int startFrame = 0,
    int durationFrames = 180}) {
  var pts = _thin(drawn, 1.0);
  if (pts.isEmpty) pts = [[0.0, 0.0], [0.5, 0.0]];
  final m = _middle(pts);
  final layer = createLayer('line')
    ..id = id
    ..color = color
    ..startFrame = startFrame
    ..durationFrames = durationFrames;
  layer.content
    ..brushRaw = [for (final p in pts) [p[0] - m.cx, p[1] - m.cy]]
    ..brushSmooth = smooth.clamp(0.0, 1.0)
    ..lineWidth = width
    ..lineCap = 'round';
  rebuildBrushLine(layer.content);
  layer.transform.anchor.defaultValue = [m.cx / stageSize.width, m.cy / stageSize.height];
  layer.transform.opacity.defaultValue = opacity.clamp(0.0, 1.0);
  return layer;
}

/// Line drawn with a finger (the Shapes window's line placed on the
/// stage): a vector line of smooth curves through the stroke - at most
/// `maxPoints` points, each editable afterwards.
Layer freehandLineLayer(List<List<double>> drawn,
    {required String id, double width = 4, double smooth = 0.6, int maxPoints = 40, int startFrame = 0, int durationFrames = 180}) {
  var pts = _thin(drawn, 1.0);
  if (pts.isEmpty) pts = [[0.0, 0.0], [0.5, 0.0]];
  pts = smoothStroke(pts, smooth * 0.5);
  // few points: the tolerance grows until they are few enough.
  var tol = 1.5;
  var kept = simplifyStroke(pts, tol);
  while (kept.length > maxPoints && tol < 500) {
    tol *= 1.4;
    kept = simplifyStroke(pts, tol);
  }
  final m = _middle(kept);
  final nodes = <LineNode>[];
  for (var i = 0; i < kept.length; i++) {
    final p = kept[i];
    final prev = kept[math.max(0, i - 1)], next = kept[math.min(kept.length - 1, i + 1)];
    final hx = (next[0] - prev[0]) / 6, hy = (next[1] - prev[1]) / 6;
    nodes.add(LineNode(p[0] - m.cx, p[1] - m.cy,
        kind: i == 0 ? 'line' : 'bezier',
        hIn: i == 0 ? [0, 0] : [-hx, -hy],
        hOut: i == kept.length - 1 ? [0, 0] : [hx, hy]));
  }
  final layer = createLayer('line')
    ..id = id
    ..startFrame = startFrame
    ..durationFrames = durationFrames;
  layer.content
    ..lineNodes = nodes
    ..lineWidth = width;
  syncLineBox(layer.content);
  layer.transform.anchor.defaultValue = [m.cx / stageSize.width, m.cy / stageSize.height];
  return layer;
}

/// Brush strokes made before strokes were light (a Brush-folder line of
/// curves with tapered ends - heavy to draw): made light the same way,
/// from the points along their curve. How many changed.
int lightenOldBrushStrokes(Project project) {
  var n = 0;
  for (final l in project.layers) {
    final c = l.content;
    final nodes = c.lineNodes;
    if (l.folder != 'Brush' || c.brushRaw != null || nodes == null || nodes.length < 2) continue;
    if (!nodes.any((p) => p.w != null)) continue;
    final pts = sampleLine(nodes, closed: c.lineClosed, perCurve: 6);
    c.brushRaw = _thin(pts, 1.0);
    c.brushSmooth = 0.2;
    rebuildBrushLine(c);
    n++;
  }
  return n;
}
