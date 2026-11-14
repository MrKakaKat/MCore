/// Origami fold lines on the stage: shown across the selected layer (also
/// at angle 0, so where a fold will be is visible) on the folded paper,
/// past the shape's edge. Each has a dot in its middle (drag it along the
/// fold's way: its position) and one at its end (turn it: its direction).
library;

import 'dart:math' as math;

import '../core/math.dart' show applyAffine, invertAffine, snapToStops;
import '../effects/builtins/origami_fold.dart';
import '../geometry/shapes.dart' show buildGrid, layerFlatOutline;
import '../model/project.dart';
import '../model/track_edit.dart' show setTrackValueAt, localFrameOf;
import '../effects/geometry_effect_registry.dart' show resolveEffectParams, applyEffectsAfter, applyEffectStack;
import 'drag_ops.dart' show DragOp;
import 'handles.dart' show getTransformBoxHandles;
import 'snapping.dart' show SnapGuideLine;

/// The layer's Origami effects, enabled.
List<EffectInstance> origamiInstances(Layer layer) =>
    [for (final i in layer.effectStack) if (i.enabled && i.effectId == 'origami_fold') i];

Map<String, dynamic> _params(Layer layer, EffectInstance inst, double lf) {
  final b = layerBox(layer);
  return resolveEffectParams(inst, lf)..['_box'] = b;
}

/// The layer's own box [minX, minY, maxX, maxY] (what the creases are
/// measured on).
List<double> layerBox(Layer layer) {
  final g = buildGrid(layer.content, 2, 2);
  final xs = g.expand((r) => r).map((p) => p[0]), ys = g.expand((r) => r).map((p) => p[1]);
  return [xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max)];
}

/// Every fold line of the layer in frame space: which effect, fold and
/// position param, its ends (the turn handle at `b`), its middle (the
/// move handle) and its points (it can bend on folded paper).
List<({EffectInstance inst, int n, String key, List<double> a, List<double> b, List<double> mid, List<List<double>> pts})>
    origamiFoldLinesFrame(Project project, Layer layer, int globalFrame) {
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final rest = buildGrid(layer.content, 2, 2);
  final lf = localFrameOf(layer, globalFrame).toDouble();
  final sc = origamiScale(layer, lf);
  return [
    for (final inst in origamiInstances(layer))
      for (final l in origamiFoldLines(_params(layer, inst, lf), rest, scale: sc))
        () {
          // carried by the effects after the fold too (a tilt).
          final after = applyEffectsAfter(layer, inst.id, [...l.pts, if (origamiFoldFrame(_params(layer, inst, lf), rest, l.n, scale: sc) case final fr?) fr.mid],
              globalFrame, project: project);
          final pts = [for (final q in after.take(l.pts.length)) applyAffine(m, q)];
          final mid = after.length > l.pts.length ? applyAffine(m, after.last) : pts[pts.length ~/ 2];
          return (inst: inst, n: l.n, key: l.key, a: pts.first, b: pts.last, mid: mid, pts: pts);
        }()
  ];
}

/// The turn handles: one at the end of each fold's line.
List<({EffectInstance inst, int n, List<double> p})> origamiDirectionHandlesFrame(
        Project project, Layer layer, int globalFrame) =>
    [for (final l in origamiFoldLinesFrame(project, layer, globalFrame)) (inst: l.inst, n: l.n, p: l.b)];

/// On screen (frame px): the crease's middle, and one rest unit along its
/// folding way and along the crease.
({List<double> mid, List<double> along, List<double> side})? _frameOf(
    Project project, Layer layer, EffectInstance inst, int n, int globalFrame) {
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final lf = localFrameOf(layer, globalFrame).toDouble();
  final fr = origamiFoldFrame(_params(layer, inst, lf), buildGrid(layer.content, 2, 2), n, scale: origamiScale(layer, lf));
  if (fr == null) return null;
  return (mid: applyAffine(m, fr.mid), along: applyAffine(m, fr.along), side: applyAffine(m, fr.side));
}

Track? _trackOf(EffectInstance inst, String key) {
  final t = inst.params[key];
  if (t is Track) return t;
  if (t is num) return inst.params[key] = Track(t.toDouble(), false);
  return null;
}

double _valueOf(Track t, int f) {
  final k = t.keyframes.where((k) => k.frame == f).firstOrNull;
  return ((k?.value ?? t.defaultValue) as num).toDouble();
}

/// Drags one fold line along its fold's way: the finger's move on the
/// screen, measured along the crease's way as it is drawn (folded paper
/// too). It sticks at the quarters, the middle and the shape's corners.
class OrigamiFoldDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  final String key;
  final int n;
  OrigamiFoldDragOp(this.layer, this.inst, this.key, [this.n = 1]);

  List<double>? _start;
  double? _startValue;
  ({List<double> mid, List<double> along, List<double> side})? _frame;

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final lf = localFrameOf(layer, globalFrame);
    final t = _trackOf(inst, key);
    if (t == null) return;
    if (_start == null) {
      _start = framePoint;
      _startValue = _valueOf(t, lf);
      _frame = _frameOf(project, layer, inst, n, globalFrame);
    }
    final fr = _frame;
    final params = _params(layer, inst, lf.toDouble());
    final rest = buildGrid(layer.content, 2, 2);
    final sc = origamiScale(layer, lf.toDouble());
    double v;
    if (fr == null) {
      final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
      v = origamiPositionAt(params, rest, applyAffine(invertAffine(m), framePoint), scale: sc, n: n);
    } else {
      // a rest unit along the fold's way, as drawn: the finger's move
      // projected on it (the fold's way points back toward the rest).
      final ux = fr.mid[0] - fr.along[0], uy = fr.mid[1] - fr.along[1];
      final ul2 = ux * ux + uy * uy;
      final dx = framePoint[0] - _start![0], dy = framePoint[1] - _start![1];
      final units = ul2 < 1e-12 ? 0.0 : (dx * ux + dy * uy) / ul2;
      // a unit is size/100 of the box; position runs across 2 * reach.
      final b = params['_box'] as List<double>;
      final size = math.max((b[2] - b[0]) * (sc?[0] ?? 1), (b[3] - b[1]) * (sc?[1] ?? 1));
      final k = origamiFolds(params).where((x) => x.n == n).firstOrNull;
      final dir = ((params[k?.direction ?? 'direction'] ?? params['direction']) as num? ?? 0) * math.pi / 180;
      final w = (b[2] - b[0]) * (sc?[0] ?? 1), h = (b[3] - b[1]) * (sc?[1] ?? 1);
      final reach = (w / 2 * math.cos(dir)).abs() + (h / 2 * math.sin(dir)).abs();
      v = reach <= 1e-9 ? _startValue! : _startValue! + units * size / 100 / (2 * reach);
    }
    v = v.clamp(0.0, 1.0);
    // the quarters, the middle, and through the shape's corners.
    final corners = origamiPositionsThrough(params, rest, layerFlatOutline(layer), scale: sc, n: n);
    v = snapToStops(v, [...origamiPositionStops, ...corners], 0.02);
    setTrackValueAt(t, lf, v);
  }
}

/// Turns a fold: its line pivots about its middle with the finger (the
/// change of the finger's angle round it, so it never jumps), sticking at
/// every 45 degrees and parallel to the shape's edges.
class OrigamiDirectionDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  final int n;
  OrigamiDirectionDragOp(this.layer, this.inst, [this.n = 1]);

  double? _startAngle, _startValue, _sign;
  List<double>? _pivot;

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final lf = localFrameOf(layer, globalFrame);
    final k = origamiFolds(inst.params).where((x) => x.n == n).firstOrNull;
    if (k == null) return;
    // a fold saved without its own direction gets one (the shared one).
    if (inst.params[k.direction] == null) {
      final d = inst.params['direction'];
      inst.params[k.direction] = Track(d is Track ? (d.defaultValue as num).toDouble() : 0.0, false);
    }
    final t = _trackOf(inst, k.direction);
    if (t == null) return;
    if (_pivot == null) {
      final fr = _frameOf(project, layer, inst, n, globalFrame);
      if (fr == null) return;
      _pivot = fr.mid;
      _startAngle = math.atan2(framePoint[1] - fr.mid[1], framePoint[0] - fr.mid[0]);
      _startValue = _valueOf(t, lf);
      // a mirrored drawing (a flap folded over, or a flipped layer) turns
      // the other way.
      // (`along` points back against the fold's way: u is its opposite.)
      final ax = fr.mid[0] - fr.along[0], ay = fr.mid[1] - fr.along[1];
      final sx = fr.side[0] - fr.mid[0], sy = fr.side[1] - fr.mid[1];
      _sign = (ax * sy - ay * sx) >= 0 ? 1 : -1;
    }
    final p = _pivot!;
    final dx = framePoint[0] - p[0], dy = framePoint[1] - p[1];
    // too near the middle the angle means nothing: hold it.
    if (dx * dx + dy * dy < 24 * 24) return;
    var delta = math.atan2(dy, dx) - _startAngle!;
    delta = math.atan2(math.sin(delta), math.cos(delta));
    var dir = (_startValue! + _sign! * delta * 180 / math.pi) % 360;
    if (dir < 0) dir += 360;
    // every 45 degrees, and along the shape's edges (either way).
    final pts = layerFlatOutline(layer);
    final edges = <double>[
      for (var i = 0; i < pts.length && pts.length <= 64; i++)
        for (final o in const [90.0, 270.0])
          (math.atan2(pts[(i + 1) % pts.length][1] - pts[i][1], pts[(i + 1) % pts.length][0] - pts[i][0]) * 180 / math.pi + o) % 360
    ];
    dir = snapToStops(dir, [for (var a = 0.0; a <= 360; a += 45) a, ...edges, ...[for (final e in edges) e + 360]], 3) % 360;
    setTrackValueAt(t, lf, dir);
  }
}

/// Bends between two lines: their second lines on the stage (frame px),
/// on the paper as it is folded - to see where the bend ends.
List<List<List<double>>> origamiSecondLinesFrame(Project project, Layer layer, int globalFrame) {
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final rest = buildGrid(layer.content, 2, 2);
  final lf = localFrameOf(layer, globalFrame).toDouble();
  final b = layerBox(layer);
  final diag = math.sqrt(math.pow(b[2] - b[0], 2) + math.pow(b[3] - b[1], 2));
  final out = <List<List<double>>>[];
  for (final inst in origamiInstances(layer)) {
    for (final f in origamiResolved(_params(layer, inst, lf), rest)) {
      final u2 = f.u2, m2 = f.m2;
      if (u2 == null || m2 == null) continue;
      // along the line (perpendicular to its normal), across the shape.
      final along = [-u2[1], u2[0]];
      final pts = [
        for (var i = 0; i <= 24; i++) [m2[0] + along[0] * diag * (i / 12 - 1), m2[1] + along[1] * diag * (i / 12 - 1)]
      ];
      final folded = applyEffectStack(layer, [pts], globalFrame, project: project).first;
      out.add([for (final q in folded) applyAffine(m, q)]);
    }
  }
  return out;
}
