import 'dart:math' as math;
import 'dart:typed_data';

/// Error-diffusion dithering (the "retro" kinds): each pixel rounded to
/// the nearest allowed colour, the error handed on to its neighbours
/// after it, by the kernel's weights.
///
/// `rgba`: straight (not premultiplied) RGBA. `mode`: 'levels' (each
/// channel to `levels` steps), 'mono' (`levels` greys) or 'palette'
/// (`palette`, RGB 0..255 each). Fully clear pixels are left alone and
/// pass no error on. Returns a new buffer.
Uint8List errorDiffuse(
  Uint8List rgba,
  int w,
  int h, {
  required String kernel,
  String mode = 'levels',
  int levels = 2,
  List<List<int>> palette = const [
    [0, 0, 0],
    [255, 255, 255]
  ],
  double bleed = 1,
  bool serpentine = true,
  bool perceptual = false,
  List<int> dark = const [0, 0, 0],
  List<int> light = const [255, 255, 255],
  double colorize = 1,
  double invert = 0,
  double scanlines = 0,
  double? stippleOpacity,
  double softness = 0,
  bool lightenOnly = false,
  double squeeze = 0,
}) {
  final k = _kernels[kernel] ?? _kernels['floyd']!;
  final n = math.max(1, levels - 1);
  final soft = softness.clamp(0.0, 1.0);
  // `v` (0..255) to the steps: the nearest - or, soft, a blend of the two
  // around halfway.
  double step(double v) {
    final x = (v / 255 * n).clamp(0.0, n.toDouble());
    final b = x.floorToDouble(), fr = x - b;
    final w = soft < 1e-3 ? (fr >= 0.5 ? 1.0 : 0.0) : _smooth(0.5 - soft / 2, 0.5 + soft / 2, fr);
    return math.min(b + w, n.toDouble()) / n * 255;
  }

  final k2 = k;
  // working values (with the errors added), 0..255 floats.
  final r = Float32List(w * h), g = Float32List(w * h), b = Float32List(w * h);
  final inv = invert.clamp(0.0, 1.0);
  for (var i = 0; i < w * h; i++) {
    // (two colours: squeezed on the brightness only, below)
    final sq = mode == 'duo' ? 1.0 : 1 - squeeze.clamp(0.0, 1.0);
    var vr = (rgba[i * 4] - 127.5) * sq + 127.5, vg = (rgba[i * 4 + 1] - 127.5) * sq + 127.5;
    var vb = (rgba[i * 4 + 2] - 127.5) * sq + 127.5;
    if (inv > 0) {
      vr += (255 - 2 * vr) * inv;
      vg += (255 - 2 * vg) * inv;
      vb += (255 - 2 * vb) * inv;
    }
    r[i] = vr;
    g[i] = vg;
    b[i] = vb;
  }
  final out = Uint8List.fromList(rgba);
  final wr = perceptual ? 0.299 : 1.0, wg = perceptual ? 0.587 : 1.0, wb = perceptual ? 0.114 : 1.0;
  for (var y = 0; y < h; y++) {
    final back = serpentine && y.isOdd;
    for (var xi = 0; xi < w; xi++) {
      final x = back ? w - 1 - xi : xi;
      final i = y * w + x;
      if (rgba[i * 4 + 3] == 0) continue;
      final cr = r[i].clamp(0.0, 255.0), cg = g[i].clamp(0.0, 255.0), cb = b[i].clamp(0.0, 255.0);
      double qr, qg, qb;
      if (mode == 'palette' && palette.isNotEmpty) {
        var best = palette.first;
        var bestD = double.infinity;
        for (final p in palette) {
          final dr = cr - p[0], dg = cg - p[1], db = cb - p[2];
          final d = wr * dr * dr + wg * dg * dg + wb * db * db;
          if (d < bestD) {
            bestD = d;
            best = p;
          }
        }
        qr = best[0].toDouble();
        qg = best[1].toDouble();
        qb = best[2].toDouble();
        if (soft > 1e-3 && palette.length > 1) {
          // the next nearest, and how far toward it along between the two
          List<int>? second;
          var secondD = double.infinity;
          for (final p in palette) {
            if (identical(p, best)) continue;
            final dr = cr - p[0], dg = cg - p[1], db = cb - p[2];
            final d = wr * dr * dr + wg * dg * dg + wb * db * db;
            if (d < secondD) {
              secondD = d;
              second = p;
            }
          }
          if (second != null) {
            final dx = second[0] - qr, dy = second[1] - qg, dz = second[2] - qb;
            final len = dx * dx + dy * dy + dz * dz;
            final f = len < 1e-6 ? 0.0 : (((cr - qr) * dx + (cg - qg) * dy + (cb - qb) * dz) / len).clamp(0.0, 1.0);
            final w = _smooth(0.5 - soft / 2, 0.5 + soft / 2, f);
            qr += dx * w;
            qg += dy * w;
            qb += dz * w;
          }
        }
      } else if (mode == 'duo') {
        // the brightness in steps, laid between the two colours; the
        // picture's own colours kept as much as `colorize` leaves.
        final l = (0.299 * cr + 0.587 * cg + 0.114 * cb - 127.5) * (1 - squeeze.clamp(0.0, 1.0)) + 127.5;
        final q = step(l) / 255;
        final k = colorize.clamp(0.0, 1.0);
        final keep = l > 0.5 ? q * 255 / l : 0.0;
        qr = cr * keep * (1 - k) + (dark[0] + (light[0] - dark[0]) * q) * k;
        qg = cg * keep * (1 - k) + (dark[1] + (light[1] - dark[1]) * q) * k;
        qb = cb * keep * (1 - k) + (dark[2] + (light[2] - dark[2]) * q) * k;
        // the error is the brightness's (what was rounded).
        final e = (l - q * 255) * bleed;
        out[i * 4] = qr.round().clamp(0, 255);
        out[i * 4 + 1] = qg.round().clamp(0, 255);
        out[i * 4 + 2] = qb.round().clamp(0, 255);
        for (final (dx, dy, wgt) in k2.taps) {
          final nx = back ? x - dx : x + dx, ny = y + dy;
          if (nx < 0 || nx >= w || ny >= h) continue;
          final j = ny * w + nx;
          if (rgba[j * 4 + 3] == 0) continue;
          final f = wgt / k2.sum;
          r[j] += e * f;
          g[j] += e * f;
          b[j] += e * f;
        }
        continue;
      } else if (mode == 'mono') {
        final l = 0.299 * cr + 0.587 * cg + 0.114 * cb;
        qr = qg = qb = step(l);
      } else {
        qr = step(cr);
        qg = step(cg);
        qb = step(cb);
      }
      out[i * 4] = qr.round();
      out[i * 4 + 1] = qg.round();
      out[i * 4 + 2] = qb.round();
      // (grey: the error of the grey, on all three)
      double er, eg, eb;
      if (mode == 'mono') {
        final e = (0.299 * cr + 0.587 * cg + 0.114 * cb) - qr;
        er = eg = eb = e * bleed;
      } else {
        er = (cr - qr) * bleed;
        eg = (cg - qg) * bleed;
        eb = (cb - qb) * bleed;
      }
      for (final (dx, dy, wgt) in k.taps) {
        final nx = back ? x - dx : x + dx, ny = y + dy;
        if (nx < 0 || nx >= w || ny >= h) continue;
        final j = ny * w + nx;
        if (rgba[j * 4 + 3] == 0) continue;
        final f = wgt / k.sum;
        r[j] += er * f;
        g[j] += eg * f;
        b[j] += eb * f;
      }
    }
  }
  // only lighter: a darkening turned into the same lightening.
  if (lightenOnly) {
    for (var i = 0; i < w * h; i++) {
      if (rgba[i * 4 + 3] == 0) continue;
      for (var c = 0; c < 3; c++) {
        // (the colour the pixel had, inverted if asked - before errors)
        var o = rgba[i * 4 + c].toDouble();
        if (inv > 0) o += (255 - 2 * o) * inv;
        final d = out[i * 4 + c] - o;
        out[i * 4 + c] = (o + d.abs()).round().clamp(0, 255);
      }
    }
  }
  // screen rows: every other one darker.
  if (scanlines > 0) {
    final keep = 1 - 0.45 * scanlines.clamp(0.0, 1.0);
    for (var y = 1; y < h; y += 2) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        out[i] = (out[i] * keep).round();
        out[i + 1] = (out[i + 1] * keep).round();
        out[i + 2] = (out[i + 2] * keep).round();
      }
    }
  }
  // opacity as dots: where the 8x8 grid is above it, the plain picture.
  final so = stippleOpacity;
  if (so != null && so < 1) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (bayer8(x, y) < so) continue;
        final i = (y * w + x) * 4;
        out[i] = rgba[i];
        out[i + 1] = rgba[i + 1];
        out[i + 2] = rgba[i + 2];
      }
    }
  }
  return out;
}

double _smooth(double a, double b, double x) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// The 8x8 ordered threshold at (x, y), 0..1.
double bayer8(int x, int y) {
  var v = 0;
  for (var bit = 0; bit < 3; bit++) {
    final xb = (x >> bit) & 1, yb = (y >> bit) & 1;
    v = (v << 2) | (((xb ^ yb) << 1) | yb);
  }
  // (bits interleaved from the coarsest down: reverse the order)
  var r = 0;
  for (var i = 0; i < 3; i++) {
    r = (r << 2) | ((v >> (i * 2)) & 3);
  }
  return (r + 0.5) / 64;
}

class _Kernel {
  final List<(int, int, double)> taps;
  final double sum;
  const _Kernel(this.taps, this.sum);
}

const _kernels = <String, _Kernel>{
  'floyd': _Kernel([(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)], 16),
  // passes on only 6/8 of the error: lighter, more contrast.
  'atkinson': _Kernel([(1, 0, 1), (2, 0, 1), (-1, 1, 1), (0, 1, 1), (1, 1, 1), (0, 2, 1)], 8),
  'jarvis': _Kernel([
    (1, 0, 7), (2, 0, 5), //
    (-2, 1, 3), (-1, 1, 5), (0, 1, 7), (1, 1, 5), (2, 1, 3),
    (-2, 2, 1), (-1, 2, 3), (0, 2, 5), (1, 2, 3), (2, 2, 1),
  ], 48),
  'stucki': _Kernel([
    (1, 0, 8), (2, 0, 4), //
    (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2),
    (-2, 2, 1), (-1, 2, 2), (0, 2, 4), (1, 2, 2), (2, 2, 1),
  ], 42),
  'burkes': _Kernel([(1, 0, 8), (2, 0, 4), (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2)], 32),
  'sierra': _Kernel([
    (1, 0, 5), (2, 0, 3), //
    (-2, 1, 2), (-1, 1, 4), (0, 1, 5), (1, 1, 4), (2, 1, 2),
    (-1, 2, 2), (0, 2, 3), (1, 2, 2),
  ], 32),
  'sierralite': _Kernel([(1, 0, 2), (-1, 1, 1), (0, 1, 1)], 4),
};
