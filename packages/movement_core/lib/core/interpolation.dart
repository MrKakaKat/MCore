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
import 'stage_size.dart';

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
///
/// `damping` (1: as before) makes the later swings die out sooner (> 1)
/// or later (< 1): the first one stays about `amount`.
double overshootCurve(double amount, int bounces, double x, {double damping = 1}) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final a = amount.clamp(0.001, 1.0);
  final w = math.pi * (bounces.clamp(0, 10) + 1.5);
  // first peak past 1 at x = pi / w: damp so it is about `amount`.
  final k = -math.log(a) * w / math.pi;
  final d = damping.clamp(0.2, 5.0);
  if (d == 1) return 1 - math.exp(-k * x) * math.cos(w * x);
  // the swings after the first die out `d` times as fast: the envelope
  // bends at the first peak (x0) and is joined smoothly there.
  final x0 = math.pi / w;
  final env = x <= x0 ? math.exp(-k * x) : math.exp(-k * x0 - k * d * (x - x0));
  // ends exactly on 1: what is left at x = 1 fades out linearly.
  final rest = math.exp(-k * x0 - k * d * (1 - x0)) * math.cos(w);
  return 1 - env * math.cos(w * x) + rest * x;
}

/// The eased progress (0 at the start, 1 at the end, possibly outside
/// in between) of `e` at `x` in 0..1. Anticipation and overshoot
/// together: the swing back takes the first half (half the way), the
/// overshoot the rest.
double easeProgress(Easing e, double x) {
  // a border: still until the key, then its value at once.
  if (e.hold) return x >= 1 ? 1 : 0;
  double over(double u, {double scale = 1}) =>
      overshootCurve((e.amount * scale).clamp(0.001, 1.0), e.bounces, u, damping: e.damping);
  double ant(double u, {double scale = 1}) =>
      1 - overshootCurve((e.antAmount * scale).clamp(0.001, 1.0), e.antBounces, 1 - u, damping: e.antDamping);
  if (e.over && e.ant) {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    return x < 0.5 ? 0.5 * ant(x * 2, scale: 2) : 0.5 + 0.5 * over((x - 0.5) * 2, scale: 2);
  }
  if (e.over) return over(x);
  if (e.ant) return ant(x);
  return solveCubicBezierY(e.x1, e.y1, e.x2, e.y2, x);
}

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
      stageSize.width,
      stageSize.height,
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
  // lengths on the stage (px), not in fractions of it: a path turned on a
  // stage that isn't square keeps its pace.
  final w = stageSize.width, h = stageSize.height;
  for (var i = 0; i < kfs.length - 1; i++) {
    final row = [total];
    var prev = spatialLerpVec2(kfs[i], kfs[i + 1], 0);
    for (var s = 1; s <= _arcSamples; s++) {
      final p = spatialLerpVec2(kfs[i], kfs[i + 1], s / _arcSamples);
      total += math.sqrt(math.pow((p[0] - prev[0]) * w, 2) + math.pow((p[1] - prev[1]) * h, 2));
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

bool _numericKey(dynamic v) => v is num || (v is List && v.every((e) => e is num));

dynamic _copyValue(dynamic v) => v is List ? [for (final e in v) (e as num).toDouble()] : v;

/// An offset loop's passes after the first that stay within its limits
/// (loopMin / loopMax) - null: no limit, it goes on. 0: it stops at its
/// last key.
int? loopOffsetPasses(Track trk) {
  final kfs = trk.keyframes;
  if (!trk.loop || trk.loopMode != 'offset' || kfs.length < 2) return null;
  if (trk.loopMin == null && trk.loopMax == null) return null;
  final start = loopStartKey(trk);
  if (!_numericKey(start.value) || !_numericKey(kfs.last.value)) return null;
  List<double> asList(dynamic v) => v is List ? [for (final e in v) (e as num).toDouble()] : [(v as num).toDouble()];
  final a = asList(start.value), b = asList(kfs.last.value);
  int? best;
  for (var i = 0; i < b.length && i < a.length; i++) {
    final d = b[i] - a[i];
    if (d.abs() < 1e-12) continue;
    final limit = d < 0 ? trk.loopMin : trk.loopMax;
    if (limit == null) continue;
    final k = ((limit - b[i]) / d + 1e-9).floor();
    final n = k < 0 ? 0 : k;
    best = best == null ? n : math.min(best, n);
  }
  return best;
}

/// Where an offset loop stops, local frame (null: it doesn't).
int? loopStopFrame(Track trk) {
  final passes = loopOffsetPasses(trk);
  if (passes == null) return null;
  final kfs = trk.keyframes;
  return kfs.last.frame + passes * (kfs.last.frame - loopStartKey(trk).frame);
}

/// Loop: the key it repeats from - `loopFrom`'s (or the last key before
/// it), else its first; never its last.
Keyframe loopStartKey(Track trk) {
  final kfs = trk.keyframes;
  final from = trk.loopFrom;
  if (from == null) return kfs.first;
  var k = kfs.first;
  for (var i = 0; i < kfs.length - 1; i++) {
    if (kfs[i].frame <= from) k = kfs[i];
  }
  return k;
}

/// `base` with the track's enabled animation layers on top (all of them,
/// or all but `skip`).
dynamic combineAnimLayers(Project? project, Track trk, dynamic base, double localFrame, [Layer? layer, AnimLayer? skip]) {
  var v = base;
  for (final a in trk.animLayers) {
    if (!a.enabled || identical(a, skip)) continue;
    // before its first key: holding it, or coming in after what moves
    // before it (see animLayerLeadIn).
    final lead = animLayerLeadIn(trk, a, localFrame);
    if (lead != null) {
      if (localFrame <= lead.from) continue;
      final t = (localFrame - lead.from) / (lead.at - lead.from);
      final firstV = _evaluateOwn(project, a.track, lead.at.toDouble(), layer);
      final neutral = a.multiply ? 1.0 : 0.0;
      final part = firstV is List
          ? <double>[for (final x in firstV) neutral + ((x as num) - neutral) * t]
          : neutral + ((firstV as num) - neutral) * t;
      v = combineValues(v, part, a.multiply);
      continue;
    }
    v = combineValues(v, _evaluateOwn(project, a.track, localFrame, layer), a.multiply);
  }
  return v;
}

/// Animation layer `a` of `trk` before its first key, as the
/// parameter's own keys behave there: with nothing else moving the
/// parameter before it, it holds its first key (an appearance from 0
/// opacity is hidden before it starts, a move waits at its start); with
/// something moving before it (the parameter's own keys, another layer's
/// range), it comes in from nothing at that movement's last key to its
/// first key - what comes before is never shifted, and nothing jumps.
/// Null: it acts as usual here (on or after its first key, or holding it).
({double from, int at})? animLayerLeadIn(Track trk, AnimLayer a, double localFrame) {
  final ks = a.track.keyframes;
  if (ks.isEmpty) return null;
  var first = ks.first.frame;
  for (final k in ks) {
    if (k.frame < first) first = k.frame;
  }
  if (localFrame >= first) return null;
  // the last key before it of anything that moves the parameter.
  int? last;
  bool moves(List<Keyframe> kk) => kk.length >= 2 && kk.any((k) => !_sameValue(k.value, kk.first.value));
  void see(List<Keyframe> kk) {
    if (!moves(kk)) return;
    for (final k in kk) {
      if (k.frame < first && (last == null || k.frame > last!)) last = k.frame;
    }
  }

  see(trk.keyframes);
  for (final o in trk.animLayers) {
    if (identical(o, a) || !o.enabled) continue;
    see(o.track.keyframes);
  }
  if (last == null) return null;
  return (from: last!.toDouble(), at: first);
}

bool _sameValue(dynamic x, dynamic y) {
  if (x is List && y is List) {
    for (var i = 0; i < x.length && i < y.length; i++) {
      if (((x[i] as num) - (y[i] as num)).abs() > 1e-12) return false;
    }
    return true;
  }
  if (x is num && y is num) return (x - y).abs() <= 1e-12;
  return x == y;
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
  // a loop stopping at a frame: after it, where it got to there.
  final stop = trk.loopEnd;
  if (trk.loop && kfs.length >= 2 && stop != null && stop > kfs.last.frame && frame > stop) {
    return _evaluateOwn(project, trk, stop.toDouble(), layer);
  }
  // loop: once past the last keyframe, wrap localFrame back into the
  // [first,last] span instead of holding at the final value - needs
  // 2+ keyframes to define a cycle length at all. (From its loop key:
  // the keys before it play once.)
  if (trk.loop && kfs.length >= 2 && frame > kfs.last.frame) {
    final startKey = loopStartKey(trk);
    final first = startKey.frame, last = kfs.last.frame;
    final span = last - first;
    // offset: each pass goes on from where the one before ended.
    if (span > 0 && trk.loopMode == 'offset' && _numericKey(startKey.value) && _numericKey(kfs.last.value)) {
      final n = ((frame - first) / span).floor();
      final passes = loopOffsetPasses(trk);
      final delta = residualValue(kfs.last.value, startKey.value, false);
      dynamic times(dynamic d, int k) => d is List ? [for (final x in d) (x as num) * k] : (d as num) * k;
      // stopped: held where the last allowed pass ended.
      if (passes != null && n > passes) {
        return combineValues(_copyValue(kfs.last.value), times(delta, passes), false);
      }
      final inner = _evaluateOwn(project, trk, first + (frame - first) - n * span, layer);
      return combineValues(_copyValue(inner), times(delta, n), false);
    }
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
  // inside a drawn way (free move: its own points between two keys): one
  // ease - the end key's - over the whole way, its points at an even pace
  // in between (they were laid out by length).
  if (k0.passive || k1.passive || k1.pace != null) {
    var s = i, e = i + 1;
    while (s > 0 && kfs[s].passive) {
      s--;
    }
    while (e < kfs.length - 1 && kfs[e].passive) {
      e++;
    }
    // drawn as the hand went: along the way at exactly its pace.
    final pace = kfs[e].pace;
    if (pace != null && pace.length >= 2 && trk.spatial && !kfs[s].passive && kfs[s].value is List) {
      return _alongDrawnWay(kfs, s, e, pace, frame);
    }
    if (!kfs[s].passive && !kfs[e].passive) {
      final whole = applyTemporalEasing(kfs[s], kfs[e], frame);
      final at = kfs[s].frame + whole * (kfs[e].frame - kfs[s].frame);
      var j = s;
      while (j < e - 1 && kfs[j + 1].frame < at) {
        j++;
      }
      final a = kfs[j], b = kfs[j + 1];
      final span = b.frame - a.frame;
      var t = span == 0 ? 0.0 : (at - a.frame) / span;
      // a point of the way drawn with the hand's own pace: its stretch
      // eased as the hand went.
      if (b.passive && !b.temporal.isOvershoot && (b.temporal.x1 != 0 || b.temporal.y1 != 0 || b.temporal.x2 != 1 || b.temporal.y2 != 1)) {
        t = easeProgress(b.temporal, t);
      }
      if (a.value is List<double>) {
        if (trk.spatial) return spatialLerpVec2(a, b, t);
        final v0 = a.value as List<double>, v1 = b.value as List<double>;
        return [for (var idx = 0; idx < v0.length; idx++) lerp(v0[idx], v1[idx], t)];
      }
      return lerp((a.value as num).toDouble(), (b.value as num).toDouble(), t);
    }
  }
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

/// A drawn way's run (keys s..e) at `frame`, as far along its length as
/// the hand's pace says at that share of its time.
List<double> _alongDrawnWay(List<Keyframe> kfs, int s, int e, List<double> pace, num frame) {
  final span = kfs[e].frame - kfs[s].frame;
  final u = span <= 0 ? 1.0 : ((frame - kfs[s].frame) / span).clamp(0.0, 1.0);
  final x = u * (pace.length - 1);
  final j = x.floor().clamp(0, pace.length - 2);
  final p = pace[j] + (pace[j + 1] - pace[j]) * (x - j);
  final table = _runTable(kfs, s, e);
  final target = p * table.total;
  var lo = 0, hi = table.len.length - 1;
  while (lo < hi - 1) {
    final mid = (lo + hi) >> 1;
    if (table.len[mid] <= target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final a = table.len[lo], b = table.len[hi];
  final f = b - a <= 1e-15 ? 0.0 : (target - a) / (b - a);
  final q0 = table.pts[lo], q1 = table.pts[hi];
  return [q0[0] + (q1[0] - q0[0]) * f, q0[1] + (q1[1] - q0[1]) * f];
}

final _runTables = Expando<({String sig, List<List<double>> pts, List<double> len, double total})>('drawnRuns');

/// The run's points (16 a stretch) and the length along it to each.
({String sig, List<List<double>> pts, List<double> len, double total}) _runTable(List<Keyframe> kfs, int s, int e) {
  final end = kfs[e];
  final sig = StringBuffer('$s:$e');
  for (var k = s; k <= e; k++) {
    final v = kfs[k].value as List;
    final st = kfs[k].spatialTangent;
    sig.write('|${v[0]},${v[1]},${st.inTan[0]},${st.inTan[1]},${st.outTan[0]},${st.outTan[1]}');
  }
  final key = sig.toString();
  final cached = _runTables[end];
  if (cached != null && cached.sig == key) return cached;
  final pts = <List<double>>[];
  final len = <double>[];
  var acc = 0.0;
  for (var k = s; k < e; k++) {
    for (var q = (k == s ? 0 : 1); q <= 16; q++) {
      final pt = spatialLerpVec2(kfs[k], kfs[k + 1], q / 16);
      if (pts.isNotEmpty) acc += math.sqrt(math.pow(pt[0] - pts.last[0], 2) + math.pow(pt[1] - pts.last[1], 2));
      pts.add(pt);
      len.add(acc);
    }
  }
  final t = (sig: key, pts: pts, len: len, total: acc);
  _runTables[end] = t;
  return t;
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

/// The keys of one movement: a stretch between holds (two keys in a row
/// at the same place - where one movement ends and the next begins, as
/// order keys put them). Indices [a, b].
List<(int, int)> pathRuns(Track trk) {
  final kfs = trk.keyframes;
  final out = <(int, int)>[];
  var start = 0;
  for (var i = 0; i < kfs.length - 1; i++) {
    if (_sameValue(kfs[i].value, kfs[i + 1].value)) {
      if (i > start) out.add((start, i));
      start = i + 1;
    }
  }
  if (kfs.length - 1 > start) out.add((start, kfs.length - 1));
  return out;
}

/// The movement (see pathRuns) the local `frame` is in, or null.
(int, int)? pathRunAt(Track trk, num frame) {
  final kfs = trk.keyframes;
  for (final r in pathRuns(trk)) {
    if (frame >= kfs[r.$1].frame && frame <= kfs[r.$2].frame) return r;
  }
  return null;
}

/// The smooth handles of key `i` from its neighbours in its movement
/// (none across a hold).
SpatialTangent _runTangent(Track trk, int i, double tension) {
  final kfs = trk.keyframes;
  final run = pathRuns(trk).where((r) => i >= r.$1 && i <= r.$2).firstOrNull;
  if (run == null) return SpatialTangent.zero();
  final points = [
    for (var j = run.$1; j <= run.$2; j++) [for (final v in kfs[j].value as List) (v as num).toDouble()]
  ];
  final m = catmullRomTangent(points, i - run.$1, tension);
  final st = SpatialTangent(outTan: [m[0] / 3, m[1] / 3], inTan: [-m[0] / 3, -m[1] / 3]);
  // the movement's ends: nothing beyond them.
  if (i == run.$1) st.inTan = [0, 0];
  if (i == run.$2) st.outTan = [0, 0];
  return st;
}

/// Straight where the object holds: a key's handle into / out of a hold
/// (no going out and back while standing still).
void _straightHolds(Track trk) {
  final kfs = trk.keyframes;
  for (var i = 0; i < kfs.length - 1; i++) {
    if (!_sameValue(kfs[i].value, kfs[i + 1].value)) continue;
    kfs[i].spatialTangent = SpatialTangent(inTan: [...kfs[i].spatialTangent.inTan], outTan: [0, 0]);
    kfs[i + 1].spatialTangent = SpatialTangent(inTan: [0, 0], outTan: [...kfs[i + 1].spatialTangent.outTan]);
  }
}

void autoComputeTangents(Track trk) {
  final kfs = trk.keyframes;
  if (kfs.length < 2 || kfs.first.value is! List) return;
  final tension = trk.tension ?? 1.0;
  final points = [for (final k in kfs) k.value as List<double>];
  final holds = kfs.length > 2 && pathRuns(trk).length != 1;
  for (var i = 0; i < kfs.length; i++) {
    // handles set by hand stay as they are.
    if (kfs[i].hand) continue;
    if (holds) {
      kfs[i].spatialTangent = _runTangent(trk, i, tension);
      continue;
    }
    final m = catmullRomTangent(points, i, tension);
    kfs[i].spatialTangent = SpatialTangent(
      outTan: [m[0] / 3, m[1] / 3],
      inTan: [-m[0] / 3, -m[1] / 3],
    );
  }
  _straightHolds(trk);
}

/// Curve handles to be set by hand on the keys of local frames
/// `from`..`to` (all: the whole track): each keeps the handles it has;
/// one with none (a straight path) gets a smooth pair along its
/// neighbours in its movement, to be dragged from.
void startHandTangents(Track trk, {int? from, int? to}) {
  final kfs = trk.keyframes;
  trk.handTangents = true;
  if (kfs.length < 2 || kfs.first.value is! List) return;
  for (var i = 0; i < kfs.length; i++) {
    final k = kfs[i];
    if ((from != null && k.frame < from) || (to != null && k.frame > to)) continue;
    k.hand = true;
    final st = k.spatialTangent;
    final none = st.inTan.every((v) => v.abs() < 1e-9) && st.outTan.every((v) => v.abs() < 1e-9);
    if (none) k.spatialTangent = _runTangent(trk, i, 0);
  }
  _straightHolds(trk);
}

/// Curve handles back to the tension on the keys of `from`..`to` (all:
/// the whole track).
void stopHandTangents(Track trk, {int? from, int? to}) {
  for (final k in trk.keyframes) {
    if ((from != null && k.frame < from) || (to != null && k.frame > to)) continue;
    k.hand = false;
  }
  trk.handTangents = trk.keyframes.any((k) => k.hand);
  autoComputeTangents(trk);
}

// ===== elasticity: a value springing after its keys =====

class _Spring {
  final int signature;
  final double elastic, rate;
  final List<double> values; // per whole local frame from 0
  double speed = 0; // at the last of them
  _Spring(this.signature, this.elastic, this.rate, this.values);
}

final _springs = Expando<_Spring>('springs');

int _keysSignature(Track t) => Object.hashAll([
      for (final k in t.keyframes) ...[k.frame, k.value, k.temporal.x1, k.temporal.y1, k.temporal.x2, k.temporal.y2]
    ]);

/// Scalar track `t` at `localFrame` as a damped spring following it: the
/// value lags, overshoots and settles after each change (`elastic` 0..1:
/// 0 nearly follows, 1 swings a lot). Stepped frame by frame from the
/// track's start (cached).
double springFollow(Track t, double localFrame, double elastic) {
  final sig = _keysSignature(t);
  var s = _springs[t];
  if (s == null || s.signature != sig || s.elastic != elastic || s.rate != fps) {
    s = _springs[t] = _Spring(sig, elastic, fps.toDouble(), [(evaluateTrack(null, t, 0.0) as num).toDouble()]);
  }
  final target = localFrame.isFinite ? localFrame.clamp(0, 100000).toDouble() : 0.0;
  final need = target.ceil();
  if (s.values.length <= need) {
    // natural frequency ~3 Hz; damping from fully damped (0) to very
    // springy (1).
    const omega = 2 * math.pi * 3.0;
    final zeta = 1.0 - 0.92 * elastic;
    const sub = 4;
    final dt = 1 / (fps <= 0 ? 30 : fps) / sub;
    var x = s.values.last;
    var v = s.speed;
    for (var f = s.values.length; f <= need; f++) {
      for (var i = 0; i < sub; i++) {
        final goal = (evaluateTrack(null, t, f - 1 + (i + 1) / sub) as num).toDouble();
        final a = omega * omega * (goal - x) - 2 * zeta * omega * v;
        v += a * dt;
        x += v * dt;
      }
      s.values.add(x);
    }
    s.speed = v;
  }
  final i = target.floor(), frac = target - i;
  if (frac <= 0 || i + 1 >= s.values.length) return s.values[math.min(i, s.values.length - 1)];
  return s.values[i] + (s.values[i + 1] - s.values[i]) * frac;
}
