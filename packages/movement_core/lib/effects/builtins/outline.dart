import '../geometry_effect_registry.dart';

/// Outline: a sticker-style stroke along the layer's silhouette contour
/// (geometry/contour.dart). It moves no points - the renderer draws the
/// stroke (canvas_renderer.dart, _drawOutlines) - so it never turns the
/// layer into a warped texture.
void registerOutline() {
  registerEffect(EffectDef(
    id: 'outline',
    name: 'Outline',
    category: 'style',
    type: 'stroke',
    deforms: false,
    params: const [
      ParamDef(key: 'width', type: 'float', defaultValue: 6.0, range: [0, 100]),
      ParamDef(key: 'offset', type: 'float', defaultValue: 0.0, range: [-50, 50]),
      ParamDef(key: 'threshold', type: 'float', defaultValue: 0.5, range: [0.05, 0.95]),
      ParamDef(key: 'smoothness', type: 'float', defaultValue: 1.0, range: [0, 4]),
      ParamDef(key: 'color', type: 'color', defaultValue: '#ffffff', animatable: false),
      ParamDef(key: 'position', type: 'enum', defaultValue: 'outside', animatable: false, options: ['outside', 'center', 'inside']),
      ParamDef(key: 'join', type: 'enum', defaultValue: 'round', animatable: false, options: ['round', 'miter']),
      ParamDef(key: 'holes', type: 'enum', defaultValue: 'on', animatable: false, options: ['on', 'off']),
      // over or under the picture; auto: under when outside, over otherwise.
      ParamDef(key: 'layer', type: 'enum', defaultValue: 'auto', animatable: false, options: ['auto', 'over media', 'under media']),
    ],
    apply: (grid, params, localFrame) => grid,
  ));
}

/// The Outline's smoothness (0..4) as contour settings: simplify
/// tolerance in working pixels plus Chaikin passes.
({double simplify, int smooth}) outlineSmoothness(double s) =>
    (simplify: 0.5 + s * 0.5, smooth: s >= 1 ? (s.floor()).clamp(0, 3) : 0);
