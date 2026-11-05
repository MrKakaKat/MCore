/// Reference projects for measuring performance on a device (the HUD's
/// baseline): each stresses one part of the engine. Built here, as plain
/// data, so they are the same every time and testable.
library;

import '../effects/builtins/builtins.dart';
import '../effects/geometry_effect_registry.dart';
import 'project.dart';

class PerfScene {
  final String name;
  final Project project;
  final int maxFrame;
  const PerfScene(this.name, this.project, this.maxFrame);
}

Layer _shape(String shape, String id, double x, double y, {double size = 40, String color = '#8ab4d8'}) {
  final l = createLayer(shape)
    ..id = id
    ..name = id
    ..color = color;
  l.content.size = [size, size];
  l.transform.anchor.defaultValue = [x, y];
  return l;
}

Keyframe _key(int frame, dynamic value) => Keyframe(frame: frame, value: value, temporal: easingPresets['easeInOut']);

/// The four reference scenes: static shapes, a pendulum chain on a long
/// timeline, a motion-blurred layer, a textured mesh-warp layer.
List<PerfScene> perfReferenceScenes() {
  registerBuiltinEffects();

  // 1. static: 12 shapes, nothing animated.
  final static = Project(layers: [
    for (var i = 0; i < 12; i++)
      _shape(['rect', 'circle', 'triangle'][i % 3], 'static_${i + 1}', 0.15 + (i % 4) * 0.23, 0.2 + (i ~/ 4) * 0.3)
        ..durationFrames = 600,
  ]);

  // 2. pendulum chain: 5 links hanging off a root that swings across,
  // 30 s timeline (each link's pendulum simulates from its first frame).
  final root = _shape('rect', 'chain_root', 0.2, 0.15, size: 30)..durationFrames = 1800;
  root.transform.anchor.keyframes = [
    for (var k = 0; k <= 1800; k += 120) _key(k, [k % 240 == 0 ? 0.2 : 0.8, 0.15]),
  ];
  final chain = <Layer>[root];
  for (var i = 1; i <= 5; i++) {
    final link = _shape('rect', 'chain_$i', 0.5, 0.5, size: 24)
      ..parentId = chain.last.id
      ..durationFrames = 1800;
    link.transform.anchor.defaultValue = [0.0, 0.12]; // below its parent
    link.pendulum.enabled = true;
    chain.add(link);
  }
  final pendulum = Project(layers: chain);

  // 3. motion blur: a shape crossing the frame back and forth, 8 samples.
  final blurred = _shape('rect', 'blurred', 0.1, 0.5, size: 60)..durationFrames = 600;
  blurred.transform.anchor.keyframes = [
    for (var k = 0; k <= 600; k += 30) _key(k, [k % 60 == 0 ? 0.1 : 0.9, 0.5]),
  ];
  blurred.motionBlur
    ..enabled = true
    ..samples = 8
    ..shutterAngle = 270;
  final blur = Project(layers: [_shape('rect', 'backdrop', 0.5, 0.5, size: 400, color: '#333344')..durationFrames = 600, blurred]);

  // 4. mesh warp: a circle (drawn as a warped texture) with moving pins.
  final warped = _shape('circle', 'warped', 0.5, 0.5, size: 260)..durationFrames = 600;
  final inst = createEffectInstance('mesh_warp', 'fx_mesh', warped);
  for (final key in ['r1c1', 'r2c2']) {
    final t = inst.params[key];
    if (t is Track) {
      t.keyframes = [
        for (var k = 0; k <= 600; k += 40) _key(k, k % 80 == 0 ? [0.0, 0.0] : [key == 'r1c1' ? 40.0 : -40.0, 30.0]),
      ];
    }
  }
  warped.effectStack.add(inst);
  final mesh = Project(layers: [warped]);

  return [
    PerfScene('Perf: static shapes', static, 600),
    PerfScene('Perf: pendulum chain', pendulum, 1800),
    PerfScene('Perf: motion blur', blur, 600),
    PerfScene('Perf: mesh warp', mesh, 600),
    PerfScene('Masks: Add, Subtract, Intersect, Exclude', _maskScene('basic', ['add', 'subtract', 'intersect', 'exclude']), 240),
    PerfScene('Masks: logic (Implication, Equivalence, Invert)',
        _maskScene('logic', ['implication', 'equivalence', 'exclude', 'subtract'], invertSecond: [false, false, true, true]),
        240),
  ];
}

/// Four mask demos in a 2x2 grid, one mode each: a square (named after
/// its mode) masked first by a still circle A (Add), then by circle B in
/// that mode, B sliding across A and back - so every overlap shows. The
/// circles themselves are hidden (turn on "Show how the masks work").
/// `invertSecond`: B inverted (Exclude + Invert = Equivalence,
/// Subtract + Invert = Intersect).
Project _maskScene(String tag, List<String> modes, {List<bool>? invertSecond}) {
  const colors = ['#e07050', '#50a0e0', '#60c080', '#d0b040'];
  final layers = <Layer>[];
  for (var i = 0; i < 4; i++) {
    final cx = i.isEven ? 0.28 : 0.72, cy = i < 2 ? 0.3 : 0.72;
    final inv = invertSecond != null && invertSecond[i];
    final a = _shape('circle', 'mask_${tag}_a$i', cx - 0.05, cy, size: 110)
      ..name = 'A ${i + 1}'
      ..durationFrames = 240
      ..hidden = true;
    final b = _shape('circle', 'mask_${tag}_b$i', cx - 0.12, cy, size: 90)
      ..name = 'B ${i + 1}'
      ..durationFrames = 240
      ..hidden = true;
    b.transform.anchor.keyframes = [
      _key(0, [cx - 0.12, cy]),
      _key(120, [cx + 0.12, cy]),
      _key(240, [cx - 0.12, cy]),
    ];
    final name = '${modes[i][0].toUpperCase()}${modes[i].substring(1)}${inv ? ' + Invert' : ''}';
    final target = _shape('rect', 'mask_${tag}_t$i', cx, cy, size: 190, color: colors[i])
      ..name = name
      ..durationFrames = 240
      ..masks.addAll([
        Mask(mode: 'add', sourceLayerId: a.id),
        Mask(mode: modes[i], sourceLayerId: b.id, invert: inv),
      ]);
    layers.addAll([a, b, target]);
  }
  return Project(layers: layers);
}
