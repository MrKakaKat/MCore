import 'dart:math' as math;

import '../geometry_effect_registry.dart';

void registerMeshWarp() {
  registerEffect(EffectDef(
    id: 'mesh_warp',
    name: 'Mesh Warp',
    category: 'geometry',
    type: 'vertex',
    // rows/cols are fixed at creation time (see createEffectInstance's
    // special-case, which builds the actual per-pin r{row}c{col} params
    // dynamically) - not adjustable afterward.
    params: const [
      ParamDef(key: 'rows', type: 'int', defaultValue: 4, animatable: false),
      ParamDef(key: 'cols', type: 'int', defaultValue: 4, animatable: false),
    ],
    apply: (grid, params, localFrame) {
      final rows = params['rows'] as int, cols = params['cols'] as int;
      List<double> pinOffset(int r, int c) => (params['r${r}c$c'] as List<double>?) ?? [0.0, 0.0];

      final all = grid.expand((row) => row).toList();
      final xs = [for (final p in all) p[0]], ys = [for (final p in all) p[1]];
      final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
      final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
      final w = (maxX - minX) == 0 ? 1.0 : maxX - minX;
      final h = (maxY - minY) == 0 ? 1.0 : maxY - minY;

      List<double> warp(List<double> p) {
        final x = p[0], y = p[1];
        final u = (x - minX) / w, v = (y - minY) / h;
        final cf = u * (cols - 1), rf = v * (rows - 1);
        final c0 = math.min(cols - 2, math.max(0, cf.floor()));
        final r0 = math.min(rows - 2, math.max(0, rf.floor()));
        final c1 = c0 + 1, r1 = r0 + 1;
        final fu = cf - c0, fv = rf - r0;
        final o00 = pinOffset(r0, c0), o10 = pinOffset(r0, c1);
        final o01 = pinOffset(r1, c0), o11 = pinOffset(r1, c1);
        final ox = o00[0] * (1 - fu) * (1 - fv) + o10[0] * fu * (1 - fv) + o01[0] * (1 - fu) * fv + o11[0] * fu * fv;
        final oy = o00[1] * (1 - fu) * (1 - fv) + o10[1] * fu * (1 - fv) + o01[1] * (1 - fu) * fv + o11[1] * fu * fv;
        return [x + ox, y + oy];
      }

      return [for (final row in grid) [for (final p in row) warp(p)]];
    },
  ));
}
