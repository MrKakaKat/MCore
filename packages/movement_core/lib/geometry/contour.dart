/// Silhouette contour: closed rings that wrap a layer's visible pixels -
/// one ring per separate piece, plus inner rings for holes. Pure Dart
/// (no Flutter): the extraction pipeline takes an alpha mask and returns
/// rings; vector content (shapes, compound paths, text) takes its exact
/// geometry instead. Used by the Outline effect (a sticker-style stroke)
/// and, later, by snapping / trim paths / collisions.
///
/// Orientation convention (later stages rely on it): rings live in a
/// y-down pixel space; an OUTER ring has a POSITIVE shoelace area
/// (`ringSignedArea`) and a HOLE a negative one. With the y axis pointing
/// up that is counter-clockwise for outers and clockwise for holes - the
/// usual maths convention - so "outers CCW, holes CW" means exactly
/// "outer area > 0, hole area < 0" here.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// One closed boundary: points without the repeated last one.
class Ring {
  final List<List<double>> points;
  final bool isHole;

  /// The outer ring a hole belongs to (index into Contour.rings), -1 for
  /// outers.
  final int parent;
  const Ring(this.points, {this.isHole = false, this.parent = -1});
}

class Contour {
  final List<Ring> rings;
  const Contour(this.rings);

  static const empty = Contour([]);

  int get outerCount => rings.where((r) => !r.isHole).length;
  int get holeCount => rings.where((r) => r.isHole).length;

  /// Every point moved by `f` (e.g. working pixels -> layer space).
  Contour map(List<double> Function(List<double> p) f) => Contour([
        for (final r in rings) Ring([for (final p in r.points) f(p)], isHole: r.isHole, parent: r.parent),
      ]);
}

/// An alpha mask: `w` x `h` values 0..1, row by row.
class AlphaMask {
  final int w, h;
  final Float32List a;
  AlphaMask(this.w, this.h, [Float32List? a]) : a = a ?? Float32List(w * h);
  double at(int x, int y) => (x < 0 || y < 0 || x >= w || y >= h) ? 0 : a[y * w + x];
}

/// The extraction settings (the cache key holds all of them).
class ContourParams {
  /// Alpha at or above this is inside (0.05..0.95).
  final double threshold;

  /// Rings smaller than this fraction of the mask's area are dropped.
  final double minAreaFraction;

  /// Ramer-Douglas-Peucker tolerance, working pixels.
  final double simplify;

  /// Chaikin smoothing passes (0 = off, 1..3).
  final int smooth;

  /// Grow (> 0) or shrink (< 0) by this many working pixels.
  final double offset;

  /// Sharp corners: a vector shape's grown / shrunk outline keeps its
  /// corners pointed (exact mitred offset) instead of rounding them.
  final bool sharp;
  const ContourParams(
      {this.threshold = 0.5,
      this.minAreaFraction = 0.001,
      this.simplify = 1.0,
      this.smooth = 0,
      this.offset = 0,
      this.sharp = false});

  String get key => '${threshold.toStringAsFixed(3)}|${minAreaFraction.toStringAsFixed(5)}|'
      '${simplify.toStringAsFixed(2)}|$smooth|${offset.toStringAsFixed(2)}|$sharp';
}

/// Shoelace area: > 0 for an outer ring, < 0 for a hole (see the library
/// doc on orientation).
double ringSignedArea(List<List<double>> pts) {
  var s = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i], q = pts[(i + 1) % pts.length];
    s += p[0] * q[1] - q[0] * p[1];
  }
  return s / 2;
}

/// Even-odd point-in-polygon.
bool pointInRing(List<double> p, List<List<double>> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) {
      inside = !inside;
    }
  }
  return inside;
}

/// Steps 2-7 of the pipeline on a mask: threshold, (offset by dilating /
/// eroding the thresholded mask - the raster route), marching squares,
/// drop specks, simplify, smooth. Rings come back in working pixels
/// (a pixel's centre is at x + 0.5).
Contour extractContour(AlphaMask mask, [ContourParams p = const ContourParams()]) {
  final w = mask.w, h = mask.h;
  if (w == 0 || h == 0) return Contour.empty;
  // the field marching squares runs on: alpha itself (smooth edges), or
  // the grown / shrunk binary mask when offset.
  Float32List field = mask.a;
  var t = p.threshold;
  if (p.offset.abs() >= 0.5) {
    field = _offsetBinary(mask, p.threshold, p.offset);
    t = 0.5;
  }
  var rings = _marchingSquares(field, w, h, t);
  final minArea = p.minAreaFraction * w * h;
  rings = [for (final r in rings) if (ringSignedArea(r).abs() >= minArea && r.length >= 3) r];
  if (p.simplify > 0) rings = [for (final r in rings) simplifyRing(r, p.simplify)];
  // smoothing rounds corners by a few pixels only: the ring is first cut
  // into short pieces, so Chaikin can't slice a long-sided shape's
  // corners off (a simplified rectangle has 4 points - corner cutting on
  // those turned it into an octagon cutting into the picture).
  if (p.smooth > 0) rings = [for (final r in rings) densifyRing(r, 1.5 + p.smooth.clamp(0, 3))];
  for (var i = 0; i < p.smooth.clamp(0, 3); i++) {
    rings = [for (final r in rings) chaikin(r)];
  }
  return classifyRings(rings);
}

/// Outer / hole by nesting depth (even = outer), hole parents (the
/// smallest outer around it), and the orientation convention enforced.
Contour classifyRings(List<List<List<double>>> rings) {
  final areas = [for (final r in rings) ringSignedArea(r).abs()];
  final depth = List<int>.filled(rings.length, 0);
  final container = List<int>.filled(rings.length, -1);
  for (var i = 0; i < rings.length; i++) {
    // a point strictly inside ring i's area is its first point nudged
    // nowhere - every ring here is disjoint from the others, so any of
    // its own points decides containment.
    final probe = rings[i][0];
    var best = -1;
    for (var j = 0; j < rings.length; j++) {
      if (i == j || areas[j] <= areas[i]) continue;
      if (pointInRing(probe, rings[j])) {
        depth[i]++;
        if (best < 0 || areas[j] < areas[best]) best = j;
      }
    }
    container[i] = best;
  }
  final out = <Ring>[];
  for (var i = 0; i < rings.length; i++) {
    final hole = depth[i].isOdd;
    var pts = rings[i];
    final a = ringSignedArea(pts);
    if ((hole && a > 0) || (!hole && a < 0)) pts = pts.reversed.toList();
    out.add(Ring(pts, isHole: hole, parent: hole ? container[i] : -1));
  }
  return Contour(out);
}

// marching squares over a padded grid (outside the mask is empty, so
// every ring closes). Segment ends are edge crossings, keyed by edge;
// each crossing joins exactly two segments, so rings are walked from the
// adjacency. Saddles (two diagonal corners inside) are decided by the
// cell centre's average: inside joins the two inside corners.
List<List<List<double>>> _marchingSquares(Float32List f, int w, int h, double t) {
  double v(int x, int y) => (x < 0 || y < 0 || x >= w || y >= h) ? 0 : f[y * w + x];
  final stride = w + 3;
  // edge keys: horizontal edge from (x,y) to (x+1,y) and vertical edge
  // from (x,y) to (x,y+1), x/y from -1.
  int hKey(int x, int y) => ((y + 1) * stride + (x + 1)) * 2;
  int vKey(int x, int y) => ((y + 1) * stride + (x + 1)) * 2 + 1;
  final pos = <int, List<double>>{};
  final adj = <int, List<int>>{};
  List<double> cross(double v0, double v1, double x0, double y0, double x1, double y1) {
    final k = v1 == v0 ? 0.5 : ((t - v0) / (v1 - v0)).clamp(0.0, 1.0);
    // pixel centres sit at +0.5.
    return [x0 + (x1 - x0) * k + 0.5, y0 + (y1 - y0) * k + 0.5];
  }

  void link(int a, int b) {
    (adj[a] ??= []).add(b);
    (adj[b] ??= []).add(a);
  }

  for (var y = -1; y < h; y++) {
    for (var x = -1; x < w; x++) {
      final tl = v(x, y), tr = v(x + 1, y), br = v(x + 1, y + 1), bl = v(x, y + 1);
      final c = (tl >= t ? 8 : 0) | (tr >= t ? 4 : 0) | (br >= t ? 2 : 0) | (bl >= t ? 1 : 0);
      if (c == 0 || c == 15) continue;
      final top = hKey(x, y), bottom = hKey(x, y + 1), left = vKey(x, y), right = vKey(x + 1, y);
      pos[top] ??= cross(tl, tr, x.toDouble(), y.toDouble(), x + 1.0, y.toDouble());
      pos[bottom] ??= cross(bl, br, x.toDouble(), y + 1.0, x + 1.0, y + 1.0);
      pos[left] ??= cross(tl, bl, x.toDouble(), y.toDouble(), x.toDouble(), y + 1.0);
      pos[right] ??= cross(tr, br, x + 1.0, y.toDouble(), x + 1.0, y + 1.0);
      final centreIn = (tl + tr + br + bl) / 4 >= t;
      switch (c) {
        case 1:
        case 14:
          link(left, bottom);
        case 2:
        case 13:
          link(bottom, right);
        case 3:
        case 12:
          link(left, right);
        case 4:
        case 11:
          link(top, right);
        case 6:
        case 9:
          link(top, bottom);
        case 7:
        case 8:
          link(left, top);
        case 5: // tr + bl inside
          if (centreIn) {
            link(left, top);
            link(bottom, right);
          } else {
            link(top, right);
            link(left, bottom);
          }
        case 10: // tl + br inside
          if (centreIn) {
            link(top, right);
            link(left, bottom);
          } else {
            link(left, top);
            link(bottom, right);
          }
      }
    }
  }
  // walk the rings.
  final rings = <List<List<double>>>[];
  final seen = <int>{};
  for (final start in adj.keys) {
    if (seen.contains(start)) continue;
    final ring = <List<double>>[];
    var prev = -1, cur = start;
    while (seen.add(cur)) {
      ring.add(pos[cur]!);
      final n = adj[cur]!;
      final next = n[0] != prev ? n[0] : (n.length > 1 ? n[1] : n[0]);
      prev = cur;
      cur = next;
    }
    if (ring.length >= 3) rings.add(ring);
  }
  return rings;
}

/// The thresholded mask grown (offset > 0) or shrunk (< 0) by |offset|
/// pixels, as 0 / 1 - a two-pass chamfer distance (3-4 weights), so it
/// is linear in the mask size.
Float32List _offsetBinary(AlphaMask m, double t, double offset) {
  final w = m.w, h = m.h;
  // pad by the offset so a grown shape isn't cut at the mask's edge.
  final grow = offset > 0;
  final r = offset.abs();
  const inf = 1 << 28;
  final d = Int32List(w * h);
  // distance to the nearest pixel of the OTHER kind: for growing, to the
  // nearest inside pixel (from outside); for shrinking, to the nearest
  // outside pixel (from inside).
  for (var i = 0; i < w * h; i++) {
    final inside = m.a[i] >= t;
    d[i] = (grow ? inside : !inside) ? 0 : inf;
  }
  // the mask's own edge counts as outside when shrinking.
  int at(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return grow ? inf : 0;
    return d[y * w + x];
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var v = d[y * w + x];
      v = math.min(v, at(x - 1, y) + 3);
      v = math.min(v, at(x, y - 1) + 3);
      v = math.min(v, at(x - 1, y - 1) + 4);
      v = math.min(v, at(x + 1, y - 1) + 4);
      d[y * w + x] = v;
    }
  }
  for (var y = h - 1; y >= 0; y--) {
    for (var x = w - 1; x >= 0; x--) {
      var v = d[y * w + x];
      v = math.min(v, at(x + 1, y) + 3);
      v = math.min(v, at(x, y + 1) + 3);
      v = math.min(v, at(x + 1, y + 1) + 4);
      v = math.min(v, at(x - 1, y + 1) + 4);
      d[y * w + x] = v;
    }
  }
  final out = Float32List(w * h);
  final lim = (r * 3).round();
  for (var i = 0; i < w * h; i++) {
    final inside = m.a[i] >= t;
    out[i] = grow ? (inside || d[i] <= lim ? 1 : 0) : (inside && d[i] > lim ? 1 : 0);
  }
  return out;
}

/// Ramer-Douglas-Peucker on a closed ring; never below 3 points.
List<List<double>> simplifyRing(List<List<double>> ring, double tolerance) {
  if (ring.length <= 3) return ring;
  // split at the point farthest from the first one: two open chains.
  var far = 0;
  var best = -1.0;
  for (var i = 1; i < ring.length; i++) {
    final dx = ring[i][0] - ring[0][0], dy = ring[i][1] - ring[0][1];
    final dd = dx * dx + dy * dy;
    if (dd > best) {
      best = dd;
      far = i;
    }
  }
  final a = _rdp(ring.sublist(0, far + 1), tolerance);
  final b = _rdp([...ring.sublist(far), ring[0]], tolerance);
  final out = [...a, ...b.sublist(1, b.length - 1)];
  if (out.length >= 3) return out;
  // too few left: keep the first, the farthest and the point farthest
  // from the line between them.
  var third = -1;
  var td = -1.0;
  for (var i = 0; i < ring.length; i++) {
    final dd = _segDist(ring[i], ring[0], ring[far]);
    if (dd > td && i != 0 && i != far) {
      td = dd;
      third = i;
    }
  }
  final idx = [0, far, third]..sort();
  return [for (final i in idx) ring[i]];
}

List<List<double>> _rdp(List<List<double>> pts, double tol) {
  if (pts.length <= 2) return pts;
  var idx = 0;
  var dmax = 0.0;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _segDist(pts[i], pts.first, pts.last);
    if (d > dmax) {
      dmax = d;
      idx = i;
    }
  }
  if (dmax <= tol) return [pts.first, pts.last];
  final l = _rdp(pts.sublist(0, idx + 1), tol), r = _rdp(pts.sublist(idx), tol);
  return [...l.sublist(0, l.length - 1), ...r];
}

double _segDist(List<double> p, List<double> a, List<double> b) {
  final dx = b[0] - a[0], dy = b[1] - a[1];
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return math.sqrt(math.pow(p[0] - a[0], 2) + math.pow(p[1] - a[1], 2));
  final k = (((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2).clamp(0.0, 1.0);
  final x = a[0] + dx * k, y = a[1] + dy * k;
  return math.sqrt((p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y));
}

/// The ring with points added so no side is longer than `maxLength`.
List<List<double>> densifyRing(List<List<double>> ring, double maxLength) => [
      for (var i = 0; i < ring.length; i++) ...() {
        final p = ring[i], q = ring[(i + 1) % ring.length];
        final dx = q[0] - p[0], dy = q[1] - p[1];
        final n = math.max(1, (math.sqrt(dx * dx + dy * dy) / maxLength).ceil());
        return [for (var k = 0; k < n; k++) [p[0] + dx * k / n, p[1] + dy * k / n]];
      }(),
    ];

/// One Chaikin corner-cutting pass on a closed ring.
List<List<double>> chaikin(List<List<double>> ring) => [
      for (var i = 0; i < ring.length; i++) ...() {
        final p = ring[i], q = ring[(i + 1) % ring.length];
        return [
          [p[0] * 0.75 + q[0] * 0.25, p[1] * 0.75 + q[1] * 0.25],
          [p[0] * 0.25 + q[0] * 0.75, p[1] * 0.25 + q[1] * 0.75],
        ];
      }(),
    ];

/// Rings (any orientation, nested = holes by even-odd) filled into a
/// mask `w` x `h` covering `rect` [minX, minY, maxX, maxY] - for vector
/// content that needs the raster route (offset, smoothing).
AlphaMask rasterizeRings(List<List<List<double>>> rings, List<double> rect, int w, int h) {
  final m = AlphaMask(w, h);
  final sx = w / (rect[2] - rect[0]), sy = h / (rect[3] - rect[1]);
  for (var y = 0; y < h; y++) {
    final py = rect[1] + (y + 0.5) / sy;
    final xs = <double>[];
    for (final r in rings) {
      for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
        final a = r[i], b = r[j];
        if ((a[1] > py) != (b[1] > py)) xs.add(a[0] + (py - a[1]) * (b[0] - a[0]) / (b[1] - a[1]));
      }
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      final x0 = ((xs[k] - rect[0]) * sx - 0.5).ceil().clamp(0, w);
      final x1 = ((xs[k + 1] - rect[0]) * sx - 0.5).floor().clamp(-1, w - 1);
      for (var x = x0; x <= x1; x++) {
        m.a[y * w + x] = 1;
      }
    }
  }
  return m;
}

/// The contour of vector rings (shapes, compound paths, glyphs) in their
/// own space: exact geometry when nothing needs the raster (no offset,
/// no smoothing); otherwise rasterized at `workSize` (longest side),
/// extracted and mapped back.
Contour contourOfVectorRings(List<List<List<double>>> rings, ContourParams p, {int workSize = 512}) {
  rings = [for (final r in rings) if (r.length >= 3) r];
  if (rings.isEmpty) return Contour.empty;
  if (p.offset == 0 && p.smooth == 0) return classifyRings(rings);
  // sharp corners: offset each ring exactly, mitred.
  if (p.sharp && p.smooth == 0) {
    final c = classifyRings(rings);
    return classifyRings([
      for (final r in c.rings)
        if (miterOffsetRing(r.points, r.isHole ? -p.offset : p.offset) case final o when o.length >= 3) o
    ]);
  }
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final r in rings) {
    for (final q in r) {
      minX = math.min(minX, q[0]);
      minY = math.min(minY, q[1]);
      maxX = math.max(maxX, q[0]);
      maxY = math.max(maxY, q[1]);
    }
  }
  final span = math.max(maxX - minX, maxY - minY);
  if (span <= 0) return Contour.empty;
  final scale = workSize / span; // working px per unit
  // room for growing.
  final pad = p.offset > 0 ? p.offset + 2 : 2;
  final rect = [minX - pad, minY - pad, maxX + pad, maxY + pad];
  final w = ((rect[2] - rect[0]) * scale).ceil().clamp(1, 4096), h = ((rect[3] - rect[1]) * scale).ceil().clamp(1, 4096);
  final mask = rasterizeRings(rings, rect, w, h);
  final c = extractContour(
      mask,
      ContourParams(
          threshold: 0.5,
          minAreaFraction: p.minAreaFraction * (span * span) / ((rect[2] - rect[0]) * (rect[3] - rect[1])),
          simplify: p.simplify,
          smooth: p.smooth,
          offset: p.offset * scale));
  return c.map((q) => [rect[0] + q[0] * (rect[2] - rect[0]) / w, rect[1] + q[1] * (rect[3] - rect[1]) / h]);
}

/// A ring moved `d` px outward (< 0: inward) along its edges' normals,
/// corners mitred (a very sharp corner is capped at 4 x d, bevelled).
List<List<double>> miterOffsetRing(List<List<double>> pts, double d) {
  final n = pts.length;
  if (n < 3 || d == 0) return pts;
  // which side is outward follows the ring's winding (its signed area).
  final sign = ringSignedArea(pts) > 0 ? 1.0 : -1.0;
  List<double> normal(List<double> a, List<double> b) {
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final l = math.sqrt(dx * dx + dy * dy);
    return l == 0 ? [0, 0] : [sign * dy / l, -sign * dx / l];
  }

  final out = <List<double>>[];
  for (var i = 0; i < n; i++) {
    final prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n];
    final n1 = normal(prev, cur), n2 = normal(cur, next);
    final bx = n1[0] + n2[0], by = n1[1] + n2[1];
    final dot = 1 + n1[0] * n2[0] + n1[1] * n2[1]; // 1 + cos
    if (dot < 0.125) {
      // nearly folding back: bevel instead of an endless spike.
      out.add([cur[0] + n1[0] * d, cur[1] + n1[1] * d]);
      out.add([cur[0] + n2[0] * d, cur[1] + n2[1] * d]);
      continue;
    }
    final k = d / dot;
    out.add([cur[0] + bx * k, cur[1] + by * k]);
  }
  return out;
}

/// Rings clipped to the box [minX, minY, maxX, maxY] (Sutherland-Hodgman,
/// ring by ring): a cropped layer's outline runs along the cut. Rings
/// left with fewer than 3 points are dropped.
List<List<List<double>>> clipRingsToRect(List<List<List<double>>> rings, List<double> box) {
  List<List<double>> clip(List<List<double>> pts, bool Function(List<double>) inside, List<double> Function(List<double>, List<double>) cut) {
    final out = <List<double>>[];
    for (var i = 0; i < pts.length; i++) {
      final cur = pts[i], prev = pts[(i + pts.length - 1) % pts.length];
      final ci = inside(cur), pi = inside(prev);
      if (ci) {
        if (!pi) out.add(cut(prev, cur));
        out.add(cur);
      } else if (pi) {
        out.add(cut(prev, cur));
      }
    }
    return out;
  }

  List<double> atX(List<double> a, List<double> b, double x) => [x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0])];
  List<double> atY(List<double> a, List<double> b, double y) => [a[0] + (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]), y];
  final out = <List<List<double>>>[];
  for (var r in rings) {
    r = clip(r, (p) => p[0] >= box[0], (a, b) => atX(a, b, box[0]));
    if (r.isNotEmpty) r = clip(r, (p) => p[0] <= box[2], (a, b) => atX(a, b, box[2]));
    if (r.isNotEmpty) r = clip(r, (p) => p[1] >= box[1], (a, b) => atY(a, b, box[1]));
    if (r.isNotEmpty) r = clip(r, (p) => p[1] <= box[3], (a, b) => atY(a, b, box[3]));
    if (r.length >= 3 && ringSignedArea(r).abs() > 1e-9) out.add(r);
  }
  return out;
}

/// Maps a point through a deformation: `src` is the undeformed grid the
/// content was laid on, `dst` the same grid after the effects. The point
/// is found in a src cell (as one of its two triangles) and placed at the
/// same barycentric spot of the dst triangle; points outside every cell
/// keep the nearest cell's mapping (extrapolated).
List<double> warpPoint(List<double> p, List<List<List<double>>> src, List<List<List<double>>> dst) {
  final rows = math.min(src.length, dst.length), cols = rows == 0 ? 0 : math.min(src[0].length, dst[0].length);
  List<double>? bestTri;
  var bestErr = double.infinity;
  late List<List<double>> bd;
  for (var r = 0; r < rows - 1; r++) {
    for (var c = 0; c < cols - 1; c++) {
      for (final t in const [
        [[0, 0], [0, 1], [1, 1]],
        [[0, 0], [1, 1], [1, 0]],
      ]) {
        final s = [for (final o in t) src[r + o[0]][c + o[1]]];
        final w = _bary(p, s[0], s[1], s[2]);
        if (w == null) continue;
        // how far outside the triangle (0 = inside).
        final err = [w[0], w[1], w[2]].fold(0.0, (e, v) => e + (v < 0 ? -v : 0));
        if (err < bestErr) {
          bestErr = err;
          bestTri = w;
          bd = [for (final o in t) dst[r + o[0]][c + o[1]]];
          if (err == 0) {
            return [
              w[0] * bd[0][0] + w[1] * bd[1][0] + w[2] * bd[2][0],
              w[0] * bd[0][1] + w[1] * bd[1][1] + w[2] * bd[2][1],
            ];
          }
        }
      }
    }
  }
  final w = bestTri;
  if (w == null) return p;
  return [
    w[0] * bd[0][0] + w[1] * bd[1][0] + w[2] * bd[2][0],
    w[0] * bd[0][1] + w[1] * bd[1][1] + w[2] * bd[2][1],
  ];
}

List<double>? _bary(List<double> p, List<double> a, List<double> b, List<double> c) {
  final d = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1]);
  if (d.abs() < 1e-12) return null;
  final u = ((b[1] - c[1]) * (p[0] - c[0]) + (c[0] - b[0]) * (p[1] - c[1])) / d;
  final v = ((c[1] - a[1]) * (p[0] - c[0]) + (a[0] - c[0]) * (p[1] - c[1])) / d;
  return [u, v, 1 - u - v];
}
