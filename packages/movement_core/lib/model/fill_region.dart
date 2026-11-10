/// Drawing tab, Fill: a tap fills the region it lands in - bounded only by
/// the edges of other layers (all of them, or only the chosen ones) and
/// the frame - as a new layer of its own.
library;

import '../core/math.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../geometry/contour_layer.dart' show layerDrawnRings;
import '../geometry/polygon_boolean.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;
import 'layer_names.dart';
import 'project.dart';
import 'timeline_rows.dart' show normalizeTimelineRows;

/// A layer's shape on the frame (frame px rings; null: nothing to bound).
List<PolyRing>? _frameRings(Project project, Layer l, int frame) {
  final s = l.content.shape;
  if (l.hidden || s == 'audio' || s == 'camera' || s == 'null' || l.mirrorProbe) return null;
  final st = getLayerStateAt(project, l.id, frame);
  if (!st.inRange) return null;
  final m = toFrameMatrix(st.matrix);
  // what it shows: its exact outline, crop, cuts and flip included.
  final local = layerDrawnRings(project, l, frame);
  if (local == null) return null;
  final rings = [
    for (final r in local)
      if (r.length >= 3) [for (final q in r) applyAffine(m, q)]
  ];
  return rings.isEmpty ? null : rings;
}

/// The region around frame point `p`: inside every layer `p` is in, and
/// outside every other one - the frame where `p` is in none. `only`: just
/// those layers bound it (the rest are as if not there).
List<PolyRing> fillRegionAt(Project project, int frame, List<double> p, {Set<String>? only}) {
  final w = stageSize.width, h = stageSize.height;
  List<PolyRing> region = [
    [
      [0, 0], [w, 0], [w, h], [0, h],
    ]
  ];
  for (final l in project.layers) {
    // only the chosen ones - and the fills drawn so far, always.
    if (only != null && !only.contains(l.id) && !l.drawing) continue;
    final rings = _frameRings(project, l, frame);
    if (rings == null) continue;
    final inside = windingNumber(rings, p[0], p[1]) != 0;
    region = polygonBoolean(region, rings, inside ? BoolOp.intersect : BoolOp.subtract);
    if (region.isEmpty) return const [];
  }
  // only the piece the tap is in (the region can fall apart in pieces):
  // the outer ring around p (not inside another ring), with its holes.
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

double _area(PolyRing r) {
  var a = 0.0;
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a / 2;
}

/// The fill as a new layer (a merged-style shape) of `color` on top -
/// `dig`: a hole through everything under it instead. Null: nothing there.
Layer? addFillLayer(Project project, int frame, List<double> p, String newId,
    {Set<String>? only, String color = '#ff8a65', bool dig = false}) {
  final region = fillRegionAt(project, frame, p, only: only);
  if (region.isEmpty) return null;
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
    ..durationFrames = project.layers.fold<int>(1, (m, l) => m > l.startFrame + l.durationFrames ? m : l.startFrame + l.durationFrames)
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
  project.layers.add(layer);
  normalizeTimelineRows(project);
  clearStateCaches();
  return layer;
}
