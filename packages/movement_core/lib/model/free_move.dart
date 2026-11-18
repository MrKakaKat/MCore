/// Keyframes tab, "Free move": the object is dragged along a path on the
/// stage; confirmed, the path becomes two keys - a new animation layer
/// (key layer) moving it from where it stands along that curve.
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../ui_geometry/drag_ops.dart' show anchorLocalFromScreen;
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

/// Free moves' passive keys follow their end keys: when the ends move,
/// each keeps its share of the time between them; with an end taken away,
/// they go too. True: something changed.
bool bindFreeMoveKeys(Layer layer) {
  var changed = false;
  void fix(Track trk) {
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
  // where the drawn way must start and end: the layer's middle there.
  List<double> centreAt(int g) {
    final m = getLayerStateAt(project, layer.id, g).matrix;
    return [m[4] * stageSize.width, m[5] * stageSize.height];
  }

  final pa = centreAt(ga), pb = centreAt(gb);
  // bent to run from pa to pb (each point shifted by its share of the way).
  final d = <double>[0];
  for (var i = 1; i < framePath.length; i++) {
    d.add(d.last +
        math.sqrt(math.pow(framePath[i][0] - framePath[i - 1][0], 2) + math.pow(framePath[i][1] - framePath[i - 1][1], 2)));
  }
  final total = d.last;
  final p0 = framePath.first, pn = framePath.last;
  final pts = [
    for (var i = 0; i < framePath.length; i++)
      () {
        final s = total <= 1e-9 ? i / (framePath.length - 1) : d[i] / total;
        return [
          framePath[i][0] + (pa[0] - p0[0]) * (1 - s) + (pb[0] - pn[0]) * s,
          framePath[i][1] + (pa[1] - p0[1]) * (1 - s) + (pb[1] - pn[1]) * s,
        ];
      }()
  ];
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
  final va = [for (final v in ka.value as List) (v as num).toDouble()];
  List<double> val(List<double> p) {
    final q = anchorLocalFromScreen(project, layer, p[0], p[1], ga);
    return [va[0] + q[0] - o[0], va[1] + q[1] - o[1]];
  }

  final local = [for (final c in pieces) [for (final p in c.curve) val(p)]];
  // the way's own points, timed by length.
  double len(List<List<double>> c) => math.sqrt(math.pow(c[3][0] - c[0][0], 2) + math.pow(c[3][1] - c[0][1], 2));
  final whole = pieces.fold(0.0, (s, c) => s + len(c.curve));
  trk.keyframes.removeWhere((k) => k.frame > a && k.frame < b);
  final linear = easingPresets['linear']!;
  var acc = 0.0, lastF = a;
  for (var i = 0; i < pieces.length - 1; i++) {
    acc += len(pieces[i].curve);
    final left = pieces.length - 2 - i;
    final f = (a + (whole == 0 ? (i + 1) * (b - a) / pieces.length : (b - a) * acc / whole)).round().clamp(lastF + 1, b - 1 - left);
    lastF = f;
    final p = local[i][3];
    trk.keyframes.add(Keyframe(
        frame: f,
        value: <double>[p[0], p[1]],
        temporal: linear,
        spatialTangent: SpatialTangent(
            inTan: [local[i][2][0] - p[0], local[i][2][1] - p[1]],
            outTan: [local[i + 1][1][0] - p[0], local[i + 1][1][1] - p[1]]),
        passive: true));
  }
  // the ends' handles toward the drawn way; the key at b keeps its value.
  final st = ka.spatialTangent;
  ka.spatialTangent = SpatialTangent(inTan: st.inTan, outTan: [local[0][1][0] - va[0], local[0][1][1] - va[1]]);
  ka.temporal = linear;
  final vb = [for (final v in kb.value as List) (v as num).toDouble()];
  final sb = kb.spatialTangent;
  kb.spatialTangent = SpatialTangent(inTan: [local.last[2][0] - vb[0], local.last[2][1] - vb[1]], outTan: sb.outTan);
  trk.keyframes.sort((x, y) => x.frame.compareTo(y.frame));
  clearStateCaches();
  return true;
}
