/// "Detach a piece" (Crop tab): a part of a layer becomes a layer of its
/// own. Nothing is deleted - the original keeps everything outside the
/// region, the new layer (a copy with the same animation and effects,
/// drawn right above it) keeps everything inside, so at first the picture
/// looks exactly the same; then the piece can be moved, animated or
/// deleted on its own. The region is a rectangle drawn on the stage or
/// the shape of another layer, taken once at the current frame.
library;

import 'dart:math' as math;

import '../core/math.dart';
import '../core/state_cache.dart';
import '../core/interpolation.dart';
import '../core/stage_size.dart';
import '../geometry/piece_outline.dart';
import '../geometry/shapes.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;
import '../ui_geometry/drag_ops.dart' show DragOp;
import '../ui_geometry/snapping.dart' show SnapGuideLine;
import 'layer_names.dart';
import 'line_path.dart' show flipLineNodes, isNodeLine;
import 'project.dart';
import 'timeline_rows.dart' show normalizeTimelineRows;

/// Frame-space points -> `layer`'s content-local space at `globalFrame`.
List<List<double>> frameToLayerLocal(Project project, Layer layer, int globalFrame, List<List<double>> framePts) {
  final inv = invertAffine(toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix));
  return [for (final p in framePts) applyAffine(inv, p)];
}

/// A rectangle dragged on the stage (two frame-space corners) as a
/// region of `layer` (a parallelogram when the layer is rotated).
List<List<double>> rectRegion(Project project, Layer layer, int globalFrame, List<double> a, List<double> b) =>
    frameToLayerLocal(project, layer, globalFrame, [
      [a[0], a[1]],
      [b[0], a[1]],
      [b[0], b[1]],
      [a[0], b[1]],
    ]);

/// The shape of `reference` (its outline after its own effects) at
/// `globalFrame`, as a region of `layer`.
List<List<double>> layerShapeRegion(Project project, Layer layer, Layer reference, int globalFrame) {
  final m = toFrameMatrix(getLayerStateAt(project, reference.id, globalFrame).matrix);
  final outline = getContentOutline(reference.content, reference, globalFrame, project: project);
  return frameToLayerLocal(project, layer, globalFrame, [for (final p in outline) applyAffine(m, p)]);
}

/// Splits `region` (content-local, at least 3 points) off `layer` into a
/// new layer right above it, which is returned. The new layer keeps the
/// original's earlier cuts too, so pieces of pieces work.
Layer? detachPiece(Project project, Layer layer, List<List<double>> region, String newId) {
  if (region.length < 3) return null;
  final pts = [for (final p in region) [...p]];
  final piece = cloneLayer(layer)
    ..id = newId
    ..rowId = null
    ..splitRoot = null;
  piece.name = nextFreeLayerName(project, '${layer.name} part');
  piece.pieceClips.add(PieceClip(points: pts, inside: true));
  layer.pieceClips.add(PieceClip(points: [for (final p in pts) [...p]], inside: false));
  // the piece shares the original's place and time: its own timeline row,
  // drawn over the original.
  project.layers.insert(project.layers.indexOf(layer) + 1, piece);
  // its motion path, pendulum and handles follow its own centre.
  if (recenterDetachedPieces) recenterPiece(project, piece);
  normalizeTimelineRows(project);
  clearStateCaches();
  return piece;
}

/// Settings: a detached piece gets its own origin (anchor) at the centre
/// of its part, so its motion path, rotation, scale and pendulum are about
/// the piece - not about the whole object it came from. Off: the piece
/// keeps the original's origin.
bool recenterDetachedPieces = true;

/// Moves `layer`'s origin to the centre of what is left of it after its
/// cuts, without changing anything on screen at any frame: the content,
/// its cuts and the pendulum grip point shift back by as much, and the
/// position track forward. When the turn or size of the layer (or its
/// parent) is animated the shift differs per frame - then the position
/// gets a key on every frame of the layer. A path-following layer is
/// left as it is (its position comes from the path).
void recenterPiece(Project project, Layer layer) {
  if (layer.transform.pathFollow.enabled) return;
  final box = pieceBoundingBox(layer);
  final c = [(box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2];
  if (c[0].abs() < 1e-9 && c[1].abs() < 1e-9) return;
  final w = stageSize.width, h = stageSize.height;

  // how far the origin moves (in its parent's space, stage fractions) at a
  // global frame: the centre's offset from the origin, turned and scaled
  // like the layer, taken back through the parent's own turn and scale.
  List<double> shiftAt(int globalFrame) {
    final base = getLayerBaseStateAt(project, layer.id, globalFrame);
    final local = matFromTRS(const [0, 0], base.baseRot, base.scale);
    final parent = layer.parentId == null ? const <double>[1, 0, 0, 1, 0, 0] : parentMatrixFor(project, layer, globalFrame);
    final parentLin = [parent[0], parent[1], parent[2], parent[3], 0.0, 0.0];
    final world = applyAffine(matMul(parentLin, local), c); // px
    return applyAffine(invertAffine(parentLin), [world[0] / w, world[1] / h]);
  }

  clearStateCaches();
  final frames = [for (var f = 0; f <= layer.durationFrames; f++) f];
  final shifts = [for (final f in frames) shiftAt(f + layer.startFrame)];
  final constant = shifts.every((d) => (d[0] - shifts.first[0]).abs() < 1e-9 && (d[1] - shifts.first[1]).abs() < 1e-9);
  final anchor = layer.transform.anchor;
  if (constant) {
    final d = shifts.first;
    final v = anchor.defaultValue as List<double>;
    anchor.defaultValue = [v[0] + d[0], v[1] + d[1]];
    for (final k in anchor.keyframes) {
      final kv = k.value as List<double>;
      k.value = [kv[0] + d[0], kv[1] + d[1]];
    }
  } else {
    final values = [
      for (var i = 0; i < frames.length; i++)
        () {
          final a = evaluateTrack(project, anchor, frames[i].toDouble(), layer) as List<double>;
          return [a[0] + shifts[i][0], a[1] + shifts[i][1]];
        }()
    ];
    anchor.keyframes
      ..clear()
      ..addAll([for (var i = 0; i < frames.length; i++) Keyframe(frame: frames[i], value: values[i])]);
    if (anchor.spatial) autoComputeTangents(anchor);
  }
  List<double> back(List<double> p) => [p[0] - c[0], p[1] - c[1]];
  layer.content.offset = back(layer.content.offset);
  for (final clip in layer.pieceClips) {
    clip.points = [for (final p in clip.points) back(p)];
  }
  final pivot = layer.pendulum.pivotOffset;
  pivot.defaultValue = back(pivot.defaultValue as List<double>);
  for (final k in pivot.keyframes) {
    k.value = back(k.value as List<double>);
  }
  if (pivot.spatial) autoComputeTangents(pivot);
  clearStateCaches();
}

/// Crop tab's quick tool: drag a rectangle on the stage over the selected
/// layer; lifting the finger detaches what is inside it.
bool pieceRectTool = false;

/// The rectangle being dragged (frame space). Nothing changes until the
/// finger lifts.
class PieceRectDragOp implements DragOp {
  final Layer layer;
  List<double>? a, b;
  PieceRectDragOp(this.layer);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    a ??= [...framePoint];
    b = [...framePoint];
  }
}

// ===== crop lines =====

/// Crop lines (Crop tab): the area a line drawn over `layer` (its points
/// in content-local space) marks. Closed (3+ points): inside the polygon.
/// Open: everything on the line's left (as drawn), its ends carried on
/// straight far past the layer so the line cuts it right through.
List<List<double>> cutLineRegion(Layer layer, List<List<double>> pts, {required bool closed}) {
  if (pts.length < 2) return const [];
  if (closed) return pts.length >= 3 ? [for (final p in pts) [...p]] : const [];
  // Open: the line, its ends carried on straight out to a big circle
  // around everything, then back along that circle on the line's left -
  // always the same side (only Invert changes it), however the points
  // move.
  final b = shapeBoundingBox(layer.content);
  final cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
  var reach = math.max(b.maxX - b.minX, b.maxY - b.minY);
  for (final p in pts) {
    reach = math.max(reach, math.max((p[0] - cx).abs(), (p[1] - cy).abs()) * 2);
  }
  final r = reach * 4 + 10;
  List<double> dir(List<double> a, List<double> c) {
    final dx = c[0] - a[0], dy = c[1] - a[1];
    final l = math.sqrt(dx * dx + dy * dy);
    return l == 0 ? [1.0, 0.0] : [dx / l, dy / l];
  }

  // where a ray from p along d leaves the circle.
  List<double> exit(List<double> p, List<double> d) {
    final ox = p[0] - cx, oy = p[1] - cy;
    final bq = ox * d[0] + oy * d[1];
    final cq = ox * ox + oy * oy - r * r;
    final t = -bq + math.sqrt(math.max(0, bq * bq - cq));
    return [p[0] + d[0] * t, p[1] + d[1] * t];
  }

  final d0 = dir(pts[1], pts[0]), d1 = dir(pts[pts.length - 2], pts.last);
  final start = exit(pts[0], d0), end = exit(pts.last, d1);
  final aEnd = math.atan2(end[1] - cy, end[0] - cx), aStart = math.atan2(start[1] - cy, start[0] - cx);
  // the left of the line's way (y down) is reached turning the angle
  // down from its end back to its start.
  var sweep = aStart - aEnd;
  while (sweep > 0) {
    sweep -= 2 * math.pi;
  }
  while (sweep <= -2 * math.pi) {
    sweep += 2 * math.pi;
  }
  const n = 48;
  return [
    start,
    for (final p in pts) [...p],
    end,
    for (var i = 1; i < n; i++)
      [cx + r * math.cos(aEnd + sweep * i / n), cy + r * math.sin(aEnd + sweep * i / n)],
  ];
}

/// A tapped crop-line point (frame space) pulled onto what is near: the
/// layer's corners first, then its edge, the frame's corners, edges and
/// middle - within `radius` (frame px).
List<double> snapCropLinePoint(Project project, Layer layer, int globalFrame, List<double> p, double radius) {
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  final outline = [for (final q in getContentOutline(layer.content, layer, globalFrame, project: project)) applyAffine(m, q)];
  double d2(List<double> a, List<double> b) => (a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]);
  final w = stageSize.width, h = stageSize.height;
  final points = [
    ...outline,
    [0.0, 0.0], [w, 0.0], [w, h], [0.0, h], [w / 2, h / 2],
  ];
  List<double>? best;
  var bestD = radius * radius;
  for (final q in points) {
    final d = d2(q, p);
    if (d <= bestD) {
      bestD = d;
      best = q;
    }
  }
  if (best != null) return [...best];
  // an edge: the nearest point along it (a bit tighter).
  bestD = radius * radius * 0.5;
  for (var i = 0; i < outline.length; i++) {
    final a = outline[i], c = outline[(i + 1) % outline.length];
    final dx = c[0] - a[0], dy = c[1] - a[1];
    final l2 = dx * dx + dy * dy;
    if (l2 == 0) continue;
    final t = (((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2).clamp(0.0, 1.0);
    final q = [a[0] + dx * t, a[1] + dy * t];
    final d = d2(q, p);
    if (d <= bestD) {
      bestD = d;
      best = q;
    }
  }
  return best ?? [...p];
}

// ===== the mirror line (Crop tab) =====

/// A point dragged on the stage pulled onto what is near (frame px,
/// within `radius`): the frame's corners, edges' middles and middle, and
/// every visible layer's corners and middle.
List<double> snapStagePoint(Project project, int globalFrame, List<double> p, double radius) {
  final w = stageSize.width, h = stageSize.height;
  final cands = <List<double>>[
    [0, 0], [w, 0], [w, h], [0, h], [w / 2, h / 2],
    [w / 2, 0], [w, h / 2], [w / 2, h], [0, h / 2],
  ];
  for (final l in project.layers) {
    if (l.hidden || l.content.shape == 'audio' || l.content.shape == 'camera') continue;
    final st = getLayerStateAt(project, l.id, globalFrame);
    if (!st.inRange) continue;
    final m = toFrameMatrix(st.matrix);
    final outline = getContentOutline(l.content, l, globalFrame, project: project);
    if (outline.length <= 8) cands.addAll([for (final q in outline) applyAffine(m, q)]);
    cands.add(applyAffine(m, l.content.offset));
  }
  List<double>? best;
  var bestD = radius * radius;
  for (final q in cands) {
    final d = (q[0] - p[0]) * (q[0] - p[0]) + (q[1] - p[1]) * (q[1] - p[1]);
    if (d <= bestD) {
      bestD = d;
      best = q;
    }
  }
  return best == null ? [...p] : [...best];
}

/// The mirror line's end `moved` pulled onto points (above), or else
/// straight / at 45 degrees from the other end `fixed` when close.
List<double> snapMirrorLineEnd(Project project, int globalFrame, List<double> moved, List<double> fixed, double radius) {
  final onPoint = snapStagePoint(project, globalFrame, moved, radius);
  if (onPoint[0] != moved[0] || onPoint[1] != moved[1]) return onPoint;
  final dx = moved[0] - fixed[0], dy = moved[1] - fixed[1];
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-9) return moved;
  final ang = math.atan2(dy, dx);
  const step = math.pi / 4;
  final snapped = (ang / step).round() * step;
  if ((snapped - ang).abs() * len > radius) return moved;
  return [fixed[0] + math.cos(snapped) * len, fixed[1] + math.sin(snapped) * len];
}

/// Mirrors `layer` across the frame line a-b: its place reflected (keys
/// too; a layer under a parent keeps its place), its turn reflected and
/// it is flipped - a line flips its own points.
void mirrorLayerAcross(Layer layer, List<double> a, List<double> b) {
  final dx = b[0] - a[0], dy = b[1] - a[1];
  final len2 = dx * dx + dy * dy;
  if (len2 < 1e-9) return;
  final theta = math.atan2(dy, dx) * 180 / math.pi;
  List<double> reflect(List<double> p) {
    final t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
    final fx = a[0] + dx * t, fy = a[1] + dy * t;
    return [2 * fx - p[0], 2 * fy - p[1]];
  }

  if (layer.parentId == null) {
    final w = stageSize.width, h = stageSize.height;
    List<double> flipAnchor(dynamic v) {
      final q = [...(v as List).map((x) => (x as num).toDouble())];
      final r = reflect([q[0] * w, q[1] * h]);
      return [r[0] / w, r[1] / h, ...q.skip(2)];
    }

    final t = layer.transform.anchor;
    t.defaultValue = flipAnchor(t.defaultValue);
    for (final k in t.keyframes) {
      k.value = flipAnchor(k.value);
    }
  }
  // a reflection = turned by 2*theta - r, then flipped top to bottom.
  final rt = layer.transform.rotation;
  double turn(dynamic v) => 2 * theta - (v as num).toDouble();
  rt.defaultValue = turn(rt.defaultValue);
  for (final k in rt.keyframes) {
    k.value = turn(k.value);
  }
  if (isNodeLine(layer.content)) {
    flipLineNodes(layer.content, horizontal: false);
  } else {
    layer.mirrorY = !layer.mirrorY;
  }
}
