/// Vector lines (shape "line" with nodes): a one-dimensional stroke
/// through points, each segment straight, a cubic bezier or a sine wave.
///
/// - Points are content-local px. The content box (offset/size) follows
///   them (see [syncLineBox]), so selection and bounds keep working.
/// - On the stage an open line has end handles (drag to lengthen) and is
///   moved by dragging it anywhere along; the Line tab shows every point
///   and the bezier handles of the selected one.
/// - "Close & fill" joins the last point to the first: from then on it is
///   a filled shape with the usual square transform box.
/// - Reveal: two animatable fractions of the length, where the drawn part
///   starts and ends.
library;

import 'dart:math' as math;

import '../core/interpolation.dart' show evaluateTrack;
import '../model/track_edit.dart' show setTrackValueAt, localFrameOf;
import '../core/math.dart' show applyAffine, invertAffine;
import '../core/stage_size.dart' show stageSize;
import '../ui_geometry/corner_round_handles.dart' show lineCorner, snapRoundingFrame;
import '../ui_geometry/drag_ops.dart' show DragOp, anchorLocalFromScreen, dragAxisLock;
import '../ui_geometry/handles.dart' show getTransformBoxHandles;
import '../ui_geometry/marquee.dart' show layerFrameBounds;
import '../ui_geometry/snapping.dart' show SnapCategory, SnapGuideLine;
import 'project.dart';
import 'line_stroke.dart' show lineStrokeRings;
import '../geometry/polygon_boolean.dart' show polygonBoolean, BoolOp;
import 'project_json.dart' show trackToJson, trackFromJson;

class LineNode {
  double x, y;

  /// How the segment arriving at this point is drawn: 'line' | 'bezier' |
  /// 'sine' | 'arc' (the first point's applies to the closing segment).
  String kind;

  /// Bezier handles, relative to the point: in (toward the previous
  /// point) and out (toward the next).
  List<double> hIn, hOut;

  /// Sine: amplitude (px, sideways) and number of waves; arc: how far it
  /// bulges (px). Animatable.
  Track ampT, wavesT;

  double get amp => (ampT.defaultValue as num).toDouble();
  set amp(double v) => ampT.defaultValue = v;
  double get waves => (wavesT.defaultValue as num).toDouble();
  set waves(double v) => wavesT.defaultValue = v;

  /// The amplitude / waves at local frame `f` (null: the base value).
  double ampAt(num? f) => f == null || ampT.keyframes.isEmpty ? amp : (evaluateTrack(null, ampT, f.toDouble()) as num).toDouble();
  double wavesAt(num? f) =>
      f == null || wavesT.keyframes.isEmpty ? waves : (evaluateTrack(null, wavesT, f.toDouble()) as num).toDouble();

  /// The point's position over time (keys on [x, y]); null: it stays
  /// where it is. x / y follow it at the editor's frame (see
  /// [syncLineToFrame]).
  Track? posT;

  /// Where the point is at local frame `f` (null: where it is now).
  (double, double) posAt(num? f) {
    final t = posT;
    if (f == null || t == null || t.keyframes.isEmpty) return (x, y);
    final v = evaluateTrack(null, t, f.toDouble()) as List;
    return ((v[0] as num).toDouble(), (v[1] as num).toDouble());
  }

  /// Keys on the point's width / corner rounding / rounding shape
  /// ('w', 'round', 'roundK'): over time they set those values (see
  /// [syncLineToFrame]).
  Map<String, Track> keys = {};

  /// `name`'s value at local frame `f` (its keys, else the plain value).
  double? valueAt(String name, num? f) {
    final t = keys[name];
    if (f != null && t != null && t.keyframes.isNotEmpty) return (evaluateTrack(null, t, f.toDouble()) as num).toDouble();
    return switch (name) { 'w' => w, 'round' => round, _ => roundK };
  }

  /// A bezier handle ('hIn' / 'hOut', relative to the point) at local
  /// frame `f`: its keys (in [keys]), else as it is.
  List<double> handleAt(String name, num? f) {
    final t = keys[name];
    if (f != null && t != null && t.keyframes.isNotEmpty) {
      final v = evaluateTrack(null, t, f.toDouble()) as List;
      return [(v[0] as num).toDouble(), (v[1] as num).toDouble()];
    }
    return name == 'hIn' ? hIn : hOut;
  }

  /// The line's width at this point, px (null: the line's own width).
  /// Between points the width changes evenly.
  double? w;

  /// The corner at this point rounded off, px (0: sharp).
  double round;

  /// The rounding's shape: 0 cut straight, ~0.55 a circle, 1 sharp again.
  double roundK;

  LineNode(this.x, this.y,
      {this.kind = 'line',
      List<double>? hIn,
      List<double>? hOut,
      double amp = 12,
      double waves = 2,
      Track? ampT,
      Track? wavesT,
      this.w,
      this.round = 0,
      this.roundK = circleRoundK})
      : hIn = hIn ?? [0, 0],
        hOut = hOut ?? [0, 0],
        ampT = ampT ?? Track(amp, false),
        wavesT = wavesT ?? Track(waves, false);

  LineNode copy() => LineNode(x, y,
      kind: kind,
      hIn: [...hIn],
      hOut: [...hOut],
      ampT: cloneTrack(ampT),
      wavesT: cloneTrack(wavesT),
      w: w,
      round: round,
      roundK: roundK)
    ..posT = posT == null ? null : cloneTrack(posT!)
    ..keys = {for (final e in keys.entries) e.key: cloneTrack(e.value)};

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        if (kind != 'line') 'kind': kind,
        if (hIn[0] != 0 || hIn[1] != 0) 'hIn': hIn,
        if (hOut[0] != 0 || hOut[1] != 0) 'hOut': hOut,
        if (kind == 'sine' || kind == 'arc') 'amp': ampT.keyframes.isEmpty ? amp : trackToJson(ampT),
        if (kind == 'sine') 'waves': wavesT.keyframes.isEmpty ? waves : trackToJson(wavesT),
        if (w != null) 'w': w,
        if (posT != null && posT!.keyframes.isNotEmpty) 'pos': trackToJson(posT!),
        if (keys.values.any((t) => t.keyframes.isNotEmpty))
          'keys': {for (final e in keys.entries) if (e.value.keyframes.isNotEmpty) e.key: trackToJson(e.value)},
        if (round != 0) 'round': round,
        if (roundK != circleRoundK) 'roundK': roundK,
      };

  static LineNode fromJson(Map<String, dynamic> j) {
    List<double>? v(Object? o) => o is List ? [for (final e in o) (e as num).toDouble()] : null;
    return LineNode((j['x'] as num).toDouble(), (j['y'] as num).toDouble(),
        kind: j['kind'] as String? ?? 'line',
        hIn: v(j['hIn']),
        hOut: v(j['hOut']),
        ampT: j['amp'] is Map ? trackFromJson(j['amp'] as Map<String, dynamic>) : Track((j['amp'] as num?)?.toDouble() ?? 12, false),
        wavesT:
            j['waves'] is Map ? trackFromJson(j['waves'] as Map<String, dynamic>) : Track((j['waves'] as num?)?.toDouble() ?? 2, false),
        w: (j['w'] as num?)?.toDouble(),
        round: (j['round'] as num?)?.toDouble() ?? 0,
        roundK: (j['roundK'] as num?)?.toDouble() ?? circleRoundK)
      ..posT = j['pos'] is Map ? trackFromJson(j['pos'] as Map<String, dynamic>) : null
      ..keys = {
        if (j['keys'] is Map)
          for (final e in (j['keys'] as Map).entries) e.key as String: trackFromJson(Map<String, dynamic>.from(e.value as Map))
      };
  }
}

/// Whether `c` is a node line (a legacy "line" is a thin rectangle).
bool isNodeLine(Content c) => c.shape == 'line' && c.lineNodes != null;

/// An open node line: end handles and drag-along instead of the box.
bool isOpenNodeLine(Content c) => isNodeLine(c) && !c.lineShowBox;

/// A filled line (a closed one drawn as a shape).
bool isFilledLine(Content c) => isNodeLine(c) && c.lineClosed && c.lineFilled;

/// A straight line `length` px long, centred.
List<LineNode> straightLineNodes(double length) => [LineNode(-length / 2, 0), LineNode(length / 2, 0)];

List<double> _segPoint(LineNode a, LineNode b, String kind, double t, [num? f]) {
  switch (kind) {
    case 'arc':
      return _arcPoint(a, b, b.ampAt(f), t);
    case 'bezier':
      final p1 = [a.x + a.hOut[0], a.y + a.hOut[1]], p2 = [b.x + b.hIn[0], b.y + b.hIn[1]];
      final u = 1 - t;
      return [
        u * u * u * a.x + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * b.x,
        u * u * u * a.y + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * b.y,
      ];
    case 'sine':
      final dx = b.x - a.x, dy = b.y - a.y;
      final len = math.sqrt(dx * dx + dy * dy);
      final nx = len == 0 ? 0.0 : -dy / len, ny = len == 0 ? 0.0 : dx / len;
      final off = b.ampAt(f) * math.sin(2 * math.pi * b.wavesAt(f) * t);
      return [a.x + dx * t + nx * off, a.y + dy * t + ny * off];
    default:
      return [a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t];
  }
}

/// A circular arc from a to b bulging `h` px to the left of a->b.
List<double> _arcPoint(LineNode a, LineNode b, double h, double t) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0 || h.abs() < 1e-6) return [a.x + dx * t, a.y + dy * t];
  final nx = -dy / len, ny = dx / len;
  // the circle through a, the bulge's top and b.
  final c = len / 2;
  final r = (h * h + c * c) / (2 * h); // signed
  final cx = (a.x + b.x) / 2 + nx * (h - r), cy = (a.y + b.y) / 2 + ny * (h - r);
  final ta = math.atan2(a.y - cy, a.x - cx), tb = math.atan2(b.y - cy, b.x - cx);
  final tm = math.atan2((a.y + b.y) / 2 + ny * h - cy, (a.x + b.x) / 2 + nx * h - cx);
  double norm(double v) => (v + math.pi) % (2 * math.pi) - math.pi;
  var sweep = norm(tb - ta);
  // through the top, not the short way round when it isn't there.
  final toTop = norm(tm - ta);
  if (toTop.sign != sweep.sign || toTop.abs() > sweep.abs()) sweep -= sweep.sign * 2 * math.pi;
  final th = ta + sweep * t;
  return [cx + r.abs() * math.cos(th), cy + r.abs() * math.sin(th)];
}

/// A rounding's handle length for a circle (a quarter circle's bezier).
const circleRoundK = 0.5523;

/// The line as points (content-local), each curved segment in `perCurve`
/// steps; closed lines end back at the first point. `frame` (local):
/// animated amplitudes / waves at that frame. Rounded corners (a point's
/// `round`) are already curved here.
List<List<double>> sampleLine(List<LineNode> nodes, {bool closed = false, int perCurve = 32, num? frame}) =>
    [for (final p in sampleLineWidths(nodes, closed: closed, perCurve: perCurve, frame: frame, width: 0)) [p[0], p[1]]];

/// [sampleLine] with the width at each point as a third value (`width`:
/// the line's own, where a point has none).
List<List<double>> sampleLineWidths(List<LineNode> nodes,
    {bool closed = false, int perCurve = 32, num? frame, required double width}) {
  if (nodes.isEmpty) return const [];
  // points with keys: where they are at that frame.
  bool keyed(LineNode n) => (n.posT != null && n.posT!.keyframes.isNotEmpty) || n.keys.values.any((t) => t.keyframes.isNotEmpty);
  if (frame != null && nodes.any(keyed)) {
    nodes = [
      for (final n in nodes)
        if (!keyed(n))
          n
        else
          () {
            final (x, y) = n.posAt(frame);
            return n.copy()
              ..x = x
              ..y = y
              ..hIn = n.handleAt('hIn', frame)
              ..hOut = n.handleAt('hOut', frame)
              ..w = n.valueAt('w', frame)
              ..round = n.valueAt('round', frame)!
              ..roundK = n.valueAt('roundK', frame)!;
          }()
    ];
  }
  double wOf(LineNode n) => n.w ?? width;
  final out = <List<double>>[
    [nodes.first.x, nodes.first.y, wOf(nodes.first)]
  ];
  // where each point landed in `out`.
  final at = <int>[0];
  final n = nodes.length;
  for (var i = 1; i <= (closed ? n : n - 1); i++) {
    final a = nodes[i - 1], b = nodes[i % n];
    final steps = b.kind == 'line' ? 1 : (b.kind == 'sine' ? math.max(perCurve, (b.wavesAt(frame) * 16).ceil()) : perCurve);
    final wa = wOf(a), wb = wOf(b);
    for (var s = 1; s <= steps; s++) {
      final t = s / steps;
      out.add([..._segPoint(a, b, b.kind, t, frame), wa + (wb - wa) * t]);
    }
    at.add(out.length - 1);
  }
  if (!nodes.any((p) => p.round > 0)) return out;
  return _roundCorners(out, at, nodes, closed);
}

/// Each rounded point's corner becomes a curve from a spot `round` px
/// back along the way in to one as far along the way out (never past the
/// neighbours' middles); its handles reach `roundK` of the way to the
/// corner.
List<List<double>> _roundCorners(List<List<double>> pts, List<int> at, List<LineNode> nodes, bool closed) {
  final n = nodes.length;
  final m = pts.length;
  final repl = <int, List<List<double>>>{};
  for (var i = 0; i < n; i++) {
    final r = nodes[i].round;
    if (r <= 0) continue;
    final idx = at[i];
    final int prevI, nextI;
    if (closed) {
      // the first point is both the first and the last sample.
      prevI = idx == 0 ? m - 2 : idx - 1;
      nextI = idx == 0 ? 1 : (idx + 1 >= m ? 1 : idx + 1);
    } else {
      if (i == 0 || i == n - 1) continue; // an open end has no corner
      prevI = idx - 1;
      nextI = idx + 1;
    }
    if (prevI < 0 || nextI >= m) continue;
    final p = pts[idx], a = pts[prevI], b = pts[nextI];
    final la = math.sqrt(math.pow(a[0] - p[0], 2) + math.pow(a[1] - p[1], 2));
    final lb = math.sqrt(math.pow(b[0] - p[0], 2) + math.pow(b[1] - p[1], 2));
    if (la < 1e-9 || lb < 1e-9) continue;
    // a shared stretch: neither corner takes more than its half.
    final d = math.min(r, math.min(la, lb) / 2);
    final t1 = [p[0] + (a[0] - p[0]) * d / la, p[1] + (a[1] - p[1]) * d / la];
    final t2 = [p[0] + (b[0] - p[0]) * d / lb, p[1] + (b[1] - p[1]) * d / lb];
    final k = nodes[i].roundK.clamp(0.0, 1.0);
    final c1 = [t1[0] + (p[0] - t1[0]) * k, t1[1] + (p[1] - t1[1]) * k];
    final c2 = [t2[0] + (p[0] - t2[0]) * k, t2[1] + (p[1] - t2[1]) * k];
    const steps = 12;
    repl[idx] = [
      for (var s = 0; s <= steps; s++)
        () {
          final t = s / steps, u = 1 - t;
          return [
            u * u * u * t1[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * t2[0],
            u * u * u * t1[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * t2[1],
            p[2],
          ];
        }()
    ];
  }
  if (repl.isEmpty) return pts;
  final out = <List<double>>[];
  for (var j = 0; j < m; j++) {
    if (closed && j == m - 1 && repl.containsKey(0)) {
      out.add(repl[0]!.first); // back to where the first corner's curve starts
      continue;
    }
    final r = repl[j];
    r == null ? out.add(pts[j]) : out.addAll(r);
  }
  return out;
}

double polylineLength(List<List<double>> pts) {
  var len = 0.0;
  for (var i = 1; i < pts.length; i++) {
    len += math.sqrt(math.pow(pts[i][0] - pts[i - 1][0], 2) + math.pow(pts[i][1] - pts[i - 1][1], 2));
  }
  return len;
}

/// The part of `pts` between fractions `t0` and `t1` of its length.
List<List<double>> trimPolyline(List<List<double>> pts, double t0, double t1) {
  t0 = t0.clamp(0.0, 1.0);
  t1 = t1.clamp(0.0, 1.0);
  if (pts.length < 2 || t1 <= t0) return const [];
  if (t0 == 0 && t1 == 1) return pts;
  final total = polylineLength(pts);
  final from = t0 * total, to = t1 * total;
  final out = <List<double>>[];
  var at = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final seg = math.sqrt(math.pow(b[0] - a[0], 2) + math.pow(b[1] - a[1], 2));
    final s0 = at, s1 = at + seg;
    List<double> lerp(double d) =>
        seg == 0 ? [...a] : [for (var k = 0; k < a.length; k++) a[k] + (b[k] - a[k]) * (d - s0) / seg];
    if (s1 >= from && s0 <= to) {
      if (out.isEmpty) out.add(lerp(math.max(from, s0)));
      out.add(lerp(math.min(to, s1)));
    }
    at = s1;
    if (at > to) break;
  }
  return out;
}

/// Reveal at local frame `f`: the drawn part [start, end] of the length.
(double, double) lineReveal(Project project, Content c, num f) {
  double v(Track? t, double d) => t == null ? d : (evaluateTrack(project, t, f.toDouble()) as num).toDouble();
  return (v(c.lineTrimStart, 0), v(c.lineTrimEnd, 1));
}

/// The content box around the line (plus half its width).
void syncLineBox(Content c) {
  final nodes = c.lineNodes;
  if (nodes == null || nodes.isEmpty) return;
  final pts = sampleLine(nodes, closed: c.lineClosed);
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final p in pts) {
    x0 = math.min(x0, p[0]);
    y0 = math.min(y0, p[1]);
    x1 = math.max(x1, p[0]);
    y1 = math.max(y1, p[1]);
  }
  final pad = c.lineWidth / 2;
  c.offset = [(x0 + x1) / 2, (y0 + y1) / 2];
  c.size = [x1 - x0 + 2 * pad, y1 - y0 + 2 * pad];
}

/// Adds a point in the middle of the segment arriving at point `i` (or,
/// for i == 0 on a closed line, the closing one); returns its index.
int insertLinePoint(Content c, int i) {
  final nodes = c.lineNodes!;
  final n = nodes.length;
  final arriving = i <= 0 ? (c.lineClosed ? n : 1) : i;
  final a = nodes[arriving - 1], b = nodes[arriving % n];
  final mid = _segPoint(a, b, b.kind, 0.5);
  final node = LineNode(mid[0], mid[1], kind: b.kind == 'sine' ? 'sine' : 'line', amp: b.amp, waves: b.waves / 2);
  if (b.kind == 'sine') b.waves = b.waves / 2;
  nodes.insert(arriving, node);
  syncLineBox(c);
  return arriving;
}

/// Removes point `i` (a line keeps at least two).
void removeLinePoint(Content c, int i) {
  final nodes = c.lineNodes!;
  if (nodes.length <= 2 || i < 0 || i >= nodes.length) return;
  nodes.removeAt(i);
  syncLineBox(c);
}

/// The segment arriving at point `i` becomes `kind` (both ends' bezier
/// handles start a third of the way along).
void setLineSegmentKind(Content c, int i, String kind) {
  final nodes = c.lineNodes!;
  final n = nodes.length;
  final b = nodes[i];
  final a = nodes[(i - 1 + n) % n];
  b.kind = kind;
  if (kind == 'bezier') {
    final dx = (b.x - a.x) / 3, dy = (b.y - a.y) / 3;
    if (a.hOut[0] == 0 && a.hOut[1] == 0) a.hOut = [dx - dy * 0.5, dy + dx * 0.5];
    if (b.hIn[0] == 0 && b.hIn[1] == 0) b.hIn = [-dx - dy * 0.5, -dy + dx * 0.5];
  }
  syncLineBox(c);
}

/// The segment on one side of point `i` ('before' / 'after'): its node
/// index, or null at an open line's end.
int? lineSideSegment(Content c, int i, String side) {
  final n = c.lineNodes!.length;
  if (side == 'before') return c.lineClosed || i > 0 ? i : null;
  return c.lineClosed || i < n - 1 ? (i + 1) % n : null;
}

/// The kind point `i` shows on `side`: a bezier only counts where this
/// point has its own handle (the other end's handle is the other point's).
String lineSideKind(Content c, int i, String side) {
  final j = lineSideSegment(c, i, side);
  if (j == null) return 'line';
  final k = c.lineNodes![j].kind;
  if (k != 'bezier') return k;
  final h = side == 'before' ? c.lineNodes![i].hIn : c.lineNodes![i].hOut;
  return h[0] == 0 && h[1] == 0 ? 'line' : 'bezier';
}

/// Sets the shape on one side of point `i` - for a bezier only this
/// point's handle (the other end stays as it is).
void setLineSideKind(Content c, int i, String side, String kind) {
  final j = lineSideSegment(c, i, side);
  if (j == null) return;
  final nodes = c.lineNodes!;
  final n = nodes.length;
  final b = nodes[j], a = nodes[(j - 1 + n) % n];
  final p = nodes[i];
  final dx = (b.x - a.x) / 3, dy = (b.y - a.y) / 3;
  if (kind == 'bezier') {
    b.kind = 'bezier';
    if (side == 'before') {
      if (p.hIn[0] == 0 && p.hIn[1] == 0) p.hIn = [-dx - dy * 0.5, -dy + dx * 0.5];
    } else if (p.hOut[0] == 0 && p.hOut[1] == 0) {
      p.hOut = [dx - dy * 0.5, dy + dx * 0.5];
    }
  } else if (kind == 'line') {
    if (side == 'before') {
      p.hIn = [0, 0];
    } else {
      p.hOut = [0, 0];
    }
    // straight once neither end bends it.
    final other = side == 'before' ? a.hOut : b.hIn;
    if (b.kind != 'bezier' || (other[0] == 0 && other[1] == 0)) b.kind = 'line';
  } else {
    b.kind = kind;
    if (kind == 'arc' && b.amp == 12) b.amp = math.sqrt(dx * dx + dy * dy) * 1.5 / 2;
  }
  syncLineBox(c);
}

/// Both sides of point `i` at once (Line tab, "Curve type"). A bezier
/// gets a mirrored pair of handles along the way through the point (the
/// same length each side with lineMirrorLength).
void setLinePointKind(Content c, int i, String kind) {
  for (final side in const ['before', 'after']) {
    if (lineSideSegment(c, i, side) != null) setLineSideKind(c, i, side, kind);
  }
  if (kind != 'bezier') return;
  final nodes = c.lineNodes!;
  final n = nodes.length;
  final p = nodes[i];
  final prev = c.lineClosed || i > 0 ? nodes[(i - 1 + n) % n] : null;
  final next = c.lineClosed || i < n - 1 ? nodes[(i + 1) % n] : null;
  if (prev == null || next == null) return; // an end has one handle
  var dx = next.x - prev.x, dy = next.y - prev.y;
  final l = math.sqrt(dx * dx + dy * dy);
  if (l < 1e-9) return;
  dx /= l;
  dy /= l;
  var li = math.sqrt(math.pow(p.x - prev.x, 2) + math.pow(p.y - prev.y, 2)) / 3;
  var lo = math.sqrt(math.pow(next.x - p.x, 2) + math.pow(next.y - p.y, 2)) / 3;
  if (c.lineMirrorLength) li = lo = (li + lo) / 2;
  p
    ..hIn = [-dx * li, -dy * li]
    ..hOut = [dx * lo, dy * lo];
  syncLineBox(c);
}

/// The kind both sides of point `i` share, or null when they differ.
String? linePointKind(Content c, int i) {
  final kinds = {
    for (final side in const ['before', 'after'])
      if (lineSideSegment(c, i, side) != null) lineSideKind(c, i, side)
  };
  return kinds.length == 1 ? kinds.first : null;
}

/// Fill: the last point joins the first and the line becomes a filled
/// shape (its points stay the handles - see Content.lineShowBox).
void closeLine(Content c) {
  if (!c.lineClosed) c.lineNodes!.first.kind = 'line'; // a straight closing segment
  c
    ..lineClosed = true
    ..lineFilled = true;
  syncLineBox(c);
}

/// Loop: joins the last point to the first (or opens it again), unfilled.
void loopLine(Content c, bool closed) {
  if (closed && !c.lineClosed) c.lineNodes!.first.kind = 'line';
  c.lineClosed = closed;
  if (!closed) c.lineFilled = false;
  syncLineBox(c);
}

/// A handle of a selected node line: 'n<i>' a point, 'i<i>' / 'o<i>' its
/// bezier handles.
({String key, List<double> local}) lineHandleLocal(Content c, String key) {
  final i = int.parse(key.substring(1));
  final p = c.lineNodes![i];
  if (key[0] == 'r' || key[0] == 'k') {
    final rc = lineCorner(c, i);
    if (rc != null) return (key: key, local: key[0] == 'r' ? rc.t2 : rc.mid);
  }
  return switch (key[0]) {
    'i' => (key: key, local: [p.x + p.hIn[0], p.y + p.hIn[1]]),
    'o' => (key: key, local: [p.x + p.hOut[0], p.y + p.hOut[1]]),
    _ => (key: key, local: [p.x, p.y]),
  };
}

/// The handles shown for a node line: its two ends, or (Line tab) every
/// point plus the bezier handles touching the selected point's segments.
List<String> lineHandleKeys(Content c, {required bool editing, int? selected}) {
  final nodes = c.lineNodes!;
  final n = nodes.length;
  if (c.lineShowBox) return const [];
  if (!editing) return ['n0', 'n${n - 1}'];
  final keys = [for (var i = 0; i < n; i++) 'n$i'];
  if (selected != null && selected < n) {
    final next = c.lineClosed || selected + 1 < n ? nodes[(selected + 1) % n] : null;
    bool has(List<double> h) => h[0] != 0 || h[1] != 0;
    if ((c.lineClosed || selected > 0) && nodes[selected].kind == 'bezier' && has(nodes[selected].hIn)) {
      keys.add('i$selected');
    }
    if (next != null && next.kind == 'bezier' && has(nodes[selected].hOut)) keys.add('o$selected');
    // the corner's rounding: its radius (always, to start one) and shape.
    if (lineCorner(c, selected) != null) {
      keys.add('r$selected');
      if (nodes[selected].round > 0) keys.add('k$selected');
    }
  }
  return keys;
}

/// Moves a handle to content-local `p`; a point carries its own bezier
/// handles along. A bezier handle turns its partner on the other side the
/// opposite way (mirrored; the same length too with lineMirrorLength).
void moveLineHandle(Content c, String key, List<double> p) {
  final i = int.parse(key.substring(1));
  final node = c.lineNodes![i];
  void mirror(List<double> moved, List<double> other, void Function(List<double>) set) {
    if (!lineHandlesMirrored || (other[0] == 0 && other[1] == 0)) return;
    final l = math.sqrt(moved[0] * moved[0] + moved[1] * moved[1]);
    if (l < 1e-9) return;
    final ol = c.lineMirrorLength ? l : math.sqrt(other[0] * other[0] + other[1] * other[1]);
    set([-moved[0] / l * ol, -moved[1] / l * ol]);
  }

  switch (key[0]) {
    case 'r':
      // the radius: how far along the way out the curve starts.
      final nodes = c.lineNodes!;
      final n = nodes.length;
      final b = nodes[(i + 1) % n];
      final ex = b.x - node.x, ey = b.y - node.y;
      final el = math.sqrt(ex * ex + ey * ey);
      if (el > 1e-9) node.round = math.max(0.0, ((p[0] - node.x) * ex + (p[1] - node.y) * ey) / el);
      final snapR = lineRoundSnap;
      if (snapR != null) node.round = snapR(node.round);
      syncLineBox(c);
      return;
    case 'k':
      final rc = lineCorner(c, i);
      if (rc != null) {
        final mx = (rc.t1[0] + rc.t2[0]) / 2, my = (rc.t1[1] + rc.t2[1]) / 2;
        final vx = rc.p[0] - mx, vy = rc.p[1] - my;
        final vl2 = vx * vx + vy * vy;
        if (vl2 > 1e-12) node.roundK = (((p[0] - mx) * vx + (p[1] - my) * vy) / vl2 / 0.75).clamp(0.0, 1.0);
      }
      syncLineBox(c);
      return;
    case 'i':
      node.hIn = [p[0] - node.x, p[1] - node.y];
      mirror(node.hIn, node.hOut, (v) => node.hOut = v);
    case 'o':
      node.hOut = [p[0] - node.x, p[1] - node.y];
      mirror(node.hOut, node.hIn, (v) => node.hIn = v);
    default:
      node
        ..x = p[0]
        ..y = p[1];
  }
  syncLineBox(c);
}

/// Line tab: the selected point (shared by the stage and the tab).
int lineSelectedPoint = 0;

/// True while the Line tab is open: every point is a handle.
bool lineEditing = true;

/// While a line corner's rounding is dragged: pulls it onto another
/// rounding's size (set by the drag op, content px in and out).
double Function(double)? lineRoundSnap;

/// Bezier handles of a point move as a mirrored pair (Line tab).
bool lineHandlesMirrored = true;

/// Snapping of a line's points (Snapping tab, "Line points"): along
/// horizontals / verticals / diagonals from the neighbouring point, to the
/// length of another stretch, onto other points (any line's, a shape's
/// corners / middles, the frame's edges).
bool snapLineAngleEnabled = true;
bool snapLineLengthEnabled = true;
bool snapLinePointsEnabled = true;

/// Drags one handle of a node line (see [lineHandleKeys]) to the finger,
/// in the layer's own space - snapping as above.
class LineHandleDragOp implements DragOp {
  final Layer layer;
  final String key;
  LineHandleDragOp(this.layer, this.key);

  List<SnapGuideLine> _guides = const [];

  @override
  List<SnapGuideLine> get snapGuides => _guides;

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final tb = getTransformBoxHandles(project, layer, globalFrame);
    final snap = snapLineHandle(project, layer, key, framePoint, globalFrame);
    _guides = snap.guides;
    final m = tb.mCanvas;
    final k = math.sqrt((m[0] * m[3] - m[1] * m[2]).abs());
    lineRoundSnap = k <= 1e-9 ? null : (r) => snapRoundingFrame(project, layer, globalFrame, r * k) / k;
    moveLineHandle(layer.content, key, applyAffine(invertAffine(tb.mCanvas), snap.point));
    lineRoundSnap = null;
    // a keyed rounding: the drag is a key at this frame.
    if (key[0] == 'r' || key[0] == 'k') {
      final node = layer.content.lineNodes![int.parse(key.substring(1))];
      final name = key[0] == 'r' ? 'round' : 'roundK';
      final t = node.keys[name];
      if (t != null && t.keyframes.isNotEmpty) {
        setTrackValueAt(t, localFrameOf(layer, globalFrame), name == 'round' ? node.round : node.roundK);
      }
    }
    // keyed bezier handles: the move (and the mirrored partner's) is a key.
    if (key[0] == 'i' || key[0] == 'o') {
      final node = layer.content.lineNodes![int.parse(key.substring(1))];
      for (final name in const ['hIn', 'hOut']) {
        final t = node.keys[name];
        if (t != null && t.keyframes.isNotEmpty) {
          setTrackValueAt(t, localFrameOf(layer, globalFrame), <double>[...(name == 'hIn' ? node.hIn : node.hOut)]);
        }
      }
    }
    // a point with keys: the move is a key at this frame.
    if (key[0] == 'n') {
      final node = layer.content.lineNodes![int.parse(key.substring(1))];
      if (node.posT != null && node.posT!.keyframes.isNotEmpty) {
        setTrackValueAt(node.posT!, localFrameOf(layer, globalFrame), [node.x, node.y]);
      }
    }
  }
}

/// Where a dragged line handle lands (frame px) and the guides that say
/// why. See [snapLineAngleEnabled].
({List<double> point, List<SnapGuideLine> guides}) snapLineHandle(
    Project project, Layer layer, String key, List<double> target, int globalFrame) {
  if (!snapEnabled || key[0] == 'r' || key[0] == 'k') return (point: target, guides: const []);
  final c = layer.content;
  final nodes = c.lineNodes!;
  final n = nodes.length;
  final i = int.parse(key.substring(1));
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  List<double> fr(double x, double y) => applyAffine(m, [x, y]);
  double dist(List<double> a, List<double> b) => math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));
  final isPoint = key[0] == 'n';
  // what the angle / length are measured from.
  final refs = <List<double>>[
    if (!isPoint) fr(nodes[i].x, nodes[i].y),
    if (isPoint && (c.lineClosed || i > 0)) fr(nodes[(i - 1 + n) % n].x, nodes[(i - 1 + n) % n].y),
    if (isPoint && (c.lineClosed || i < n - 1)) fr(nodes[(i + 1) % n].x, nodes[(i + 1) % n].y),
  ];
  final guides = <SnapGuideLine>[];

  // 1. onto a point: other lines' points, this line's other points, the
  // corners / middles of shapes, the frame's corners and middle.
  // (with the centres' snapping on, any handle - bezier ones too - also
  // lands on a shape's centre.)
  final points = snapLinePointsEnabled && isPoint;
  if (points || snapCenterToCenterEnabled) {
    final r = points ? snapCornerToCornerFrameRadius : snapCenterToCenterFrameRadius;
    List<double>? best;
    var bestD = r;
    void consider(List<double> q) {
      final d = dist(q, target);
      if (d < bestD) {
        bestD = d;
        best = q;
      }
    }

    for (final l in project.layers) {
      if (l.hidden) continue;
      if (!points) {
        // centres only: every other shape's middle.
        if (l == layer || l.content.shape == 'audio' || l.content.shape == 'camera') continue;
        final b = layerFrameBounds(project, l, globalFrame);
        if (b != null) consider([(b.$1 + b.$3) / 2, (b.$2 + b.$4) / 2]);
        continue;
      }
      if (isNodeLine(l.content)) {
        final lm = getTransformBoxHandles(project, l, globalFrame).mCanvas;
        final ln = l.content.lineNodes!;
        for (var j = 0; j < ln.length; j++) {
          final own = l == layer && (j == i || j - 1 == i);
          if (!(l == layer && j == i)) consider(applyAffine(lm, [ln[j].x, ln[j].y]));
          // the middle between two points (not one the dragged point moves).
          if (j > 0 && !own) consider(applyAffine(lm, [(ln[j].x + ln[j - 1].x) / 2, (ln[j].y + ln[j - 1].y) / 2]));
        }
      } else if (l != layer && l.content.shape != 'audio' && l.content.shape != 'camera') {
        final b = layerFrameBounds(project, l, globalFrame);
        if (b == null) continue;
        final xs = [b.$1, (b.$1 + b.$3) / 2, b.$3], ys = [b.$2, (b.$2 + b.$4) / 2, b.$4];
        for (final x in xs) {
          for (final y in ys) {
            consider([x, y]);
          }
        }
      }
    }
    final w = stageSize.width, h = stageSize.height;
    for (final x in [0.0, w / 2, w]) {
      for (final y in [0.0, h / 2, h]) {
        if (points || (x == w / 2 && y == h / 2)) consider([x, y]);
      }
    }
    if (best != null) {
      return (
        point: best!,
        guides: [SnapGuideLine(category: SnapCategory.cornerToCorner, a: best!, b: best!)],
      );
    }
  }

  var p = [...target];
  var angled = false;
  // 2. along a horizontal / vertical / diagonal from a neighbour.
  if (snapLineAngleEnabled && refs.isNotEmpty) {
    final tol = snapRotationToleranceDeg * math.pi / 180;
    List<double>? bestP;
    var bestErr = tol;
    List<double>? bestRef;
    for (final r in refs) {
      final dx = p[0] - r[0], dy = p[1] - r[1];
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < 1e-6) continue;
      final ang = math.atan2(dy, dx);
      final snapped = (ang / (math.pi / 4)).round() * (math.pi / 4);
      final err = (ang - snapped).abs();
      if (err < bestErr) {
        bestErr = err;
        bestRef = r;
        bestP = [r[0] + math.cos(snapped) * len, r[1] + math.sin(snapped) * len];
      }
    }
    if (bestP != null) {
      p = bestP;
      angled = true;
      guides.add(SnapGuideLine(category: SnapCategory.rotationAngle, a: bestRef!, b: p));
    }
  }
  // 3. the length of another stretch (this line's or another's), keeping
  // the direction.
  if (snapLineLengthEnabled && refs.isNotEmpty) {
    final r0 = refs.first;
    final dx = p[0] - r0[0], dy = p[1] - r0[1];
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 1e-6) {
      double? bestL;
      var bestErr = snapEqualSizeFrameRadius;
      for (final l in project.layers) {
        if (l.hidden || !isNodeLine(l.content)) continue;
        final lm = getTransformBoxHandles(project, l, globalFrame).mCanvas;
        final ln = l.content.lineNodes!;
        for (var j = 1; j < ln.length; j++) {
          // the stretches touching the dragged point don't count.
          if (l == layer && isPoint && (j == i || j - 1 == i)) continue;
          final a = applyAffine(lm, [ln[j - 1].x, ln[j - 1].y]), b = applyAffine(lm, [ln[j].x, ln[j].y]);
          final sl = dist(a, b);
          final err = (sl - len).abs();
          if (err < bestErr) {
            bestErr = err;
            bestL = sl;
          }
        }
      }
      if (bestL != null) {
        p = [r0[0] + dx / len * bestL, r0[1] + dy / len * bestL];
        guides.add(SnapGuideLine(category: SnapCategory.centerLine, a: r0, b: p));
      }
    }
  }
  // 4. the frame's edges and middle lines (not while held to an angle).
  if (!angled && snapFrameBoundaryEnabled) {
    final w = stageSize.width, h = stageSize.height, r = snapFrameBoundaryFrameRadius;
    for (final x in [0.0, w / 2, w]) {
      if ((p[0] - x).abs() < r) {
        p = [x, p[1]];
        guides.add(SnapGuideLine(category: SnapCategory.frameBoundary, a: [x, 0], b: [x, h]));
        break;
      }
    }
    for (final y in [0.0, h / 2, h]) {
      if ((p[1] - y).abs() < r) {
        p = [p[0], y];
        guides.add(SnapGuideLine(category: SnapCategory.frameBoundary, a: [0, y], b: [w, y]));
        break;
      }
    }
  }
  // the stage's axis lock holds a point to one direction from where it was.
  if (dragAxisLock != null && isPoint) {
    final was = fr(nodes[i].x, nodes[i].y);
    p = dragAxisLock == 'x' ? [p[0], was[1]] : [was[0], p[1]];
  }
  return (point: p, guides: guides);
}

/// The keyed points of a line move to where they are at `globalFrame` (the
/// editor's frame): the handles and edits work on what is shown.
void syncLineToFrame(Layer layer, int globalFrame) {
  final nodes = layer.content.lineNodes;
  if (nodes == null ||
      !nodes.any((n) => (n.posT != null && n.posT!.keyframes.isNotEmpty) || n.keys.values.any((t) => t.keyframes.isNotEmpty))) {
    return;
  }
  final f = localFrameOf(layer, globalFrame);
  for (final n in nodes) {
    final (x, y) = n.posAt(f);
    n
      ..x = x
      ..y = y
      ..hIn = [...n.handleAt('hIn', f)]
      ..hOut = [...n.handleAt('hOut', f)]
      ..w = n.valueAt('w', f)
      ..round = n.valueAt('round', f)!
      ..roundK = n.valueAt('roundK', f)!;
  }
  syncLineBox(layer.content);
}

/// Sets point `i`'s `name` ('w' / 'round' / 'roundK') - a key at local
/// frame `f` when it has keys.
void setLinePointValue(Content c, int i, String name, double? v, int f) {
  final n = c.lineNodes![i];
  switch (name) {
    case 'w':
      n.w = v;
    case 'round':
      n.round = v ?? 0;
    default:
      n.roundK = v ?? circleRoundK;
  }
  final t = n.keys[name];
  if (t != null && t.keyframes.isNotEmpty && v != null) setTrackValueAt(t, f, v);
}

/// Keys point `i`'s `name` at local frame `f` (or takes the key away).
void toggleLinePointValueKey(Content c, int i, String name, int f) {
  final n = c.lineNodes![i];
  final v = n.valueAt(name, null) ?? c.lineWidth;
  final t = n.keys[name] ??= Track(v, false);
  final at = t.keyframes.indexWhere((k) => k.frame == f);
  if (at >= 0) {
    t.keyframes.removeAt(at);
  } else {
    t.keyframes
      ..add(Keyframe(frame: f, value: v))
      ..sort((a, b) => a.frame.compareTo(b.frame));
  }
}

/// Keys the position of point `i` at local frame `f` (or, keyed there
/// already, takes the key away).
void toggleLinePointKey(Content c, int i, int f) {
  final n = c.lineNodes![i];
  final t = n.posT ??= Track(<double>[n.x, n.y], false);
  final at = t.keyframes.indexWhere((k) => k.frame == f);
  if (at >= 0) {
    t.keyframes.removeAt(at);
  } else {
    t.keyframes
      ..add(Keyframe(frame: f, value: <double>[n.x, n.y]))
      ..sort((a, b) => a.frame.compareTo(b.frame));
  }
}

/// Turns about the middle of its points: moves the line's own origin
/// (its pivot) there, the anchor along so nothing moves on the stage.
/// Two points: half way; more: the average of them all.
void centerLinePivot(Project project, Layer layer, int globalFrame) {
  final c = layer.content;
  final nodes = c.lineNodes;
  if (nodes == null || nodes.isEmpty) return;
  var cx = 0.0, cy = 0.0;
  for (final p in nodes) {
    cx += p.x;
    cy += p.y;
  }
  cx /= nodes.length;
  cy /= nodes.length;
  if (cx.abs() < 1e-6 && cy.abs() < 1e-6) return;
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final f0 = applyAffine(m, const [0, 0]), f1 = applyAffine(m, [cx, cy]);
  final a0 = anchorLocalFromScreen(project, layer, f0[0], f0[1], globalFrame);
  final a1 = anchorLocalFromScreen(project, layer, f1[0], f1[1], globalFrame);
  final dx = a1[0] - a0[0], dy = a1[1] - a0[1];
  for (final p in nodes) {
    p
      ..x -= cx
      ..y -= cy;
    final t = p.posT;
    if (t != null) {
      List<double> sh(Object? v) {
        final l = v as List;
        return [(l[0] as num).toDouble() - cx, (l[1] as num).toDouble() - cy];
      }

      t.defaultValue = sh(t.defaultValue);
      for (final k in t.keyframes) {
        k.value = sh(k.value);
      }
    }
  }
  final trk = layer.transform.anchor;
  List<double> shift(Object? v) {
    final l = v as List;
    return [(l[0] as num).toDouble() + dx, (l[1] as num).toDouble() + dy];
  }

  trk.defaultValue = shift(trk.defaultValue);
  for (final k in trk.keyframes) {
    k.value = shift(k.value);
  }
  syncLineBox(c);
}

/// Line tab, "Add by tapping": a point at content-local `p` after the
/// selected one - past an end it lengthens the line; from a point in the
/// middle it returns false (the caller starts a new line from there).
/// Returns the new point's index, or null when it isn't an end.
int? addLinePointAt(Content c, int selected, List<double> p) {
  final nodes = c.lineNodes!;
  if (c.lineClosed) return null;
  if (selected == nodes.length - 1) {
    nodes.add(LineNode(p[0], p[1]));
    syncLineBox(c);
    return nodes.length - 1;
  }
  if (selected == 0) {
    // the first point: the new one comes before it (its segment shape
    // moves to the old first point).
    nodes.insert(0, LineNode(p[0], p[1]));
    syncLineBox(c);
    return 0;
  }
  return null;
}

/// Joins line `b` onto line `a` at their nearest ends (b's points move
/// into a's space; ends closer than `touch` px become one point). Returns
/// false when either isn't an open node line.
bool joinLines(Project project, Layer a, Layer b, int globalFrame, {double touch = 1}) {
  final ca = a.content, cb = b.content;
  if (!isNodeLine(ca) || !isNodeLine(cb) || ca.lineClosed || cb.lineClosed) return false;
  final ma = getTransformBoxHandles(project, a, globalFrame).mCanvas;
  final mb = getTransformBoxHandles(project, b, globalFrame).mCanvas;
  final inv = invertAffine(ma);
  // b's points (and bezier handles) in a's space.
  List<double> toA(double x, double y) => applyAffine(inv, applyAffine(mb, [x, y]));
  final moved = <LineNode>[];
  for (final p in cb.lineNodes!) {
    final q = toA(p.x, p.y);
    final hi = toA(p.x + p.hIn[0], p.y + p.hIn[1]), ho = toA(p.x + p.hOut[0], p.y + p.hOut[1]);
    moved.add(p.copy()
      ..x = q[0]
      ..y = q[1]
      ..hIn = [hi[0] - q[0], hi[1] - q[1]]
      ..hOut = [ho[0] - q[0], ho[1] - q[1]]);
  }
  final na = ca.lineNodes!;
  double d(LineNode p, LineNode q) => math.sqrt(math.pow(p.x - q.x, 2) + math.pow(p.y - q.y, 2));
  // the nearest pair of ends.
  final pairs = [
    (d(na.last, moved.first), false, false),
    (d(na.last, moved.last), false, true),
    (d(na.first, moved.first), true, false),
    (d(na.first, moved.last), true, true),
  ]..sort((x, y) => x.$1.compareTo(y.$1));
  final (gap, aFirst, bLast) = pairs.first;
  var list = [...na];
  if (aFirst) list = _reverseNodes(list);
  var add = bLast ? _reverseNodes(moved) : moved;
  // in a's space, a pixel there is not a frame pixel - close enough.
  if (gap <= touch) {
    final joint = list.removeLast();
    add = [add.first..hIn = joint.hIn, ...add.skip(1)];
  }
  // the first of b's points now arrives from a: a straight stretch.
  add.first.kind = 'line';
  ca.lineNodes = [...list, ...add];
  syncLineBox(ca);
  project.layers.remove(b);
  return true;
}

/// The same line walked the other way (each segment's shape stays with
/// it, the bezier handles swap sides).
List<LineNode> _reverseNodes(List<LineNode> nodes) {
  final n = nodes.length;
  final out = <LineNode>[];
  for (var k = n - 1; k >= 0; k--) {
    final p = nodes[k].copy();
    final h = p.hIn;
    p
      ..hIn = p.hOut
      ..hOut = h
      // the segment arriving here (walking backwards) is the one that left
      // it forwards: its shape is the next point's.
      ..kind = k + 1 < n ? nodes[k + 1].kind : 'line';
    if (k + 1 < n) {
      p
        ..ampT = cloneTrack(nodes[k + 1].ampT)
        ..wavesT = cloneTrack(nodes[k + 1].wavesT);
      // a circle bulges to the left of the way: walked back, the other side.
      if (p.kind == 'arc') {
        p.ampT.defaultValue = -(p.ampT.defaultValue as num).toDouble();
        for (final key in p.ampT.keyframes) {
          key.value = -(key.value as num).toDouble();
        }
      }
    }
    out.add(p);
  }
  return out;
}

/// A node line's handles in frame space (key -> point).
Map<String, List<double>> lineHandlesFrame(Project project, Layer layer, int globalFrame,
    {required bool editing, int? selected}) {
  final c = layer.content;
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  return {
    for (final k in lineHandleKeys(c, editing: editing, selected: selected)) k: applyAffine(m, lineHandleLocal(c, k).local)
  };
}

/// The line itself in frame space (for grabbing it along its length).
List<List<double>> lineFramePoints(Project project, Layer layer, int globalFrame) {
  final c = layer.content;
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  return [
    for (final p in sampleLine(c.lineNodes!, closed: c.lineClosed, perCurve: 16, frame: globalFrame - layer.startFrame))
      applyAffine(m, p)
  ];
}

/// A line's anchor on the stage: its pivot (content-local 0, 0), frame px.
List<double> lineAnchorFrame(Project project, Layer layer, int globalFrame) =>
    applyAffine(getTransformBoxHandles(project, layer, globalFrame).mCanvas, const [0, 0]);

/// A filled line's shape (see Content.lineFillMode): through its points;
/// with its width around them; or less its width.
List<List<List<double>>> filledLineRings(Content c, {num? frame}) {
  final pts = sampleLine(c.lineNodes!, closed: true, perCurve: 16, frame: frame);
  final poly = [pts.sublist(0, pts.length - 1)];
  if (c.lineFillMode == 'points' || c.lineWidth <= 0) return poly;
  var band = <List<List<double>>>[];
  for (final r in lineStrokeRings(c, frame: frame)) {
    band = band.isEmpty ? [r] : polygonBoolean(band, [r], BoolOp.union);
  }
  if (band.isEmpty) return poly;
  return polygonBoolean(poly, band, c.lineFillMode == 'inner' ? BoolOp.subtract : BoolOp.union);
}

/// Collide: a line as it is - one thin box per stretch of it (its width),
/// at most `cap` of them; a filled line as its outline.
List<List<List<double>>> lineCollisionRings(Content c, {num? frame, int cap = 32}) {
  var pts = sampleLine(c.lineNodes!, closed: c.lineClosed, perCurve: 12, frame: frame);
  if (isFilledLine(c)) return filledLineRings(c, frame: frame);
  final step = ((pts.length - 1) / cap).ceil();
  if (step > 1) {
    pts = [for (var i = 0; i < pts.length; i += step) pts[i], if ((pts.length - 1) % step != 0) pts.last];
  }
  final h = math.max(0.5, c.lineWidth / 2);
  final out = <List<List<double>>>[];
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-9) continue;
    final nx = -dy / len * h, ny = dx / len * h;
    out.add([
      [a[0] + nx, a[1] + ny],
      [b[0] + nx, b[1] + ny],
      [b[0] - nx, b[1] - ny],
      [a[0] - nx, a[1] - ny],
    ]);
  }
  return out;
}

/// The outline of a line as drawn (Contour / Show contour): a filled one's
/// shape; an open one, the band its width covers around it; a loop, the
/// band's two edges (outer and inner).
List<List<List<double>>> lineOutlineRings(Content c, {num? frame}) {
  final pts = sampleLine(c.lineNodes!, closed: c.lineClosed, perCurve: 16, frame: frame);
  if (isFilledLine(c)) return filledLineRings(c, frame: frame);
  final h = math.max(0.5, c.lineWidth / 2);
  final ring = c.lineClosed ? pts.sublist(0, pts.length - 1) : pts;
  final n = ring.length;
  if (n < 2) return const [];
  List<double> normalAt(int i) {
    List<double> seg(int a, int b) {
      final dx = ring[b][0] - ring[a][0], dy = ring[b][1] - ring[a][1];
      final l = math.sqrt(dx * dx + dy * dy);
      return l == 0 ? [0, 0] : [-dy / l, dx / l];
    }

    final hasPrev = c.lineClosed || i > 0, hasNext = c.lineClosed || i < n - 1;
    final a = hasPrev ? seg((i - 1 + n) % n, i) : null, b = hasNext ? seg(i, (i + 1) % n) : null;
    if (a == null) return b!;
    if (b == null) return a;
    final x = a[0] + b[0], y = a[1] + b[1];
    final l = math.sqrt(x * x + y * y);
    if (l < 1e-9) return a;
    // mitred, capped so a sharp turn doesn't spike.
    final k = (2 / l).clamp(1.0, 3.0) / 1;
    return [x / l * k, y / l * k];
  }

  final left = [for (var i = 0; i < n; i++) () {
    final m = normalAt(i);
    return [ring[i][0] + m[0] * h, ring[i][1] + m[1] * h];
  }()];
  final right = [for (var i = 0; i < n; i++) () {
    final m = normalAt(i);
    return [ring[i][0] - m[0] * h, ring[i][1] - m[1] * h];
  }()];
  if (c.lineClosed) return [left, right];
  return [
    [...left, ...right.reversed]
  ];
}


/// Sets point `i`'s position (content-local) - a key at local frame `f`
/// when it has keys.
void setLinePointPos(Content c, int i, List<double> p, int f) {
  final n = c.lineNodes![i];
  n
    ..x = p[0]
    ..y = p[1];
  final t = n.posT;
  if (t != null && t.keyframes.isNotEmpty) setTrackValueAt(t, f, <double>[p[0], p[1]]);
  syncLineBox(c);
}

/// Sets point `i`'s bezier handle ('hIn' / 'hOut', relative to the point)
/// - a key at local frame `f` when it has keys.
void setLineHandle(Content c, int i, String name, List<double> v, int f) {
  final n = c.lineNodes![i];
  name == 'hIn' ? n.hIn = [v[0], v[1]] : n.hOut = [v[0], v[1]];
  final t = n.keys[name];
  if (t != null && t.keyframes.isNotEmpty) setTrackValueAt(t, f, <double>[v[0], v[1]]);
  syncLineBox(c);
}

/// Keys point `i`'s handle `name` at local frame `f` (or takes the key
/// away).
void toggleLineHandleKey(Content c, int i, String name, int f) {
  final n = c.lineNodes![i];
  final v = <double>[...(name == 'hIn' ? n.hIn : n.hOut)];
  final t = n.keys[name] ??= Track(v, false);
  final at = t.keyframes.indexWhere((k) => k.frame == f);
  if (at >= 0) {
    t.keyframes.removeAt(at);
  } else {
    t.keyframes
      ..add(Keyframe(frame: f, value: v))
      ..sort((a, b) => a.frame.compareTo(b.frame));
  }
}

/// A point put into the line where `p` (content-local) lies on it, within
/// `reach` px: between the two points of that stretch (its shape kept as
/// near as it goes). Returns its index, or null when `p` is off the line.
int? insertLinePointOn(Content c, List<double> p, double reach) {
  final nodes = c.lineNodes!;
  final n = nodes.length;
  final segs = c.lineClosed ? n : n - 1;
  var best = reach;
  int? at;
  for (var s = 0; s < segs; s++) {
    final a = nodes[s], b = nodes[(s + 1) % n];
    for (var k = 0; k <= 24; k++) {
      final q = _segPoint(a, b, b.kind, k / 24);
      final d = math.sqrt(math.pow(q[0] - p[0], 2) + math.pow(q[1] - p[1], 2));
      if (d < best) {
        best = d;
        at = s;
      }
    }
  }
  if (at == null) return null;
  final b = nodes[(at + 1) % n];
  final node = LineNode(p[0], p[1], kind: b.kind == 'bezier' ? 'line' : b.kind, w: b.w)
    ..ampT = cloneTrack(b.ampT)
    ..wavesT = cloneTrack(b.wavesT);
  nodes.insert(at + 1, node);
  syncLineBox(c);
  return at + 1;
}

/// The line flipped about its own middle (sideways or upside down): its
/// points, handles and keys - the handles on the stage go with it.
void flipLineNodes(Content c, {required bool horizontal}) {
  final nodes = c.lineNodes!;
  final i = horizontal ? 0 : 1;
  final mid = c.offset[i];
  List<double> pt(List v) {
    final q = [for (final e in v) (e as num).toDouble()];
    q[i] = 2 * mid - q[i];
    return q;
  }

  List<double> vec(List v) {
    final q = [for (final e in v) (e as num).toDouble()];
    q[i] = -q[i];
    return q;
  }

  for (final n in nodes) {
    final q = pt([n.x, n.y]);
    n
      ..x = q[0]
      ..y = q[1]
      ..hIn = vec(n.hIn)
      ..hOut = vec(n.hOut);
    final t = n.posT;
    if (t != null) {
      t.defaultValue = pt(t.defaultValue as List);
      for (final k in t.keyframes) {
        k.value = pt(k.value as List);
      }
    }
    for (final name in const ['hIn', 'hOut']) {
      final h = n.keys[name];
      if (h == null) continue;
      h.defaultValue = vec(h.defaultValue as List);
      for (final k in h.keyframes) {
        k.value = vec(k.value as List);
      }
    }
    // a sine / arc bulges to the other side now.
    n.ampT.defaultValue = -(n.ampT.defaultValue as num).toDouble();
    for (final k in n.ampT.keyframes) {
      k.value = -(k.value as num).toDouble();
    }
  }
  syncLineBox(c);
}

/// Splits an open line at point `i` (a middle one): this line keeps the
/// points up to it, the returned list is the rest (from it on). A loop is
/// opened there instead (returns an empty list). Null when there is
/// nothing to split (an end point).
List<LineNode>? splitLineAt(Content c, int i) {
  final nodes = c.lineNodes!;
  if (c.lineClosed) {
    // open the loop at the point: it becomes both ends.
    final rot = [...nodes.sublist(i), ...nodes.sublist(0, i), nodes[i].copy()..kind = nodes[i].kind];
    rot.first.kind = 'line';
    c
      ..lineNodes = rot
      ..lineClosed = false
      ..lineFilled = false;
    syncLineBox(c);
    return const [];
  }
  if (i <= 0 || i >= nodes.length - 1) return null;
  final rest = [nodes[i].copy()..kind = 'line', ...nodes.sublist(i + 1)];
  c.lineNodes = nodes.sublist(0, i + 1);
  syncLineBox(c);
  return rest;
}
