// ===== pendulum: a damped swing driven by the grip point's motion =====
// The layer hangs from its grip point (pivotOffset) like a weight on a
// spring hinge. Whenever the grip point accelerates, the inertia of the
// layer's body pushes it the other way: the torque is the cross product
// of the lever (grip point -> centre of the layer) and the acceleration,
// so it responds the same way a real pendulum does - from rest, smoothly,
// the very frame motion starts, growing with how hard the support speeds
// up or slows down, then ringing out after it stops.
//
//   theta'' = omega^2 * (target - theta) - 2 * damping * theta'
//   target  = sensitivity * a_perp + freeze * v_perp
//
// - a_perp: the support's acceleration across the lever (stage sizes /
//   s^2) - the inertial push;
// - v_perp: its velocity across the lever - "freeze": while the support
//   moves fast the layer leans back against the motion (like drag) and
//   holds there, swinging back as it slows down;
// - the angle is soft-limited to maxAngle (tanh), so even a jerk stays
//   within it.
//
// Still pull-model: every call integrates from the anchor track's first
// keyframe to the asked frame (nothing cached between frames), using the
// WORLD position of the layer (getLayerBaseStateAt - its own swing
// excluded, a parent's included), which is what makes rig chains cascade.
//
// Replaces the earlier "sum of fixed damped sines" model: it only started
// once the support's speed crossed a threshold and then switched the full
// swing on at once - motionless for the first frames of an eased start,
// then a visible kick in the motion path.
library;

import 'dart:math' as math;

import '../../core/interpolation.dart';
import '../../core/stage_size.dart';
import '../../core/state_cache.dart';
import '../../geometry/shapes.dart';
import '../../model/project.dart';

/// The pendulum's weight (content-local): its own point, or the middle
/// of the content.
List<double> pendulumWeightPoint(Layer layer) {
  final w = layer.pendulum.weightPoint;
  if (w != null) return w;
  final box = shapeBoundingBox(layer.content);
  return [(box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2];
}

double evaluatePendulumOffset(Project project, Layer layer, int globalFrame) {
  final p = layer.pendulum;
  if (!p.enabled) return 0;
  final maxAngle = math.max(0.0, math.min(90.0, p.maxAngle));
  if (maxAngle == 0) return 0;
  final kfs = layer.transform.anchor.keyframes;
  // with keyframes: nothing before the track's own first keyframe.
  // Without (a chain link moved only by its parent): from frame 0.
  final startLocalFrame = kfs.isNotEmpty ? kfs.first.frame : 0;
  final endLocalFrame = globalFrame - layer.startFrame;
  if (endLocalFrame <= startLocalFrame) return 0;

  final freqHz = 0.2 + (p.frequency / 100) * 4.8; // 0..100 -> 0.2..5 Hz
  final damping = 0.1 + (p.damping / 100) * 2.9; // 0..100 -> 0.1..3 per second
  final omega = freqHz * 2 * math.pi;
  // degrees of lean per stage-size/s^2 of acceleration: x4 per 50 steps.
  final accelGain = 2.5 * math.pow(4.0, (p.sensitivity - 50) / 50);
  // degrees of lean per stage-size/s of speed.
  final dragGain = p.freeze / 100 * 30;

  final w = stageSize.width, h = stageSize.height;
  final norm = math.max(1.0, math.max(w, h));
  final weight = pendulumWeightPoint(layer);
  final cx = weight[0], cy = weight[1];

  // the layer's world position (px) and the lever's direction at a frame.
  List<double> matrixAt(int localFrame) => getLayerBaseStateAt(project, layer.id, localFrame + layer.startFrame).baseMatrix;
  List<double> lever(List<double> m, int localFrame) {
    final clamped = math.min(layer.durationFrames, math.max(0, localFrame)).toDouble();
    final pivot = evaluateTrack(project, p.pivotOffset, clamped, layer) as List<double>;
    final rx = cx - pivot[0], ry = cy - pivot[1];
    final wx = m[0] * rx + m[2] * ry, wy = m[1] * rx + m[3] * ry;
    final len = math.sqrt(wx * wx + wy * wy);
    // grip point at the centre: as if hanging straight down.
    return len < 1e-6 ? const [0.0, 1.0] : [wx / len, wy / len];
  }

  const dt = 1.0;
  final step = dt / fps;
  const substeps = 4;
  final hStep = step / substeps;
  var prev = matrixAt(startLocalFrame - 1), cur = matrixAt(startLocalFrame);
  var theta = 0.0, rate = 0.0; // degrees, degrees per second
  for (var lf = startLocalFrame; lf < endLocalFrame; lf++) {
    final next = matrixAt(lf + 1);
    final px = [prev[4] * w, prev[5] * h], qx = [cur[4] * w, cur[5] * h], nx = [next[4] * w, next[5] * h];
    final vx = (nx[0] - px[0]) / (2 * step) / norm, vy = (nx[1] - px[1]) / (2 * step) / norm;
    final ax = (nx[0] - 2 * qx[0] + px[0]) / (step * step) / norm;
    final ay = (nx[1] - 2 * qx[1] + px[1]) / (step * step) / norm;
    final u = lever(cur, lf);
    // across the lever, signed so a positive value turns the layer the
    // way the swing's rotation (positive = clockwise on screen) goes.
    final aPerp = u[1] * ax - u[0] * ay;
    final vPerp = u[1] * vx - u[0] * vy;
    final target = accelGain * aPerp + dragGain * vPerp;
    for (var s = 0; s < substeps; s++) {
      rate += (omega * omega * (target - theta) - 2 * damping * rate) * hStep;
      theta += rate * hStep;
    }
    prev = cur;
    cur = next;
  }
  return maxAngle * _tanh(theta / maxAngle);
}

double _tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}
