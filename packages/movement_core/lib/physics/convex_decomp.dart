/// Convex decomposition for Collide: a concave outline (a "C", an L, a
/// ring with a hole) becomes convex parts, so collisions follow the real
/// shape instead of its convex hull.
///
/// Each outer ring takes its holes in through bridges, is triangulated
/// (ear clipping) and the triangles are merged back while the result stays
/// convex (Hertel-Mehlhorn). Every part knows which of its edges lie on the
/// original outline (`boundary`) - contacts prefer those, never a seam
/// between two parts of the same layer. A convex ring stays one part.
library;

import 'dart:math' as math;

import '../geometry/contour.dart' show classifyRings, ringSignedArea, simplifyRing;

class ConvexPart {
  /// Counter-clockwise (positive shoelace area), content-local.
  final List<List<double>> points;

  /// Per edge (points[i] -> points[i + 1]): on the original outline.
  final List<bool> boundary;
  const ConvexPart(this.points, this.boundary);
}

/// Parts of `rings` (outer rings and holes, any winding), at most `cap`:
/// over it the rings are simplified harder (physics only) until they fit.
List<ConvexPart> convexParts(List<List<List<double>>> rings, {int cap = 32}) {
  var tol = 0.0;
  var span = 0.0;
  for (final r in rings) {
    for (final p in r) {
      span = math.max(span, math.max(p[0].abs(), p[1].abs()));
    }
  }
  for (var tries = 0; tries < 12; tries++) {
    final src = tol == 0 ? rings : [for (final r in rings) simplifyRing(r, tol)];
    final parts = _decompose([for (final r in src) if (r.length >= 3) r]);
    if (parts.length <= cap) return parts;
    tol = tol == 0 ? math.max(0.5, span / 400) : tol * 2;
  }
  // still too many: the hull of everything.
  return [_hullPart([for (final r in rings) ...r])];
}

List<ConvexPart> _decompose(List<List<List<double>>> rings) {
  if (rings.isEmpty) return const [];
  final c = classifyRings(rings);
  final out = <ConvexPart>[];
  for (var i = 0; i < c.rings.length; i++) {
    final r = c.rings[i];
    if (r.isHole) continue;
    final holes = [
      for (var j = 0; j < c.rings.length; j++)
        if (c.rings[j].isHole && c.rings[j].parent == i) c.rings[j].points
    ];
    out.addAll(_decomposeOne(r.points, holes));
  }
  return out;
}

double _cross(List<double> o, List<double> a, List<double> b) =>
    (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);

List<List<double>> _ccw(List<List<double>> r) => ringSignedArea(r) >= 0 ? r : r.reversed.toList();
List<List<double>> _cw(List<List<double>> r) => ringSignedArea(r) <= 0 ? r : r.reversed.toList();

bool _isConvex(List<List<double>> pts) {
  final n = pts.length;
  for (var i = 0; i < n; i++) {
    if (_cross(pts[i], pts[(i + 1) % n], pts[(i + 2) % n]) < -1e-9) return false;
  }
  return true;
}

ConvexPart _hullPart(List<List<double>> pts) {
  final sorted = [...pts]..sort((a, b) => a[0] != b[0] ? a[0].compareTo(b[0]) : a[1].compareTo(b[1]));
  final lower = <List<double>>[], upper = <List<double>>[];
  for (final p in sorted) {
    while (lower.length >= 2 && _cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in sorted.reversed) {
    while (upper.length >= 2 && _cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  final hull = [...lower.sublist(0, lower.length - 1), ...upper.sublist(0, upper.length - 1)];
  return ConvexPart(hull, List.filled(hull.length, true));
}

bool _segmentsCross(List<double> a, List<double> b, List<double> c, List<double> d) {
  final d1 = _cross(c, d, a), d2 = _cross(c, d, b), d3 = _cross(a, b, c), d4 = _cross(a, b, d);
  return ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) &&
      ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9));
}

/// One outer ring (and its holes) into convex parts.
List<ConvexPart> _decomposeOne(List<List<double>> outer, List<List<List<double>>> holes) {
  var poly = _ccw(outer);
  if (holes.isEmpty && _isConvex(poly)) return [_hullPart(poly)];
  // edges on the outline: (a, b) pairs of vertex indices in the bridged
  // polygon, recorded as it's built.
  var pts = [...poly];
  final boundary = <String>{};
  void ringEdges(int from, int count) {
    for (var k = 0; k < count; k++) {
      final a = from + k, b = from + (k + 1) % count;
      boundary.add('$a>$b');
    }
  }

  ringEdges(0, pts.length);
  // holes: rightmost first, each bridged from its rightmost vertex to a
  // vertex of the polygon it can see.
  final hs = [for (final h in holes) _cw(h)]
    ..sort((a, b) => b.map((p) => p[0]).reduce(math.max).compareTo(a.map((p) => p[0]).reduce(math.max)));
  // index bookkeeping: the polygon as indices into `all`.
  final all = <List<double>>[...pts];
  var order = [for (var i = 0; i < pts.length; i++) i];
  for (final h in hs) {
    final base = all.length;
    all.addAll(h);
    for (var k = 0; k < h.length; k++) {
      boundary.add('${base + k}>${base + (k + 1) % h.length}');
    }
    var hi = 0;
    for (var k = 1; k < h.length; k++) {
      if (h[k][0] > h[hi][0]) hi = k;
    }
    final hp = h[hi];
    // nearest visible polygon vertex.
    int? best;
    var bestD = double.infinity;
    for (var oi = 0; oi < order.length; oi++) {
      final v = all[order[oi]];
      final d = math.pow(v[0] - hp[0], 2) + math.pow(v[1] - hp[1], 2);
      if (d >= bestD) continue;
      var blocked = false;
      for (var e = 0; e < order.length && !blocked; e++) {
        final a = all[order[e]], b = all[order[(e + 1) % order.length]];
        if (_segmentsCross(hp, v, a, b)) blocked = true;
      }
      for (var e = 0; e < h.length && !blocked; e++) {
        if (_segmentsCross(hp, v, h[e], h[(e + 1) % h.length])) blocked = true;
      }
      if (!blocked) {
        bestD = d.toDouble();
        best = oi;
      }
    }
    if (best == null) continue; // can't bridge: the hole is left out
    final holeLoop = [for (var k = 0; k <= h.length; k++) base + (hi + k) % h.length];
    order = [...order.sublist(0, best + 1), ...holeLoop, order[best], ...order.sublist(best + 1)];
  }
  // ear clipping over `order` (indices may repeat at bridges).
  final tris = <List<int>>[];
  final rest = [...order];
  var guard = 0;
  while (rest.length > 3 && guard++ < 10000) {
    var clipped = false;
    for (var i = 0; i < rest.length; i++) {
      final ia = rest[(i - 1 + rest.length) % rest.length], ib = rest[i], ic = rest[(i + 1) % rest.length];
      final a = all[ia], b = all[ib], c = all[ic];
      if (_cross(a, b, c) <= 1e-12) continue; // reflex or flat
      var inside = false;
      for (final k in rest) {
        if (k == ia || k == ib || k == ic) continue;
        final p = all[k];
        if ((p[0] == a[0] && p[1] == a[1]) || (p[0] == b[0] && p[1] == b[1]) || (p[0] == c[0] && p[1] == c[1])) continue;
        if (_cross(a, b, p) >= -1e-12 && _cross(b, c, p) >= -1e-12 && _cross(c, a, p) >= -1e-12) {
          inside = true;
          break;
        }
      }
      if (inside) continue;
      tris.add([ia, ib, ic]);
      rest.removeAt(i);
      clipped = true;
      break;
    }
    if (!clipped) {
      // degenerate leftovers (collinear runs): drop a flat vertex.
      var dropped = false;
      for (var i = 0; i < rest.length; i++) {
        final a = all[rest[(i - 1 + rest.length) % rest.length]], b = all[rest[i]], c = all[rest[(i + 1) % rest.length]];
        if (_cross(a, b, c).abs() <= 1e-9) {
          rest.removeAt(i);
          dropped = true;
          break;
        }
      }
      if (!dropped) break;
    }
  }
  if (rest.length == 3 && _cross(all[rest[0]], all[rest[1]], all[rest[2]]).abs() > 1e-12) tris.add([...rest]);
  // Hertel-Mehlhorn: merge across shared diagonals while convex.
  var polys = [for (final t in tris) [...t]];
  var merged = true;
  while (merged) {
    merged = false;
    outer:
    for (var p = 0; p < polys.length; p++) {
      for (var q = p + 1; q < polys.length; q++) {
        final m = _mergeIfConvex(polys[p], polys[q], all, boundary);
        if (m != null) {
          polys[p] = m;
          polys.removeAt(q);
          merged = true;
          break outer;
        }
      }
    }
  }
  return [
    for (final poly in polys)
      ConvexPart([for (final k in poly) [...all[k]]], [
        for (var e = 0; e < poly.length; e++)
          boundary.contains('${poly[e]}>${poly[(e + 1) % poly.length]}')
      ])
  ];
}

/// `p` and `q` joined along a shared edge that isn't on the outline, if
/// the result is convex.
List<int>? _mergeIfConvex(List<int> p, List<int> q, List<List<double>> all, Set<String> boundary) {
  for (var i = 0; i < p.length; i++) {
    final a = p[i], b = p[(i + 1) % p.length];
    if (boundary.contains('$a>$b')) continue;
    for (var j = 0; j < q.length; j++) {
      if (q[j] != b || q[(j + 1) % q.length] != a) continue;
      // p: ... a, b ...; q: ... b, a ... -> p up to a, then q after a
      // round to b, then p after b.
      final out = <int>[];
      for (var k = 0; k < p.length; k++) {
        out.add(p[(i + 1 + k) % p.length]); // starts at b, ends at a
      }
      // out = b ... a; insert q's vertices between a and b (after a).
      for (var k = 2; k < q.length; k++) {
        out.add(q[(j + k) % q.length]);
      }
      final pts = [for (final k in out) all[k]];
      if (_isConvex(pts)) return out;
      return null;
    }
  }
  return null;
}
