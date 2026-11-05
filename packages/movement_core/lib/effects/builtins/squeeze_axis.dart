import 'dart:math' as math;

import '../geometry_effect_registry.dart';

void registerSqueezeAxis() {
  registerEffect(EffectDef(
    id: 'squeeze_axis',
    name: 'Squeeze',
    category: 'geometry',
    type: 'vertex',
    params: const [
      ParamDef(key: 'axisX', type: 'float', defaultValue: 1.0, range: [0.1, 3]),
      ParamDef(key: 'axisY', type: 'float', defaultValue: 1.0, range: [0.1, 3]),
    ],
    apply: (grid, params, localFrame) {
      final all = grid.expand((row) => row).toList();
      final xs = [for (final p in all) p[0]], ys = [for (final p in all) p[1]];
      final cx = (xs.reduce(math.min) + xs.reduce(math.max)) / 2;
      final cy = (ys.reduce(math.min) + ys.reduce(math.max)) / 2;
      final axisX = params['axisX'] as double, axisY = params['axisY'] as double;
      return [
        for (final row in grid)
          [for (final p in row) [cx + (p[0] - cx) * axisX, cy + (p[1] - cy) * axisY]],
      ];
    },
  ));
}
