/// Polygon booleans (union, intersect, subtract, exclude) and polygon
/// offset (miter / round / bevel joins), on rings of [x, y] points.
///
/// The boolean is an arrangement method: every edge of both inputs is
/// split where it meets another (shared vertices and collinear overlaps
/// included), coincident pieces are merged into one, and each piece is
/// kept when the result is inside on exactly one of its sides - which is
/// decided by the inputs' winding numbers (non-zero) just beside it. The
/// kept pieces, all turned so the inside is on their left, are linked
/// back into rings. Degenerate input (touching vertices, edges on edges,
/// identical shapes) needs no special case.
///
/// Offset grows (or, negative, shrinks) a shape by unioning (subtracting)
/// a strip along every edge plus a join at every vertex.
library;

import 'dart:math' as math;

typedef PolyRing = List<List<double>>;

enum BoolOp { union, intersect, subtract, exclude }

/// Join of an offset's corners.
enum OffsetJoin { miter, round, bevel }

/// Winding number of `rings` around `p` (non-zero: inside).
int windingNumber(List<PolyRing> rings, double px, double py) {
  var w = 0;
  for (final r in rings) {
    final n = r.length;
    for (var i = 0; i < n; i++) {
      final a = r[i], b = r[(i + 1) % n];
      if (a[1] <= py) {
        if (b[1] > py && _cross(a, b, px, py) > 0) w++;
      } else if (b[1] <= py && _cross(a, b, px, py) < 0) {
        w--;
      }
    }
  }
  return w;
}

double _cross(List<double> a, List<double> b, double px, double py) =>
    (b[0] - a[0]) * (py - a[1]) - (px - a[0]) * (b[1] - a[1]);

double ringArea(PolyRing r) {
  var s = 0.0;
  for (var i = 0; i < r.length; i++) {
    final a = r[i], b = r[(i + 1) % r.length];
    s += a[0] * b[1] - b[0] * a[1];
  }
  return s / 2;
}

/// `a` op `b` (each a set of rings, non-zero fill). The result's rings
/// have the inside on their left (positive area outers, negative holes).
List<PolyRing> polygonBoolean(List<PolyRing> a, List<PolyRing> b, BoolOp op) {
  a = [for (final r in a) if (r.length >= 3) r];
  b = [for (final r in b) if (r.length >= 3) r];
  bool keep(bool ia, bool ib) => switch (op) {
        BoolOp.union => ia || ib,
        BoolOp.intersect => ia && ib,
        BoolOp.subtract => ia && !ib,
        BoolOp.exclude => ia != ib,
      };
  if (a.isEmpty && b.isEmpty) return const [];

  // scale for the tolerances.
  var span = 1.0;
  for (final r in [...a, ...b]) {
    for (final p in r) {
      span = math.max(span, math.max(p[0].abs(), p[1].abs()));
    }
  }
  final eps = span * 1e-9;
  final delta = span * 1e-7; // the side test's step off a piece

  // all edges.
  final edges = <(List<double>, List<double>)>[];
  for (final r in [...a, ...b]) {
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      if ((p[0] - q[0]).abs() > eps || (p[1] - q[1]).abs() > eps) edges.add((p, q));
    }
  }

  // split points along each edge (as 0..1).
  final ts = [for (final _ in edges) <double>[0, 1]];
  for (var i = 0; i < edges.length; i++) {
    final (p, q) = edges[i];
    final rx = q[0] - p[0], ry = q[1] - p[1];
    final len2 = rx * rx + ry * ry;
    for (var j = i + 1; j < edges.length; j++) {
      final (s, e) = edges[j];
      // quick reject by boxes.
      if (math.max(p[0], q[0]) < math.min(s[0], e[0]) - eps ||
          math.max(s[0], e[0]) < math.min(p[0], q[0]) - eps ||
          math.max(p[1], q[1]) < math.min(s[1], e[1]) - eps ||
          math.max(s[1], e[1]) < math.min(p[1], q[1]) - eps) {
        continue;
      }
      final sx = e[0] - s[0], sy = e[1] - s[1];
      final slen2 = sx * sx + sy * sy;
      final den = rx * sy - ry * sx;
      final qpx = s[0] - p[0], qpy = s[1] - p[1];
      if (den.abs() > 1e-12 * math.sqrt(len2 * slen2)) {
        final t = (qpx * sy - qpy * sx) / den, u = (qpx * ry - qpy * rx) / den;
        final te = eps / math.sqrt(len2), ue = eps / math.sqrt(slen2);
        if (t >= -te && t <= 1 + te && u >= -ue && u <= 1 + ue) {
          ts[i].add(t.clamp(0.0, 1.0));
          ts[j].add(u.clamp(0.0, 1.0));
        }
      }
      // collinear overlap: each one's ends on the other.
      void onto(List<double> pt, List<double> o, double ox, double oy, double ol2, List<double> into) {
        final t = ((pt[0] - o[0]) * ox + (pt[1] - o[1]) * oy) / ol2;
        if (t <= 0 || t >= 1) return;
        final cx = o[0] + ox * t - pt[0], cy = o[1] + oy * t - pt[1];
        if (cx * cx + cy * cy <= eps * eps * 4) into.add(t);
      }

      onto(s, p, rx, ry, len2, ts[i]);
      onto(e, p, rx, ry, len2, ts[i]);
      onto(p, s, sx, sy, slen2, ts[j]);
      onto(q, s, sx, sy, slen2, ts[j]);
    }
  }

  // vertices, merged when closer than eps.
  final verts = <List<double>>[];
  final grid = <String, List<int>>{};
  final cell = math.max(eps * 8, 1e-12);
  int vertex(double x, double y) {
    final gx = (x / cell).floor(), gy = (y / cell).floor();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final k in grid['${gx + dx},${gy + dy}'] ?? const <int>[]) {
          final v = verts[k];
          if ((v[0] - x).abs() <= eps * 2 && (v[1] - y).abs() <= eps * 2) return k;
        }
      }
    }
    verts.add([x, y]);
    (grid['$gx,$gy'] ??= []).add(verts.length - 1);
    return verts.length - 1;
  }

  // the pieces, each once.
  final seen = <int>{};
  final pieces = <(int, int)>[];
  for (var i = 0; i < edges.length; i++) {
    final (p, q) = edges[i];
    final list = ts[i]..sort();
    var prev = vertex(p[0], p[1]);
    for (var k = 1; k < list.length; k++) {
      final t = list[k];
      final v = k == list.length - 1 ? vertex(q[0], q[1]) : vertex(p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t);
      if (v != prev) {
        final key = prev < v ? prev * 1000003 + v : v * 1000003 + prev;
        if (seen.add(key)) pieces.add((prev, v));
      }
      prev = v;
    }
  }

  // keep the pieces on the result's edge, inside on their left.
  final kept = <(int, int)>[];
  for (final (u, v) in pieces) {
    final pu = verts[u], pv = verts[v];
    final dx = pv[0] - pu[0], dy = pv[1] - pu[1];
    final l = math.sqrt(dx * dx + dy * dy);
    if (l == 0) continue;
    final mx = (pu[0] + pv[0]) / 2, my = (pu[1] + pv[1]) / 2;
    final nx = -dy / l * delta, ny = dx / l * delta;
    final left = keep(windingNumber(a, mx + nx, my + ny) != 0, windingNumber(b, mx + nx, my + ny) != 0);
    final right = keep(windingNumber(a, mx - nx, my - ny) != 0, windingNumber(b, mx - nx, my - ny) != 0);
    if (left == right) continue;
    kept.add(left ? (u, v) : (v, u));
  }

  // link them into rings: at a meeting point take the sharpest left turn
  // (the ring hugs its own piece of the result).
  final out = <int, List<int>>{};
  for (var i = 0; i < kept.length; i++) {
    (out[kept[i].$1] ??= []).add(i);
  }
  final used = List<bool>.filled(kept.length, false);
  final rings = <PolyRing>[];
  for (var s = 0; s < kept.length; s++) {
    if (used[s]) continue;
    final ring = <int>[kept[s].$1];
    var cur = s;
    var closed = false;
    for (var guard = 0; guard <= kept.length; guard++) {
      used[cur] = true;
      final (u, v) = kept[cur];
      if (v == kept[s].$1) {
        closed = true;
        break;
      }
      ring.add(v);
      final pu = verts[u], pv = verts[v];
      final ix = pv[0] - pu[0], iy = pv[1] - pu[1];
      int? best;
      var bestAngle = -double.infinity;
      for (final c in out[v] ?? const <int>[]) {
        if (used[c]) continue;
        final w = verts[kept[c].$2];
        final ox = w[0] - pv[0], oy = w[1] - pv[1];
        final ang = math.atan2(ix * oy - iy * ox, ix * ox + iy * oy);
        if (ang > bestAngle) {
          bestAngle = ang;
          best = c;
        }
      }
      if (best == null) break;
      cur = best;
    }
    if (!closed || ring.length < 3) continue;
    final pts = _dropCollinear([for (final k in ring) [...verts[k]]], eps);
    if (pts.length >= 3 && ringArea(pts).abs() > eps * eps) rings.add(pts);
  }
  return rings;
}

PolyRing _dropCollinear(PolyRing r, double eps) {
  var pts = r;
  var changed = true;
  while (changed && pts.length >= 3) {
    changed = false;
    final next = <List<double>>[];
    for (var i = 0; i < pts.length; i++) {
      final a = next.isEmpty ? pts[(i - 1 + pts.length) % pts.length] : next.last;
      final b = pts[i], c = pts[(i + 1) % pts.length];
      final abx = b[0] - a[0], aby = b[1] - a[1], bcx = c[0] - b[0], bcy = c[1] - b[1];
      final cr = abx * bcy - aby * bcx;
      final l = math.sqrt(abx * abx + aby * aby) + math.sqrt(bcx * bcx + bcy * bcy);
      // straight on through b: b goes.
      if (cr.abs() <= eps * l && abx * bcx + aby * bcy >= 0) {
        changed = true;
        continue;
      }
      next.add(b);
    }
    pts = next;
  }
  return pts;
}

/// `rings` grown by `d` (shrunk when negative), corners joined `join`
/// (a miter longer than `miterLimit` x d is bevelled, like SVG).
/// `tolerance`: the most a round join's arc may stray (px).
List<PolyRing> offsetRings(List<PolyRing> rings, double d,
    {OffsetJoin join = OffsetJoin.miter, double miterLimit = 10, double tolerance = 0.25}) {
  rings = [for (final r in rings) if (r.length >= 3) r];
  if (d == 0 || rings.isEmpty) return rings;
  final s = d.abs();
  final pieces = <PolyRing>[];
  void addPiece(PolyRing p) {
    if (p.length < 3) return;
    final area = ringArea(p);
    if (area.abs() < 1e-12) return;
    pieces.add(area > 0 ? p : p.reversed.toList());
  }

  var span = 1.0;
  for (final r in rings) {
    for (final p in r) {
      span = math.max(span, math.max(p[0].abs(), p[1].abs()));
    }
  }
  final delta = span * 1e-7;
  for (final r in rings) {
    final n = r.length;
    // each edge's normal toward the side the strip goes (outside to grow,
    // inside to shrink), found by the shape's winding just beside it.
    final normals = <List<double>>[];
    for (var i = 0; i < n; i++) {
      final a = r[i], b = r[(i + 1) % n];
      final dx = b[0] - a[0], dy = b[1] - a[1];
      final l = math.sqrt(dx * dx + dy * dy);
      if (l == 0) {
        normals.add(const [0, 0]);
        continue;
      }
      var nx = -dy / l, ny = dx / l;
      final mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2;
      final leftInside = windingNumber(rings, mx + nx * delta, my + ny * delta) != 0;
      // grow: away from the inside; shrink: into it.
      if (leftInside == (d > 0)) {
        nx = -nx;
        ny = -ny;
      }
      normals.add([nx, ny]);
      addPiece([a, b, [b[0] + nx * s, b[1] + ny * s], [a[0] + nx * s, a[1] + ny * s]]);
    }
    // the joins (where they'd fall inside the strips anyway, harmless).
    for (var i = 0; i < n; i++) {
      final n1 = normals[(i - 1 + n) % n], n2 = normals[i];
      if ((n1[0] == 0 && n1[1] == 0) || (n2[0] == 0 && n2[1] == 0)) continue;
      final v = r[i];
      final p1 = [v[0] + n1[0] * s, v[1] + n1[1] * s], p2 = [v[0] + n2[0] * s, v[1] + n2[1] * s];
      final cos = n1[0] * n2[0] + n1[1] * n2[1];
      if (cos > 1 - 1e-12) continue; // straight on
      switch (join) {
        case OffsetJoin.bevel:
          addPiece([v, p1, p2]);
        case OffsetJoin.round:
          final a1 = math.atan2(n1[1], n1[0]);
          var sweep = math.atan2(n1[0] * n2[1] - n1[1] * n2[0], cos);
          final steps = math.max(2, (sweep.abs() / (2 * math.acos(math.max(-1.0, 1 - tolerance / s)))).ceil());
          addPiece([
            v,
            for (var k = 0; k <= steps; k++)
              [v[0] + s * math.cos(a1 + sweep * k / steps), v[1] + s * math.sin(a1 + sweep * k / steps)]
          ]);
        case OffsetJoin.miter:
          final bx = n1[0] + n2[0], by = n1[1] + n2[1];
          final k = 1 + cos; // |bisector|^2 / 2
          if (k < 1e-12 || math.sqrt(2 / k) > miterLimit) {
            addPiece([v, p1, p2]);
          } else {
            final m = [v[0] + bx * s / k, v[1] + by * s / k];
            addPiece([v, p1, m, p2]);
          }
      }
    }
  }
  return polygonBoolean(rings, pieces, d > 0 ? BoolOp.union : BoolOp.subtract);
}
