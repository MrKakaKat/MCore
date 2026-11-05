import 'dart:math' as math;

import '../../model/project.dart';

// ===== wiggle: "drunk hand" position wander =====
// periodically (per `speed`) pick a new random waypoint within
// `amplitude` of rest, then spline THROUGH that sequence of waypoints
// using the exact same catmull-rom tangent formula path tension
// already uses - `smoothness` IS that same 0..1 tension convention.
// no rotation involved at all - this only ever offsets ANCHOR
// (position), added on top of whatever the layer's own anchor curve
// already produces.

// deterministic hash -> [0,1) (NOT a real RNG - a pull-model
// re-evaluation of the same frame must always give the same result)
double _hashToUnit(double n) {
  final x = math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - x.floorToDouble();
}

List<double> _wiggleWaypoint(Layer layer, int i, double amplitude) {
  final seed = i * 1000.7 + (layer.wiggle.wiggleSeed ?? 0);
  final angle = _hashToUnit(seed) * math.pi * 2;
  final r = amplitude * math.sqrt(_hashToUnit(seed + 0.37)); // sqrt -> uniform over the DISK, not just the radius
  return [math.cos(angle) * r, math.sin(angle) * r];
}

List<double> evaluateWiggleOffset(Layer layer, int globalFrame) {
  final w = layer.wiggle;
  if (!w.enabled) return [0, 0];
  final speedHz = 0.1 + (w.speed / 100) * 3.9; // 0..100 -> 0.1..4 new waypoints/sec (never fully frozen)
  final amplitude = (w.amplitude / 100) * 0.15; // 0..100 -> 0..15% of canvas
  final tension = w.smoothness / 100; // 0..100 -> 0..1, same convention as path tension

  final framesPerWaypoint = fps / speedHz;
  final t = globalFrame / framesPerWaypoint;
  final i0 = t.floor();
  final localT = t - i0;

  final pM1 = _wiggleWaypoint(layer, i0 - 1, amplitude);
  final p0 = _wiggleWaypoint(layer, i0, amplitude);
  final p1 = _wiggleWaypoint(layer, i0 + 1, amplitude);
  final p2 = _wiggleWaypoint(layer, i0 + 2, amplitude);

  final k = 1 - tension; // identical to catmullRomTangent's own k
  final m0 = [k * (p1[0] - pM1[0]) / 2, k * (p1[1] - pM1[1]) / 2];
  final m1 = [k * (p2[0] - p0[0]) / 2, k * (p2[1] - p0[1]) / 2];
  final tt = localT;
  final tt2 = tt * tt, tt3 = tt2 * tt;
  final h00 = 2 * tt3 - 3 * tt2 + 1;
  final h10 = tt3 - 2 * tt2 + tt;
  final h01 = -2 * tt3 + 3 * tt2;
  final h11 = tt3 - tt2;
  return [
    h00 * p0[0] + h10 * m0[0] + h01 * p1[0] + h11 * m1[0],
    h00 * p0[1] + h10 * m0[1] + h01 * p1[1] + h11 * m1[1],
  ];
}
