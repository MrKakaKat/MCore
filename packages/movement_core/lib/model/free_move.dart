/// Keyframes tab, "Free move": the object is dragged along a path on the
/// stage; confirmed, the path becomes two keys - a new animation layer
/// (key layer) moving it from where it stands along that curve.
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../core/state_cache.dart';
import '../ui_geometry/drag_ops.dart' show anchorLocalFromScreen;
import '../ui_geometry/handles.dart' show computeLayerFrameGeometry;
import 'project.dart';
import 'track_edit.dart';

/// The two inner control points of the cubic curve from `pts.first` to
/// `pts.last` closest to all of `pts` (least squares, points spread by
/// their distance along the stroke). Fewer than 3 points or a straight
/// stroke: the straight line's thirds.
List<List<double>> fitCubicInner(List<List<double>> pts) {
  final p0 = pts.first, p3 = pts.last;
  List<double> third(double k) => [p0[0] + (p3[0] - p0[0]) * k, p0[1] + (p3[1] - p0[1]) * k];
  if (pts.length < 3) return [third(1 / 3), third(2 / 3)];
  // chord-length parameters.
  final d = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    d.add(d.last + math.sqrt(math.pow(pts[i][0] - pts[i - 1][0], 2) + math.pow(pts[i][1] - pts[i - 1][1], 2)));
  }
  final total = d.last;
  if (total <= 1e-9) return [third(1 / 3), third(2 / 3)];
  // B(t) = b0 p0 + b1 p1 + b2 p2 + b3 p3: solve for p1, p2.
  var c11 = 0.0, c12 = 0.0, c22 = 0.0;
  final x1 = [0.0, 0.0], x2 = [0.0, 0.0];
  for (var i = 0; i < pts.length; i++) {
    final t = d[i] / total, u = 1 - t;
    final b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t;
    c11 += b1 * b1;
    c12 += b1 * b2;
    c22 += b2 * b2;
    for (var c = 0; c < 2; c++) {
      final r = pts[i][c] - b0 * p0[c] - b3 * p3[c];
      x1[c] += b1 * r;
      x2[c] += b2 * r;
    }
  }
  final det = c11 * c22 - c12 * c12;
  if (det.abs() < 1e-12) return [third(1 / 3), third(2 / 3)];
  return [
    [(x1[0] * c22 - x2[0] * c12) / det, (x1[1] * c22 - x2[1] * c12) / det],
    [(c11 * x2[0] - c12 * x1[0]) / det, (c11 * x2[1] - c12 * x1[1]) / det],
  ];
}

/// The cubic curve from `pts.first` to `pts.last` (a 4-point list).
List<List<double>> _fitPiece(List<List<double>> pts) => [pts.first, ...fitCubicInner(pts), pts.last];

/// How far `pts` stray from curve `c` (each point against the curve at
/// its share of the stroke's length); and where the worst one is.
(double, int) _stray(List<List<double>> pts, List<List<double>> c) {
  final d = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    d.add(d.last + math.sqrt(math.pow(pts[i][0] - pts[i - 1][0], 2) + math.pow(pts[i][1] - pts[i - 1][1], 2)));
  }
  var worst = 0.0, at = pts.length ~/ 2;
  for (var i = 1; i < pts.length - 1; i++) {
    final t = d.last == 0 ? 0.0 : d[i] / d.last, u = 1 - t;
    final x = u * u * u * c[0][0] + 3 * u * u * t * c[1][0] + 3 * u * t * t * c[2][0] + t * t * t * c[3][0];
    final y = u * u * u * c[0][1] + 3 * u * u * t * c[1][1] + 3 * u * t * t * c[2][1] + t * t * t * c[3][1];
    final e = math.sqrt(math.pow(x - pts[i][0], 2) + math.pow(y - pts[i][1], 2));
    if (e > worst) {
      worst = e;
      at = i;
    }
  }
  return (worst, at);
}

/// The stroke as cubic pieces (each [p0, p1, p2, p3]) none of which
/// strays more than `tolerance` from it - split where it strays most.
List<List<List<double>>> fitCubicPieces(List<List<double>> pts, double tolerance) =>
    [for (final p in _fitIndexed(pts, tolerance)) p.curve];

/// The pieces with the stroke points they run between.
List<({List<List<double>> curve, int from, int to})> _fitIndexed(List<List<double>> pts, double tolerance) {
  final out = <({List<List<double>> curve, int from, int to})>[];
  void fit(int i, int j) {
    final part = pts.sublist(i, j + 1);
    final c = _fitPiece(part);
    if (j - i < 3) {
      out.add((curve: c, from: i, to: j));
      return;
    }
    final (err, at) = _stray(part, c);
    if (err <= tolerance) {
      out.add((curve: c, from: i, to: j));
      return;
    }
    final k = i + at.clamp(1, j - i - 1);
    fit(i, k);
    fit(k, j);
  }

  fit(0, pts.length - 1);
  return out;
}

/// A new animation layer on `layer` moving it along `framePath` (frame
/// px, its first point where it stands) from `globalFrame`. `smoothing`
/// 0..1: 0 follows the way as drawn (as many keys as it takes), more lets
/// the curve stray further (fewer keys), 1 is one smooth curve - two keys,
/// the curve in their handles.
///
/// Timing: by default it takes `frames` frames at one pace along the
/// whole way, shaped by one ease from its first key to its last (`ease`).
/// With `times` (seconds from the first point, one per point of the way)
/// it keeps the pace it was drawn with - as long and as quick as the hand
/// was. Returns the layer's number (0: nothing to make).
int addFreeMoveLayer(Project project, Layer layer, List<List<double>> framePath, int globalFrame, int frames,
    {double smoothing = 1, List<double>? times, Easing? ease}) {
  if (framePath.length < 2) return 0;
  final first = framePath.first;
  if (framePath.every((p) => (p[0] - first[0]).abs() < 1e-9 && (p[1] - first[1]).abs() < 1e-9)) return 0;
  final timed = times != null && times.length == framePath.length && times.last > 0;
  if (timed) frames = math.max(1, (times.last * fps).round());
  if (frames < 1) return 0;
  // the pieces, in frame px; at most one per frame.
  List<({List<List<double>> curve, int from, int to})> pieces;
  if (smoothing >= 0.999) {
    pieces = [(curve: _fitPiece(framePath), from: 0, to: framePath.length - 1)];
  } else {
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final p in framePath) {
      x0 = math.min(x0, p[0]);
      x1 = math.max(x1, p[0]);
      y0 = math.min(y0, p[1]);
      y1 = math.max(y1, p[1]);
    }
    final size = math.max(1.0, math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)));
    var tol = 0.75 + smoothing * smoothing * 0.15 * size;
    pieces = _fitIndexed(framePath, tol);
    while (pieces.length > frames) {
      tol *= 2;
      pieces = _fitIndexed(framePath, tol);
    }
  }
  // in the position's own space (a parent's too), from the start.
  final o = anchorLocalFromScreen(project, layer, first[0], first[1], globalFrame);
  List<double> loc(List<double> p) {
    final q = anchorLocalFromScreen(project, layer, p[0], p[1], globalFrame);
    return [q[0] - o[0], q[1] - o[1]];
  }

  final local = [for (final c in pieces) [for (final p in c.curve) loc(p)]];
  // key times: by when the hand was there, or by length along the way.
  double len(List<List<double>> c) => math.sqrt(math.pow(c[3][0] - c[0][0], 2) + math.pow(c[3][1] - c[0][1], 2));
  final total = pieces.fold(0.0, (a, c) => a + len(c.curve));
  final f0 = layerLocalFrame(layer, globalFrame).round();
  final keyTimes = <int>[f0];
  var acc = 0.0;
  for (var i = 0; i < pieces.length; i++) {
    acc += len(pieces[i].curve);
    final left = pieces.length - 1 - i; // keys still to come after this one
    var f = i == pieces.length - 1
        ? f0 + frames
        : timed
            ? f0 + (times[pieces[i].to] * fps).round()
            : f0 + (total == 0 ? i + 1 : (frames * acc / total).round());
    f = f.clamp(keyTimes.last + 1, f0 + frames - left);
    keyTimes.add(f);
  }
  final n = addTransformAnimLayer(layer);
  final trk = layer.transform.anchor.animLayers[n - 1].track
    ..spatial = true
    ..freeMove = true
    ..freeMoveSpan = [f0, f0 + frames];
  final linear = easingPresets['linear']!;
  trk.keyframes = [
    for (var i = 0; i <= pieces.length; i++)
      () {
        final p = i < pieces.length ? local[i][0] : local[i - 1][3];
        final inTan = i == 0 ? [0.0, 0.0] : [local[i - 1][2][0] - p[0], local[i - 1][2][1] - p[1]];
        final outTan = i == pieces.length ? [0.0, 0.0] : [local[i][1][0] - p[0], local[i][1][1] - p[1]];
        return Keyframe(
            frame: keyTimes[i],
            value: <double>[p[0], p[1]],
            temporal: linear,
            spatialTangent: SpatialTangent(inTan: inTan, outTan: outTan),
            // the way's own points: no keys to pick.
            passive: i > 0 && i < pieces.length);
      }()
  ];
  if (!timed) {
    // one pace along the whole way, one ease from its first key to its
    // last.
    trk.constantSpeed = true;
    trk.globalEasing = ease ?? newKeyEasing();
  }
  // its time reaches the last key.
  if (f0 + frames > layer.durationFrames) layer.durationFrames = f0 + frames;
  clearStateCaches();
  return n;
}

/// Each position track's own keys (not the drawn way's points) as last
/// seen - to tell which were taken away.
final _knownEnds = Expando<List<Keyframe>>('freeMoveEnds');

/// A drawn way goes with its end keys: a key taken away takes the drawn
/// points on both sides of it (up to the keys next to it) along. True:
/// something went.
bool _dropOrphanedWays(Track trk) {
  final ends = trk.keyframes.where((k) => !k.passive).toList()..sort((a, b) => a.frame.compareTo(b.frame));
  final before = _knownEnds[trk];
  _knownEnds[trk] = ends;
  if (before == null || ends.length >= before.length || !trk.keyframes.any((k) => k.passive)) return false;
  final gone = <(double, double)>[];
  for (var i = 0; i < before.length; i++) {
    final k = before[i];
    if (ends.any((e) => identical(e, k) || e.frame == k.frame)) continue;
    gone.add((i > 0 ? before[i - 1].frame.toDouble() : double.negativeInfinity,
        i + 1 < before.length ? before[i + 1].frame.toDouble() : double.infinity));
  }
  if (gone.isEmpty) return false;
  final n = trk.keyframes.length;
  trk.keyframes.removeWhere((k) => k.passive && gone.any((g) => k.frame > g.$1 && k.frame < g.$2));
  return trk.keyframes.length != n;
}

/// Free moves' passive keys follow their end keys: when the ends move,
/// each keeps its share of the time between them; with an end taken away,
/// they go too. True: something changed.
bool bindFreeMoveKeys(Layer layer) {
  var changed = false;
  void fix(Track trk) {
    if (_dropOrphanedWays(trk)) changed = true;
    if (trk.freeMove && trk.freeMoveSpan != null && !trk.keyframes.any((k) => k.passive)) {
      trk.freeMoveSpan = null;
      changed = true;
    }
    if (!trk.freeMove || !trk.keyframes.any((k) => k.passive)) return;
    final ends = trk.keyframes.where((k) => !k.passive).toList()..sort((a, b) => a.frame.compareTo(b.frame));
    if (ends.length < 2) {
      trk.keyframes.removeWhere((k) => k.passive);
      trk.freeMoveSpan = null;
      changed = true;
      return;
    }
    // its own two ends: the keys at (nearest) its span's ends - not the
    // track's first and last (a key added after it isn't its end).
    final span = trk.freeMoveSpan;
    final a0 = span?[0] ?? ends.first.frame, b0 = span?[1] ?? ends.last.frame;
    Keyframe nearest(int f, Keyframe? not) => ends
        .where((k) => !identical(k, not))
        .reduce((x, y) => (x.frame - f).abs() <= (y.frame - f).abs() ? x : y);
    final ka = nearest(a0, null), kb = nearest(b0, ka);
    final a1 = math.min(ka.frame, kb.frame), b1 = math.max(ka.frame, kb.frame);
    final passive = trk.keyframes.where((k) => k.passive).toList();
    final inside = passive.every((k) => k.frame > a1 && k.frame < b1);
    if (a0 == a1 && b0 == b1 && inside) return;
    // each keeps its share of the time between the ends (in its order).
    passive.sort((x, y) => x.frame.compareTo(y.frame));
    var last = a1;
    for (var i = 0; i < passive.length; i++) {
      final share = b0 == a0 ? (i + 1) / (passive.length + 1) : (passive[i].frame - a0) / (b0 - a0);
      final room = b1 - (passive.length - i); // the ones after it still need a frame each
      passive[i].frame = (a1 + share * (b1 - a1)).round().clamp(last + 1, math.max(last + 1, room));
      last = passive[i].frame;
    }
    trk.keyframes.sort((x, y) => x.frame.compareTo(y.frame));
    trk.freeMoveSpan = [a1, b1];
    changed = true;
  }

  fix(layer.transform.anchor);
  for (final al in layer.transform.anchor.animLayers) {
    fix(al.track);
  }
  return changed;
}

/// The selected layer's latest free move (its track), if it has one.
Track? latestFreeMove(Layer layer) {
  for (final al in layer.transform.anchor.animLayers.reversed) {
    if (al.track.freeMove) return al.track;
  }
  return null;
}

/// Before a move by hand at local frame `f` outside a free move's time:
/// the position's own track holds where it is at the free move's end
/// (or start) with a key, and gets a key at `f` - so the edit moves only
/// the stretch after (before) it, never the whole drawn way. No-op with
/// an animation layer picked for edits.
void holdAroundFreeMoves(Project project, Layer layer, int f) {
  final base = layer.transform.anchor;
  if (activeAnimLayerOf(base) != null) return;
  Keyframe key(int at) => Keyframe(
      frame: at, value: _copyValue(evaluateTrackOwn(project, base, at.toDouble(), layer)), temporal: newKeyEasing());
  for (final al in base.animLayers) {
    final t = al.track;
    if (!t.freeMove || !al.enabled) continue;
    final span = t.freeMoveSpan;
    if (span == null) continue;
    final a = span[0], b = span[1];
    final edge = f > b ? b : (f < a ? a : null);
    if (edge == null) continue;
    final adds = <Keyframe>[
      if (keyframeAt(base, edge) == null) key(edge),
      if (keyframeAt(base, f) == null) key(f),
    ];
    if (adds.isEmpty) continue;
    base.keyframes
      ..addAll(adds)
      ..sort((x, y) => x.frame.compareTo(y.frame));
    if (base.spatial) autoComputeTangents(base);
  }
}

dynamic _copyValue(dynamic v) => v is List ? [for (final e in v) (e as num).toDouble()] : v;

/// A drawn way set between two points as drawn: the hand's line kept,
/// only its very end led onto `pb` (its start onto `pa`) - the stretch
/// bent is as short as the miss allows. Drawn on past `pb` and back, it is
/// cut where it came closest to it.
List<List<double>> fitWayToEnds(List<List<double>> path, List<double> pa, List<double> pb) {
  if (path.length < 2) return [for (final p in path) [...p]];
  double dist(List<double> p, List<double> q) => math.sqrt(math.pow(p[0] - q[0], 2) + math.pow(p[1] - q[1], 2));
  final d = <double>[0];
  for (var i = 1; i < path.length; i++) {
    d.add(d.last + dist(path[i], path[i - 1]));
  }
  // where it ends: the point nearest pb in its later half.
  var cut = path.length - 1;
  for (var i = path.length - 1; i >= 1 && d[i] >= d.last / 2; i--) {
    if (dist(path[i], pb) < dist(path[cut], pb) - 1e-9) cut = i;
  }
  final way = [for (var i = 0; i <= cut; i++) [...path[i]]];
  final len = d[cut];
  final p0 = way.first, pn = way.last;
  final e0 = [pa[0] - p0[0], pa[1] - p0[1]], e1 = [pb[0] - pn[0], pb[1] - pn[1]];
  double reach(List<double> e) => math.min(len / 2, math.max(1.0, 3 * math.sqrt(e[0] * e[0] + e[1] * e[1])));
  final t0 = reach(e0), t1 = reach(e1);
  double smooth(double x) {
    final t = x.clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  for (var i = 0; i < way.length; i++) {
    final w0 = len <= 1e-9 ? 1 - i / math.max(1, way.length - 1) : 1 - smooth(d[i] / t0);
    final w1 = len <= 1e-9 ? i / math.max(1, way.length - 1) : smooth(1 - (len - d[i]) / t1);
    way[i] = [way[i][0] + e0[0] * w0 + e1[0] * w1, way[i][1] + e0[1] * w0 + e1[1] * w1];
  }
  return way;
}

/// Whether the way between `trk`'s keys at local frames a and b was drawn
/// (it has a drawn way's own points).
bool drawnWayBetween(Track trk, int a, int b) => trk.keyframes.any((k) => k.passive && k.frame > a && k.frame < b);

/// The drawn way between the keys at a and b taken away: its own points
/// go, the keys stay and the way between them is straight again. False:
/// nothing was drawn there.
bool removeMoveBetweenKeys(Track trk, int a, int b) {
  final ka = keyframeAt(trk, a), kb = keyframeAt(trk, b);
  if (ka == null || kb == null || !drawnWayBetween(trk, a, b)) return false;
  trk.keyframes.removeWhere((k) => k.passive && k.frame > a && k.frame < b);
  ka.spatialTangent = SpatialTangent(inTan: ka.spatialTangent.inTan, outTan: [0, 0]);
  kb.spatialTangent = SpatialTangent(inTan: [0, 0], outTan: kb.spatialTangent.outTan);
  if (trk.freeMove && !trk.keyframes.any((k) => k.passive)) trk.freeMoveSpan = null;
  clearStateCaches();
  return true;
}

/// Free move over a stretch already keyed: the way between `trk`'s keys at
/// local frames `a` and `b` (next to each other) is drawn anew -
/// `framePath` (frame px, from where the layer stands at `a`), bent so it
/// ends where the key at `b` puts it. The keys keep their frames and
/// values; the drawn way's own points come between them (passive, by
/// length - one pace). False when there is nothing to replace.
bool replaceMoveBetweenKeys(Project project, Layer layer, Track trk, int a, int b, List<List<double>> framePath,
    {double smoothing = 1}) {
  final ka = keyframeAt(trk, a), kb = keyframeAt(trk, b);
  if (ka == null || kb == null || b - a < 1 || framePath.length < 2) return false;
  if (trk.keyframes.any((k) => k.frame > a && k.frame < b && !k.passive)) return false;
  final ga = layer.startFrame + a, gb = layer.startFrame + b;
  // where the drawn way must start and end: the layer's middle there (as
  // the drawing does).
  List<double> centreAt(int g) => computeLayerFrameGeometry(project, layer, g, includeVertices: false).center;

  final pa = centreAt(ga), pb = centreAt(gb);
  // what the rest of the position adds at each frame (its own track
  // left out): the drawn way is the total, this track only its share.
  final base = layer.transform.anchor;
  List<double> v2(dynamic v) => [for (final e in v as List) (e as num).toDouble()];
  final others = <int, List<double>>{
    for (var f = a; f <= b; f++)
      f: () {
        final total = v2(evaluateTrack(project, base, f.toDouble(), layer));
        final own = identical(trk, base) ? v2(evaluateTrackOwn(project, base, f.toDouble(), layer)) : v2(evaluateTrack(project, trk, f.toDouble()));
        return [total[0] - own[0], total[1] - own[1]];
      }()
  };
  final totalA = v2(evaluateTrack(project, base, a.toDouble(), layer));
  final pts = fitWayToEnds(framePath, pa, pb);
  // the pieces (at most one per frame between the keys).
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final p in pts) {
    x0 = math.min(x0, p[0]);
    x1 = math.max(x1, p[0]);
    y0 = math.min(y0, p[1]);
    y1 = math.max(y1, p[1]);
  }
  final size = math.max(1.0, math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2)));
  var tol = smoothing >= 0.999 ? double.infinity : 0.75 + smoothing * smoothing * 0.15 * size;
  var pieces = tol.isInfinite ? [(curve: _fitPiece(pts), from: 0, to: pts.length - 1)] : _fitIndexed(pts, tol);
  while (pieces.length > b - a) {
    tol = tol.isInfinite ? tol : tol * 2;
    pieces = tol.isInfinite ? [(curve: _fitPiece(pts), from: 0, to: pts.length - 1)] : _fitIndexed(pts, tol);
  }
  // in the track's own values: the key at a's value plus how far from pa
  // (in the position's own space at a).
  final o = anchorLocalFromScreen(project, layer, pa[0], pa[1], ga);
  // the whole position for a point of the way (what this track's share
  // is found from, frame by frame).
  List<double> whole(List<double> p) {
    final q = anchorLocalFromScreen(project, layer, p[0], p[1], ga);
    return [totalA[0] + q[0] - o[0], totalA[1] + q[1] - o[1]];
  }

  List<double> share(List<double> w, int f) => [w[0] - others[f]![0], w[1] - others[f]![1]];
  final local = [for (final c in pieces) [for (final p in c.curve) whole(p)]];
  // the way's own points, timed by length.
  double len(List<List<double>> c) => math.sqrt(math.pow(c[3][0] - c[0][0], 2) + math.pow(c[3][1] - c[0][1], 2));
  final wholeLen = pieces.fold(0.0, (s, c) => s + len(c.curve));
  trk.keyframes.removeWhere((k) => k.frame > a && k.frame < b);
  final linear = easingPresets['linear']!;
  var acc = 0.0, lastF = a;
  for (var i = 0; i < pieces.length - 1; i++) {
    acc += len(pieces[i].curve);
    final left = pieces.length - 2 - i;
    final f = (a + (wholeLen == 0 ? (i + 1) * (b - a) / pieces.length : (b - a) * acc / wholeLen)).round().clamp(lastF + 1, b - 1 - left);
    lastF = f;
    final p = local[i][3];
    final v = share(p, f);
    trk.keyframes.add(Keyframe(
        frame: f,
        value: <double>[v[0], v[1]],
        temporal: linear,
        spatialTangent: SpatialTangent(
            inTan: [local[i][2][0] - p[0], local[i][2][1] - p[1]],
            outTan: [local[i + 1][1][0] - p[0], local[i + 1][1][1] - p[1]]),
        passive: true));
  }
  // the ends' handles toward the drawn way; the key at b keeps its value.
  final st = ka.spatialTangent;
  ka.spatialTangent = SpatialTangent(inTan: st.inTan, outTan: [local[0][1][0] - local[0][0][0], local[0][1][1] - local[0][0][1]]);
  ka.temporal = linear;
  final sb = kb.spatialTangent;
  kb.spatialTangent = SpatialTangent(inTan: [local.last[2][0] - local.last[3][0], local.last[2][1] - local.last[3][1]], outTan: sb.outTan);
  trk.keyframes.sort((x, y) => x.frame.compareTo(y.frame));
  clearStateCaches();
  return true;
}

/// The free move (its track) that local frame `f` comes after - the
/// latest one ended before it - when no animation layer is picked for
/// edits; null: none.
Track? freeMoveBefore(Layer layer, int f) {
  if (activeAnimLayerOf(layer.transform.anchor) != null) return null;
  Track? best;
  for (final al in layer.transform.anchor.animLayers) {
    final t = al.track, span = t.freeMoveSpan;
    if (!t.freeMove || !al.enabled || span == null || span[1] >= f) continue;
    if (best == null || span[1] > best.freeMoveSpan![1]) best = t;
  }
  return best;
}
