import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';

/// Layer contours, cached (geometry/contour.dart does the work).
///
/// - Vector content (shapes, text): computed on demand, kept until its
///   key (content + settings) changes.
/// - Raster content (images, video frames): extracted off the UI thread
///   from the source pixels at a working size; one entry per source frame
///   in an LRU with a fixed budget. While a frame's contour isn't ready,
///   the layer's last contour is held (like video frames are).
/// - Nothing is extracted unless something asks (an Outline effect, the
///   debug view).
class ContourCache {
  ContourCache({this.budget = 96, this.workSize = 512});

  final int budget;
  final int workSize;

  final LinkedHashMap<String, Contour> _lru = LinkedHashMap();
  final Set<String> _pending = {};
  final Map<String, Contour> _held = {};

  // the HUD line: extractions and cache hits in the last second, and the
  // last extraction's time.
  final List<int> _extractions = [], _hits = [];
  double lastExtractionMs = 0;

  // raster extractions in the isolate: the last 20 round trips (spawn,
  // copy, extract, copy back), as measured on this device.
  final List<double> _isolateMs = [];

  ({int extractions, int hits, double ms, double? isolateAvgMs, double? isolateLastMs}) stats() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _extractions.removeWhere((t) => now - t > 1000);
    _hits.removeWhere((t) => now - t > 1000);
    return (
      extractions: _extractions.length,
      hits: _hits.length,
      ms: lastExtractionMs,
      isolateAvgMs: _isolateMs.isEmpty ? null : _isolateMs.reduce((a, b) => a + b) / _isolateMs.length,
      isolateLastMs: _isolateMs.isEmpty ? null : _isolateMs.last,
    );
  }

  /// How many contours were computed in total (tests).
  int computed = 0;

  Contour? _get(String key) {
    final c = _lru.remove(key);
    if (c == null) return null;
    _lru[key] = c; // most recent
    _hits.add(DateTime.now().millisecondsSinceEpoch);
    return c;
  }

  void _put(String key, Contour c) {
    _lru[key] = c;
    while (_lru.length > budget) {
      _lru.remove(_lru.keys.first);
    }
  }

  /// A vector layer's contour (content-local).
  Contour vector(String key, Contour Function() compute) {
    final hit = _get(key);
    if (hit != null) return hit;
    final sw = Stopwatch()..start();
    final c = compute();
    _note(sw);
    _put(key, c);
    return c;
  }

  void _note(Stopwatch sw) {
    lastExtractionMs = sw.elapsedMicroseconds / 1000;
    _extractions.add(DateTime.now().millisecondsSinceEpoch);
    computed++;
  }

  /// A raster layer's contour (content-local): the cached one for `key`,
  /// or - while it's being extracted - the layer's last one (null at
  /// first). `onReady` runs once a new one is in.
  Contour? raster({
    required String layerId,
    required String key,
    required Future<({Uint8List rgba, int width, int height})?> Function() pixels,
    required List<double> offset,
    required List<double> size,
    required ContourParams params,
    List<double>? crop,
    void Function()? onReady,
  }) {
    final hit = _get(key);
    if (hit != null) return _held[layerId] = hit;
    if (_pending.add(key)) {
      () async {
        try {
          final px = await pixels();
          if (px == null) return;
          final sw = Stopwatch()..start();
          final work = workSize;
          // the content rect's units per source pixel: the offset param
          // is in layer pixels, the extraction works in mask pixels.
          final c = await _extractOffThread(px.rgba, px.width, px.height, work, offset, size, params, crop);
          _note(sw);
          _isolateMs.add(lastExtractionMs);
          if (_isolateMs.length > 20) _isolateMs.removeAt(0);
          _put(key, c);
          _held[layerId] = c;
          onReady?.call();
        } finally {
          _pending.remove(key);
        }
      }();
    }
    return _held[layerId];
  }

  /// The layer's last contour (while a new one isn't ready).
  Contour? held(String layerId) => _held[layerId];

  void clear() {
    _lru.clear();
    _held.clear();
  }
}

// its own function: the isolate closure must capture only plain data
// (a closure inside raster() would carry the renderer along).
Future<Contour> _extractOffThread(Uint8List rgba, int sw, int sh, int work, List<double> offset, List<double> size,
        ContourParams p, List<double>? crop) =>
    Isolate.run(() => _extractFromRgba(rgba, sw, sh, work, offset, size, p, crop));

/// Source RGBA -> alpha mask at most `work` px on its longer side ->
/// contour, mapped into the content rect (centre `offset`, `size`).
/// `crop`: the kept box [minX, minY, maxX, maxY] in content units - the
/// mask is empty outside it, so the outline runs along the cut (and a
/// grown one grows past it).
Contour _extractFromRgba(Uint8List rgba, int sw, int sh, int work, List<double> offset, List<double> size,
    ContourParams p, [List<double>? crop]) {
  final k = math.min(1.0, work / math.max(sw, sh));
  final w = math.max(1, (sw * k).round()), h = math.max(1, (sh * k).round());
  final perPx = size[0] / w; // content units per mask pixel
  final grow = perPx == 0 ? 0.0 : p.offset / perPx;
  // a border, so a grown outline isn't cut at the picture's edge.
  final pad = grow > 0 ? grow.ceil() + 2 : 1;
  final pw = w + 2 * pad, ph = h + 2 * pad;
  final mask = AlphaMask(pw, ph);
  // box-average the source alpha into each mask pixel.
  for (var y = 0; y < h; y++) {
    final y0 = (y * sh / h).floor(), y1 = math.max(y0 + 1, ((y + 1) * sh / h).floor());
    for (var x = 0; x < w; x++) {
      final x0 = (x * sw / w).floor(), x1 = math.max(x0 + 1, ((x + 1) * sw / w).floor());
      var sum = 0, n = 0;
      for (var yy = y0; yy < y1 && yy < sh; yy++) {
        for (var xx = x0; xx < x1 && xx < sw; xx++) {
          sum += rgba[(yy * sw + xx) * 4 + 3];
          n++;
        }
      }
      if (crop != null) {
        final cx = offset[0] - size[0] / 2 + (x + 0.5) * size[0] / w;
        final cy = offset[1] - size[1] / 2 + (y + 0.5) * size[1] / h;
        if (cx < crop[0] || cx > crop[2] || cy < crop[1] || cy > crop[3]) continue;
      }
      mask.a[(y + pad) * pw + x + pad] = n == 0 ? 0 : sum / (n * 255);
    }
  }
  final c = extractContour(
      mask,
      ContourParams(
          threshold: p.threshold,
          simplify: p.simplify,
          smooth: p.smooth,
          minAreaFraction: p.minAreaFraction * (w * h) / (pw * ph),
          offset: grow));
  final left = offset[0] - size[0] / 2, top = offset[1] - size[1] / 2;
  return c.map((q) => [left + (q[0] - pad) * size[0] / w, top + (q[1] - pad) * size[1] / h]);
}
