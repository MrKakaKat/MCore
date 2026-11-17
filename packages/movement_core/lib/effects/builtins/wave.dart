import 'dart:math' as math;

import '../../model/project.dart' show fps;
import '../geometry_effect_registry.dart';
import 'bend_arc.dart' show gridBox;

/// Wave: the shape ripples like a flag - every point pushed across the
/// wave's way (`angle`, degrees) by a sine of where it lies along it.
/// `height` px, `length` px from crest to crest, `frequency` ripples per
/// second in place and `speed` px per second the waves travel along.
void registerWave() {
  registerEffect(EffectDef(
    id: 'wave',
    name: 'Wave',
    category: 'geometry',
    type: 'vertex',
    params: const [
      ParamDef(key: 'angle', type: 'float', defaultValue: 0.0, range: [-180, 180]),
      ParamDef(key: 'height', type: 'float', defaultValue: 12.0, range: [0, 200]),
      ParamDef(key: 'length', type: 'float', defaultValue: 120.0, range: [8, 1000]),
      ParamDef(key: 'frequency', type: 'float', defaultValue: 1.0, range: [0, 10]),
      ParamDef(key: 'speed', type: 'float', defaultValue: 0.0, range: [-600, 600]),
    ],
    apply: (grid, params, localFrame) => waveGrid(grid, params, localFrame / fps),
    // fine rows along the wave's way: enough points per crest to stay round.
    gridHints: (params, rest) {
      final b = gridBox(rest);
      final half = math.sqrt(math.pow(b.maxX - b.minX, 2) + math.pow(b.maxY - b.minY, 2)) / 2;
      final len = _n(params, 'length', 120).clamp(8.0, 1000.0);
      final rows = (2 * half / len * 12).ceil().clamp(8, 160);
      return [GridHint(axisAngle: _n(params, 'angle', 0), from: -half, to: half, rows: rows)];
    },
  ));
}

double _n(Map<String, dynamic> p, String k, double d) {
  final v = p[k];
  return v is num ? v.toDouble() : d;
}

/// The grid rippled at time `t` (seconds).
Grid waveGrid(Grid grid, Map<String, dynamic> params, double t) {
  final b = gridBox(grid);
  final cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
  final a = _n(params, 'angle', 0) * math.pi / 180;
  final dx = math.cos(a), dy = math.sin(a);
  final h = _n(params, 'height', 12);
  final len = math.max(1.0, _n(params, 'length', 120));
  final f = _n(params, 'frequency', 1), v = _n(params, 'speed', 0);
  return [
    for (final row in grid)
      [
        for (final p in row)
          () {
            final s = (p[0] - cx) * dx + (p[1] - cy) * dy;
            final d = h * math.sin(2 * math.pi * ((s - v * t) / len + f * t));
            return [p[0] - dy * d, p[1] + dx * d];
          }(),
      ],
  ];
}
