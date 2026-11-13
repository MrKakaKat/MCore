/// Drawing tab, Fill: a tap fills the region it lands in - bounded by the
/// vector outlines of the other layers as they show (crop, cuts, masks,
/// flips, deformations) and the frame - as a new shape on top.
library;

import '../core/interpolation.dart' show evaluateTrack;
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

/// Whether the layer can bound a fill at `frame` at all.
bool _bounds(Project project, Layer l, int frame) {
  final s = l.content.shape;
  if (l.hidden || s == 'audio' || s == 'camera' || s == 'null' || s == 'trail' || l.mirrorProbe) return false;
  if (!getLayerStateAt(project, l.id, frame).inRange) return false;
  // nothing to see: fully see-through.
  final op = (evaluateTrack(project, l.transform.opacity, layerLocalFrame(l, frame), l) as num).toDouble();
  if (op <= 0.001) return false;
  final c = l.color ?? '';
  if (c == 'transparent' || (c.length == 9 && c.endsWith('00') && !isMediaShape(s) && s != 'text')) return false;
  return true;
}

/// A layer's shape on the frame (frame px rings; null: nothing to bound).
List<PolyRing>? _frameRings(Project project, Layer l, int frame) {
  if (!_bounds(project, l, frame)) return null;
  final m = toFrameMatrix(getLayerStateAt(project, l.id, frame).matrix);
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
FillPlan planFill(Project project, int frame, List<double> p, {Set<String>? only, Set<String> keepOut = const {}}) {
  var region = _frameRect();
  final inside = <Layer>[];
  final outside = <Layer, List<PolyRing>>{};
  for (final l in project.layers) {
    if (only != null && !only.contains(l.id) && !l.drawing) continue;
    if (keepOut.contains(l.id)) continue;
    final rings = _frameRings(project, l, frame);
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
  if (region.isEmpty) return const [];
  // the booleans wind every outer ring one way and every hole the other:
  // the biggest ring is an outer one.
  final biggest = region.reduce((x, y) => _area(x).abs() >= _area(y).abs() ? x : y);
  final outerSign = _area(biggest).sign;
  // the smallest outer ring around the point ...
  PolyRing? mine;
  for (final r in region) {
    if (_area(r).sign != outerSign || windingNumber([r], p[0], p[1]) == 0) continue;
    if (mine == null || _area(r).abs() < _area(mine).abs()) mine = r;
  }
  // (not in any: nothing here - never the other pieces)
  if (mine == null) return const [];
  // ... with the holes inside it that leave the point out.
  return [
    mine,
    for (final r in region)
      if (_area(r).sign != outerSign && windingNumber([mine], r[0][0], r[0][1]) != 0 && windingNumber([r], p[0], p[1]) == 0) r,
  ];
}

/// The region around frame point `p` (see [planFill]).
List<PolyRing> fillRegionAt(Project project, int frame, List<double> p, {Set<String>? only}) =>
    planFill(project, frame, p, only: only).region;

double _area(PolyRing r) {
  var a = 0.0;
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a / 2;
}

/// A fill shape (frame px rings) as a new layer of `color` on top of
/// everything - `dig`: a hole through everything under it instead.
Layer addFillShape(Project project, List<PolyRing> region, String newId, {String color = '#ff8a65', bool dig = false}) {
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
  final layers = project.layers;
  final layer = createLayer('rect')
    ..id = newId
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
  layers.add(layer);
  normalizeTimelineRows(project);
  clearStateCaches();
  return layer;
}
