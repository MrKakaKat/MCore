/// Chroma key for image layers: makes pixels close to a key colour
/// transparent. Pure pixel math on straight (non-premultiplied) RGBA
/// bytes, so it runs and is tested without Flutter.
///
/// Closeness is measured mostly on colour (the Cb/Cr chroma plane), with
/// a smaller brightness term so a grey or black key still works:
/// - inside `strength` of the key -> fully transparent,
/// - between that and `strength + softness` -> a soft edge,
/// - further away -> untouched.
/// With scope 'region' only pixels inside the drawn closed region are
/// keyed; everything outside it stays as it is.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/math.dart';
import '../core/state_cache.dart';
import '../geometry/shapes.dart';
import '../model/project.dart';
import '../ui_geometry/drag_ops.dart';
import '../ui_geometry/handles.dart';
import '../ui_geometry/snapping.dart';

/// Parses '#RRGGBB' -> [r, g, b] (0..255), or null.
List<int>? parseRgbHex(String? hex) {
  if (hex == null) return null;
  final t = hex.replaceFirst('#', '');
  if (t.length != 6) return null;
  final v = int.tryParse(t, radix: 16);
  if (v == null) return null;
  return [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
}

String rgbHex(int r, int g, int b) =>
    '#${((r << 16) | (g << 8) | b).toRadixString(16).padLeft(6, '0')}';

List<double> _ycc(double r, double g, double b) => [
      0.299 * r + 0.587 * g + 0.114 * b,
      -0.168736 * r - 0.331264 * g + 0.5 * b,
      0.5 * r - 0.418688 * g - 0.081312 * b,
    ];

/// How far a colour is from the key, 0 (same) .. about 1.
double chromaDistance(List<int> rgb, List<int> key) {
  final a = _ycc(rgb[0] / 255, rgb[1] / 255, rgb[2] / 255);
  final k = _ycc(key[0] / 255, key[1] / 255, key[2] / 255);
  final dy = (a[0] - k[0]) * 0.5, dcb = a[1] - k[1], dcr = a[2] - k[2];
  return math.sqrt(dy * dy + dcb * dcb + dcr * dcr) / 0.72;
}

double _smoothstep(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Keys `rgba` (straight RGBA, `width` x `height`) in place.
/// `mask`, when given, is one byte per pixel: only non-zero pixels are keyed.
void applyChromaKey(
  Uint8List rgba,
  int width,
  int height, {
  required List<int> key,
  required double strength,
  required double softness,
  Uint8List? mask,
}) {
  final inner = strength.clamp(0.0, 1.0) * 0.5;
  final outer = inner + softness.clamp(0.0, 1.0) * 0.4 + 1e-4;
  final k = _ycc(key[0] / 255, key[1] / 255, key[2] / 255);
  final n = width * height;
  for (var i = 0; i < n; i++) {
    if (mask != null && mask[i] == 0) continue;
    final o = i * 4;
    final a = rgba[o + 3];
    if (a == 0) continue;
    final c = _ycc(rgba[o] / 255, rgba[o + 1] / 255, rgba[o + 2] / 255);
    final dy = (c[0] - k[0]) * 0.5, dcb = c[1] - k[1], dcr = c[2] - k[2];
    final d = math.sqrt(dy * dy + dcb * dcb + dcr * dcr) / 0.72;
    if (d >= outer) continue;
    rgba[o + 3] = (a * _smoothstep(inner, outer, d)).round();
  }
}

/// A one-byte-per-pixel mask of the closed polygon `uv` (points as
/// fractions 0..1 of the image), even-odd filled along pixel centres.
Uint8List regionMask(List<List<double>> uv, int width, int height) {
  final mask = Uint8List(width * height);
  if (uv.length < 3) return mask;
  final pts = [for (final p in uv) [p[0] * width, p[1] * height]];
  final xs = <double>[];
  for (var y = 0; y < height; y++) {
    final cy = y + 0.5;
    xs.clear();
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      if ((a[1] <= cy && b[1] > cy) || (b[1] <= cy && a[1] > cy)) {
        xs.add(a[0] + (cy - a[1]) / (b[1] - a[1]) * (b[0] - a[0]));
      }
    }
    xs.sort();
    for (var i = 0; i + 1 < xs.length; i += 2) {
      final from = math.max(0, (xs[i] - 0.5).ceil());
      final to = math.min(width - 1, (xs[i + 1] - 0.5).floor());
      for (var x = from; x <= to; x++) {
        mask[y * width + x] = 1;
      }
    }
  }
  return mask;
}

/// The average colour of the 3x3 pixels around (u, v) (fractions 0..1).
List<int> sampleRgb(Uint8List rgba, int width, int height, double u, double v) {
  final cx = (u * width).floor().clamp(0, width - 1), cy = (v * height).floor().clamp(0, height - 1);
  var r = 0, g = 0, b = 0, n = 0;
  for (var y = cy - 1; y <= cy + 1; y++) {
    for (var x = cx - 1; x <= cx + 1; x++) {
      if (x < 0 || y < 0 || x >= width || y >= height) continue;
      final o = (y * width + x) * 4;
      if (rgba[o + 3] == 0) continue;
      r += rgba[o];
      g += rgba[o + 1];
      b += rgba[o + 2];
      n++;
    }
  }
  if (n == 0) return [0, 0, 0];
  return [(r / n).round(), (g / n).round(), (b / n).round()];
}

/// One key's "how much stays" per pixel (1 kept .. 0 removed), with its
/// extras: connected-only (from the seed), grow, invert, feather, region.
Float32List chromaKeepMap(Uint8List rgba, int width, int height, ChromaKey k) {
  final n = width * height;
  final keep = Float32List(n)..fillRange(0, n, 1);
  final key = parseRgbHex(k.color) ?? const [0, 255, 0];
  final inner = k.strength.clamp(0.0, 1.0) * 0.5;
  final outer = inner + k.softness.clamp(0.0, 1.0) * 0.4 + 1e-4;
  final kc = _ycc(key[0] / 255, key[1] / 255, key[2] / 255);
  for (var i = 0; i < n; i++) {
    final o = i * 4;
    if (rgba[o + 3] == 0) continue;
    final c = _ycc(rgba[o] / 255, rgba[o + 1] / 255, rgba[o + 2] / 255);
    final dy = (c[0] - kc[0]) * 0.5, dcb = c[1] - kc[1], dcr = c[2] - kc[2];
    final d = math.sqrt(dy * dy + dcb * dcb + dcr * dcr) / 0.72;
    if (d < outer) keep[i] = _smoothstep(inner, outer, d);
  }
  // connected only: what the picked colour reaches from the seed without
  // crossing other colours.
  final seed = k.seed;
  if (k.contiguous && seed != null) {
    final sx = (seed[0] * width).floor().clamp(0, width - 1), sy = (seed[1] * height).floor().clamp(0, height - 1);
    final reached = Uint8List(n);
    final start = sy * width + sx;
    if (keep[start] < 1) {
      final stack = <int>[start];
      reached[start] = 1;
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        final x = i % width, y = i ~/ width;
        for (final j in [if (x > 0) i - 1, if (x < width - 1) i + 1, if (y > 0) i - width, if (y < height - 1) i + width]) {
          if (reached[j] == 0 && keep[j] < 1) {
            reached[j] = 1;
            stack.add(j);
          }
        }
      }
    }
    for (var i = 0; i < n; i++) {
      if (reached[i] == 0) keep[i] = 1;
    }
  }
  if (k.expand > 0) _minFilter(keep, width, height, k.expand.round());
  if (k.invert) {
    for (var i = 0; i < n; i++) {
      keep[i] = 1 - keep[i];
    }
  }
  if (k.feather > 0) _boxBlur(keep, width, height, k.feather.round());
  // (the "inside region" scope was removed - every key acts on the whole
  // picture, "connected only" covers picking one part.)
  return keep;
}

/// Grows the low (removed) values by `r` pixels: a running minimum, rows
/// then columns.
void _minFilter(Float32List v, int w, int h, int r) {
  if (r <= 0) return;
  final tmp = Float32List(v.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var m = 1.0;
      for (var dx = math.max(0, x - r); dx <= math.min(w - 1, x + r); dx++) {
        m = math.min(m, v[y * w + dx]);
      }
      tmp[y * w + x] = m;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var m = 1.0;
      for (var dy = math.max(0, y - r); dy <= math.min(h - 1, y + r); dy++) {
        m = math.min(m, tmp[dy * w + x]);
      }
      v[y * w + x] = m;
    }
  }
}

/// A box blur of radius `r`, rows then columns (running sums).
void _boxBlur(Float32List v, int w, int h, int r) {
  if (r <= 0) return;
  final tmp = Float32List(v.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0, c = 0;
      for (var dx = math.max(0, x - r); dx <= math.min(w - 1, x + r); dx++) {
        s += v[y * w + dx];
        c++;
      }
      tmp[y * w + x] = s / c;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var s = 0.0, c = 0;
      for (var dy = math.max(0, y - r); dy <= math.min(h - 1, y + r); dy++) {
        s += tmp[dy * w + x];
        c++;
      }
      v[y * w + x] = s / c;
    }
  }
}

/// Every submitted (and not hidden) key and the one being edited, as one
/// "how much stays" map.
Float32List chromaKeepAll(Uint8List rgba, int width, int height, ChromaKey ck) {
  final keep = Float32List(width * height)..fillRange(0, width * height, 1);
  for (final k in [...ck.applied, ck]) {
    if (!k.enabled) continue;
    final m = chromaKeepMap(rgba, width, height, k);
    for (var i = 0; i < keep.length; i++) {
      keep[i] *= m[i];
    }
  }
  return keep;
}

/// Keys a copy of the image according to the layer's settings: every
/// submitted (and not hidden) key, then the one being edited.
Uint8List chromaKeyedCopy(Uint8List rgba, int width, int height, ChromaKey ck) {
  final out = Uint8List.fromList(rgba);
  final keep = chromaKeepAll(rgba, width, height, ck);
  for (var i = 0; i < keep.length; i++) {
    out[i * 4 + 3] = (rgba[i * 4 + 3] * keep[i]).round();
  }
  return out;
}

/// Edge matte ("colour to alpha"): a picture shot on a background of
/// colour `matte` (black: light things on black - lightens; white: dark
/// things on white - darkens) gets that colour taken out: each pixel
/// becomes as see-through as it is close to the matte, its colour freed
/// of it - glows and soft edges keep their light without a dark (or pale)
/// fringe. `strength` 0..1 goes from untouched to all the way.
void colorToAlpha(Uint8List rgba, int width, int height, List<int> matte, double strength) {
  final s = strength.clamp(0.0, 1.0);
  if (s == 0) return;
  final m = [for (final v in matte) v / 255];
  for (var i = 0; i < width * height; i++) {
    final o = i * 4;
    final a0 = rgba[o + 3];
    if (a0 == 0) continue;
    var an = 0.0;
    for (var c = 0; c < 3; c++) {
      final v = rgba[o + c] / 255, mc = m[c];
      final t = v > mc ? (mc >= 1 ? 0.0 : (v - mc) / (1 - mc)) : v < mc ? (mc <= 0 ? 0.0 : (mc - v) / mc) : 0.0;
      if (t > an) an = t;
    }
    final ae = 1 - s + s * an;
    if (ae <= 0) {
      rgba[o + 3] = 0;
      continue;
    }
    for (var c = 0; c < 3; c++) {
      final v = rgba[o + c] / 255;
      rgba[o + c] = ((m[c] + (v - m[c]) / ae).clamp(0.0, 1.0) * 255).round();
    }
    rgba[o + 3] = (a0 * ae).round();
  }
}

/// The contrast view: exactly what is kept, white, and what is removed,
/// black (opaque, the image's own transparency counts as removed).
Uint8List chromaMatte(Uint8List rgba, int width, int height, ChromaKey ck) {
  final keep = chromaKeepAll(rgba, width, height, ck);
  final out = Uint8List(rgba.length);
  for (var i = 0; i < keep.length; i++) {
    final v = (255 * keep[i] * rgba[i * 4 + 3] / 255).round();
    out[i * 4] = v;
    out[i * 4 + 1] = v;
    out[i * 4 + 2] = v;
    out[i * 4 + 3] = 255;
  }
  return out;
}

/// "Submit": the edited key joins the removed colours and the editor
/// starts fresh for the next colour. False when there's nothing to submit.
bool submitChromaKey(ChromaKey ck) {
  if (!ck.enabled) return false;
  ck.applied.add(ck.copy()
    ..applied = []
    ..enabled = true);
  // the editor is free for the next colour (off until one is picked: it
  // would key the same colour twice); its settings stay for it - only
  // invert goes back.
  ck
    ..enabled = false
    ..invert = false;
  return true;
}

/// Content-local point -> image fraction (u, v), undoing the layer's
/// mirror so the region and the eyedropper follow what's on screen.
List<double> contentLocalToImageUv(Layer layer, List<double> local) {
  final b = shapeBoundingBox(layer.content);
  final w = b.maxX - b.minX, h = b.maxY - b.minY;
  var u = w == 0 ? 0.5 : (local[0] - b.minX) / w;
  var v = h == 0 ? 0.5 : (local[1] - b.minY) / h;
  if (layer.mirrorX) u = 1 - u;
  if (layer.mirrorY) v = 1 - v;
  return [u, v];
}

/// The inverse of contentLocalToImageUv.
List<double> imageUvToContentLocal(Layer layer, List<double> uv) {
  final b = shapeBoundingBox(layer.content);
  final u = layer.mirrorX ? 1 - uv[0] : uv[0];
  final v = layer.mirrorY ? 1 - uv[1] : uv[1];
  return [b.minX + u * (b.maxX - b.minX), b.minY + v * (b.maxY - b.minY)];
}

/// Stage tool for the Chroma tab: 'none' | 'pick' (tap = eyedropper) |
/// 'region' (drag = draw the closed region).
String chromaTool = 'none';

/// Frame point -> the layer's image fraction (u, v) at `globalFrame`.
List<double> framePointToImageUv(Project project, Layer layer, int globalFrame, List<double> framePoint) {
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  return contentLocalToImageUv(layer, applyAffine(invertAffine(m), framePoint));
}

/// Freehand region drawing (Chroma tab, tool 'region'): collects the
/// finger's path as image fractions. Nothing is written to the layer
/// while drawing - the caller commits `points` when the finger lifts, so
/// the (costly) keying runs once, not on every move.
class ChromaRegionDragOp implements DragOp {
  final Layer layer;
  final List<List<double>> points = [];
  ChromaRegionDragOp(this.layer);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final uv = framePointToImageUv(project, layer, globalFrame, framePoint);
    final p = [uv[0].clamp(0.0, 1.0), uv[1].clamp(0.0, 1.0)];
    if (points.isNotEmpty) {
      final last = points.last;
      if ((p[0] - last[0]).abs() < 0.004 && (p[1] - last[1]).abs() < 0.004) return;
    }
    points.add(p);
  }
}

/// Eyedropper drag (Chroma tab, tool 'pick'): follows the finger; the
/// colour under it is taken when the finger lifts. The stage shows a
/// loupe above the finger meanwhile.
class ChromaPickDragOp implements DragOp {
  final Layer layer;
  List<double>? framePoint;
  ChromaPickDragOp(this.layer);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) => this.framePoint = framePoint;
}
