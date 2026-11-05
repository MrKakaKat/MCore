/// ============================================================
/// INTERPOLATION MODULE
/// - temporal easing: cubic-bezier(x1,y1,x2,y2) solved for t, this
///   is stored PER KEYFRAME SEGMENT independent of spatial path
/// - spatial interpolation: only meaningful for vector params
///   (position). Uses in/out tangents per keyframe -> cubic bezier
///   path. Falls back to linear when tangents are [0,0].
/// - pure functions only: no platform dependency, no side effects.
///
/// Ported from movement-core/src/core/interpolation.js.
/// ============================================================
library;

import 'dart:math' as math;

import '../model/project.dart';
import 'expressions.dart';

double solveCubicBezierY(double x1, double y1, double x2, double y2, double x) {
  // Newton-Raphson on the bezier parametric curve, solving for t at given x, returning y
  var t = x;
  for (var i = 0; i < 8; i++) {
    final cx = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t;
    final dx = 3 * (1 - t) * (1 - t) * x1 + 6 * (1 - t) * t * (x2 - x1) + 3 * t * t * (1 - x2);
    if (dx.abs() < 1e-6) break;
    t -= (cx - x) / dx;
    t = math.min(1, math.max(0, t));
  }
  return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t;
}

/// Overshoot: a damped swing that ends exactly on 1 - starts at 0,
/// passes 1 by about `amount` and swings `bounces` more times, getting
/// smaller each time, before landing (y(0) = 0, y(1) = 1).
double overshootCurve(double amount, int bounces, double x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final a = amount.clamp(0.001, 1.0);
  final w = math.pi * (bounces.clamp(0, 10) + 1.5);
  // first peak past 1 at x = pi / w: damp so it is about `amount`.
  final k = -math.log(a) * w / math.pi;
  return 1 - math.exp(-k * x) * math.cos(w * x);
}

/// The eased progress (0 at the start, 1 at the end, possibly outside
/// in between) of `e` at `x` in 0..1.
double easeProgress(Easing e, double x) => switch (e.kind) {
      'overshoot' => overshootCurve(e.amount, e.bounces, x),
      'anticipate' => 1 - overshootCurve(e.amount, e.bounces, 1 - x),
      _ => solveCubicBezierY(e.x1, e.y1, e.x2, e.y2, x),
    };

/// Speed-graph editing: a bezier whose speed peaks at `peak` (0..1 of
/// the time) - `smooth` 0 is a sharp spike there, 1 an even speed.
Easing speedPeakEasing(double peak, double smooth) {
  final p = peak.clamp(0.0, 1.0), s = smooth.clamp(0.0, 1.0);
  return Easing(p * (1 - s), 0, p + (1 - p) * s, 1);
}

/// The speed (d progress / d time) of `e` at `n + 1` even times 0..1.
List<double> easeSpeedSamples(Easing e, {int n = 60}) {
  const h = 1e-3;
  return [
    for (var i = 0; i <= n; i++)
      () {
        final x = i / n;
        final a = (x - h).clamp(0.0, 1.0), b = (x + h).clamp(0.0, 1.0);
        return (easeProgress(e, b) - easeProgress(e, a)) / (b - a);
      }()
  ];
}

/// Named speed shapes for the speed graph.
const speedPresets = <String, Easing>{
  'sharp': Easing(0.45, 0, 0.55, 1),
  'sine': Easing(0.37, 0, 0.63, 1),
  'soft start': Easing(0.5, 0, 1, 1),
  'soft end': Easing(0, 0, 0.5, 1),
  'even': Easing(0, 0, 1, 1),
};

double applyTemporalEasing(Keyframe k0, Keyframe k1, double localFrame) {
  final span = k1.frame - k0.frame;
  final x = span == 0 ? 0.0 : (localFrame - k0.frame) / span;
  return easeProgress(k1.temporal, x);
}

double lerp(double a, double b, double t) => a + (b - a) * t;

List<double> spatialLerpVec2(Keyframe k0, Keyframe k1, double easedT) {
  // an overshoot / anticipation leaves the segment: carry straight on
  // along the path's direction at its end (or start), so the object
  // passes the key and comes back the way it came.
  if (easedT > 1 || easedT < 0) {
    final end = easedT > 1;
    final at = spatialLerpVec2(k0, k1, end ? 1 : 0);
    final d = spatialDerivative(k0, k1, end ? 1 : 0);
    final over = end ? easedT - 1 : easedT;
    return [at[0] + d[0] * over, at[1] + d[1] * over];
  }
  final inTan = k0.spatialTangent.outTan;
  final outTan = k1.spatialTangent.inTan;
  final flat = inTan[0] == 0 && inTan[1] == 0 && outTan[0] == 0 && outTan[1] == 0;
  final p0 = k0.value as List<double>, p3 = k1.value as List<double>;
  if (flat) {
    return [lerp(p0[0], p3[0], easedT), lerp(p0[1], p3[1], easedT)];
  }
  // cubic bezier path using tangents as control-point offsets
  final p1 = [p0[0] + inTan[0], p0[1] + inTan[1]];
  final p2 = [p3[0] + outTan[0], p3[1] + outTan[1]];
  final t = easedT;
  final mt = 1 - t;
  final x = mt * mt * mt * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t * t * t * p3[0];
  final y = mt * mt * mt * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t * t * t * p3[1];
  return [x, y];
}

/// d(position)/d(t) of the segment at `t`.
List<double> spatialDerivative(Keyframe k0, Keyframe k1, double t) {
  final p0 = k0.value as List<double>, p3 = k1.value as List<double>;
  final a = k0.spatialTangent.outTan, b = k1.spatialTangent.inTan;
  final p1 = [p0[0] + a[0], p0[1] + a[1]], p2 = [p3[0] + b[0], p3[1] + b[1]];
  final mt = 1 - t;
  final d = [
    for (var c = 0; c < 2; c++)
      3 * mt * mt * (p1[c] - p0[c]) + 6 * mt * t * (p2[c] - p1[c]) + 3 * t * t * (p3[c] - p2[c])
  ];
  // a tangent pulled right onto its key gives no direction there: use
  // the chord.
  if (d[0].abs() < 1e-9 && d[1].abs() < 1e-9) return [p3[0] - p0[0], p3[1] - p0[1]];
  return d;
}

/// Arc-length table of a spatial track's whole path: per segment, the
/// cumulative length at evenly spaced bezier parameters.
class _ArcTable {
  final int signature;
  final List<List<double>> cumulative; // [segment][sample]
  final double total;
  _ArcTable(this.signature, this.cumulative, this.total);
}

const _arcSamples = 48;
final _arcTables = Expando<_ArcTable>('arcTables');

int _pathSignature(List<Keyframe> kfs) => Object.hashAll([
      for (final k in kfs) ...[
        ...(k.value as List<double>),
        ...k.spatialTangent.inTan,
        ...k.spatialTangent.outTan,
      ]
    ]);

_ArcTable _arcTable(Track trk) {
  final kfs = trk.keyframes;
  final sig = _pathSignature(kfs);
  final cached = _arcTables[trk];
  if (cached != null && cached.signature == sig) return cached;
  final cumulative = <List<double>>[];
  var total = 0.0;
  for (var i = 0; i < kfs.length - 1; i++) {
    final row = [total];
    var prev = spatialLerpVec2(kfs[i], kfs[i + 1], 0);
    for (var s = 1; s <= _arcSamples; s++) {
      final p = spatialLerpVec2(kfs[i], kfs[i + 1], s / _arcSamples);
      total += math.sqrt(math.pow(p[0] - prev[0], 2) + math.pow(p[1] - prev[1], 2));
      row.add(total);
      prev = p;
    }
    cumulative.add(row);
  }
  return _arcTables[trk] = _ArcTable(sig, cumulative, total);
}

/// Constant speed: the point `progress` (0..1, beyond for an overshoot)
/// of the way along the whole path, by length.
List<double> _pointAtPathFraction(Track trk, double progress) {
  final kfs = trk.keyframes;
  final table = _arcTable(trk);
  if (table.total <= 0) return [...(kfs.first.value as List<double>)];
  final last = kfs.length - 2;
  if (progress >= 1 || progress <= 0) {
    final end = progress >= 1;
    final seg = end ? last : 0;
    final segLen = table.cumulative[seg].last - table.cumulative[seg].first;
    // past an end: continue at the same speed, in the path's direction.
    final over = (end ? progress - 1 : progress) * table.total;
    final t = segLen <= 0 ? (end ? 1.0 : 0.0) : (end ? 1 + over / segLen : over / segLen);
    return spatialLerpVec2(kfs[seg], kfs[seg + 1], t);
  }
  final target = progress * table.total;
  var seg = 0;
  while (seg < last && table.cumulative[seg].last < target) {
    seg++;
  }
  final row = table.cumulative[seg];
  var s = 1;
  while (s < _arcSamples && row[s] < target) {
    s++;
  }
  final a = row[s - 1], b = row[s];
  final t = (s - 1 + (b > a ? (target - a) / (b - a) : 0)) / _arcSamples;
  return spatialLerpVec2(kfs[seg], kfs[seg + 1], t);
}

/// generic per-parameter evaluator: works for scalar or vec2 tracks.
/// `project`/`layer` are optional exactly like the JS (`layer` gates the
/// expression context; a null layer just calls evaluateExpression with
/// whatever context is already active, matching evaluateTrack's own
/// fallback when called without a layer).
dynamic evaluateTrack(Project? project, Track trk, double localFrame, [Layer? layer]) {
  final own = _evaluateOwn(project, trk, localFrame, layer);
  if (trk.animLayers.isEmpty) return own;
  return combineAnimLayers(project, trk, own, localFrame, layer);
}

/// `base` with the track's enabled animation layers on top (all of them,
/// or all but `skip`).
dynamic combineAnimLayers(Project? project, Track trk, dynamic base, double localFrame, [Layer? layer, AnimLayer? skip]) {
  var v = base;
  for (final a in trk.animLayers) {
    if (!a.enabled || identical(a, skip)) continue;
    v = combineValues(v, _evaluateOwn(project, a.track, localFrame, layer), a.multiply);
  }
  return v;
}

/// v + d (or v * d), number or per component.
dynamic combineValues(dynamic v, dynamic d, bool multiply) {
  if (v is List<double> && d is List) {
    return [for (var i = 0; i < v.length; i++) multiply ? v[i] * (d[i] as num) : v[i] + (d[i] as num)];
  }
  final a = (v as num).toDouble(), b = (d as num).toDouble();
  return multiply ? a * b : a + b;
}

/// What a layer must hold so that `others` combined with it gives `total`.
dynamic residualValue(dynamic total, dynamic others, bool multiply) {
  if (total is List && others is List) {
    return <double>[
      for (var i = 0; i < total.length; i++)
        multiply
            ? ((others[i] as num) == 0 ? 1.0 : (total[i] as num) / (others[i] as num))
            : (total[i] as num).toDouble() - (others[i] as num)
    ];
  }
  final t = (total as num).toDouble(), o = (others as num).toDouble();
  return multiply ? (o == 0 ? 1.0 : t / o) : t - o;
}

/// A track's own value (keys / default / expression), no animation layers.
dynamic evaluateTrackOwn(Project? project, Track trk, double localFrame, [Layer? layer]) =>
    _evaluateOwn(project, trk, localFrame, layer);

dynamic _evaluateOwn(Project? project, Track trk, double localFrame, [Layer? layer]) {
  // a text track (text keys): each key holds until the next.
  if (trk.defaultValue is String) {
    var v = trk.defaultValue;
    for (final k in trk.keyframes) {
      if (k.frame <= localFrame) v = k.value;
    }
    return v;
  }
  if (trk.expression != null) {
    if (layer != null && project != null) {
      return withExpressionContext(
        (localFrame + layer.startFrame).round(),
        layer,
        () => evaluateExpression(project, trk),
      );
    }
    return project != null ? evaluateExpression(project, trk) : trk.defaultValue;
  }

  final kfs = trk.keyframes;
  if (kfs.isEmpty) return trk.defaultValue;

  var frame = localFrame;
  // loop: once past the last keyframe, wrap localFrame back into the
  // [first,last] span instead of holding at the final value - needs
  // 2+ keyframes to define a cycle length at all.
  if (trk.loop && kfs.length >= 2 && frame > kfs.last.frame) {
    final first = kfs.first.frame, last = kfs.last.frame;
    final span = last - first;
    if (span > 0) frame = first + ((frame - first) % span + span) % span;
  }

  if (frame <= kfs.first.frame) return kfs.first.value;
  if (frame >= kfs.last.frame) return kfs.last.value;

  final spatialPath = trk.spatial && kfs.length >= 2 && kfs.first.value is List<double>;

  // constant speed: one pace along the whole path by length, shaped only
  // by the whole-path curve; the keys' own times don't matter.
  if (spatialPath && trk.constantSpeed) {
    final f0 = kfs.first.frame, span = kfs.last.frame - f0;
    final globalT = span == 0 ? 0.0 : (frame - f0) / span;
    final g = trk.globalEasing;
    final progress = g == null ? globalT : _wholePathProgress(g, globalT);
    return _pointAtPathFraction(trk, progress);
  }

  // whole-path easing: ONE bezier curve governs pace across the ENTIRE
  // path instead of one per segment.
  if (spatialPath && trk.globalEasing != null) {
    final f0 = kfs.first.frame, fN = kfs.last.frame;
    final span = fN - f0;
    final globalT = span == 0 ? 0.0 : (frame - f0) / span;
    final eased = _wholePathProgress(trk.globalEasing!, globalT);
    if (eased > 1 || eased < 0) {
      // overshoot past the last key (anticipation before the first),
      // along the path's direction there.
      final end = eased > 1;
      final k0 = end ? kfs[kfs.length - 2] : kfs[0], k1 = end ? kfs.last : kfs[1];
      final segSpan = math.max(1, k1.frame - k0.frame);
      final over = (end ? eased - 1 : eased) * span / segSpan;
      return spatialLerpVec2(k0, k1, end ? 1 + over : over);
    }
    final effectiveFrame = f0 + eased * span;
    var gi = 0;
    while (gi < kfs.length - 1 && kfs[gi + 1].frame < effectiveFrame) {
      gi++;
    }
    final gk0 = kfs[gi], gk1 = kfs[gi + 1];
    final segSpan = gk1.frame - gk0.frame;
    final segT = segSpan == 0 ? 0.0 : (effectiveFrame - gk0.frame) / segSpan;
    return spatialLerpVec2(gk0, gk1, segT);
  }

  var i = 0;
  while (i < kfs.length - 1 && kfs[i + 1].frame < frame) {
    i++;
  }
  final k0 = kfs[i], k1 = kfs[i + 1];
  final easedT = applyTemporalEasing(k0, k1, frame);

  if (k0.value is List<double>) {
    if (trk.spatial) {
      return spatialLerpVec2(k0, k1, easedT); // treats the array as a literal 2D path
    }
    final v0 = k0.value as List<double>, v1 = k1.value as List<double>;
    return [for (var idx = 0; idx < v0.length; idx++) lerp(v0[idx], v1[idx], easedT)]; // independent channels
  }
  return lerp((k0.value as num).toDouble(), (k1.value as num).toDouble(), easedT);
}

/// Whole-path pace at `x`. A bezier is clamped to [0,1] - a y-overshoot
/// bezier makes Y(x) non-monotonic, which for a SPATIAL path means
/// progress-along-the-path briefly runs backward and the path draws over
/// itself. An overshoot ease is allowed past the ends: the object leaves
/// the path along its direction there and comes back.
double _wholePathProgress(Easing g, double x) {
  final y = easeProgress(g, x);
  return g.isOvershoot ? y : math.min(1.0, math.max(0.0, y));
}

/// ============================================================
/// SPLINE TENSION (auto-tangent for spatial paths only)
/// - Cardinal/Catmull-Rom style: one scalar (0..1) per track, drives
///   every keyframe's spatialTangent automatically from its neighbors.
/// - tension=0 -> loose, fully rounded path (classic Catmull-Rom)
/// - tension=1 -> tangents collapse to zero -> straight segments
/// ============================================================

List<double> catmullRomTangent(List<List<double>> points, int i, double tension) {
  final n = points.length;
  final k = 1 - tension;
  if (i == 0) {
    final p0 = points[0], p1 = points[1];
    return [k * (p1[0] - p0[0]), k * (p1[1] - p0[1])];
  }
  if (i == n - 1) {
    final p0 = points[n - 2], p1 = points[n - 1];
    return [k * (p1[0] - p0[0]), k * (p1[1] - p0[1])];
  }
  final pp = points[i - 1], pn = points[i + 1];
  return [k * (pn[0] - pp[0]) / 2, k * (pn[1] - pp[1]) / 2];
}

void autoComputeTangents(Track trk) {
  final kfs = trk.keyframes;
  if (kfs.length < 2) return;
  final tension = trk.tension ?? 1.0;
  final points = [for (final k in kfs) k.value as List<double>];
  for (var i = 0; i < kfs.length; i++) {
    final m = catmullRomTangent(points, i, tension);
    kfs[i].spatialTangent = SpatialTangent(
      outTan: [m[0] / 3, m[1] / 3],
      inTan: [-m[0] / 3, -m[1] / 3],
    );
  }
}
