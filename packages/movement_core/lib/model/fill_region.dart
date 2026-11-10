/// Drawing tab, Fill: a tap fills the region it lands in - bounded only by
/// the edges of other layers (all of them, or only the chosen ones) and
/// the frame - as a new layer of its own.
///
/// Vector edges are the layers' own geometry. Raster edges (pictures, and
/// in "vector by pixel edges" also whatever has no vector look) come from
/// the app as frame rings of their opaque core (`raster`): the fill runs
/// on under their soft edge and is placed under them, so at every edge
/// pixel the picture's alpha n shows n of the picture and 1 - n of the
/// fill - no seam. Layers bounding the fill from above get a small bleed
/// under them as well (`bleed`, frame px) for the same reason.
library;

import 'dart:typed_data';

import '../core/math.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../geometry/contour_layer.dart' show layerDrawnRings;
import '../geometry/polygon_boolean.dart';
import '../geometry/shapes.dart' show isMediaShape;
import '../ui_geometry/handles.dart' show toFrameMatrix;
import 'layer_names.dart';
import 'project.dart';
import 'timeline_rows.dart' show normalizeTimelineRows;

/// Frame rings of a layer from somewhere else (the app's pixel contours);
/// null: use its vector geometry.
typedef FillRingsOverride = List<PolyRing>? Function(Layer layer);

/// Whether the layer can bound a fill at `frame` at all.
bool _bounds(Project project, Layer l, int frame) {
  final s = l.content.shape;
  if (l.hidden || s == 'audio' || s == 'camera' || s == 'null' || l.mirrorProbe) return false;
  return getLayerStateAt(project, l.id, frame).inRange;
}

/// A layer's shape on the frame (frame px rings; null: nothing to bound).
List<PolyRing>? _frameRings(Project project, Layer l, int frame, FillRingsOverride? raster) {
  if (!_bounds(project, l, frame)) return null;
  final m = toFrameMatrix(getLayerStateAt(project, l.id, frame).matrix);
  final over = raster?.call(l);
  if (over != null) {
    // pixel contours carry crop and mirror; the detached cuts go on top.
    var rings = [for (final r in over) if (r.length >= 3) r];
    for (final cut in l.pieceClips) {
      if (cut.points.length < 3 || rings.isEmpty) continue;
      rings = polygonBoolean(rings, [
        [for (final q in cut.points) applyAffine(m, q)]
      ], cut.inside ? BoolOp.intersect : BoolOp.subtract);
    }
    return rings.isEmpty ? null : rings;
  }
  // what it shows: its exact outline, crop, cuts and flip included.
  final local = layerDrawnRings(project, l, frame);
  if (local == null) return null;
  final rings = [
    for (final r in local)
      if (r.length >= 3) [for (final q in r) applyAffine(m, q)]
  ];
  return rings.isEmpty ? null : rings;
}

List<PolyRing> _frameRect() {
  final w = stageSize.width, h = stageSize.height;
  return [
    [
      [0, 0], [w, 0], [w, h], [0, h],
    ]
  ];
}

/// The fill's region and what bounds it: the layers `p` is inside of, and
/// the layers left out of it (with their rings).
class FillPlan {
  final List<PolyRing> region;
  final List<Layer> inside;
  final Map<Layer, List<PolyRing>> outside;
  FillPlan(this.region, this.inside, this.outside);
}

/// The region around frame point `p`: inside every layer `p` is in, and
/// outside every other one - the frame where `p` is in none. `only`: just
/// those layers bound it (and the fills drawn before; the rest are as if
/// not there). `keepOut`: layers that bound nothing here (handled by the
/// fill's own mask instead).
FillPlan planFill(Project project, int frame, List<double> p,
    {Set<String>? only, FillRingsOverride? raster, Set<String> keepOut = const {}}) {
  var region = _frameRect();
  final inside = <Layer>[];
  final outside = <Layer, List<PolyRing>>{};
  for (final l in project.layers) {
    if (only != null && !only.contains(l.id) && !l.drawing) continue;
    if (keepOut.contains(l.id)) continue;
    final rings = _frameRings(project, l, frame, raster);
    if (rings == null) continue;
    final isIn = windingNumber(rings, p[0], p[1]) != 0;
    if (isIn) {
      inside.add(l);
    } else {
      outside[l] = rings;
    }
    region = polygonBoolean(region, rings, isIn ? BoolOp.intersect : BoolOp.subtract);
    if (region.isEmpty) return FillPlan(const [], inside, outside);
  }
  return FillPlan(_pieceAt(region, p), inside, outside);
}

/// Only the piece of `region` the point is in (it can fall apart in
/// pieces): the outer ring around p (not inside another ring), with its
/// holes.
List<PolyRing> _pieceAt(List<PolyRing> region, List<double> p) {
  int depth(PolyRing r) => [
        for (final o in region)
          if (!identical(o, r) && windingNumber([o], r[0][0], r[0][1]) != 0) o
      ].length;
  final outers = [for (final r in region) if (depth(r).isEven) r];
  PolyRing? mine;
  for (final r in outers) {
    if (windingNumber([r], p[0], p[1]) != 0 && (mine == null || _area(r).abs() < _area(mine).abs())) mine = r;
  }
  if (mine == null) return region;
  return [
    mine,
    for (final r in region)
      if (!identical(r, mine) && depth(r).isOdd && windingNumber([mine], r[0][0], r[0][1]) != 0) r,
  ];
}

/// The region around frame point `p` (see [planFill]).
List<PolyRing> fillRegionAt(Project project, int frame, List<double> p,
        {Set<String>? only, FillRingsOverride? raster}) =>
    planFill(project, frame, p, only: only, raster: raster).region;

double _area(PolyRing r) {
  var a = 0.0;
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a / 2;
}

/// The fill as a new layer (a merged-style shape) of `color` - `dig`: a
/// hole through everything under it instead. Null: nothing there.
///
/// Where it goes: above the layers it is inside of, and right under the
/// lowest of the layers bounding it from outside (their edges then cover
/// its own); `bleed` px of it reach on under those. `overPictures`: the
/// pictures bounding it don't cut it - it goes over them, and each one
/// takes itself out of the fill as a mask by its alpha (1 - n).
Layer? addFillLayer(Project project, int frame, List<double> p, String newId,
    {Set<String>? only,
    String color = '#ff8a65',
    bool dig = false,
    FillRingsOverride? raster,
    double bleed = 0,
    bool overPictures = false}) {
  final pictures = overPictures
      ? {
          for (final l in project.layers)
            if (isMediaShape(l.content.shape) && _bounds(project, l, frame)) l.id
        }
      : <String>{};
  final plan = planFill(project, frame, p, only: only, raster: raster, keepOut: pictures);
  var region = plan.region;
  if (region.isEmpty) return null;
  final layers = project.layers;
  // the layers left out that actually border it (within 2 px).
  final near = offsetRings(region, 2, join: OffsetJoin.round);
  final touching = [
    for (final e in plan.outside.entries)
      if (polygonBoolean(near, e.value, BoolOp.intersect).isNotEmpty) e.key
  ];
  final insideTop = plan.inside.map(layers.indexOf).fold(-1, (a, b) => a > b ? a : b);
  final above = [for (final l in touching) if (layers.indexOf(l) > insideTop) layers.indexOf(l)]..sort();
  var at = above.isEmpty ? layers.length : above.first;
  // over the pictures: above every one it meets.
  final masked = <String>[];
  if (overPictures) {
    for (final id in pictures) {
      final l = layers.firstWhere((x) => x.id == id);
      final rings = _frameRings(project, l, frame, raster);
      if (rings == null || polygonBoolean(near, rings, BoolOp.intersect).isEmpty) continue;
      masked.add(id);
      if (layers.indexOf(l) + 1 > at) at = layers.indexOf(l) + 1;
    }
  }
  // the bleed: on under the bounding layers drawn above it only (a
  // containing shape under it, or a bound under it, must not be crossed).
  if (bleed > 0) {
    var allowed = _frameRect();
    for (final l in plan.inside) {
      allowed = polygonBoolean(allowed, _frameRings(project, l, frame, raster)!, BoolOp.intersect);
    }
    for (final e in plan.outside.entries) {
      if (layers.indexOf(e.key) < at) allowed = polygonBoolean(allowed, e.value, BoolOp.subtract);
    }
    final grown = polygonBoolean(offsetRings(region, bleed, join: OffsetJoin.round), allowed, BoolOp.intersect);
    final piece = _pieceAt(grown, p);
    if (piece.isNotEmpty) region = piece;
  }
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final r in region) {
    for (final q in r) {
      if (q[0] < minX) minX = q[0];
      if (q[1] < minY) minY = q[1];
      if (q[0] > maxX) maxX = q[0];
      if (q[1] > maxY) maxY = q[1];
    }
  }
  final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  final layer = createLayer('rect')
    ..id = newId
    // a hole cuts by the fill's shape: drawn solid (it never shows).
    ..color = dig ? '#000000' : color
    ..dig = dig
    ..drawing = true
    ..startFrame = 0
    ..durationFrames = layers.fold<int>(1, (m, l) => m > l.startFrame + l.durationFrames ? m : l.startFrame + l.durationFrames)
    ..content = Content(
      shape: 'compound',
      offset: [0, 0],
      size: [maxX - minX, maxY - minY],
      contours: [
        for (final r in region) [for (final q in r) [q[0] - cx, q[1] - cy]]
      ],
    );
  layer.transform.anchor.defaultValue = [cx / stageSize.width, cy / stageSize.height];
  layer.name = nextFreeLayerName(project, 'Fill');
  // over a picture: it takes itself out by its alpha.
  for (final id in masked) {
    layer.masks.add(Mask(mode: 'subtract', sourceLayerId: id));
  }
  layers.insert(at.clamp(0, layers.length), layer);
  normalizeTimelineRows(project);
  clearStateCaches();
  return layer;
}

/// Fill, all pixels: the pixels reached from (x0, y0) through touching
/// pixels (4 ways) whose colour and alpha are each within `tolerance`
/// (0..255) of the first one's; `grow` px more all round (under the
/// edges). 1 = filled, 0 = not; w x h.
Uint8List floodFillMask(Uint8List rgba, int w, int h, int x0, int y0, int tolerance, {int grow = 0}) {
  final mask = Uint8List(w * h);
  final s = (y0 * w + x0) * 4;
  final r0 = rgba[s], g0 = rgba[s + 1], b0 = rgba[s + 2], a0 = rgba[s + 3];
  bool near(int i) {
    final k = i * 4;
    return (rgba[k] - r0).abs() <= tolerance &&
        (rgba[k + 1] - g0).abs() <= tolerance &&
        (rgba[k + 2] - b0).abs() <= tolerance &&
        (rgba[k + 3] - a0).abs() <= tolerance;
  }

  final stack = Int32List(w * h);
  var top = 0;
  stack[top++] = y0 * w + x0;
  mask[y0 * w + x0] = 1;
  while (top > 0) {
    final i = stack[--top];
    final x = i % w, y = i ~/ w;
    for (final j in [if (x > 0) i - 1, if (x < w - 1) i + 1, if (y > 0) i - w, if (y < h - 1) i + w]) {
      if (mask[j] == 0 && near(j)) {
        mask[j] = 1;
        stack[top++] = j;
      }
    }
  }
  for (var g = 0; g < grow; g++) {
    final was = Uint8List.fromList(mask);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (was[y * w + x] == 1) continue;
        var any = false;
        for (var dy = -1; dy <= 1 && !any; dy++) {
          for (var dx = -1; dx <= 1 && !any; dx++) {
            final nx = x + dx, ny = y + dy;
            if (nx >= 0 && ny >= 0 && nx < w && ny < h && was[ny * w + nx] == 1) any = true;
          }
        }
        if (any) mask[y * w + x] = 1;
      }
    }
  }
  return mask;
}
