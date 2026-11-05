import 'dart:math' as math;

import '../geometry_effect_registry.dart';

void registerCornerPin() {
  registerEffect(EffectDef(
    id: 'corner_pin',
    name: 'Corner Pin',
    category: 'geometry',
    type: 'vertex',
    params: const [
      ParamDef(key: 'tl', type: 'vec2', defaultValue: [0.0, 0.0]),
      ParamDef(key: 'tr', type: 'vec2', defaultValue: [0.0, 0.0]),
      ParamDef(key: 'br', type: 'vec2', defaultValue: [0.0, 0.0]),
      ParamDef(key: 'bl', type: 'vec2', defaultValue: [0.0, 0.0]),
    ],
    apply: (grid, params, localFrame) {
      // exact-N-point mode: pin points sit AT the shape's own vertices
      // (grid is the single-row [p0..pN-1] list here) - a triangle's 3
      // (affine) or a confirmed polygon's 4 (projective, same Heckbert
      // formula as the bbox mode below, just fed the RAW points directly).
      if (params.containsKey('p0')) {
        final src = grid.expand((row) => row).toList();
        final pKeys = params.keys.where((k) => RegExp(r'^p\d+$').hasMatch(k)).toList()
          ..sort((a, b) => int.parse(a.substring(1)).compareTo(int.parse(b.substring(1))));
        if (src.length != pKeys.length) return grid;
        final dst = [
          for (var i = 0; i < src.length; i++)
            [src[i][0] + (params[pKeys[i]] as List<double>)[0], src[i][1] + (params[pKeys[i]] as List<double>)[1]],
        ];

        if (pKeys.length == 3) {
          // source triangle (x0..y2) vs destination triangle (dstX0..dstY2)
          // - same lower/uppercase source-vs-destination convention as
          // movement-core/src/effects/builtins/cornerPin.js's own
          // [[X0,Y0],[X1,Y1],[X2,Y2]] naming, just prefixed instead of
          // capitalized (Dart lints against non-lowerCamelCase locals).
          final x0 = src[0][0], y0 = src[0][1], x1 = src[1][0], y1 = src[1][1], x2 = src[2][0], y2 = src[2][1];
          final dstX0 = dst[0][0], dstY0 = dst[0][1], dstX1 = dst[1][0], dstY1 = dst[1][1], dstX2 = dst[2][0], dstY2 = dst[2][1];
          final dxa = x1 - x0, dya = y1 - y0, dxb = x2 - x0, dyb = y2 - y0;
          final denom = dxa * dyb - dxb * dya;
          if (denom.abs() < 1e-9) return grid; // degenerate (collinear) triangle
          final dX1 = dstX1 - dstX0, dX2 = dstX2 - dstX0, dY1 = dstY1 - dstY0, dY2 = dstY2 - dstY0;
          final a = (dX1 * dyb - dX2 * dya) / denom;
          final b = (dxa * dX2 - dxb * dX1) / denom;
          final c = (dY1 * dyb - dY2 * dya) / denom;
          final d = (dxa * dY2 - dxb * dY1) / denom;
          final e = dstX0 - a * x0 - b * y0;
          final f = dstY0 - c * x0 - d * y0;
          return [
            for (final row in grid) [for (final p in row) [a * p[0] + b * p[1] + e, c * p[0] + d * p[1] + f]],
          ];
        }

        if (pKeys.length == 4) {
          final p0 = dst[0], p1 = dst[1], p2 = dst[2], p3 = dst[3];
          if (!quadIsConvex(p0, p1, p2, p3)) {
            const uvs = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
            return [
              for (final row in grid)
                [for (var i = 0; i < row.length; i++) quadMap(p0, p1, p2, p3, uvs[i][0], uvs[i][1])],
            ];
          }
          final dx1 = p1[0] - p2[0], dx2 = p3[0] - p2[0], dx3 = p0[0] - p1[0] + p2[0] - p3[0];
          final dy1 = p1[1] - p2[1], dy2 = p3[1] - p2[1], dy3 = p0[1] - p1[1] + p2[1] - p3[1];
          double a, b, c, d, e, f, g, h;
          if (dx3.abs() < 1e-9 && dy3.abs() < 1e-9) {
            a = p1[0] - p0[0]; b = p2[0] - p1[0]; c = p0[0];
            d = p1[1] - p0[1]; e = p2[1] - p1[1]; f = p0[1];
            g = 0; h = 0;
          } else {
            final denom = dx1 * dy2 - dx2 * dy1;
            g = denom == 0 ? 0 : (dx3 * dy2 - dx2 * dy3) / denom;
            h = denom == 0 ? 0 : (dx1 * dy3 - dx3 * dy1) / denom;
            a = p1[0] - p0[0] + g * p1[0]; b = p3[0] - p0[0] + h * p3[0]; c = p0[0];
            d = p1[1] - p0[1] + g * p1[1]; e = p3[1] - p0[1] + h * p3[1]; f = p0[1];
          }
          // u,v assigned by POSITION IN THE ARRAY (point i always plays
          // "corner role i" by construction), not derived from the
          // points' own coordinates/bbox.
          const uvByIndex = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]];
          return [
            for (final row in grid)
              [
                for (var colIdx = 0; colIdx < row.length; colIdx++)
                  () {
                    final u = uvByIndex[colIdx][0], v = uvByIndex[colIdx][1];
                    final denom = g * u + h * v + 1;
                    return [(a * u + b * v + c) / denom, (d * u + e * v + f) / denom];
                  }(),
              ],
          ];
        }
        return grid;
      }

      final all = grid.expand((row) => row).toList();
      final xs = [for (final p in all) p[0]], ys = [for (final p in all) p[1]];
      final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
      final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
      final w = (maxX - minX) == 0 ? 1 : maxX - minX;
      final boxH = (maxY - minY) == 0 ? 1 : maxY - minY;

      final tl = params['tl'] as List<double>, tr = params['tr'] as List<double>;
      final br = params['br'] as List<double>, bl = params['bl'] as List<double>;
      // destination quad corners = natural rect corners + this frame's offsets
      final p0 = [minX + tl[0], minY + tl[1]]; // top-left    <- u=0,v=0
      final p1 = [maxX + tr[0], minY + tr[1]]; // top-right   <- u=1,v=0
      final p2 = [maxX + br[0], maxY + br[1]]; // bottom-right<- u=1,v=1
      final p3 = [minX + bl[0], maxY + bl[1]]; // bottom-left <- u=0,v=1

      // a caved-in (or crossed) quad has no perspective that keeps the
      // shape in one piece - the projective map passes through infinity
      // and the shape flew apart. Blend the corners instead (bilinear).
      if (!quadIsConvex(p0, p1, p2, p3)) {
        return [
          for (final row in grid)
            [for (final p in row) quadMap(p0, p1, p2, p3, (p[0] - minX) / w, (p[1] - minY) / boxH)],
        ];
      }

      // classic unit-square -> arbitrary-quad projective mapping (Heckbert).
      final dx1 = p1[0] - p2[0], dx2 = p3[0] - p2[0], dx3 = p0[0] - p1[0] + p2[0] - p3[0];
      final dy1 = p1[1] - p2[1], dy2 = p3[1] - p2[1], dy3 = p0[1] - p1[1] + p2[1] - p3[1];
      double a, b, c, d, e, f, g, h;
      if (dx3.abs() < 1e-9 && dy3.abs() < 1e-9) {
        a = p1[0] - p0[0]; b = p2[0] - p1[0]; c = p0[0];
        d = p1[1] - p0[1]; e = p2[1] - p1[1]; f = p0[1];
        g = 0; h = 0;
      } else {
        final denom = dx1 * dy2 - dx2 * dy1;
        g = denom == 0 ? 0 : (dx3 * dy2 - dx2 * dy3) / denom;
        h = denom == 0 ? 0 : (dx1 * dy3 - dx3 * dy1) / denom;
        a = p1[0] - p0[0] + g * p1[0]; b = p3[0] - p0[0] + h * p3[0]; c = p0[0];
        d = p1[1] - p0[1] + g * p1[1]; e = p3[1] - p0[1] + h * p3[1]; f = p0[1];
      }

      List<double> warp(List<double> pt) {
        final u = (pt[0] - minX) / w, v = (pt[1] - minY) / boxH;
        final denom = g * u + h * v + 1;
        return [(a * u + b * v + c) / denom, (d * u + e * v + f) / denom];
      }

      return [for (final row in grid) [for (final p in row) warp(p)]];
    },
  ));
}

/// Whether the quad p0 p1 p2 p3 (in order) is convex - every turn the
/// same way, none flat.
bool quadIsConvex(List<double> p0, List<double> p1, List<double> p2, List<double> p3) {
  final q = [p0, p1, p2, p3];
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
    final cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    if (cross.abs() < 1e-9) return false;
    final s = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// The point at (u, v) of the unit square, carried bilinearly onto the
/// quad p0 (0,0) p1 (1,0) p2 (1,1) p3 (0,1).
List<double> bilinearQuad(List<double> p0, List<double> p1, List<double> p2, List<double> p3, double u, double v) => [
      (1 - u) * (1 - v) * p0[0] + u * (1 - v) * p1[0] + u * v * p2[0] + (1 - u) * v * p3[0],
      (1 - u) * (1 - v) * p0[1] + u * (1 - v) * p1[1] + u * v * p2[1] + (1 - u) * v * p3[1],
    ];

/// The point at (u, v) of the unit square on a quad that has no
/// perspective (caved in, or crossed). A caved-in one: two triangles split
/// along the diagonal from its inner corner, each mapped flat - the shape
/// is exactly the quad (blending the corners instead folded it out past
/// the inner corner, a bulge). A crossed one: blended (bilinear).
List<double> quadMap(List<double> p0, List<double> p1, List<double> p2, List<double> p3, double u, double v) {
  final q = [p0, p1, p2, p3];
  const uv = [
    [0.0, 0.0],
    [1.0, 0.0],
    [1.0, 1.0],
    [0.0, 1.0]
  ];
  double cross(int i) {
    final a = q[(i + 3) % 4], b = q[i], c = q[(i + 1) % 4];
    return (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
  }

  final signs = [for (var i = 0; i < 4; i++) cross(i).sign];
  final pos = signs.where((x) => x > 0).length, neg = signs.where((x) => x < 0).length;
  int? inner;
  if (pos == 3 && neg == 1) inner = signs.indexOf(-1);
  if (neg == 3 && pos == 1) inner = signs.indexOf(1);
  if (inner == null) return bilinearQuad(p0, p1, p2, p3, u, v);
  final k = inner, o = (k + 2) % 4;
  // which side of the diagonal k-o (in the square) the point is on.
  final a = uv[k], b = uv[o];
  final side = (b[0] - a[0]) * (v - a[1]) - (b[1] - a[1]) * (u - a[0]);
  final m = (k + 1) % 4, n2 = (k + 3) % 4;
  final sm = (b[0] - a[0]) * (uv[m][1] - a[1]) - (b[1] - a[1]) * (uv[m][0] - a[0]);
  final third = (side >= 0) == (sm >= 0) ? m : n2;
  // barycentric in the square's triangle (k, o, third), then on the quad.
  final t0 = uv[k], t1 = uv[o], t2 = uv[third];
  final d = (t1[1] - t2[1]) * (t0[0] - t2[0]) + (t2[0] - t1[0]) * (t0[1] - t2[1]);
  final w0 = ((t1[1] - t2[1]) * (u - t2[0]) + (t2[0] - t1[0]) * (v - t2[1])) / d;
  final w1 = ((t2[1] - t0[1]) * (u - t2[0]) + (t0[0] - t2[0]) * (v - t2[1])) / d;
  final w2 = 1 - w0 - w1;
  return [
    w0 * q[k][0] + w1 * q[o][0] + w2 * q[third][0],
    w0 * q[k][1] + w1 * q[o][1] + w2 * q[third][1],
  ];
}
