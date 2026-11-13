import 'dart:math' as math;

// motion path-follow: walks a piecewise-linear parametrization (t: 0..1)
// two parametrizations for walking a closed outline by t (0..1):
// - arcLength (default): equal t covers equal DISTANCE, so speed along
//   the path is even regardless of vertex spacing.
// - vertex (legacy/alternate): equal t covers equal VERTEX COUNT,
//   ignoring actual edge length.
List<double> pointOnOutlineByVertex(List<List<double>> canvasSpacePoints, double t, {bool isClosed = true}) {
  if (canvasSpacePoints.isEmpty) return [0, 0];
  final closed = isClosed ? [...canvasSpacePoints, canvasSpacePoints[0]] : canvasSpacePoints;
  final n = closed.length - 1;
  if (n <= 0) return closed[0];
  final tt = isClosed ? ((t % 1) + 1) % 1 : t.clamp(0.0, 1.0); // wrap negative/over-1 values
  final idxF = tt * n;
  final i = math.min(n - 1, idxF.floor());
  final frac = idxF - i;
  final a = closed[i], b = closed[i + 1];
  return [a[0] + (b[0] - a[0]) * frac, a[1] + (b[1] - a[1]) * frac];
}

List<double> pointOnOutlineArcLength(List<List<double>> canvasSpacePoints, double t, {bool isClosed = true}) {
  if (canvasSpacePoints.isEmpty) return [0, 0];
  final closed = isClosed ? [...canvasSpacePoints, canvasSpacePoints[0]] : canvasSpacePoints;
  final n = closed.length - 1;
  if (n <= 0) return closed[0];
  final lengths = <double>[];
  var total = 0.0;
  for (var i = 0; i < n; i++) {
    final d = math.sqrt(math.pow(closed[i + 1][0] - closed[i][0], 2) + math.pow(closed[i + 1][1] - closed[i][1], 2));
    lengths.add(d);
    total += d;
  }
  if (total == 0) return closed[0];
  // an open path: from its start (0) to its end (1), held past them.
  final tt = isClosed ? ((t % 1) + 1) % 1 : t.clamp(0.0, 1.0);
  final targetDist = tt * total;
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    if (acc + lengths[i] >= targetDist || i == n - 1) {
      final segFrac = lengths[i] == 0 ? 0.0 : (targetDist - acc) / lengths[i];
      final a = closed[i], b = closed[i + 1];
      return [a[0] + (b[0] - a[0]) * segFrac, a[1] + (b[1] - a[1]) * segFrac];
    }
    acc += lengths[i];
  }
  return closed[n];
}

/// `closed`: an outline (t wraps round it); else an open line from its
/// start (t = 0) to its end (t = 1).
List<double> pointOnOutline(List<List<double>> canvasSpacePoints, double t, String? mode, {bool closed = true}) {
  return mode == 'vertex'
      ? pointOnOutlineByVertex(canvasSpacePoints, t, isClosed: closed)
      : pointOnOutlineArcLength(canvasSpacePoints, t, isClosed: closed);
}
