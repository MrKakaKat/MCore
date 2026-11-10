import 'dart:math' as math;

import '../core/interpolation.dart';
import '../core/math.dart';
import '../core/state_cache.dart';
import '../geometry/shapes.dart';
import '../ui_geometry/drag_ops.dart';
import '../ui_geometry/handles.dart';
import '../ui_geometry/snapping.dart';
import 'project.dart';
import 'track_edit.dart';

/// The selected layer's glow handles show on the stage (the Fill tab sets
/// this while it is open).
bool glowHandlesVisible = false;

/// Shapes a gradient fill applies to: vector shapes drawn in one colour
/// (not images / video, not text, which has its own colours).
bool supportsShapeFill(Layer layer) {
  final s = layer.content.shape;
  return !isMediaShape(s) && s != 'text';
}

/// How a glow fades with distance: `t` is distance / radius; full at 0,
/// nothing from 1 on, with no hard edge at either end.
double glowFalloff(double t) {
  if (t >= 1) return 0;
  if (t <= 0) return 1;
  final u = 1 - t * t;
  return u * u;
}

/// A glow evaluated at one frame, in the layer's content-local space.
class GlowSample {
  final GlowEmitter glow;
  final List<double> a, b; // b == a for a point
  final double radius;
  final double strength;

  /// A guided glow's guide line (its point moves only along it).
  final List<double>? guideA, guideB;
  GlowSample(this.glow, this.a, this.b, this.radius, this.strength, {this.guideA, this.guideB});
}

List<double> _vec(Project? project, Track t, double frame, Layer layer) {
  final v = evaluateTrack(project, t, frame, layer);
  return v is List ? [for (final x in v) (x as num).toDouble()] : [0.5, 0.5];
}

/// The layer's enabled glows at `globalFrame` (empty unless the gradient
/// fill is on), positions mapped from box fractions into content space.
List<GlowSample> evaluateGlows(Project? project, Layer layer, num globalFrame) {
  if (!layer.fill.active) return const [];
  final frame = layerLocalFrame(layer, globalFrame);
  final box = shapeBoundingBox(layer.content);
  final w = box.maxX - box.minX, h = box.maxY - box.minY;
  final side = math.max(w, h);
  List<double> place(List<double> f) => [box.minX + f[0] * w, box.minY + f[1] * h];
  return [
    for (final g in layer.fill.glows)
      if (g.enabled)
        () {
          final a = place(_vec(project, g.position, frame, layer));
          final r = (evaluateTrack(project, g.radius, frame, layer) as double) * side;
          final s = (evaluateTrack(project, g.strength, frame, layer) as double).clamp(0.0, 1.0);
          if (g.kind == 'guided') {
            final e = place(_vec(project, g.end, frame, layer));
            final t = (evaluateTrack(project, g.along, frame, layer) as num).toDouble().clamp(0.0, 1.0);
            final p = [a[0] + (e[0] - a[0]) * t, a[1] + (e[1] - a[1]) * t];
            return GlowSample(g, p, p, math.max(r, 0.0), s, guideA: a, guideB: e);
          }
          final b = g.kind == 'line' ? place(_vec(project, g.end, frame, layer)) : a;
          return GlowSample(g, a, b, math.max(r, 0.0), s);
        }()
  ];
}

int _glowCounter = 0;

/// Adds a glow to the layer (turning the gradient fill on): a point in
/// the middle, or a line across the middle. Returns it.
GlowEmitter addGlow(Layer layer, String kind, {String color = '#ffffff'}) {
  if (kind == 'guided') {
    // across the middle, its ends on the shape's edge.
    final ends = _edgeAcross(layer, [0.5, 0.5], 0);
    final g = GlowEmitter(
      id: 'glow_${DateTime.now().microsecondsSinceEpoch}_${_glowCounter++}',
      kind: kind,
      color: color,
      position: track(ends.$1, true),
      end: track(ends.$2, true),
      radius: track(0.35),
    );
    layer.fill.gradient = true;
    layer.fill.glows.add(g);
    return g;
  }
  final g = GlowEmitter(
    id: 'glow_${DateTime.now().microsecondsSinceEpoch}_${_glowCounter++}',
    kind: kind,
    color: color,
    position: track(kind == 'line' ? [0.2, 0.5] : [0.5, 0.5], true),
    end: track([0.8, 0.5], true),
    radius: track(kind == 'line' ? 0.25 : 0.5),
  );
  layer.fill.gradient = true;
  layer.fill.glows.add(g);
  return g;
}

/// The shape's outline (content-local) and its bounding box.
({List<List<double>> outline, double minX, double minY, double w, double h}) _shapeEdge(Layer layer) {
  final box = shapeBoundingBox(layer.content);
  final outline = getContentOutline(layer.content, layer, layer.startFrame);
  return (outline: outline, minX: box.minX, minY: box.minY, w: box.maxX - box.minX, h: box.maxY - box.minY);
}

/// The nearest point of the shape's edge to `local` (content space).
List<double> _nearestOnEdge(List<List<double>> outline, List<double> local) {
  if (outline.length < 2) return local;
  List<double>? best;
  var bestD = double.infinity;
  for (var i = 0; i < outline.length; i++) {
    final a = outline[i], b = outline[(i + 1) % outline.length];
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len2 = dx * dx + dy * dy;
    final t = len2 == 0 ? 0.0 : (((local[0] - a[0]) * dx + (local[1] - a[1]) * dy) / len2).clamp(0.0, 1.0);
    final p = [a[0] + dx * t, a[1] + dy * t];
    final d = math.pow(p[0] - local[0], 2) + math.pow(p[1] - local[1], 2);
    if (d < bestD) {
      bestD = d.toDouble();
      best = p;
    }
  }
  return best ?? local;
}

/// The line through `center` (box fractions) at `angle` (radians) cut
/// by the shape's edge: its two ends, box fractions.
(List<double>, List<double>) _edgeAcross(Layer layer, List<double> center, double angle) {
  final e = _shapeEdge(layer);
  if (e.w <= 0 || e.h <= 0) return ([0.0, 0.5], [1.0, 0.5]);
  final c = [e.minX + center[0] * e.w, e.minY + center[1] * e.h];
  final d = [math.cos(angle), math.sin(angle)];
  var tMin = double.infinity, tMax = -double.infinity;
  final o = e.outline;
  for (var i = 0; i < o.length; i++) {
    final a = o[i], b = o[(i + 1) % o.length];
    final sx = b[0] - a[0], sy = b[1] - a[1];
    final den = d[0] * sy - d[1] * sx;
    if (den.abs() < 1e-12) continue;
    final t = ((a[0] - c[0]) * sy - (a[1] - c[1]) * sx) / den;
    final u = ((a[0] - c[0]) * d[1] - (a[1] - c[1]) * d[0]) / den;
    if (u < 0 || u > 1) continue;
    tMin = math.min(tMin, t);
    tMax = math.max(tMax, t);
  }
  if (!tMin.isFinite || !tMax.isFinite) return ([0.0, 0.5], [1.0, 0.5]);
  List<double> frac(double t) => [(c[0] + d[0] * t - e.minX) / e.w, (c[1] + d[1] * t - e.minY) / e.h];
  return (frac(tMin), frac(tMax));
}

/// Stage handles of a layer's glows, in frame space: `key` is
/// '<glow id>:a' (the point / line start) or '<glow id>:b' (line end).
class GlowHandle {
  final GlowEmitter glow;
  final String key;
  final String end; // 'a' | 'b'
  final List<double> screen;
  GlowHandle(this.glow, this.end, this.screen) : key = '${glow.id}:$end';
}

List<GlowHandle> getGlowHandles(Project project, Layer layer, int globalFrame) {
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  return [
    for (final s in evaluateGlows(project, layer, globalFrame))
      if (s.glow.kind == 'guided') ...[
        GlowHandle(s.glow, 'a', applyAffine(m, s.guideA!)),
        GlowHandle(s.glow, 'b', applyAffine(m, s.guideB!)),
        GlowHandle(s.glow, 'c', applyAffine(m, s.a)),
      ] else ...[
        GlowHandle(s.glow, 'a', applyAffine(m, s.a)),
        if (s.glow.kind == 'line') GlowHandle(s.glow, 'b', applyAffine(m, s.b)),
      ]
  ];
}

/// The glow's radius drawn on the stage: the content-space circle (point)
/// or capsule outline (line) mapped to frame space.
List<List<double>> glowOutline(Project project, Layer layer, GlowSample s, int globalFrame) {
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  final dx = s.b[0] - s.a[0], dy = s.b[1] - s.a[1];
  final base = math.atan2(dy, dx);
  final pts = <List<double>>[];
  for (final (c, from) in [(s.b, base - math.pi / 2), (s.a, base + math.pi / 2)]) {
    for (var i = 0; i <= 24; i++) {
      final ang = from + math.pi * i / 24;
      pts.add(applyAffine(m, [c[0] + s.radius * math.cos(ang), c[1] + s.radius * math.sin(ang)]));
    }
  }
  return pts;
}

/// Drags one end of a glow on the stage (keyed by the usual rule, see
/// setTrackValueAt).
class GlowDragOp implements DragOp {
  final Layer layer;
  final GlowEmitter glow;
  final String end;
  final List<double> grabDelta; // content-space grab point minus the handle
  GlowDragOp({required this.layer, required this.glow, required this.end, required this.grabDelta});

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
    final local = applyAffine(invertAffine(m), framePoint);
    final box = shapeBoundingBox(layer.content);
    final w = box.maxX - box.minX, h = box.maxY - box.minY;
    if (w <= 0 || h <= 0) return;
    final lf = localFrameOf(layer, globalFrame);
    if (glow.kind == 'guided') {
      final p = [local[0] - grabDelta[0], local[1] - grabDelta[1]];
      final ga = evaluateTrack(project, glow.position, lf.toDouble(), layer) as List, gb = evaluateTrack(project, glow.end, lf.toDouble(), layer) as List;
      final a = [box.minX + (ga[0] as num) * w, box.minY + (ga[1] as num) * h];
      final b = [box.minX + (gb[0] as num) * w, box.minY + (gb[1] as num) * h];
      if (end == 'c') {
        // the point: only along its line.
        final dx = b[0] - a[0], dy = b[1] - a[1];
        final len2 = dx * dx + dy * dy;
        final t = len2 == 0 ? 0.0 : (((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2).clamp(0.0, 1.0);
        setTrackValueAt(glow.along, lf, t);
        return;
      }
      // an end: stays on the shape's edge.
      final q = _nearestOnEdge(_shapeEdge(layer).outline, p);
      setTrackValueAt(end == 'b' ? glow.end : glow.position, lf, [(q[0] - box.minX) / w, (q[1] - box.minY) / h]);
      return;
    }
    setTrackValueAt(end == 'b' ? glow.end : glow.position, lf, [
      (local[0] - grabDelta[0] - box.minX) / w,
      (local[1] - grabDelta[1] - box.minY) / h,
    ]);
  }

  factory GlowDragOp.grab(Project project, Layer layer, GlowHandle handle, int globalFrame, List<double> grabFramePoint) {
    final inv = invertAffine(toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix));
    final grab = applyAffine(inv, grabFramePoint);
    final at = applyAffine(inv, handle.screen);
    return GlowDragOp(layer: layer, glow: handle.glow, end: handle.end, grabDelta: [grab[0] - at[0], grab[1] - at[1]]);
  }
}
