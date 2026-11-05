import 'dart:math' as math;

import '../geometry_effect_registry.dart';
import '../../model/project.dart' show EffectInstance, Track, track;
import 'bend_arc.dart' show gridBox;

/// "Origami": folds the object like paper, in 3D, along straight lines
/// across it.
///
/// - direction: which way the folding part lies from the fold line, in
///   degrees (0: the right part folds, 90: the lower part).
/// - position: where the fold line crosses the object along that way
///   (0..1 of its extent).
/// - angle: how far it folds (degrees; + toward the viewer, - away). 90
///   stands the part on its edge - seen straight on it vanishes; 180 lays
///   it flat back over the rest.
/// - softness: 0 a sharp crease; more bends it round like an elastic
///   sheet (the bend's radius, a fraction of the object).
/// - more folds ("Add fold": params fold<N>_angle / fold<N>_position): the
///   folded part folds again further along (positions on the same 0..1
///   scale, past the one before).
/// - perspective: 0 flat, up to 1 strong.
///
/// The parts are mapped through one profile along the fold direction, so
/// folds stack correctly whatever their angles.
void registerOrigamiFold() {
  registerEffect(EffectDef(
    id: 'origami_fold',
    name: 'Origami fold',
    category: 'geometry',
    type: 'vertex',
    params: const [
      ParamDef(key: 'angle', type: 'float', defaultValue: 0.0, range: [-180, 180]),
      ParamDef(key: 'direction', type: 'float', defaultValue: 0.0, range: [0, 360]),
      ParamDef(key: 'position', type: 'float', defaultValue: 0.5, range: [0, 1]),
      ParamDef(key: 'softness', type: 'float', defaultValue: 0.0, range: [0, 1]),
      ParamDef(key: 'perspective', type: 'float', defaultValue: 0.3, range: [0, 1]),
    ],
    apply: origamiGrid,
    gridHints: (params, rest) {
      final f = _OrigamiFrame.of(params, rest);
      if (f == null) return const [];
      return [
        for (final h in f.hinges)
          GridHint(
            axisAngle: f.axisDeg,
            from: h.s, // the hinge itself, exactly
            to: h.s + h.len,
            rows: h.len <= 1e-9 ? 1 : (h.theta.abs() * 180 / math.pi / 5).ceil().clamp(2, 36),
          ),
      ];
    },
  ));
}

double _num(dynamic v, double d) => v is num ? v.toDouble() : d;

/// The folds' (angle key, position key, default position), in order: the
/// first, then any added ones (fold2_..., fold3_...; older saves'
/// angle2 / angle3 too).
List<(String, String, double)> origamiFoldKeys(Map<String, dynamic> params) {
  final extra = <int>{
    for (final k in params.keys)
      if (RegExp(r'^fold(\d+)_angle$').firstMatch(k) case final m?) int.parse(m.group(1)!)
  }.toList()
    ..sort();
  return [
    ('angle', 'position', 0.5),
    if (params.containsKey('angle2')) ('angle2', 'position2', 0.75),
    if (params.containsKey('angle3')) ('angle3', 'position3', 0.9),
    for (final n in extra) ('fold${n}_angle', 'fold${n}_position', 0.75),
  ];
}

/// Adds a fold past the last one; returns its number.
int addOrigamiFold(EffectInstance inst) {
  final keys = origamiFoldKeys(inst.params);
  var n = 2;
  while (inst.params.containsKey('fold${n}_angle')) {
    n++;
  }
  final lastPos = keys.map((k) => inst.params[k.$2]).whereType<Track>().map((t) => (t.defaultValue as num).toDouble()).fold(0.5, math.max);
  inst.params['fold${n}_angle'] = track(45.0);
  inst.params['fold${n}_position'] = track(math.min(1.0, lastPos + 0.15));
  return n;
}

/// Takes fold `n` away (the first stays).
void removeOrigamiFold(EffectInstance inst, int n) {
  inst.params
    ..remove('fold${n}_angle')
    ..remove('fold${n}_position');
}

/// Stage: the fold lines can be dragged (Origami card, next to position).
bool origamiFoldsOnStage = true;

/// Each fold line across the layer's box, content space: its position
/// param, the line's two ends.
List<({String key, List<double> a, List<double> b})> origamiFoldLines(Map<String, dynamic> params, Grid rest) {
  final box = gridBox(rest);
  final w = box.maxX - box.minX, h = box.maxY - box.minY;
  final ang = _num(params['direction'], 0) * math.pi / 180;
  final u = [math.cos(ang), math.sin(ang)], n = [-u[1], u[0]];
  final reach = (w / 2 * u[0]).abs() + (h / 2 * u[1]).abs();
  final across = (w / 2 * n[0]).abs() + (h / 2 * n[1]).abs();
  final c = [(box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2];
  return [
    for (final (_, pk, pd) in origamiFoldKeys(params))
      () {
        final s = -reach + 2 * reach * _num(params[pk], pd).clamp(0.0, 1.0);
        final m = [c[0] + u[0] * s, c[1] + u[1] * s];
        return (key: pk, a: [m[0] - n[0] * across, m[1] - n[1] * across], b: [m[0] + n[0] * across, m[1] + n[1] * across]);
      }()
  ];
}

/// The position (0..1) a content-space point sets a fold line to.
double origamiPositionAt(Map<String, dynamic> params, Grid rest, List<double> p) {
  final box = gridBox(rest);
  final w = box.maxX - box.minX, h = box.maxY - box.minY;
  final ang = _num(params['direction'], 0) * math.pi / 180;
  final u = [math.cos(ang), math.sin(ang)];
  final reach = (w / 2 * u[0]).abs() + (h / 2 * u[1]).abs();
  if (reach <= 1e-9) return 0.5;
  final c = [(box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2];
  final s = (p[0] - c[0]) * u[0] + (p[1] - c[1]) * u[1];
  return ((s + reach) / (2 * reach)).clamp(0.0, 1.0);
}

class _Hinge {
  final double s, theta, len;
  _Hinge(this.s, this.theta, this.len);
}

/// The folds in the rest grid's space: the direction `u` (rows run across
/// it), the box centre `c`, the half extent along `u`, and the hinges in
/// order (each at a distance `s` along `u` from the centre, folding by
/// `theta` over a bend `len` long).
class _OrigamiFrame {
  final List<double> u, c;
  final double reach, axisDeg, size;
  final List<_Hinge> hinges;
  _OrigamiFrame(this.u, this.c, this.reach, this.axisDeg, this.size, this.hinges);

  static _OrigamiFrame? of(Map<String, dynamic> params, Grid grid) {
    final all = grid.expand((r) => r).toList();
    if (all.isEmpty) return null;
    final box = gridBox(grid);
    final w = box.maxX - box.minX, h = box.maxY - box.minY;
    final a = _num(params['direction'], 0) * math.pi / 180;
    final u = [math.cos(a), math.sin(a)];
    final reach = (w / 2 * u[0]).abs() + (h / 2 * u[1]).abs();
    if (reach <= 1e-9) return null;
    final c = [(box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2];
    final r = _num(params['softness'], 0).clamp(0.0, 1.0) * reach;
    double at(String k, double d) => -reach + 2 * reach * _num(params[k], d).clamp(0.0, 1.0);
    final hinges = <_Hinge>[];
    var last = -double.infinity;
    for (final (ak, pk, pd) in origamiFoldKeys(params)) {
      final th = _num(params[ak], 0) * math.pi / 180;
      final s = at(pk, pd);
      // a later fold has to lie past the one before (and its bend).
      if (th == 0 || s <= last) continue;
      final len = r * th.abs();
      hinges.add(_Hinge(s, th, len));
      last = s + len;
    }
    if (hinges.isEmpty) return null;
    return _OrigamiFrame(u, c, reach, a * 180 / math.pi, math.max(w, h), hinges);
  }

  /// Where the material at distance `s` along `u` ends up: along `u` and
  /// out of the page (toward the viewer).
  (double, double) profile(double s) {
    final first = hinges.first.s;
    if (s <= first) return (s, 0);
    var x = first, z = 0.0, dir = 0.0, cur = first;
    for (final h in hinges) {
      if (s <= h.s) break;
      // flat up to the hinge.
      x += math.cos(dir) * (h.s - cur);
      z += math.sin(dir) * (h.s - cur);
      cur = h.s;
      if (h.len <= 1e-9) {
        dir += h.theta;
        continue;
      }
      // round the bend (as much of it as reaches s).
      final l = math.min(h.len, s - h.s);
      final k = h.theta / h.len;
      x += (math.sin(dir + k * l) - math.sin(dir)) / k;
      z += (math.cos(dir) - math.cos(dir + k * l)) / k;
      dir += k * l;
      cur = h.s + l;
      if (l < h.len) return (x, z);
    }
    x += math.cos(dir) * (s - cur);
    z += math.sin(dir) * (s - cur);
    return (x, z);
  }
}

Grid origamiGrid(Grid grid, Map<String, dynamic> params, double localFrame) {
  final f = _OrigamiFrame.of(params, grid);
  if (f == null) return grid;
  final persp = _num(params['perspective'], 0).clamp(0.0, 1.0);
  final focal = persp <= 0 ? double.infinity : f.size / persp;
  final u = f.u, n = [-u[1], u[0]], c = f.c;
  List<double> map(List<double> p) {
    final dx = p[0] - c[0], dy = p[1] - c[1];
    final s = dx * u[0] + dy * u[1], w = dx * n[0] + dy * n[1];
    final (x, z) = f.profile(s);
    var px = x * u[0] + w * n[0], py = x * u[1] + w * n[1];
    if (focal.isFinite) {
      final k = focal / math.max(focal * 0.05, focal - z);
      px *= k;
      py *= k;
    }
    return [c[0] + px, c[1] + py];
  }

  return [for (final row in grid) [for (final p in row) map(p)]];
}
