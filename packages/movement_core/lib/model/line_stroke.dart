/// A vector line's stroke as filled pieces: a band per stretch (its width
/// can change from point to point), a join where it turns (round, miter or
/// bevel) and a cap at each open end (round, square - its corners rounded
/// or not - or a triangle). Every piece winds the same way, so filled
/// together (non-zero) they make one shape without seams.
///
/// The plain round line with one width keeps being drawn as a stroke; see
/// [lineNeedsShapedStroke].
library;

import 'dart:math' as math;

import 'line_path.dart';
import 'project.dart';

/// Whether `c` needs its stroke built from pieces (anything but round ends
/// and joins with one width all along).
bool lineNeedsShapedStroke(Content c) =>
    isNodeLine(c) &&
    !isFilledLine(c) &&
    (c.lineCap != 'round' || c.lineJoin != 'round' || c.lineStationShapes || c.lineNodes!.any((n) => n.w != null));

/// The stroke of `c` (content-local), between fractions `t0` and `t1` of
/// its length, as rings to fill together (non-zero).
List<List<List<double>>> lineStrokeRings(Content c, {num? frame, double t0 = 0, double t1 = 1}) {
  final full = sampleLineWidths(c.lineNodes!, closed: c.lineClosed, frame: frame, width: c.lineWidth);
  final whole = t0 <= 0 && t1 >= 1;
  var pts = whole ? full : trimPolyline(full, t0, t1);
  // drop repeats (a zero-length stretch has no direction).
  final clean = <List<double>>[];
  for (final p in pts) {
    if (clean.isEmpty || (p[0] - clean.last[0]).abs() > 1e-9 || (p[1] - clean.last[1]).abs() > 1e-9) clean.add(p);
  }
  pts = clean;
  if (pts.length < 2) return const [];
  final loop = c.lineClosed && whole;
  if (loop && pts.length > 2) pts = pts.sublist(0, pts.length - 1); // the closing repeat
  final out = <List<List<double>>>[];
  final n = pts.length;
  final segs = loop ? n : n - 1;
  List<double> dir(int i) {
    final a = pts[i], b = pts[(i + 1) % n];
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final l = math.sqrt(dx * dx + dy * dy);
    return [dx / l, dy / l];
  }

  // the bands.
  for (var i = 0; i < segs; i++) {
    final a = pts[i], b = pts[(i + 1) % n];
    final d = dir(i);
    final ha = a[2] / 2, hb = b[2] / 2;
    out.add([
      [a[0] - d[1] * ha, a[1] + d[0] * ha],
      [b[0] - d[1] * hb, b[1] + d[0] * hb],
      [b[0] + d[1] * hb, b[1] - d[0] * hb],
      [a[0] + d[1] * ha, a[1] - d[0] * ha],
    ]);
  }
  // the joins.
  for (var i = loop ? 0 : 1; i < (loop ? n : n - 1); i++) {
    final p = pts[i], h = p[2] / 2;
    final d1 = dir((i - 1 + n) % n), d2 = dir(i);
    final cross = d1[0] * d2[1] - d1[1] * d2[0];
    final dot = d1[0] * d2[0] + d1[1] * d2[1];
    if (cross.abs() < 1e-9 && dot > 0) continue; // straight on
    if (h <= 0) continue;
    // the outer side: left of the way for a right turn.
    final s = cross > 0 ? 1.0 : -1.0;
    final n1 = [d1[1] * s, -d1[0] * s], n2 = [d2[1] * s, -d2[0] * s];
    final e1 = [p[0] + n1[0] * h, p[1] + n1[1] * h], e2 = [p[0] + n2[0] * h, p[1] + n2[1] * h];
    if (c.lineJoin == 'round') {
      // the outer edge bent round the point (no whole circle: the point
      // itself gets no shape of its own - see lineStationShapes).
      final a1 = math.atan2(n1[1], n1[0]);
      var sweep = math.atan2(n2[1], n2[0]) - a1;
      while (sweep > math.pi) {
        sweep -= 2 * math.pi;
      }
      while (sweep < -math.pi) {
        sweep += 2 * math.pi;
      }
      final steps = math.max(2, (sweep.abs() / (math.pi / 12)).ceil());
      out.add([
        p,
        for (var k = 0; k <= steps; k++) [p[0] + h * math.cos(a1 + sweep * k / steps), p[1] + h * math.sin(a1 + sweep * k / steps)],
      ]);
      continue;
    }
    if (c.lineJoin == 'miter') {
      // where the two outer edges meet.
      final half = math.acos(dot.clamp(-1.0, 1.0)) / 2; // half the turn
      final reach = h / math.cos(half); // from the point to the tip
      if (reach.isFinite && reach / h <= c.lineMiterLimit) {
        final bx = n1[0] + n2[0], by = n1[1] + n2[1];
        final bl = math.sqrt(bx * bx + by * by);
        if (bl > 1e-9) {
          out.add([p, e1, [p[0] + bx / bl * reach, p[1] + by / bl * reach], e2]);
          continue;
        }
      }
    }
    out.add([p, e1, e2]);
  }
  // the points between the ends: their own circle / square, when asked.
  if (c.lineStationShapes) {
    final nodes = c.lineNodes!;
    for (var i = c.lineClosed ? 0 : 1; i < (c.lineClosed ? nodes.length : nodes.length - 1); i++) {
      final (x, y) = nodes[i].posAt(frame);
      final w = (nodes[i].valueAt('w', frame) ?? c.lineWidth) * (c.lineStationSizes[i] ?? 1);
      final h = w / 2;
      if (h <= 0) continue;
      if (c.lineCap == 'square') {
        // along the line there.
        final prev = nodes[(i - 1 + nodes.length) % nodes.length].posAt(frame);
        final next = nodes[(i + 1) % nodes.length].posAt(frame);
        var dx = next.$1 - prev.$1, dy = next.$2 - prev.$2;
        final l = math.sqrt(dx * dx + dy * dy);
        if (l < 1e-9) {
          dx = 1;
          dy = 0;
        } else {
          dx /= l;
          dy /= l;
        }
        out.add([
          [x + (dx - dy) * h, y + (dy + dx) * h],
          [x + (-dx - dy) * h, y + (-dy + dx) * h],
          [x + (-dx + dy) * h, y + (-dy - dx) * h],
          [x + (dx + dy) * h, y + (dy - dx) * h],
        ]);
      } else {
        out.add(_circle([x, y, w], h));
      }
    }
  }
  // the ends.
  if (!loop) {
    out.addAll(_cap(c, pts[0], [-dir(0)[0], -dir(0)[1]]));
    final dl = dir(n - 2);
    out.addAll(_cap(c, pts[n - 1], dl));
  }
  return [for (final r in out) if (r.length >= 3) _ccw(r)];
}

/// One end at `p`, the line leaving it the way `d` (unit) points.
List<List<List<double>>> _cap(Content c, List<double> p, List<double> d) {
  final h = p[2] / 2;
  if (h <= 0) return const [];
  final nx = -d[1], ny = d[0];
  switch (c.lineCap) {
    case 'square':
      final r = (c.lineCapRound.clamp(0.0, 1.0)) * h;
      // from the point: a box reaching h out, its two far corners rounded.
      final a = [p[0] + nx * h, p[1] + ny * h], b = [p[0] - nx * h, p[1] - ny * h];
      final fa = [a[0] + d[0] * h, a[1] + d[1] * h], fb = [b[0] + d[0] * h, b[1] + d[1] * h];
      if (r <= 1e-9) return [[a, fa, fb, b]];
      List<List<double>> corner(List<double> cn, List<double> from, List<double> to) {
        // a quarter bend from `from` to `to` round corner `cn`.
        return [
          for (var s = 0; s <= 6; s++)
            () {
              final t = s / 6, u = 1 - t;
              final k = c.lineCapShape.clamp(0.0, 1.0);
              final c1 = [from[0] + (cn[0] - from[0]) * k, from[1] + (cn[1] - from[1]) * k];
              final c2 = [to[0] + (cn[0] - to[0]) * k, to[1] + (cn[1] - to[1]) * k];
              return [
                u * u * u * from[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * to[0],
                u * u * u * from[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * to[1],
              ];
            }()
        ];
      }

      final ra = corner(fa, [fa[0] - d[0] * r, fa[1] - d[1] * r], [fa[0] - nx * r, fa[1] - ny * r]);
      final rb = corner(fb, [fb[0] + nx * r, fb[1] + ny * r], [fb[0] - d[0] * r, fb[1] - d[1] * r]);
      return [
        [a, ...ra, ...rb, b]
      ];
    case 'triangle':
      final len = c.lineCapLength.clamp(0.0, 20.0) * h;
      return [
        [
          [p[0] + nx * h, p[1] + ny * h],
          [p[0] + d[0] * len, p[1] + d[1] * len],
          [p[0] - nx * h, p[1] - ny * h],
        ]
      ];
    default:
      return [_circle(p, h)];
  }
}

List<List<double>> _circle(List<double> p, double r) {
  final steps = (r * 1.5).clamp(12, 48).round();
  return [for (var i = 0; i < steps; i++) [p[0] + r * math.cos(2 * math.pi * i / steps), p[1] + r * math.sin(2 * math.pi * i / steps)]];
}

/// The same way round for every piece (positive area), 2D points.
List<List<double>> _ccw(List<List<double>> r) {
  var a = 0.0;
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  final two = [for (final p in r) [p[0], p[1]]];
  return a < 0 ? two.reversed.toList() : two;
}
