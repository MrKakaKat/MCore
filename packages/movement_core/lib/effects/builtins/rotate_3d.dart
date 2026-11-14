import 'dart:math' as math;

import '../geometry_effect_registry.dart';

/// "3D Rotate": a simulated 3D turn of the flat object about an axis
/// lying in its own plane, through a pivot, with a perspective
/// projection - a card flipping, a door opening, a coin turning. The
/// object stays a flat layer (no depth sorting between layers, no real
/// lighting): the grid is rotated in 3D and projected back, and the
/// renderer darkens it by `shading` as it turns away (see `brightness`).
///
/// - angle: degrees of turn.
/// - axis: the turn axis's direction in the object's plane, in degrees -
///   0 = horizontal (tips forward/back), 90 = vertical (turns like a door).
/// - pivot: where the axis passes, as a fraction of the object's box.
/// - perspective: 0 = flat (orthographic), up to 1 = strong.
/// - shading: how much it darkens edge-on / from the back.
/// - backface: 'show' (mirrored back side) or 'hide'.
void registerRotate3d() {
  registerEffect(EffectDef(
    id: 'rotate_3d',
    name: '3D Rotate',
    category: 'geometry',
    type: 'vertex',
    params: const [
      ParamDef(key: 'angle', type: 'float', defaultValue: 0.0, range: [-360, 360]),
      ParamDef(key: 'axis', type: 'float', defaultValue: 90.0, range: [0, 180]),
      ParamDef(key: 'pivot', type: 'vec2', defaultValue: [0.5, 0.5]),
      ParamDef(key: 'perspective', type: 'float', defaultValue: 0.5, range: [0, 1]),
      ParamDef(key: 'shading', type: 'float', defaultValue: 0.3, range: [0, 1]),
      ParamDef(
        key: 'backface', type: 'enum', defaultValue: 'show',
        options: ['show', 'hide'], animatable: false,
      ),
    ],
    apply: rotate3dGrid,
    brightness: (params) {
      final cosT = math.cos(_num(params['angle'], 0) * math.pi / 180).abs();
      final shading = _num(params['shading'], 0).clamp(0.0, 1.0);
      return 1 - shading * (1 - cosT);
    },
  ));
}

double _num(dynamic v, double fallback) => v is num ? v.toDouble() : fallback;

Grid rotate3dGrid(Grid grid, Map<String, dynamic> params, double localFrame) {
  final angle = _num(params['angle'], 0);
  if (angle == 0) return grid;
  final all = grid.expand((row) => row).toList();
  if (all.isEmpty) return grid;
  // the layer's own box (given as `_box`): the same pivot whatever part of
  // it comes through, folded or not; else the grid's.
  final b = params['_box'];
  final double minX, maxX, minY, maxY;
  if (b is List && b.length == 4) {
    minX = (b[0] as num).toDouble();
    minY = (b[1] as num).toDouble();
    maxX = (b[2] as num).toDouble();
    maxY = (b[3] as num).toDouble();
  } else {
    final xs = [for (final p in all) p[0]], ys = [for (final p in all) p[1]];
    minX = xs.reduce(math.min);
    maxX = xs.reduce(math.max);
    minY = ys.reduce(math.min);
    maxY = ys.reduce(math.max);
  }
  final w = maxX - minX, h = maxY - minY;

  final pivot = params['pivot'];
  final pf = pivot is List && pivot.length >= 2
      ? [(pivot[0] as num).toDouble(), (pivot[1] as num).toDouble()]
      : const [0.5, 0.5];
  final cx = minX + pf[0] * w, cy = minY + pf[1] * h;

  final theta = angle * math.pi / 180;
  final cosT = math.cos(theta), sinT = math.sin(theta);
  if (params['backface'] == 'hide' && cosT < 0) {
    // facing away: collapse to the pivot - nothing gets drawn.
    return [for (final row in grid) [for (final _ in row) <double>[cx, cy]]];
  }

  final a = _num(params['axis'], 90) * math.pi / 180;
  final ux = math.cos(a), uy = math.sin(a);
  final persp = _num(params['perspective'], 0).clamp(0.0, 1.0);
  final focal = persp <= 0 ? double.infinity : math.max(w, h) / persp;

  List<double> turn(List<double> p) {
    final dx = p[0] - cx, dy = p[1] - cy;
    final dot = ux * dx + uy * dy;
    // Rodrigues' rotation of (dx, dy, 0) about the in-plane unit axis u.
    final x = dx * cosT + ux * dot * (1 - cosT);
    final y = dy * cosT + uy * dot * (1 - cosT);
    final z = (ux * dy - uy * dx) * sinT;
    var s = 1.0;
    if (focal.isFinite) {
      s = focal / math.max(focal * 0.05, focal + z);
    }
    return [cx + x * s, cy + y * s];
  }

  return [for (final row in grid) [for (final p in row) turn(p)]];
}
