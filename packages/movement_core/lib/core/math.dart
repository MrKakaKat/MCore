import 'dart:math' as math;

/// ============================================================
/// MATRIX / PARENTING
/// - flat list of layers with parentId (no nested tree in storage)
/// - final matrix = parent.matrix x layer.local matrix
/// - 2D affine, stored as [a,b,c,d,tx,ty] - deliberately affine-only
///   for now; corner pin (perspective) plugs in later as an extra
///   stage after this, not a replacement for it
/// - kept as plain List<double> (not a Matrix2D class) to mirror
///   movement-core/src/core/math.js exactly - every call site there
///   destructures/indexes a bare array, so this stays a 1:1 port.
/// ============================================================

List<double> matFromTRS(List<double> pos, double rotDeg, List<double> scale) {
  final r = rotDeg * math.pi / 180;
  final cos = math.cos(r), sin = math.sin(r);
  return [
    cos * scale[0], sin * scale[0],
    -sin * scale[1], cos * scale[1],
    pos[0], pos[1],
  ];
}

/// m1 applied after m2 (m1 x m2), both [a,b,c,d,tx,ty]
List<double> matMul(List<double> m1, List<double> m2) {
  return [
    m1[0] * m2[0] + m1[2] * m2[1],
    m1[1] * m2[0] + m1[3] * m2[1],
    m1[0] * m2[2] + m1[2] * m2[3],
    m1[1] * m2[2] + m1[3] * m2[3],
    m1[0] * m2[4] + m1[2] * m2[5] + m1[4],
    m1[1] * m2[4] + m1[3] * m2[5] + m1[5],
  ];
}

// needed for track matte: projecting one layer's local geometry into
// another layer's local space requires inverting the target's matrix.
// generic 2x3 affine inverse - works regardless of what units the
// translation component is in, as long as both matrices being
// composed with it use the SAME units (we always use canvas-pixel
// translation for this, see drawLayer's mask stage).
List<double> invertAffine(List<double> m) {
  final a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5];
  final det = a * d - b * c;
  if (det.abs() < 1e-9) return [1, 0, 0, 1, 0, 0]; // degenerate (zero scale) - fallback identity
  final ia = d / det, ib = -b / det, ic = -c / det, id = a / det;
  return [ia, ib, ic, id, -(ia * e + ic * f), -(ib * e + id * f)];
}

List<double> applyAffine(List<double> m, List<double> p) {
  return [m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5]];
}
