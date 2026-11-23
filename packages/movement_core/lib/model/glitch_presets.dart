import 'dart:math' as math;

import 'project.dart';

/// Glitch looks, made of what a layer already has: colours pulled apart
/// (the chromatic blur), the picture jolted (a rough wiggle) and stepped
/// in time, torn by noise (the fractal warp), flashes of negative - in
/// bursts, the values jumping (border keys), not sliding.
const glitchPresets = <(String, String)>[
  ('rgb', 'RGB split'),
  ('shake', 'Shake'),
  ('noise', 'Noise tear'),
  ('flicker', 'Flicker'),
  ('bursts', 'Bursts'),
  ('heavy', 'Heavy'),
];

const _jump = Easing(0, 0, 1, 1, hold: true);

/// Short bursts over `duration` frames: `off` mostly, `on(r)` now and
/// then for a frame or few - each key a border (the value jumps).
List<Keyframe> _bursts(math.Random r, int duration, double off, double Function(math.Random) on,
    {int minGap = 6, int maxGap = 24, int maxLen = 4}) {
  final ks = <Keyframe>[Keyframe(frame: 0, value: off, temporal: _jump)];
  var f = minGap + r.nextInt(maxGap - minGap + 1);
  while (f < duration - 1) {
    ks.add(Keyframe(frame: f, value: on(r), temporal: _jump));
    // a burst may change within itself.
    final len = 1 + r.nextInt(maxLen);
    for (var i = 1; i < len && f + i < duration - 1; i++) {
      if (r.nextBool()) ks.add(Keyframe(frame: f + i, value: on(r), temporal: _jump));
    }
    final end = f + len;
    if (end >= duration) break;
    ks.add(Keyframe(frame: end, value: off, temporal: _jump));
    f = end + minGap + r.nextInt(maxGap - minGap + 1);
  }
  return ks;
}

void _keys(Track t, List<Keyframe> ks) {
  t.keyframes = ks;
}

/// Takes the glitch off: the parts a preset sets go back to plain.
void clearGlitch(Layer layer) {
  final f = layer.filters;
  if (f.blurKind == 'chromatic') {
    f.blur
      ..keyframes = []
      ..defaultValue = 0.0;
  }
  f.warp
    ..keyframes = []
    ..defaultValue = 0.0;
  f.negative
    ..keyframes = []
    ..defaultValue = 0.0;
  layer.wiggle.enabled = false;
  layer.timeQuantize.enabled = false;
}

/// Puts glitch preset `name` (see glitchPresets) on the layer, over its
/// whole length; another `seed` makes other bursts.
void applyGlitchPreset(Layer layer, String name, {int seed = 1}) {
  final r = math.Random(seed);
  final d = math.max(2, layer.durationFrames);
  final f = layer.filters;
  clearGlitch(layer);
  void rgb({required bool bursts, double strength = 1}) {
    f
      ..blurKind = 'chromatic'
      ..blurCentered = false
      ..blurAngle = r.nextBool() ? 0 : 180
      ..blurFocus = 'none';
    if (bursts) {
      _keys(f.blur, _bursts(r, d, 2 * strength, (r) => (6 + r.nextDouble() * 18) * strength));
    } else {
      f.blur.defaultValue = 8.0 * strength;
    }
  }

  void shake() {
    layer.wiggle
      ..enabled = true
      ..amplitude = 8
      ..speed = 60
      ..smoothness = 0
      ..wiggleSeed = seed.toDouble();
    layer.timeQuantize
      ..enabled = true
      ..fps = 12;
  }

  void noise({required bool bursts}) {
    f
      ..warpScale = 6
      ..warpSpeed = 5;
    if (bursts) {
      _keys(f.warp, _bursts(r, d, 0, (r) => 6 + r.nextDouble() * 16, minGap: 10, maxGap: 36, maxLen: 3));
    } else {
      f.warp.defaultValue = 8.0;
    }
  }

  void flicker({int minGap = 10, int maxGap = 40}) {
    _keys(f.negative, _bursts(r, d, 0, (_) => 1, minGap: minGap, maxGap: maxGap, maxLen: 2));
  }

  switch (name) {
    case 'rgb':
      rgb(bursts: false);
    case 'shake':
      shake();
    case 'noise':
      noise(bursts: false);
    case 'flicker':
      flicker();
    case 'bursts':
      rgb(bursts: true);
      noise(bursts: true);
    case 'heavy':
      rgb(bursts: true, strength: 1.4);
      noise(bursts: true);
      shake();
      flicker(minGap: 24, maxGap: 70);
  }
}
