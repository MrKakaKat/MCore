import 'dart:math' as math;

import '../effects/geometry_effect_registry.dart';
import '../model/project.dart';
import '../model/prop_links.dart' show linkOffset;
import '../core/interpolation.dart' show evaluateTrack;
import '../effects/builtins/origami_fold.dart' show origamiFoldLines, origamiScale;
import 'contour.dart' show warpPoint, densifyRing;

/// an image layer's content is placed exactly like a "rect" one
/// (offset/size define its bounding rect) - only the render backend
/// treats the two differently (a decoded bitmap instead of a solid
/// fill). Every geometry function below that special-cases "rect"
/// shares that placement with "image" through this helper, so nothing
/// here needs its own separate image-shaped branch.
/// Picture content (a still image or a video).
/// A project reference draws as a picture too (its rendered frames).
bool isMediaShape(String shape) => shape == 'image' || shape == 'video' || shape == 'projectRef';

/// A sound layer: nothing to draw, nothing to grab on the stage.
bool isAudioShape(String shape) => shape == 'audio';

/// Layers the Chroma tab works on: images, videos and merged shapes.
bool chromaCapable(String shape) => isMediaShape(shape) || shape == 'compound';

/// The stage camera's frame (see model/stage_camera.dart): placed like a
/// rect, never drawn into the picture.
bool isCameraShape(String shape) => shape == 'camera';

/// Content that plays a source over time (Content.sourceIn applies).
bool isTimedMedia(String shape) => shape == 'video' || shape == 'audio';

/// Text and compound shapes are placed by their box the same way.
/// A vector line is a long, thin rectangle (its thickness is its height).
bool isRectLikeShape(String shape) =>
    shape == 'rect' || shape == 'line' || shape == 'image' || shape == 'video' || shape == 'text' || shape == 'textGroup' || shape == 'compound' || shape == 'camera' || shape == 'projectRef';

class BoundingBox {
  final double minX, maxX, minY, maxY;
  const BoundingBox({required this.minX, required this.maxX, required this.minY, required this.maxY});
}

/// a rectangular grid of points spanning `content`'s offset/size, split
/// into `cols` x `rows` cells - the source geometry vertex effects (and
/// the render backend's per-cell warp) deform.
List<List<List<double>>> buildGrid(Content content, int cols, int rows) {
  final offset = content.offset, size = content.size;
  final grid = <List<List<double>>>[];
  for (var r = 0; r < rows; r++) {
    final row = <List<double>>[];
    final y = offset[1] - size[1] / 2 + (size[1] * r) / (rows - 1);
    for (var c = 0; c < cols; c++) {
      final x = offset[0] - size[0] / 2 + (size[0] * c) / (cols - 1);
      row.add([x, y]);
    }
    grid.add(row);
  }
  return grid;
}

// non-rect content shapes: a closed perimeter point list, offset from
// the anchor. deliberately NOT run through applyEffectStack yet - bend
// in particular assumes a row/col grid (its baseAxis/t parametrization
// has no meaning on an arbitrary polygon outline).
List<List<double>> shapePoints(Content content) {
  final shape = content.shape;
  if (shape == 'polygon') {
    return content.points ?? [];
  }
  final r = math.min(content.size[0], content.size[1]) / 2;
  final pts = <List<double>>[];
  if (shape == 'circle') {
    final seg = content.sides ?? 48;
    for (var i = 0; i < seg; i++) {
      final a = i / seg * math.pi * 2;
      pts.add([math.cos(a) * r, math.sin(a) * r]);
    }
  } else if (shape == 'triangle') {
    for (var i = 0; i < 3; i++) {
      final a = -math.pi / 2 + i * (math.pi * 2 / 3);
      pts.add([math.cos(a) * r, math.sin(a) * r]);
    }
  } else if (shape == 'ngon') {
    final n = content.sides ?? 6;
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + i / n * math.pi * 2;
      pts.add([math.cos(a) * r, math.sin(a) * r]);
    }
  }
  return [for (final p in pts) [p[0] + content.offset[0], p[1] + content.offset[1]]];
}

BoundingBox shapeBoundingBox(Content content) {
  // a null is a point; its box (the handles' square) is its size.
  if (isRectLikeShape(content.shape) || content.shape == 'null') {
    final ox = content.offset[0], oy = content.offset[1];
    final w = content.size[0], h = content.size[1];
    return BoundingBox(minX: ox - w / 2, maxX: ox + w / 2, minY: oy - h / 2, maxY: oy + h / 2);
  }
  final pts = shapePoints(content);
  if (pts.isEmpty) return const BoundingBox(minX: 0, maxX: 0, minY: 0, maxY: 0);
  final xs = [for (final p in pts) p[0]], ys = [for (final p in pts) p[1]];
  return BoundingBox(
    minX: xs.reduce(math.min), maxX: xs.reduce(math.max),
    minY: ys.reduce(math.min), maxY: ys.reduce(math.max),
  );
}

// perimeter outline of a layer's content, AFTER its own effect stack -
// used by both track-matte masks and path-follow, both of which need
// "what shape does this layer actually look like right now", not its
// undeformed geometry. `layer`/`globalFrame` are optional so old call
// sites without them still get a sane (undeformed) fallback.
List<List<double>> getContentOutline(Content content, Layer? layer, int? globalFrame, {Project? project}) {
  final hasEffects = layer != null && layer.effectStack.any(isDeformingEffect);

  if (isRectLikeShape(content.shape)) {
    if (hasEffects) {
      const n = 10; // match the render path's subdivision so the boundary follows the same deformed grid
      var grid = buildEffectGrid(layer, content, globalFrame!, project: project, n: n);
      grid = applyEffectStack(layer, grid, globalFrame, project: project);
      final rows = grid.length, cols = grid[0].length;
      return [
        ...grid[0],
        ...grid.sublist(1).map((row) => row[cols - 1]),
        ...grid[rows - 1].sublist(0, cols - 1).reversed,
        ...grid.sublist(0, rows - 1).reversed.map((row) => row[0]),
      ];
    }
    final ox = content.offset[0], oy = content.offset[1];
    final w = content.size[0], h = content.size[1];
    // rounded corners change the shape itself: masks, cuts, the outline,
    // physics and merge all take the rounded one.
    if (layer != null && content.shape == 'rect' && (layer.fill.cornerRadius > 0 || _roundLinked(layer))) {
      final (rx, ry) = cornerRadii(layer, globalFrame, project: project);
      return roundedRectRing(ox, oy, w, h, rx, ry,
          k: layer.fill.cornerShape, corners: layer.fill.cornersOn, each: cornerRadiiEach(layer, globalFrame, project: project));
    }
    return [
      [ox - w / 2, oy - h / 2], [ox + w / 2, oy - h / 2],
      [ox + w / 2, oy + h / 2], [ox - w / 2, oy + h / 2],
    ];
  }

  final pts = layer == null ? shapePoints(content) : layerShapePoints(layer);
  if (hasEffects) {
    // a triangle's exact corner pin works on its own points.
    if (layer.effectStack.any((i) => i.enabled && i.effectId == 'corner_pin' && i.params.containsKey('p0'))) {
      return applyEffectStack(layer, [pts], globalFrame!, project: project)[0];
    }
    return warpRingThroughEffects(layer, content, pts, globalFrame!, project: project);
  }
  return pts;
}

/// A vector outline carried through the layer's deforming effects (mesh
/// warp, bend, squeeze, corner pin, 3D): the effects bend a grid laid on
/// the shape's box, and every point of the (densified) ring follows its
/// cell - the shape stays a sharp vector, whatever its form. With
/// `inherited`, a parent's bend too.
List<List<double>> warpRingThroughEffects(Layer layer, Content content, List<List<double>> ring, int globalFrame,
    {Project? project, bool inherited = false}) {
  final bbox = shapeBoundingBox(content);
  final box = Content(
    shape: 'rect',
    offset: [(bbox.minX + bbox.maxX) / 2, (bbox.minY + bbox.maxY) / 2],
    size: [math.max(1e-6, bbox.maxX - bbox.minX), math.max(1e-6, bbox.maxY - bbox.minY)],
  );
  // point by point effects (origami): the outline goes through them
  // exactly, no grid in between.
  final inherits = inherited && project != null && deformingAncestors(project, layer, globalFrame).isNotEmpty;
  if (deformsPointwise(layer) && !inherits) {
    final diag = math.sqrt(math.pow(box.size[0], 2) + math.pow(box.size[1], 2));
    final dense = ring.length < 3 ? ring : densifyRing(ring, diag / 120);
    return applyEffectStack(layer, [dense], globalFrame, project: project).first;
  }
  final src = buildEffectGrid(layer, box, globalFrame, project: project, n: 10);
  var dst = applyEffectStack(layer, [for (final row in src) [for (final p in row) [...p]]], globalFrame, project: project);
  if (inherited && project != null) dst = applyInheritedDeform(project, layer, dst, globalFrame);
  final diag = math.sqrt(math.pow(box.size[0], 2) + math.pow(box.size[1], 2));
  final dense = ring.length < 3 ? ring : densifyRing(ring, diag / 60);
  return [for (final p in dense) warpPoint(p, src, dst)];
}


/// A rect's rounded-corner radii in its own (unscaled) units: as set, or -
/// keeping them round - divided by the layer's scale on each axis, so on
/// screen they are circles of the radius times the smaller scale.
(double, double) cornerRadii(Layer layer, int? globalFrame, {Project? project}) {
  final each = cornerRadiiEach(layer, globalFrame, project: project);
  // the biggest of the corners (they are all the same without links).
  var best = each.first;
  for (final e in each) {
    if (e.$1 > best.$1) best = e;
  }
  return best;
}

/// Each corner's radii (top left, top right, bottom right, bottom left):
/// the rounding plus what links add to it ('round' all, 'round0'..'round3'
/// one). Kept round when scaled: a circle on the screen, at most half the
/// shorter side as it is drawn - whatever the scale.
List<(double, double)> cornerRadiiEach(Layer layer, int? globalFrame, {Project? project}) {
  final c = layer.content;
  final base = layer.fill.cornerRadius;
  final all = project == null || globalFrame == null || layer.links.isEmpty ? 0.0 : linkOffset(project, layer, 'round', globalFrame);
  final w = c.size[0].abs(), h = c.size[1].abs();
  var sx = 1.0, sy = 1.0;
  if (layer.fill.cornersKeepRound) {
    final f = globalFrame == null ? 0.0 : layerLocalFrame(layer, globalFrame).toDouble();
    final sc = evaluateTrack(project, layer.transform.scale, f, layer) as List;
    sx = (sc[0] as num).toDouble().abs();
    sy = (sc[1] as num).toDouble().abs();
  }
  return [
    for (var i = 0; i < 4; i++)
      () {
        final one = project == null || globalFrame == null || layer.links.isEmpty ? 0.0 : linkOffset(project, layer, 'round$i', globalFrame);
        final r = math.max(0.0, base + all + one);
        if (!layer.fill.cornersKeepRound || sx <= 1e-9 || sy <= 1e-9) {
          return (r.clamp(0.0, w / 2).toDouble(), r.clamp(0.0, h / 2).toDouble());
        }
        // on the screen: the smaller scale's size, up to half the shorter
        // drawn side - then back into the layer's own units.
        final screen = (r * math.min(sx, sy)).clamp(0.0, math.min(w * sx, h * sy) / 2).toDouble();
        return (screen / sx, screen / sy);
      }()
  ];
}

/// A rounded rect's outline: each corner a quarter ellipse (rx, ry) - or
/// each its own (`each`); `corners` off stay sharp.
List<List<double>> roundedRectRing(double cx, double cy, double w, double h, double rx, double ry,
    {int perCorner = 10, double k = 0.5523, List<bool>? corners, List<(double, double)>? each}) {
  final x0 = cx - w / 2, x1 = cx + w / 2, y0 = cy - h / 2, y1 = cy + h / 2;
  final out = <List<double>>[];
  final circle = (k - 0.5523).abs() < 1e-4;
  final pts = [
    [x0, y0],
    [x1, y0],
    [x1, y1],
    [x0, y1]
  ];
  // which way the two sides run from each corner (x, y).
  const dirs = [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)];
  for (var i = 0; i < 4; i++) {
    final (ax, ay) = corners != null && !corners[i] ? (0.0, 0.0) : (each?[i] ?? (rx, ry));
    final p = pts[i];
    if (ax <= 1e-9 || ay <= 1e-9) {
      out.add(p);
      continue;
    }
    final (dx, dy) = dirs[i];
    if (circle) {
      // a quarter ellipse round the corner's centre.
      final ccx = p[0] + dx * ax, ccy = p[1] + dy * ay;
      final a0 = const [math.pi, 1.5 * math.pi, 0.0, 0.5 * math.pi][i];
      for (var j = 0; j <= perCorner; j++) {
        final a = a0 + j / perCorner * math.pi / 2;
        out.add([ccx + ax * math.cos(a), ccy + ay * math.sin(a)]);
      }
    } else {
      // from the side before the corner to the side after it.
      final before = i.isEven ? [p[0], p[1] + dy * ay] : [p[0] + dx * ax, p[1]];
      final after = i.isEven ? [p[0] + dx * ax, p[1]] : [p[0], p[1] + dy * ay];
      out.addAll(roundCornerCurve(before, p, after, k, steps: perCorner));
    }
  }
  return out;
}

/// The curve rounding corner `p` from `t1` (on the way in) to `t2` (on
/// the way out): a bezier whose handles reach `k` of the way to the
/// corner - 0 a straight cut, ~0.55 a circle, 1 the sharp corner.
List<List<double>> roundCornerCurve(List<double> t1, List<double> p, List<double> t2, double k, {int steps = 10}) {
  k = k.clamp(0.0, 1.0);
  final c1 = [t1[0] + (p[0] - t1[0]) * k, t1[1] + (p[1] - t1[1]) * k];
  final c2 = [t2[0] + (p[0] - t2[0]) * k, t2[1] + (p[1] - t2[1]) * k];
  return [
    for (var s = 0; s <= steps; s++)
      () {
        final t = s / steps, u = 1 - t;
        return [
          u * u * u * t1[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * t2[0],
          u * u * u * t1[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * t2[1],
        ];
      }()
  ];
}

/// A closed ring with its corners rounded: the ones bulging out by
/// `convex` px (cut off), the ones pointing in - more than 180 degrees
/// inside - by `concave` px (filled in, adding to the shape). Each corner
/// takes at most half of either side. `k`: the rounding's shape.
List<List<double>> roundRingCorners(List<List<double>> ring, double convex, double concave, {double k = 0.5523}) {
  final n = ring.length;
  if (n < 3 || (convex <= 0 && concave <= 0)) return ring;
  // which way the ring winds: a corner turning the same way bulges out.
  var area = 0.0;
  for (var i = 0; i < n; i++) {
    final a = ring[i], b = ring[(i + 1) % n];
    area += a[0] * b[1] - b[0] * a[1];
  }
  final out = <List<double>>[];
  for (var i = 0; i < n; i++) {
    final a = ring[(i - 1 + n) % n], p = ring[i], b = ring[(i + 1) % n];
    final cross = (p[0] - a[0]) * (b[1] - p[1]) - (p[1] - a[1]) * (b[0] - p[0]);
    final out_ = cross * area > 0; // turns with the ring: a convex corner
    final r = out_ ? convex : concave;
    final la = math.sqrt(math.pow(a[0] - p[0], 2) + math.pow(a[1] - p[1], 2));
    final lb = math.sqrt(math.pow(b[0] - p[0], 2) + math.pow(b[1] - p[1], 2));
    if (r <= 0 || cross.abs() < 1e-9 || la < 1e-9 || lb < 1e-9) {
      out.add(p);
      continue;
    }
    final d = math.min(r, math.min(la, lb) / 2);
    final t1 = [p[0] + (a[0] - p[0]) * d / la, p[1] + (a[1] - p[1]) * d / la];
    final t2 = [p[0] + (b[0] - p[0]) * d / lb, p[1] + (b[1] - p[1]) * d / lb];
    out.addAll(roundCornerCurve(t1, p, t2, k, steps: 8));
  }
  return out;
}

/// A merged shape's contours with the layer's corner rounding (Fill tab):
/// its corners rounded off, its inward corners (where shapes joined)
/// filled round. A hole (a contour going with the one before) has the two
/// the other way round.
List<List<List<double>>> layerContours(Layer layer) {
  final rings = layer.content.contours ?? const <List<List<double>>>[];
  final f = layer.fill;
  if (f.cornerRadius <= 0 && f.outerRadius <= 0) return rings;
  final join = layer.content.contourJoin;
  return [
    for (var i = 0; i < rings.length; i++)
      join != null && join.length == rings.length && join[i]
          ? roundRingCorners(rings[i], f.outerRadius, f.cornerRadius, k: f.cornerShape)
          : roundRingCorners(rings[i], f.cornerRadius, f.outerRadius, k: f.cornerShape)
  ];
}

/// A polygon-like shape's points with the layer's corner rounding (Fill
/// tab): triangles, polygons, stars, imported shapes.
List<List<double>> layerShapePoints(Layer layer) {
  final pts = shapePoints(layer.content);
  final f = layer.fill;
  if (f.cornerRadius <= 0 && f.outerRadius <= 0) return pts;
  if (isRectLikeShape(layer.content.shape) || layer.content.shape == 'circle') return pts;
  return roundRingCorners(pts, f.cornerRadius, f.outerRadius, k: f.cornerShape);
}

/// The shape's own outline, flat (content space): a rect's four corners
/// (its rounded corners too), a polygon's points with their rounding.
List<List<double>> layerFlatOutline(Layer layer, {int? globalFrame, Project? project}) {
  final c = layer.content;
  if (c.shape == 'rect') {
    if (layer.fill.cornerRadius > 0 || _roundLinked(layer)) {
      final (rx, ry) = cornerRadii(layer, globalFrame, project: project);
      return roundedRectRing(c.offset[0], c.offset[1], c.size[0], c.size[1], rx, ry,
          k: layer.fill.cornerShape, corners: layer.fill.cornersOn, each: cornerRadiiEach(layer, globalFrame, project: project));
    }
    final w = c.size[0] / 2, h = c.size[1] / 2;
    return [
      [c.offset[0] - w, c.offset[1] - h], [c.offset[0] + w, c.offset[1] - h],
      [c.offset[0] + w, c.offset[1] + h], [c.offset[0] - w, c.offset[1] + h],
    ];
  }
  return layerShapePoints(layer);
}

/// An outline under origami, in pieces: cut along every crease (the
/// pieces are the paper's parts), each folded point by point and turned
/// back the right way round where its part lies face down - so parts that
/// fold over each other add up instead of cancelling. Holes (a ring the
/// other way round) stay holes. Null when the layer has no origami to do
/// this for (or a parent's deformation joins in).
List<List<List<double>>>? origamiRingPieces(Layer layer, List<List<double>> ring, int globalFrame, {Project? project}) {
  if (!deformsPointwise(layer)) return null;
  if (project != null && deformingAncestors(project, layer, globalFrame).isNotEmpty) return null;
  final lf = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
  final rest = buildGrid(layer.content, 2, 2);
  final bb = shapeBoundingBox(layer.content);
  // the creases on the flat shape, content space.
  final cuts = <(List<double>, List<double>)>[];
  for (final inst in layer.effectStack) {
    if (!inst.enabled || inst.effectId != 'origami_fold' || !effectActiveAt(layer, inst.id, lf)) continue;
    final params = resolveEffectParams(inst, lf)..['_box'] = [bb.minX, bb.minY, bb.maxX, bb.maxY];
    for (final l in origamiFoldLines(params, rest, scale: origamiScale(layer, lf), flat: true)) {
      cuts.add((l.a, l.b));
    }
  }
  final diag = math.sqrt(math.pow(bb.maxX - bb.minX, 2) + math.pow(bb.maxY - bb.minY, 2));
  var cells = <List<List<double>>>[ring];
  for (final (a, b) in cuts) {
    final next = <List<List<double>>>[];
    for (final c in cells) {
      for (final side in const [1.0, -1.0]) {
        final piece = _clipHalfPlane(c, a, b, side);
        if (piece.length >= 3) next.add(piece);
      }
    }
    cells = next;
  }
  final out = <List<List<double>>>[];
  for (final c in cells) {
    final dense = densifyRing(c, diag / 120);
    var mapped = applyEffectStack(layer, [dense], globalFrame, project: project).first;
    // which way round the part lies now: a small triangle inside it.
    final o = _insidePoint(c);
    if (o != null) {
      final e = diag / 1000;
      final tri = applyEffectStack(layer, [
        [o, [o[0] + e, o[1]], [o[0], o[1] + e]]
      ], globalFrame, project: project)
          .first;
      final area = (tri[1][0] - tri[0][0]) * (tri[2][1] - tri[0][1]) - (tri[2][0] - tri[0][0]) * (tri[1][1] - tri[0][1]);
      if (area < 0) mapped = mapped.reversed.toList();
    }
    out.add(mapped);
  }
  return out;
}

/// The part of ring `r` on one side (`side` +1 / -1) of the line a-b.
List<List<double>> _clipHalfPlane(List<List<double>> r, List<double> a, List<double> b, double side) {
  double f(List<double> p) => side * ((b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]));
  final out = <List<double>>[];
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    final fp = f(p), fq = f(q);
    if (fp >= 0) out.add(p);
    if ((fp >= 0) != (fq >= 0)) {
      final t = fp / (fp - fq);
      out.add([p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t]);
    }
  }
  return out;
}

/// A point inside a ring (not on its edge), or null for a sliver.
List<double>? _insidePoint(List<List<double>> r) {
  // the middle of a scanline through the ring's middle height.
  final ys = r.map((p) => p[1]);
  final y = (ys.reduce(math.min) + ys.reduce(math.max)) / 2;
  final xs = <double>[];
  for (var i = 0; i < r.length; i++) {
    final p = r[i], q = r[(i + 1) % r.length];
    if ((p[1] <= y) != (q[1] <= y)) xs.add(p[0] + (y - p[1]) / (q[1] - p[1]) * (q[0] - p[0]));
  }
  if (xs.length < 2) return null;
  xs.sort();
  var best = 0;
  for (var i = 0; i + 1 < xs.length; i += 2) {
    if (xs[i + 1] - xs[i] > xs[best + 1] - xs[best]) best = i;
  }
  return [(xs[best] + xs[best + 1]) / 2, y];
}

bool _roundLinked(Layer layer) => layer.links.any((k) => k.enabled && k.to.startsWith('round'));
