/// Bend (Arc).
///
/// Two kinds of instance share this effect id:
///
/// - **v2** (has an `axisAngle` param - every bend created now): two
///   parallel lines across the shape, perpendicular to the bend axis.
///   `start` and `end` are their places along the axis as fractions of
///   the shape's extent (0 = the static side's far edge). Before `start`
///   nothing moves; between the lines the shape bends along a circular
///   arc (the centre line keeps its length); past `end` it is carried
///   rigidly, rotated by the whole angle and continuing the arc's tangent
///   - continuous at both lines, no kink at `end`. Lines live in the
///   layer's rest (undeformed) space. Consecutive bends act as joints:
///   see applyBendGroup.
/// - **legacy** (only `angle`, `base`, `baseAxis` - projects saved before
///   v2): the original "rotate around the base centre by an amount that
///   grows along the shape" formula, kept unchanged so old projects
///   render exactly as before. The Effects tab offers converting one to
///   v2 (that changes its look: v2 is a true arc).
///
/// Physics (v2): the bend can swing like a flexible object under tension
/// - `inertia` makes it lag and ring when the layer starts, stops or
///   changes direction; `spring` makes the keyed angle overshoot and
///   settle. Both are damped oscillations sharing `frequency` (Hz) and
///   `damping`. Simulated from the layer's first frame to the current one
///   (pull-model: every call is independent, nothing cached).
library;

import 'dart:math' as math;

import '../../core/interpolation.dart';
import '../../core/stage_size.dart';
import '../../core/state_cache.dart';
import '../../geometry/shapes.dart' show BoundingBox;
import '../../model/project.dart';
import '../geometry_effect_registry.dart';

const bendV2Keys = ['angle', 'axisAngle', 'start', 'end', 'inertia', 'spring', 'frequency', 'damping', 'react'];

void registerBendArc() {
  registerEffect(EffectDef(
    id: 'bend_arc',
    name: 'Bend (Arc)',
    category: 'geometry',
    type: 'vertex',
    params: const [
      ParamDef(key: 'angle', type: 'float', defaultValue: 0.0, range: [-180, 180]),
      // v2: the bend axis (degrees, from the static side toward the free
      // end; -90 = up) and the two lines along it (fractions 0..1).
      ParamDef(key: 'axisAngle', type: 'float', defaultValue: -90.0, range: [-180, 180]),
      ParamDef(key: 'start', type: 'float', defaultValue: 0.25, range: [0, 1]),
      ParamDef(key: 'end', type: 'float', defaultValue: 0.75, range: [0, 1]),
      // v2 physics.
      ParamDef(key: 'inertia', type: 'float', defaultValue: 0.0, range: [0, 100]),
      ParamDef(key: 'spring', type: 'float', defaultValue: 0.0, range: [0, 100]),
      ParamDef(key: 'frequency', type: 'float', defaultValue: 2.0, range: [0.2, 6]),
      ParamDef(key: 'damping', type: 'float', defaultValue: 30.0, range: [0, 100]),
      // collisions: how much of a push bends it instead of moving it (the
      // static side stays put; the free end gives and springs back).
      ParamDef(key: 'react', type: 'float', defaultValue: 0.0, range: [0, 100]),
      // legacy only (never created for new instances).
      ParamDef(key: 'base', type: 'float', defaultValue: 0.0, range: [0, 0.95]),
      ParamDef(
        key: 'baseAxis', type: 'enum', defaultValue: 'bottom',
        options: ['top', 'bottom', 'left', 'right'], animatable: false,
      ),
    ],
    apply: (grid, params, localFrame) =>
        isBendV2Params(params) ? applyBendGroup(grid, grid, [params], gridBox(grid)) : _legacyBend(grid, params),
    gridHints: (params, rest) => isBendV2Params(params) ? [bendGridHint(params, gridBox(rest))] : const [],
  ));
}

bool isBendV2Params(Map<String, dynamic> params) => params.containsKey('axisAngle');

bool isBendV2(EffectInstance inst) => inst.effectId == 'bend_arc' && inst.params.containsKey('axisAngle');

double _num(Map<String, dynamic> p, String k, double d) {
  final v = p[k];
  return v is num ? v.toDouble() : d;
}

// ===== v2 geometry =====

/// One bend in rest space: axis `u`, its normal `n` (the side a positive
/// angle bends toward), the rest box centre `c`, the lines at `s0`/`s1`
/// (signed distances along `u` from `c`), and the angle in radians.
class BendFrame {
  final List<double> u, n, c;
  final double s0, s1, sMin, sMax, theta;
  BendFrame(this.u, this.n, this.c, this.s0, this.s1, this.sMin, this.sMax, this.theta);

  double sOf(List<double> r) => (r[0] - c[0]) * u[0] + (r[1] - c[1]) * u[1];
  double wOf(List<double> r) => (r[0] - c[0]) * n[0] + (r[1] - c[1]) * n[1];
  List<double> at(double s, double w) => [c[0] + s * u[0] + w * n[0], c[1] + s * u[1] + w * n[1]];
}

/// The bounding box of a grid's points.
BoundingBox gridBox(Grid g) {
  var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
  for (final row in g) {
    for (final p in row) {
      minX = math.min(minX, p[0]);
      maxX = math.max(maxX, p[0]);
      minY = math.min(minY, p[1]);
      maxY = math.max(maxY, p[1]);
    }
  }
  return BoundingBox(minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

/// The bend's frame for resolved params over the layer's rest box (its
/// content bounding box).
BendFrame bendFrameFor(Map<String, dynamic> params, BoundingBox b) {
  final a = _num(params, 'axisAngle', -90) * math.pi / 180;
  final u = [math.cos(a), math.sin(a)];
  final n = [-u[1], u[0]];
  final c = [(b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2];
  // extent along the axis: the box corners' projections.
  final hw = (b.maxX - b.minX) / 2, hh = (b.maxY - b.minY) / 2;
  final reach = (hw * u[0]).abs() + (hh * u[1]).abs();
  final sMin = -reach, sMax = reach, len = math.max(1e-9, sMax - sMin);
  final start = _num(params, 'start', 0.25).clamp(0.0, 1.0);
  final end = math.max(start + 0.02, _num(params, 'end', 0.75).clamp(0.0, 1.0));
  return BendFrame(u, n, c, sMin + start * len, sMin + end * len, sMin, sMax,
      _num(params, 'angle', 0) * math.pi / 180);
}

/// Where one bend sends a point: classified by its rest position `r`,
/// transforming its current position `p`.
List<double> bendMap(BendFrame f, List<double> r, List<double> p) {
  if (f.theta.abs() < 1e-9) return p;
  final s = f.sOf(r);
  if (s <= f.s0) return p;
  final len = f.s1 - f.s0;
  final radius = len / f.theta;
  // arc centre: on the normal through the start line's centre-line point.
  final cx = f.c[0] + f.s0 * f.u[0] + radius * f.n[0];
  final cy = f.c[1] + f.s0 * f.u[1] + radius * f.n[1];
  final along = math.min(s, f.s1) - f.s0;
  final phi = f.theta * along / len;
  // slide back to the start line, then turn around the arc centre.
  final qx = p[0] - along * f.u[0] - cx, qy = p[1] - along * f.u[1] - cy;
  final cs = math.cos(phi), sn = math.sin(phi);
  return [cx + qx * cs - qy * sn, cy + qx * sn + qy * cs];
}

/// A run of consecutive v2 bends as joints on one stick (spec: base ->
/// tip in stack order). Each bend classifies points by their REST
/// coordinate and transforms their current position; they run tip-first
/// (reverse order), so each lower bend carries the already-bent upper
/// part rigidly - forward kinematics: moving a lower joint carries the
/// upper ones with the stick. Bends whose static sides point different
/// ways follow the same rule (stack order = base -> tip); place them in
/// the stack accordingly.
Grid applyBendGroup(Grid grid, Grid rest, List<Map<String, dynamic>> paramsBaseToTip, BoundingBox box) {
  var g = grid;
  for (final params in paramsBaseToTip.reversed) {
    final f = bendFrameFor(params, box);
    if (f.theta.abs() < 1e-9) continue;
    g = [
      for (var r = 0; r < g.length; r++) [for (var c = 0; c < g[r].length; c++) bendMap(f, rest[r][c], g[r][c])],
    ];
  }
  return g;
}

// ===== adaptive grid =====

/// One bend's request for grid rows: rows across the axis exactly on
/// both lines, and `rows` evenly inside the band (about one per 5° of
/// bend, at least 2).
GridHint bendGridHint(Map<String, dynamic> params, BoundingBox box) {
  final f = bendFrameFor(params, box);
  final deg = f.theta.abs() * 180 / math.pi;
  return GridHint(
    axisAngle: math.atan2(f.u[1], f.u[0]) * 180 / math.pi,
    from: f.s0,
    to: f.s1,
    rows: (deg / 5).ceil().clamp(2, 36),
  );
}

// ===== legacy =====

Grid _legacyBend(Grid grid, Map<String, dynamic> params) {
  final angle = params['angle'] as double;
  if (angle == 0) return grid;
  final all = grid.expand((row) => row).toList();
  final xs = [for (final p in all) p[0]], ys = [for (final p in all) p[1]];
  final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
  final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);

  final raw = params['base'];
  final b = (raw is num ? raw.toDouble() : 0.0).clamp(0.0, 0.95);
  final w = maxX - minX, h = maxY - minY;

  late List<double> pivot;
  late double Function(double x, double y) tOf;
  switch (params['baseAxis'] as String? ?? 'bottom') {
    case 'top':
      pivot = [(minX + maxX) / 2, minY + b * h];
      tOf = (x, y) => (y - minY) / h;
    case 'left':
      pivot = [minX + b * w, (minY + maxY) / 2];
      tOf = (x, y) => (x - minX) / w;
    case 'right':
      pivot = [maxX - b * w, (minY + maxY) / 2];
      tOf = (x, y) => (maxX - x) / w;
    default: // "bottom"
      pivot = [(minX + maxX) / 2, maxY - b * h];
      tOf = (x, y) => (maxY - y) / h;
  }

  List<double> bendPoint(List<double> p) {
    final x = p[0], y = p[1];
    final t = math.max(0.0, (tOf(x, y) - b) / (1 - b));
    final rad = (t * angle) * math.pi / 180;
    final cos = math.cos(rad), sin = math.sin(rad);
    final dx = x - pivot[0], dy = y - pivot[1];
    return [pivot[0] + dx * cos - dy * sin, pivot[1] + dx * sin + dy * cos];
  }

  return [for (final row in grid) [for (final p in row) bendPoint(p)]];
}

/// The v2 params that reproduce a legacy instance's lines: the old base
/// side becomes the axis, `base` the start line, the far edge the end.
void convertLegacyBend(EffectInstance inst) {
  if (inst.effectId != 'bend_arc' || inst.params.containsKey('axisAngle')) return;
  final baseRaw = inst.params.remove('base');
  final base = baseRaw is Track ? baseRaw.defaultValue as double : (baseRaw is num ? baseRaw.toDouble() : 0.0);
  final axis = switch (inst.params.remove('baseAxis') as String? ?? 'bottom') {
    'top' => 90.0,
    'left' => 0.0,
    'right' => 180.0,
    _ => -90.0,
  };
  inst.params['axisAngle'] = track(axis);
  inst.params['start'] = track(base);
  inst.params['end'] = track(1.0);
  for (final k in ['inertia', 'spring']) {
    inst.params[k] = track(0.0);
  }
  inst.params['frequency'] = track(2.0);
  inst.params['damping'] = track(30.0);
}

// ===== physics =====

/// The bend angle with physics (degrees) at `localFrame`: the keyed angle,
/// plus an overshoot toward it (`spring`) and a lag from the layer's own
/// motion (`inertia`), both ringing out at `frequency` with `damping`.
/// `project` lets the lag follow the layer's world motion (parents
/// included); without it the layer's own position keys are used.
/// Collisions bending a layer (bend's `react`): the extra angle (degrees)
/// the physics bake gives it at a frame. Set by the physics module.
double Function(Project project, Layer layer, int globalFrame)? bendCollisionLookup;

double bendPhysicsAngle(Project? project, Layer layer, EffectInstance inst, double localFrame) {
  final lookup = bendCollisionLookup;
  final react = inst.params['react'];
  final extra = project != null && lookup != null && react is Track && (react.defaultValue as num) > 0
      ? lookup(project, layer, layer.startFrame + localFrame.round())
      : 0.0;
  return _bendPhysicsAngle(project, layer, inst, localFrame) + extra;
}

double _bendPhysicsAngle(Project? project, Layer layer, EffectInstance inst, double localFrame) {
  double at(String k, double f, double d) {
    final v = inst.params[k];
    return v is Track ? (evaluateTrack(null, v, f) as num).toDouble() : (v is num ? v.toDouble() : d);
  }

  final target = at('angle', localFrame, 0);
  final inertia = at('inertia', localFrame, 0), spring = at('spring', localFrame, 0);
  if (inertia <= 0 && spring <= 0) return target;
  final freq = at('frequency', localFrame, 2).clamp(0.05, 30.0);
  final zeta = 0.03 + 0.97 * at('damping', localFrame, 30).clamp(0.0, 100.0) / 100;
  final omega = 2 * math.pi * freq;
  const sub = 4;
  final dt = 1 / fps / sub;

  // world position (px) of the layer origin and its axis normal.
  List<double> posAt(int f) {
    if (project != null) {
      final m = getLayerBaseStateAt(project, layer.id, layer.startFrame + f).baseMatrix;
      return [m[4] * stageSize.width, m[5] * stageSize.height];
    }
    final a = evaluateTrack(null, layer.transform.anchor, f.toDouble()) as List<double>;
    return [a[0] * stageSize.width, a[1] * stageSize.height];
  }

  List<double> normalAt(int f) {
    final a = at('axisAngle', f.toDouble(), -90) * math.pi / 180;
    var ux = math.cos(a), uy = math.sin(a);
    if (project != null) {
      final m = getLayerBaseStateAt(project, layer.id, layer.startFrame + f).baseMatrix;
      final wx = m[0] * ux + m[2] * uy, wy = m[1] * ux + m[3] * uy;
      final l = math.sqrt(wx * wx + wy * wy);
      if (l > 1e-12) {
        ux = wx / l;
        uy = wy / l;
      }
    }
    return [-uy, ux];
  }

  var x = at('angle', 0, 0), vx = 0.0; // spring follower
  var y = 0.0, vy = 0.0; // inertia lag
  final frames = localFrame.floor();
  var prev = posAt(-1), cur = posAt(0);
  for (var f = 0; f < frames; f++) {
    final next = posAt(f + 1);
    final ax = (next[0] - 2 * cur[0] + prev[0]) * fps * fps;
    final ay = (next[1] - 2 * cur[1] + prev[1]) * fps * fps;
    final nrm = inertia > 0 ? normalAt(f) : const [0.0, 0.0];
    // the free end lags opposite the acceleration: 1000 px/s² at full
    // inertia leans it 30°.
    final drive = (-(inertia / 100) * 0.03 * (ax * nrm[0] + ay * nrm[1])).clamp(-90.0, 90.0);
    final tgt = at('angle', f.toDouble(), 0);
    for (var k = 0; k < sub; k++) {
      vx += (omega * omega * (tgt - x) - 2 * zeta * omega * vx) * dt;
      x += vx * dt;
      vy += (omega * omega * (drive - y) - 2 * zeta * omega * vy) * dt;
      y += vy * dt;
    }
    prev = cur;
    cur = next;
  }
  return target + (spring / 100) * (x - target) + y;
}

/// The two ends of the line across the bend axis at `s`, clipped to the
/// rest box (rest space).
List<List<double>> bendChord(BendFrame f, BoundingBox box, double s) {
  final hw = (box.maxX - box.minX) / 2, hh = (box.maxY - box.minY) / 2;
  var lo = -double.infinity, hi = double.infinity;
  void slab(double base, double dir, double half) {
    if (dir.abs() < 1e-12) return;
    final t1 = (-half - base) / dir, t2 = (half - base) / dir;
    lo = math.max(lo, math.min(t1, t2));
    hi = math.min(hi, math.max(t1, t2));
  }

  slab(s * f.u[0], f.n[0], hw);
  slab(s * f.u[1], f.n[1], hh);
  if (lo > hi) lo = hi = (lo + hi) / 2; // a corner: rounding can flip the range
  return [f.at(s, lo), f.at(s, hi)];
}
