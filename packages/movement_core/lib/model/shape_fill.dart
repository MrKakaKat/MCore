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
  GlowSample(this.glow, this.a, this.b, this.radius, this.strength);
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
          final b = g.kind == 'line' ? place(_vec(project, g.end, frame, layer)) : a;
          final r = (evaluateTrack(project, g.radius, frame, layer) as double) * side;
          final s = (evaluateTrack(project, g.strength, frame, layer) as double).clamp(0.0, 1.0);
          return GlowSample(g, a, b, math.max(r, 0.0), s);
        }()
  ];
}

int _glowCounter = 0;

/// Adds a glow to the layer (turning the gradient fill on): a point in
/// the middle, or a line across the middle. Returns it.
GlowEmitter addGlow(Layer layer, String kind, {String color = '#ffffff'}) {
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
    for (final s in evaluateGlows(project, layer, globalFrame)) ...[
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
    setTrackValueAt(end == 'b' ? glow.end : glow.position, localFrameOf(layer, globalFrame), [
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
