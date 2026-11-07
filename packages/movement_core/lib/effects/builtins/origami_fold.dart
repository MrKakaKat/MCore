import 'dart:math' as math;

import '../geometry_effect_registry.dart';
import '../../core/interpolation.dart' show evaluateTrack;
import '../../model/project.dart' show EffectInstance, Layer, Track, track;
import 'bend_arc.dart' show gridBox;
import '../../model/line_path.dart' show circleRoundK;

/// "Origami": folds the object like paper, in 3D, along straight creases.
///
/// Every fold has its own settings (the first: `angle`, `direction`,
/// `position`, `softness`, `round`; added ones: `fold<N>_angle`, ...):
/// - direction: which way the folding part lies from the crease, degrees
///   (0: the right part folds, 90: the lower part);
/// - position: where the crease crosses the object along that way (0..1
///   of its extent);
/// - angle: how far it folds (+ toward the viewer, - away; 90 stands the
///   part on its edge, 180 lays it flat back);
/// - softness: 0 a sharp crease; more bends it round over a stretch of
///   paper (the folded part gets shorter);
/// - round: the crease rounded off in 3D, px (at most the paper there is
///   on either side) - only the paper right at the
///   crease, the parts and the creases stay where they are.
/// `perspective` (0 flat, up to 1 strong) is the whole effect's.
///
/// The creases are drawn on the paper itself: a later fold lies in one
/// part of an earlier one (`fold<N>_in`: '<fold>:far' its folded part,
/// '<fold>:near' the part that stays, 'free' anywhere) and moves with it.
/// The folds are applied in 3D one after another (the innermost first),
/// so any directions combine; creases that cross fold both parts where
/// the fold is free.
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
      ParamDef(key: 'softShape', type: 'float', defaultValue: 0.5523, range: [0, 1]),
      ParamDef(key: 'round', type: 'float', defaultValue: 0.0, range: [0, 200]),
      ParamDef(key: 'roundShape', type: 'float', defaultValue: 0.5523, range: [0, 1]),
      ParamDef(key: 'perspective', type: 'float', defaultValue: 0.3, range: [0, 1]),
    ],
    apply: origamiGrid,
    gridHints: (params, rest) {
      final f = _Folds.of(params, rest);
      if (f == null) return const [];
      return [
        for (final h in f.folds)
          if (h.theta != 0)
          GridHint(
            axisAngle: h.dirDeg,
            from: h.s - h.round,
            to: h.s + math.max(h.len, h.round),
            // rows by the bend's size (a short bend needs few).
            rows: math.max(h.len, h.round) <= 1e-9
                ? 1
                : math.max(h.round > 0 ? 12 : 2, (math.max(h.len, h.round) / math.max(1.0, f.size / 60)).ceil()).clamp(2, 48),
          ),
      ];
    },
  ));
}

double _num(dynamic v, double d) => v is num ? v.toDouble() : d;

/// One fold's parameter names. `n`: 1 for the first, else its number.
class OrigamiFoldKeys {
  final int n;
  final String angle, position, direction, softness, round, region;
  final double defaultPosition;
  const OrigamiFoldKeys(this.n, this.angle, this.position, this.direction, this.softness, this.round, this.region,
      this.defaultPosition);

  /// The soft bend's shape: 0 cut straight, ~0.55 a circle, 1 sharp.
  String get softShape => n == 1 ? 'softShape' : round.startsWith('fold') ? 'fold${n}_softShape' : 'softShape$n';

  /// The rounding's shape: 0 cut straight, ~0.55 a circle, 1 sharp.
  String get roundShape => n == 1 ? 'roundShape' : round.startsWith('fold') ? 'fold${n}_roundShape' : 'roundShape$n';
}

/// The folds' parameter names, in order: the first, then any added ones
/// (fold2_..., fold3_...; older saves' angle2 / angle3 too).
List<OrigamiFoldKeys> origamiFolds(Map<String, dynamic> params) {
  final extra = <int>{
    for (final k in params.keys)
      if (RegExp(r'^fold(\d+)_angle$').firstMatch(k) case final m?) int.parse(m.group(1)!)
  }.toList()
    ..sort();
  return [
    const OrigamiFoldKeys(1, 'angle', 'position', 'direction', 'softness', 'round', '', 0.5),
    if (params.containsKey('angle2')) const OrigamiFoldKeys(2, 'angle2', 'position2', 'direction2', 'softness2', 'round2', 'in2', 0.75),
    if (params.containsKey('angle3')) const OrigamiFoldKeys(3, 'angle3', 'position3', 'direction3', 'softness3', 'round3', 'in3', 0.9),
    for (final n in extra)
      OrigamiFoldKeys(n, 'fold${n}_angle', 'fold${n}_position', 'fold${n}_direction', 'fold${n}_softness', 'fold${n}_round',
          'fold${n}_in', 0.75),
  ];
}

/// The folds' (angle key, position key, default position), in order.
List<(String, String, double)> origamiFoldKeys(Map<String, dynamic> params) =>
    [for (final f in origamiFolds(params)) (f.angle, f.position, f.defaultPosition)];

/// Which fold a parameter belongs to (1: the first), or null (the whole
/// effect's, e.g. perspective).
int? origamiFoldOf(Map<String, dynamic> params, String key) {
  for (final f in origamiFolds(params)) {
    if ([f.angle, f.position, f.direction, f.softness, f.softShape, f.round, f.roundShape].contains(key)) return f.n;
  }
  return null;
}

/// Adds a fold; returns its number. It lies in `region` ('<fold>:far' the
/// folded part of that fold, '<fold>:near' the part that stays, 'free'
/// anywhere) - by default the last fold's folded part - pointing the same
/// way as that fold, half way into it.
int addOrigamiFold(EffectInstance inst, {String? region}) {
  final folds = origamiFolds(inst.params);
  var n = 2;
  while (inst.params.containsKey('fold${n}_angle') || inst.params.containsKey('angle$n')) {
    n++;
  }
  final last = folds.last;
  double v(String k, double d) {
    final t = inst.params[k];
    return t is Track ? _num(t.defaultValue, d) : _num(t, d);
  }

  final reg = region ?? '${last.n}:far';
  final parent = folds.where((f) => f.n == int.tryParse(reg.split(':').first)).firstOrNull ?? last;
  final dir = v(parent.direction, v('direction', 0));
  final pPos = v(parent.position, parent.defaultPosition);
  final far = !reg.endsWith(':near');
  inst.params['fold${n}_angle'] = track(45.0);
  inst.params['fold${n}_direction'] = track(dir);
  inst.params['fold${n}_position'] = track(reg == 'free' ? 0.5 : (far ? (pPos + 1) / 2 : pPos / 2));
  inst.params['fold${n}_softness'] = track(0.0);
  inst.params['fold${n}_softShape'] = track(0.5523);
  inst.params['fold${n}_round'] = track(0.0);
  inst.params['fold${n}_roundShape'] = track(0.5523);
  inst.params['fold${n}_in'] = reg;
  return n;
}

/// Takes fold `n` away (the first stays); folds that lay in it move to
/// where it lay.
void removeOrigamiFold(EffectInstance inst, int n) {
  if (n <= 1) return;
  final gone = origamiFolds(inst.params).where((f) => f.n == n).firstOrNull;
  if (gone == null) return;
  final its = _regionOf(inst.params, gone);
  for (final k in [gone.angle, gone.position, gone.direction, gone.softness, gone.softShape, gone.round, gone.roundShape, gone.region]) {
    inst.params.remove(k);
  }
  for (final f in origamiFolds(inst.params)) {
    if (f.region.isEmpty) continue;
    final r = _regionOf(inst.params, f);
    if (r.startsWith('$n:')) inst.params[f.region] = its;
  }
}

/// Where fold `f` lies: 'free', or '<fold>:far' / '<fold>:near' (saved
/// before it was kept: the folded part of the fold before).
String _regionOf(Map<String, dynamic> params, OrigamiFoldKeys f) {
  if (f.n == 1 || f.region.isEmpty) return 'free';
  final r = params[f.region];
  if (r is String && r.isNotEmpty) return r;
  final all = origamiFolds(params);
  final i = all.indexWhere((x) => x.n == f.n);
  return i > 0 ? '${all[i - 1].n}:far' : 'free';
}

/// Fold `n`'s region (see [addOrigamiFold]).
String origamiRegion(Map<String, dynamic> params, int n) {
  final f = origamiFolds(params).where((x) => x.n == n).firstOrNull;
  return f == null ? 'free' : _regionOf(params, f);
}

/// Sets fold `n`'s region.
void setOrigamiRegion(EffectInstance inst, int n, String region) {
  final f = origamiFolds(inst.params).where((x) => x.n == n).firstOrNull;
  if (f == null || f.region.isEmpty) return;
  inst.params[f.region] = region;
}

/// The angles a fold sticks to (its control and nothing else).
const origamiAngleStops = [0.0, 45.0, 90.0, 135.0, 180.0, -45.0, -90.0, -135.0, -180.0];

/// The positions a fold line sticks to, in its control and on the stage.
const origamiPositionStops = [0.25, 0.5, 0.75];

/// Stage: the fold lines can be dragged (Origami card).
bool origamiFoldsOnStage = true;

/// Stage: the creases where they are on the flat shape (off: on the
/// folded paper, moving with the folds they lie in).
bool origamiLinesOnFlat = false;

/// How far a crease line on the stage reaches past the shape, as a
/// fraction of its size (it can be grabbed outside the shape).
const origamiLineReach = 0.25;

/// One fold, resolved: its crease in the rest space (through `m`, along
/// `n`; the folding part lies along `u`), angle, bend length and rounding.
class OrigamiFold {
  final int n;
  final List<double> u, nrm, m;
  final double s, theta, len, round, roundShape, softShape, dirDeg;

  /// Its region: null (free) or (fold index in [_Folds.folds], far side?).
  final (int, bool)? region;
  OrigamiFold(this.n, this.u, this.nrm, this.m, this.s, this.theta, this.len, this.round, this.dirDeg, this.region,
      [this.roundShape = 0.5523, this.softShape = 0.5523]);

  /// Signed distance of rest point p from the crease, along u.
  double d(List<double> p) => (p[0] - m[0]) * u[0] + (p[1] - m[1]) * u[1];
}

class _Folds {
  final List<double> c;
  final double size;
  final List<OrigamiFold> folds;
  _Folds(this.c, this.size, this.folds);

  static _Folds? of(Map<String, dynamic> params, Grid grid, {bool all = false}) {
    final b = params['_box'];
    final double minX, minY, maxX, maxY;
    if (b is List && b.length == 4) {
      minX = _num(b[0], 0);
      minY = _num(b[1], 0);
      maxX = _num(b[2], 0);
      maxY = _num(b[3], 0);
    } else {
      final pts = grid.expand((r) => r).toList();
      if (pts.isEmpty) return null;
      final box = gridBox(grid);
      minX = box.minX;
      minY = box.minY;
      maxX = box.maxX;
      maxY = box.maxY;
    }
    final w = maxX - minX, h = maxY - minY;
    final c = [(minX + maxX) / 2, (minY + maxY) / 2];
    final keys = origamiFolds(params);
    final out = <OrigamiFold>[];
    final index = <int, int>{};
    for (final k in keys) {
      final th = _num(params[k.angle], 0) * math.pi / 180;
      if (th == 0 && !all) {
        // a fold at 0 does nothing - but folds in it still lie in it.
      }
      final dirDeg = _num(params[k.direction] ?? params['direction'], 0);
      final a = dirDeg * math.pi / 180;
      final u = [math.cos(a), math.sin(a)], nrm = [-u[1], u[0]];
      final reach = (w / 2 * u[0]).abs() + (h / 2 * u[1]).abs();
      final s = -reach + 2 * reach * _num(params[k.position], k.defaultPosition).clamp(0.0, 1.0);
      final soft = _num(params[k.softness] ?? params['softness'], 0).clamp(0.0, 1.0);
      // never longer than the paper past the crease.
      final len = (soft * reach * th.abs()).clamp(0.0, math.max(0.0, reach - s)).toDouble();
      final softShape = _num(params[k.softShape], 0.5523).clamp(0.0, 1.0).toDouble();
      // never more than the paper on either side of the crease.
      final round = math.max(0.0, _num(params[k.round], 0)).clamp(0.0, math.max(0.0, math.min(reach + s, reach - s))).toDouble();
      final roundShape = _num(params[k.roundShape], 0.5523).clamp(0.0, 1.0).toDouble();
      final reg = _regionOf(params, k);
      (int, bool)? region;
      if (reg != 'free') {
        final parts = reg.split(':');
        final pi = index[int.tryParse(parts.first) ?? -1];
        if (pi != null) region = (pi, parts.length < 2 || parts[1] != 'near');
      }
      index[k.n] = out.length;
      out.add(OrigamiFold(k.n, u, nrm, [c[0] + u[0] * s, c[1] + u[1] * s], s, th, len, round, dirDeg, region, roundShape, softShape));
    }
    return _Folds(c, math.max(w, h), out);
  }

  /// Whether rest point p lies in fold i's region (its parent's part, all
  /// the way up).
  bool inRegion(int i, List<double> p) {
    var r = folds[i].region;
    while (r != null) {
      final parent = folds[r.$1];
      final far = parent.d(p) > 0;
      if (far != r.$2) return false;
      r = parent.region;
    }
    return true;
  }

  /// Where rest point p ends up, in 3D (x, y in the rest plane, z toward
  /// the viewer): the innermost fold first.
  List<double> map(List<double> p) {
    var q = [p[0], p[1], 0.0];
    for (var i = folds.length - 1; i >= 0; i--) {
      final f = folds[i];
      if (f.theta == 0) continue;
      final d = f.d(p);
      if (d <= -f.round) continue;
      if (!inRegion(i, p)) continue;
      q = _fold(f, d, q);
    }
    return q;
  }

  /// Fold f on 3D point q (rest distance d from the crease).
  static List<double> _fold(OrigamiFold f, double d, List<double> q) {
    final th = f.theta;
    // q in the fold's frame: along the crease, across it, and up.
    final rx = q[0] - f.m[0], ry = q[1] - f.m[1];
    final along = rx * f.nrm[0] + ry * f.nrm[1];
    final across = rx * f.u[0] + ry * f.u[1];
    final up = q[2];
    double ou, oz, du, dz;
    // the crease rounded off: from -R (flat) to R (folded), the whole
    // corner between, shaped like a rect's rounded corner (a bezier with
    // handles `roundShape` of the way to the corner: 0 a straight cut,
    // ~0.55 a circle, 1 sharp) - nothing past it moves.
    if (f.round > 0 && d.abs() < f.round && f.len <= 1e-9) {
      final r = f.round;
      final k = f.roundShape;
      final p0 = [-r, 0.0], p3 = [r * math.cos(th), r * math.sin(th)];
      final p1 = [p0[0] * (1 - k), p0[1] * (1 - k)], p2 = [p3[0] * (1 - k), p3[1] * (1 - k)];
      List<double> at(double t) {
        final a = 1 - t;
        return [
          a * a * a * p0[0] + 3 * a * a * t * p1[0] + 3 * a * t * t * p2[0] + t * t * t * p3[0],
          a * a * a * p0[1] + 3 * a * a * t * p1[1] + 3 * a * t * t * p2[1] + t * t * t * p3[1],
        ];
      }

      // along the curve evenly: the paper's length spread over all of it.
      final t = _evenT(at, (d + r) / (2 * r));
      final b = at(t);
      final bu = b[0], bz = b[1];
      // the paper's own thickness offsets go with the local direction.
      final e = at(math.min(1.0, t + 1e-4)), e0 = at(math.max(0.0, t - 1e-4));
      final tu = e[0] - e0[0], tz = e[1] - e0[1];
      final tl = math.sqrt(tu * tu + tz * tz);
      final cu = tl < 1e-12 ? 1.0 : tu / tl, cz = tl < 1e-12 ? 0.0 : tz / tl;
      final rest = across - d; // its own offset (0 on flat paper)
      ou = bu + cu * rest - cz * up;
      oz = bz + cz * rest + cu * up;
      return [f.m[0] + f.nrm[0] * along + f.u[0] * ou, f.m[1] + f.nrm[1] * along + f.u[1] * ou, oz];
    }
    if (d <= 0) return q;
    if (f.len > 1e-9) {
      // the bend: from the crease to where a round bend of this length ends
      // (folded by the whole angle), shaped like a rounded corner - its
      // handles along the paper, `softShape` (0.55: a circle; 0 cut
      // straight; 1 sharper) of a circle's - then on, straight.
      final r = f.len / th;
      final end = [r * math.sin(th), r * (1 - math.cos(th))];
      final h = f.softShape / circleRoundK * (4 / 3) * math.tan(th / 4) * r;
      final p1 = [h, 0.0], p2 = [end[0] - math.cos(th) * h, end[1] - math.sin(th) * h];
      List<double> at(double t) {
        final a = 1 - t;
        return [
          3 * a * a * t * p1[0] + 3 * a * t * t * p2[0] + t * t * t * end[0],
          3 * a * a * t * p1[1] + 3 * a * t * t * p2[1] + t * t * t * end[1],
        ];
      }

      final reached = math.min(d, f.len);
      if (reached >= f.len) {
        ou = end[0];
        oz = end[1];
        du = math.cos(th);
        dz = math.sin(th);
      } else {
        final t = _evenT(at, reached / f.len);
        final b = at(t);
        ou = b[0];
        oz = b[1];
        final e = at(math.min(1.0, t + 1e-4)), e0 = at(math.max(0.0, t - 1e-4));
        final tl = math.sqrt(math.pow(e[0] - e0[0], 2) + math.pow(e[1] - e0[1], 2));
        du = tl < 1e-12 ? 1.0 : (e[0] - e0[0]) / tl;
        dz = tl < 1e-12 ? 0.0 : (e[1] - e0[1]) / tl;
      }
      final restU = across - reached;
      final nu = ou + du * restU - dz * up;
      final nz = oz + dz * restU + du * up;
      return [f.m[0] + f.nrm[0] * along + f.u[0] * nu, f.m[1] + f.nrm[1] * along + f.u[1] * nu, nz];
    }
    du = math.cos(th);
    dz = math.sin(th);
    final nu = du * across - dz * up;
    final nz = dz * across + du * up;
    return [f.m[0] + f.nrm[0] * along + f.u[0] * nu, f.m[1] + f.nrm[1] * along + f.u[1] * nu, nz];
  }
}

/// The resolved folds of an origami (for the stage).
List<OrigamiFold> origamiResolved(Map<String, dynamic> params, Grid rest) => _Folds.of(params, rest, all: true)?.folds ?? const [];

/// Each crease line, content space: its fold, the position key, the
/// line's two ends (past the shape by [origamiLineReach]) - on the folded
/// paper unless [origamiLinesOnFlat] (or `flat`). `scale`: the layer's,
/// when the folds keep their angles on screen (see [origamiScale]).
List<({int n, String key, List<double> a, List<double> b, List<List<double>> pts})> origamiFoldLines(Map<String, dynamic> params, Grid rest,
    {List<double>? scale, bool? flat}) {
  final sc = scale ?? const [1.0, 1.0];
  final c0 = _centre(params, rest);
  final g = scale == null ? rest : scaleGridAbout(rest, c0, sc);
  final p = scale == null ? params : _scaledParams(params, c0, sc);
  final f = _Folds.of(p, g, all: true);
  if (f == null) return const [];
  final box = _boxOf(p, g);
  final w = box[2] - box[0], h = box[3] - box[1];
  final ext = math.max(w, h) * origamiLineReach;
  final keys = origamiFolds(params);
  final persp = _num(params['perspective'], 0).clamp(0.0, 1.0);
  final focal = persp <= 0 ? double.infinity : f.size / persp;
  List<double> back(List<double> q) => [c0[0] + (q[0] - c0[0]) / sc[0], c0[1] + (q[1] - c0[1]) / sc[1]];
  List<double> show(List<double> q) {
    if (flat ?? origamiLinesOnFlat) return back(q);
    final m = f.map(q);
    return back(_project(m, f.c, focal));
  }

  return [
    for (var i = 0; i < f.folds.length; i++)
      () {
        final fo = f.folds[i];
        final across = (w / 2 * fo.nrm[0]).abs() + (h / 2 * fo.nrm[1]).abs() + ext;
        // the crease's middle: where the box's middle line meets it.
        final mid = [f.c[0] + fo.u[0] * fo.s, f.c[1] + fo.u[1] * fo.s];
        final a = [mid[0] - fo.nrm[0] * across, mid[1] - fo.nrm[1] * across];
        final b = [mid[0] + fo.nrm[0] * across, mid[1] + fo.nrm[1] * across];
        // along it too: on folded paper it can bend where it crosses others.
        final pts = [
          for (var k = 0; k <= 16; k++) show([a[0] + (b[0] - a[0]) * k / 16, a[1] + (b[1] - a[1]) * k / 16])
        ];
        return (n: fo.n, key: keys[i].position, a: pts.first, b: pts.last, pts: pts);
      }()
  ];
}

/// A crease's middle and a point one unit along its folding way, both as
/// shown (content space) - how the stage turns a finger's move into the
/// fold's position and direction.
({List<double> mid, List<double> along, List<double> side})? origamiFoldFrame(
    Map<String, dynamic> params, Grid rest, int n,
    {List<double>? scale}) {
  final sc = scale ?? const [1.0, 1.0];
  final c0 = _centre(params, rest);
  final g = scale == null ? rest : scaleGridAbout(rest, c0, sc);
  final p = scale == null ? params : _scaledParams(params, c0, sc);
  final f = _Folds.of(p, g, all: true);
  if (f == null) return null;
  final fo = f.folds.where((x) => x.n == n).firstOrNull;
  if (fo == null) return null;
  final persp = _num(params['perspective'], 0).clamp(0.0, 1.0);
  final focal = persp <= 0 ? double.infinity : f.size / persp;
  List<double> back(List<double> q) => [c0[0] + (q[0] - c0[0]) / sc[0], c0[1] + (q[1] - c0[1]) / sc[1]];
  List<double> show(List<double> q) =>
      (origamiLinesOnFlat) ? back(q) : back(_project(f.map(q), f.c, focal));
  final mid = [f.c[0] + fo.u[0] * fo.s, f.c[1] + fo.u[1] * fo.s];
  final unit = f.size / 100;
  return (
    mid: show(mid),
    along: show([mid[0] - fo.u[0] * unit, mid[1] - fo.u[1] * unit]),
    side: show([mid[0] + fo.nrm[0] * unit, mid[1] + fo.nrm[1] * unit]),
  );
}

/// The position (0..1) that puts fold `n`'s crease through rest point p.
double origamiPositionAt(Map<String, dynamic> params, Grid rest, List<double> p, {List<double>? scale, int n = 1}) {
  final sc = scale ?? const [1.0, 1.0];
  final c0 = _centre(params, rest);
  final box = _boxOf(params, rest);
  final w = (box[2] - box[0]) * sc[0], h = (box[3] - box[1]) * sc[1];
  final k = origamiFolds(params).where((x) => x.n == n).firstOrNull ?? origamiFolds(params).first;
  final ang = _num(params[k.direction] ?? params['direction'], 0) * math.pi / 180;
  final u = [math.cos(ang), math.sin(ang)];
  final reach = (w / 2 * u[0]).abs() + (h / 2 * u[1]).abs();
  if (reach <= 1e-9) return 0.5;
  final s = (p[0] - c0[0]) * sc[0] * u[0] + (p[1] - c0[1]) * sc[1] * u[1];
  return ((s + reach) / (2 * reach)).clamp(0.0, 1.0);
}

/// The positions (0..1) where fold `n`'s crease passes through one of
/// `points` (the shape's corners - for snapping it edge to corner).
List<double> origamiPositionsThrough(Map<String, dynamic> params, Grid rest, List<List<double>> points,
        {List<double>? scale, int n = 1}) =>
    [for (final p in points) origamiPositionAt(params, rest, p, scale: scale, n: n)];

/// The fold direction (degrees) that points from the box's middle to a
/// content-space point.
double origamiDirectionAt(Grid rest, List<double> p, {List<double>? scale}) {
  final sc = scale ?? const [1.0, 1.0];
  final c0 = _centre(const {}, rest);
  final d = math.atan2((p[1] - c0[1]) * sc[1], (p[0] - c0[0]) * sc[0]) * 180 / math.pi;
  return (d + 360) % 360;
}

/// Fold `n` set so its crease runs through rest points a and b (the part
/// on the side it already folds keeps folding).
void origamiFoldThrough(EffectInstance inst, Grid rest, int n, List<double> a, List<double> b, int frame,
    void Function(Track t, int f, dynamic v) setAt) {
  final k = origamiFolds(inst.params).where((x) => x.n == n).firstOrNull;
  if (k == null) return;
  final dx = b[0] - a[0], dy = b[1] - a[1];
  if (dx * dx + dy * dy < 1e-9) return;
  // two ways across the line: keep the one nearer the current direction.
  final cur = _trackValue(inst.params[k.direction] ?? inst.params['direction'], 0) * math.pi / 180;
  var nd = math.atan2(dx, -dy); // a normal of a->b
  final c1 = math.cos(nd - cur);
  if (c1 < 0) nd += math.pi;
  final deg = (nd * 180 / math.pi + 360) % 360;
  final dt = inst.params[k.direction];
  if (dt is Track) {
    setAt(dt, frame, deg);
  } else {
    inst.params[k.direction] = track(deg);
  }
  final params = {...inst.params}..[k.direction] = deg;
  final pos = origamiPositionAt(params, rest, a, n: n);
  final pt = inst.params[k.position];
  if (pt is Track) setAt(pt, frame, pos);
}

double _trackValue(dynamic t, double d) => t is Track ? _num(t.defaultValue, d) : _num(t, d);

List<double> _boxOf(Map<String, dynamic> params, Grid g) {
  final b = params['_box'];
  if (b is List && b.length == 4) return [for (final v in b) _num(v, 0)];
  final box = gridBox(g);
  return [box.minX, box.minY, box.maxX, box.maxY];
}

List<double> _centre(Map<String, dynamic> params, Grid g) {
  final b = _boxOf(params, g);
  return [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2];
}

Map<String, dynamic> _scaledParams(Map<String, dynamic> params, List<double> c, List<double> s) {
  final b = params['_box'];
  if (b is! List || b.length != 4) return params;
  final v = [for (final e in b) _num(e, 0)];
  return {
    ...params,
    '_box': [c[0] + (v[0] - c[0]) * s[0], c[1] + (v[1] - c[1]) * s[1], c[0] + (v[2] - c[0]) * s[0], c[1] + (v[3] - c[1]) * s[1]],
  };
}

/// `g` stretched by `s` about `c`.
Grid scaleGridAbout(Grid g, List<double> c, List<double> s) => [
      for (final row in g) [for (final p in row) [c[0] + (p[0] - c[0]) * s[0], c[1] + (p[1] - c[1]) * s[1]]]
    ];

/// The layer's scale at `localFrame` when its folds keep their angles on
/// screen and it is stretched unevenly; null otherwise (nothing to undo).
List<double>? origamiScale(Layer layer, double localFrame) {
  if (!layer.foldsIgnoreScale) return null;
  final v = evaluateTrack(null, layer.transform.scale, localFrame);
  if (v is! List || v.length < 2) return null;
  final sx = (v[0] as num).toDouble().abs(), sy = (v[1] as num).toDouble().abs();
  if (sx < 1e-6 || sy < 1e-6 || (sx - sy).abs() < 1e-9) return null;
  return [sx, sy];
}

/// Origami in on-screen proportions: the grid stretched by `s`, folded,
/// and stretched back - so a stretched layer folds at the angles shown.
Grid origamiGridScaled(Grid grid, Map<String, dynamic> params, double localFrame, List<double> s) {
  final c = _centre(params, grid);
  final folded = origamiGrid(scaleGridAbout(grid, c, s), _scaledParams(params, c, s), localFrame);
  return scaleGridAbout(folded, c, [1 / s[0], 1 / s[1]]);
}

/// The grid hints of origami in on-screen proportions, turned back into
/// the layer's own space.
List<GridHint> origamiHintsScaled(Map<String, dynamic> params, Grid rest, List<double> s) {
  final c = _centre(params, rest);
  final hints = effectRegistry['origami_fold']!.gridHints!(_scaledParams(params, c, s), scaleGridAbout(rest, c, s));
  return [
    for (final h in hints)
      () {
        final a = h.axisAngle * math.pi / 180;
        final us = [math.cos(a), math.sin(a)];
        // the fold line's way across, in the layer's own space.
        final nc0 = [-us[1] / s[0], us[0] / s[1]];
        final nl = math.sqrt(nc0[0] * nc0[0] + nc0[1] * nc0[1]);
        var uc = [nc0[1] / nl, -nc0[0] / nl];
        final ud = [us[0] / s[0], us[1] / s[1]];
        var k = ud[0] * uc[0] + ud[1] * uc[1];
        if (k < 0) {
          uc = [-uc[0], -uc[1]];
          k = -k;
        }
        return GridHint(axisAngle: math.atan2(uc[1], uc[0]) * 180 / math.pi, from: h.from * k, to: h.to * k, rows: h.rows);
      }()
  ];
}

List<double> _project(List<double> q, List<double> c, double focal) {
  if (!focal.isFinite) return [q[0], q[1]];
  final k = focal / math.max(focal * 0.05, focal - q[2]);
  return [c[0] + (q[0] - c[0]) * k, c[1] + (q[1] - c[1]) * k];
}

/// Whether the creases' directions differ (the grid's rows can follow
/// only one way - then a fine even grid is used instead).
bool origamiMixedDirections(Map<String, dynamic> params) {
  final ds = <double>{
    for (final f in origamiFolds(params))
      if (_num(params[f.angle], 0) != 0) (_num(params[f.direction] ?? params['direction'], 0) % 180).roundToDouble()
  };
  return ds.length > 1;
}

Grid origamiGrid(Grid grid, Map<String, dynamic> params, double localFrame) {
  final f = _Folds.of(params, grid);
  if (f == null || f.folds.every((x) => x.theta == 0)) return grid;
  final persp = _num(params['perspective'], 0).clamp(0.0, 1.0);
  final focal = persp <= 0 ? double.infinity : f.size / persp;
  return [
    for (final row in grid) [for (final p in row) _project(f.map(p), f.c, focal)]
  ];
}

/// The curve parameter at fraction `f` of its length (24 chords).
double _evenT(List<double> Function(double t) at, double f) {
  const n = 24;
  final lens = <double>[0];
  var prev = at(0);
  for (var i = 1; i <= n; i++) {
    final p = at(i / n);
    lens.add(lens.last + math.sqrt(math.pow(p[0] - prev[0], 2) + math.pow(p[1] - prev[1], 2)));
    prev = p;
  }
  final total = lens.last;
  if (total <= 1e-12) return f;
  final target = f.clamp(0.0, 1.0) * total;
  for (var i = 1; i <= n; i++) {
    if (lens[i] >= target) {
      final seg = lens[i] - lens[i - 1];
      final u = seg <= 1e-12 ? 0.0 : (target - lens[i - 1]) / seg;
      return (i - 1 + u) / n;
    }
  }
  return 1;
}
