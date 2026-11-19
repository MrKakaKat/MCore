/// 3D projects: layers are flat cards in space, seen through a camera.
///
/// World: frame px - x right, y down (as the flat stage), z away from the
/// camera. A card is the layer drawn as in a flat project (its anchor,
/// turn about z, size, parent...), then turned about its anchor point
/// about x and y and set `z` deep. The default camera looks at the
/// frame straight on from just far enough that the plane z = 0 shows
/// exactly as the flat frame - a 3D project starts looking like a flat
/// one.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../core/interpolation.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../model/project.dart';

/// The camera that shows the plane z = 0 as the `w` x `h` frame.
Camera3 defaultCamera3(double w, double h, {double fov = 50}) {
  final d = (h / 2) / math.tan(fov * math.pi / 360);
  return Camera3(eye: [w / 2, h / 2, -d], target: [w / 2, h / 2, 0], fov: fov);
}

/// The project's camera (its own, or the default for the frame).
Camera3 cameraOf(Project p, double w, double h) => p.camera ?? defaultCamera3(w, h);

List<double> _sub(List<double> a, List<double> b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
List<double> _cross(List<double> a, List<double> b) =>
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
double _dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
List<double> _norm(List<double> a) {
  final l = math.sqrt(_dot(a, a));
  return l < 1e-12 ? [0, 0, 0] : [a[0] / l, a[1] / l, a[2] / l];
}

/// A camera set up for a `w` x `h` picture: its axes and focal length.
class View3 {
  final List<double> eye, right, up, fwd;
  final double focal, cx, cy;
  View3._(this.eye, this.right, this.up, this.fwd, this.focal, this.cx, this.cy);

  factory View3(Camera3 c, double w, double h) {
    final f = _norm(_sub(c.target, c.eye));
    // the picture's up is -y (y runs down); straight up or down: z.
    var r = _cross(f, const [0.0, -1.0, 0.0]);
    if (_dot(r, r) < 1e-12) r = _cross(f, const [0.0, 0.0, 1.0]);
    r = _norm(r);
    final u = _cross(r, f);
    final focal = (h / 2) / math.tan(c.fov * math.pi / 360);
    return View3._([...c.eye], r, u, f, focal, w / 2, h / 2);
  }

  /// A world point in the camera's space: [right, up, depth].
  List<double> toView(List<double> p) {
    final d = _sub(p, eye);
    return [_dot(right, d), _dot(up, d), _dot(fwd, d)];
  }

  /// A world point on the picture: [x, y, depth] (depth <= 0: behind).
  List<double> project(List<double> p) {
    final v = toView(p);
    final z = v[2].abs() < 1e-9 ? 1e-9 : v[2];
    return [cx + v[0] / z * focal, cy - v[1] / z * focal, v[2]];
  }

  /// The camera as one matrix (row-major 4x4): world -> picture (x, y
  /// over w; w = depth).
  List<double> matrix() {
    double t(List<double> a) => -_dot(a, eye);
    return [
      focal * right[0] + cx * fwd[0], focal * right[1] + cx * fwd[1], focal * right[2] + cx * fwd[2], focal * t(right) + cx * t(fwd),
      -focal * up[0] + cy * fwd[0], -focal * up[1] + cy * fwd[1], -focal * up[2] + cy * fwd[2], -focal * t(up) + cy * t(fwd),
      fwd[0], fwd[1], fwd[2], t(fwd),
      fwd[0], fwd[1], fwd[2], t(fwd),
    ];
  }

  /// Where the picture point (`sx`, `sy`) meets the plane z = `planeZ`
  /// (world), or null (the ray runs along it, or the plane is behind).
  List<double>? onPlaneZ(double sx, double sy, double planeZ) {
    final a = (sx - cx) / focal, b = -(sy - cy) / focal;
    final dir = [right[0] * a + up[0] * b + fwd[0], right[1] * a + up[1] * b + fwd[1], right[2] * a + up[2] * b + fwd[2]];
    if (dir[2].abs() < 1e-9) return null;
    final t = (planeZ - eye[2]) / dir[2];
    if (t <= 0) return null;
    return [eye[0] + dir[0] * t, eye[1] + dir[1] * t, planeZ];
  }

  /// A world segment on the picture, cut where it goes behind the camera
  /// (`near` px in front): [x1, y1, x2, y2], or null (all behind).
  List<double>? segment(List<double> a, List<double> b, {double near = 1}) {
    var va = toView(a), vb = toView(b);
    if (va[2] < near && vb[2] < near) return null;
    List<double> cut(List<double> p, List<double> q) {
      final t = (near - p[2]) / (q[2] - p[2]);
      return [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t, near];
    }

    if (va[2] < near) va = cut(va, vb);
    if (vb[2] < near) vb = cut(vb, va);
    return [cx + va[0] / va[2] * focal, cy - va[1] / va[2] * focal, cx + vb[0] / vb[2] * focal, cy - vb[1] / vb[2] * focal];
  }
}

/// Row-major 4x4 product a * b.
List<double> mul4(List<double> a, List<double> b) => [
      for (var r = 0; r < 4; r++)
        for (var c = 0; c < 4; c++) a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c] + a[r * 4 + 2] * b[8 + c] + a[r * 4 + 3] * b[12 + c]
    ];

/// A point through a row-major 4x4: [x, y, z, w].
List<double> apply4(List<double> m, double x, double y, double z) => [
      m[0] * x + m[1] * y + m[2] * z + m[3],
      m[4] * x + m[5] * y + m[6] * z + m[7],
      m[8] * x + m[9] * y + m[10] * z + m[11],
      m[12] * x + m[13] * y + m[14] * z + m[15],
    ];

/// Row-major to the column-major list a canvas takes.
Float64List toColumnMajor(List<double> m) =>
    Float64List.fromList([for (var c = 0; c < 4; c++) for (var r = 0; r < 4; r++) m[r * 4 + c]]);

/// The layer's own 3D: depth, the turns about x and y (degrees), the
/// depth's size - at `globalFrame`.
({double z, double rx, double ry, double sz}) layer3dAt(Project project, Layer layer, num globalFrame) {
  final f = (globalFrame - layer.startFrame).toDouble();
  double v(Track t) => (evaluateTrack(project, t, f, layer) as num).toDouble();
  final t = layer.transform;
  return (z: v(t.z), rx: v(t.rotationX), ry: v(t.rotationY), sz: v(t.scaleZ));
}

/// The card's 3D placement (row-major 4x4, world px): the flat layer
/// turned about its anchor point - about x, then y - and set its depth.
List<double> layerTilt3d(Project project, Layer layer, num globalFrame) {
  final m = getLayerStateAt(project, layer.id, globalFrame).matrix;
  final ax = m[4] * stageSize.width, ay = m[5] * stageSize.height;
  final d = layer3dAt(project, layer, globalFrame);
  final x = d.rx * math.pi / 180, y = d.ry * math.pi / 180;
  final cx = math.cos(x), sx = math.sin(x), cy = math.cos(y), sy = math.sin(y);
  // R = Ry * Rx
  final r = <double>[
    cy, sy * sx, sy * cx, //
    0.0, cx, -sx, //
    -sy, cy * sx, cy * cx,
  ];
  // T(a + z) * R * T(-a)
  final tx = ax - (r[0] * ax + r[1] * ay), ty = ay - (r[3] * ax + r[4] * ay), tz = d.z - (r[6] * ax + r[7] * ay);
  return [
    r[0], r[1], r[2], tx, //
    r[3], r[4], r[5], ty, //
    r[6], r[7], r[8], tz, //
    0.0, 0.0, 0.0, 1.0,
  ];
}

/// The card on the picture: one matrix (row-major) taking the flat
/// layer's frame px to the picture through the camera.
List<double> layerPictureMatrix(View3 view, Project project, Layer layer, num globalFrame) =>
    mul4(view.matrix(), layerTilt3d(project, layer, globalFrame));

/// How far the card's anchor point is from the camera (to draw the far
/// ones first).
double layerDepth3d(View3 view, Project project, Layer layer, num globalFrame) {
  final m = getLayerStateAt(project, layer.id, globalFrame).matrix;
  final p = apply4(layerTilt3d(project, layer, globalFrame), m[4] * stageSize.width, m[5] * stageSize.height, 0);
  return view.toView([p[0], p[1], p[2]])[2];
}

/// Frame-px points of the flat layer (its outline) on the picture; null
/// when any is behind the camera (`near` px).
List<List<double>>? projectFlatPoints(View3 view, List<double> tilt, List<List<double>> pts, {double near = 1}) {
  final out = <List<double>>[];
  final cam = view.matrix();
  final m = mul4(cam, tilt);
  for (final p in pts) {
    final q = apply4(m, p[0], p[1], 0);
    if (q[3] < near) return null;
    out.add([q[0] / q[3], q[1] / q[3]]);
  }
  return out;
}

/// A camera going round `target` (world): turned `yaw` about the up axis
/// and `pitch` up (degrees), `dist` px away.
Camera3 orbitCamera3(List<double> target, double yaw, double pitch, double dist, {double fov = 50}) {
  final y = yaw * math.pi / 180, p = pitch.clamp(-89.0, 89.0) * math.pi / 180;
  final eye = [
    target[0] - dist * math.sin(y) * math.cos(p),
    target[1] - dist * math.sin(p),
    target[2] - dist * math.cos(y) * math.cos(p),
  ];
  return Camera3(eye: eye, target: [...target], fov: fov);
}

/// Point (x, y) inside the polygon `poly` (picture px).
bool insidePolygon(List<List<double>> poly, double x, double y) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a[1] > y) != (b[1] > y) && x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
  }
  return inside;
}
