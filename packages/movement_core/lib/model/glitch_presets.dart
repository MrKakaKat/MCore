import 'dart:math' as math;

import 'project.dart';

/// A glitch on a layer, made of what the layer already has - colours
/// pulled apart (the chromatic blur), the picture jolted (a rough wiggle)
/// and stepped in time, torn by noise (the fractal warp), flashes of
/// negative. All of it in bursts: calm, then for a frame or few the
/// values jump (border keys, no sliding) and calm again. Every number is
/// the user's to set; the presets are only starting points.
class GlitchSettings {
  // ---- when: the bursts ----
  /// Frames between bursts (each gap picked between the two).
  int gapMin, gapMax;

  /// A burst's length, frames (picked from 1 up to it).
  int burstMax;

  /// How strong a burst is (times every burst value) and how much bursts
  /// differ from each other (0: all alike, 1: from nothing to full).
  double intensity, variance;

  /// Other bursts (another draw of the dice).
  int seed;

  // ---- colours pulled apart ----
  bool rgb;
  double rgbCalm, rgbBurst, rgbAngle;

  /// Each burst pulls to the other side at random.
  bool rgbFlip;

  // ---- jolts ----
  bool shake;
  double shakeAmount, shakeSpeed, shakeSmooth;

  /// Time in steps of this many frames a second (0: smooth time).
  double stepFps;

  // ---- tears (noise) ----
  bool tear;
  double tearCalm, tearBurst, tearSize, tearSpeed;

  // ---- flashes of negative ----
  bool flicker;

  /// The share of bursts that flash (0..1).
  double flickerChance;

  /// What it acts on: 'self' (the layer), 'scene' (the whole frame) or
  /// 'glass' (what is under the layer).
  String scope;

  GlitchSettings({
    this.gapMin = 6,
    this.gapMax = 24,
    this.burstMax = 4,
    this.intensity = 1,
    this.variance = 0.7,
    this.seed = 1,
    this.rgb = true,
    this.rgbCalm = 0,
    this.rgbBurst = 14,
    this.rgbAngle = 0,
    this.rgbFlip = true,
    this.shake = false,
    this.shakeAmount = 8,
    this.shakeSpeed = 60,
    this.shakeSmooth = 0,
    this.stepFps = 0,
    this.tear = false,
    this.tearCalm = 0,
    this.tearBurst = 14,
    this.tearSize = 6,
    this.tearSpeed = 5,
    this.flicker = false,
    this.flickerChance = 0.3,
    this.scope = 'self',
  });

  GlitchSettings copy() => GlitchSettings.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'gapMin': gapMin,
        'gapMax': gapMax,
        'burstMax': burstMax,
        'intensity': intensity,
        'variance': variance,
        'seed': seed,
        'rgb': rgb,
        'rgbCalm': rgbCalm,
        'rgbBurst': rgbBurst,
        'rgbAngle': rgbAngle,
        'rgbFlip': rgbFlip,
        'shake': shake,
        'shakeAmount': shakeAmount,
        'shakeSpeed': shakeSpeed,
        'shakeSmooth': shakeSmooth,
        'stepFps': stepFps,
        'tear': tear,
        'tearCalm': tearCalm,
        'tearBurst': tearBurst,
        'tearSize': tearSize,
        'tearSpeed': tearSpeed,
        'flicker': flicker,
        'flickerChance': flickerChance,
        'scope': scope,
      };

  static GlitchSettings fromJson(Map<String, dynamic> j) {
    double d(String k, double v) => (j[k] as num?)?.toDouble() ?? v;
    int i(String k, int v) => (j[k] as num?)?.toInt() ?? v;
    bool b(String k, bool v) => j[k] as bool? ?? v;
    final g = GlitchSettings();
    return GlitchSettings(
      gapMin: i('gapMin', g.gapMin),
      gapMax: i('gapMax', g.gapMax),
      burstMax: i('burstMax', g.burstMax),
      intensity: d('intensity', g.intensity),
      variance: d('variance', g.variance),
      seed: i('seed', g.seed),
      rgb: b('rgb', g.rgb),
      rgbCalm: d('rgbCalm', g.rgbCalm),
      rgbBurst: d('rgbBurst', g.rgbBurst),
      rgbAngle: d('rgbAngle', g.rgbAngle),
      rgbFlip: b('rgbFlip', g.rgbFlip),
      shake: b('shake', g.shake),
      shakeAmount: d('shakeAmount', g.shakeAmount),
      shakeSpeed: d('shakeSpeed', g.shakeSpeed),
      shakeSmooth: d('shakeSmooth', g.shakeSmooth),
      stepFps: d('stepFps', g.stepFps),
      tear: b('tear', g.tear),
      tearCalm: d('tearCalm', g.tearCalm),
      tearBurst: d('tearBurst', g.tearBurst),
      tearSize: d('tearSize', g.tearSize),
      tearSpeed: d('tearSpeed', g.tearSpeed),
      flicker: b('flicker', g.flicker),
      flickerChance: d('flickerChance', g.flickerChance),
      scope: j['scope'] as String? ?? g.scope,
    );
  }
}

/// Starting points (id, name, settings).
final glitchPresets = <(String, String, GlitchSettings Function())>[
  ('subtle', 'Subtle', () => GlitchSettings(gapMin: 20, gapMax: 70, burstMax: 2, rgbBurst: 6, variance: 0.5)),
  ('rgb', 'RGB split', () => GlitchSettings(rgbCalm: 6, rgbBurst: 18, rgbFlip: false, gapMin: 10, gapMax: 40)),
  ('digital', 'Digital', () => GlitchSettings(tear: true, tearBurst: 16, rgbBurst: 16, burstMax: 3)),
  ('vhs', 'VHS', () => GlitchSettings(rgbCalm: 3, rgbBurst: 10, shake: true, shakeAmount: 4, shakeSmooth: 40, tear: true, tearCalm: 2, tearBurst: 8, tearSize: 20, tearSpeed: 1, gapMin: 12, gapMax: 50, burstMax: 8)),
  ('stutter', 'Stutter', () => GlitchSettings(rgb: false, shake: true, shakeAmount: 5, stepFps: 8, gapMin: 30, gapMax: 90)),
  ('strobe', 'Strobe', () => GlitchSettings(rgbBurst: 8, flicker: true, flickerChance: 0.8, gapMin: 3, gapMax: 10, burstMax: 1)),
  ('heavy', 'Heavy', () => GlitchSettings(rgbCalm: 3, rgbBurst: 24, shake: true, stepFps: 12, tear: true, tearBurst: 22, flicker: true, flickerChance: 0.25, intensity: 1.3, gapMin: 4, gapMax: 18, burstMax: 5)),
  ('scene', 'Whole frame', () => GlitchSettings(scope: 'scene', tear: true, tearBurst: 12, rgbBurst: 12, flicker: true, flickerChance: 0.15)),
];

/// The preset's settings by id (null: none such).
GlitchSettings? glitchPreset(String id) {
  for (final (k, _, make) in glitchPresets) {
    if (k == id) return make();
  }
  return null;
}

const _jump = Easing(0, 0, 1, 1, hold: true);

/// Takes the glitch off: what it set goes back to plain.
void clearGlitch(Layer layer) {
  final f = layer.filters;
  if (layer.glitch != null || f.blurKind == 'chromatic') {
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
  if (layer.glitch != null) f.scope = 'self';
  layer.glitch = null;
}

/// Puts the glitch `g` on the layer over its whole length (kept on the
/// layer, to be changed and put on again).
void applyGlitch(Layer layer, GlitchSettings g) {
  clearGlitch(layer);
  layer.glitch = g;
  final r = math.Random(g.seed);
  final d = math.max(2, layer.durationFrames);
  final f = layer.filters..scope = g.scope;
  final lo = math.max(1, math.min(g.gapMin, g.gapMax)), hi = math.max(lo, math.max(g.gapMin, g.gapMax));
  // the bursts: where, how long, how strong, flashing or not.
  final bursts = <({int at, int len, double k, bool flash, bool flip})>[];
  var t = lo + r.nextInt(hi - lo + 1);
  while (t < d - 1) {
    final len = 1 + r.nextInt(math.max(1, g.burstMax));
    final k = g.intensity * (1 - g.variance.clamp(0.0, 1.0) * r.nextDouble());
    bursts.add((at: t, len: len, k: k, flash: g.flicker && r.nextDouble() < g.flickerChance, flip: g.rgbFlip && r.nextBool()));
    t += len + lo + r.nextInt(hi - lo + 1);
  }
  List<Keyframe> keys(double calm, double Function(({int at, int len, double k, bool flash, bool flip}) b, int i) on,
      {bool Function(({int at, int len, double k, bool flash, bool flip}) b)? only}) {
    final ks = <Keyframe>[Keyframe(frame: 0, value: calm, temporal: _jump)];
    for (final b in bursts) {
      if (only != null && !only(b)) continue;
      // a burst may change within itself, a frame at a time.
      for (var i = 0; i < b.len && b.at + i < d - 1; i++) {
        ks.add(Keyframe(frame: b.at + i, value: on(b, i), temporal: _jump));
      }
      if (b.at + b.len < d) ks.add(Keyframe(frame: b.at + b.len, value: calm, temporal: _jump));
    }
    return ks;
  }

  if (g.rgb) {
    f
      ..blurKind = 'chromatic'
      ..blurCentered = false
      ..blurFocus = 'none'
      ..blurAngle = g.rgbAngle;
    // the side it pulls to: the angle turned half round for a flip (one
    // angle for the whole layer - a flip is a pull the other way, so the
    // amount goes negative).
    f.blur.keyframes = bursts.isEmpty
        ? []
        : keys(g.rgbCalm, (b, i) => (b.flip ? -1 : 1) * g.rgbBurst * b.k * (0.6 + 0.4 * r.nextDouble()));
    f.blur.defaultValue = g.rgbCalm;
  }
  if (g.shake) {
    layer.wiggle
      ..enabled = true
      ..amplitude = g.shakeAmount
      ..speed = g.shakeSpeed
      ..smoothness = g.shakeSmooth
      ..wiggleSeed = g.seed.toDouble();
  }
  if (g.stepFps > 0) {
    layer.timeQuantize
      ..enabled = true
      ..fps = g.stepFps;
  }
  if (g.tear) {
    f
      ..warpScale = g.tearSize
      ..warpSpeed = g.tearSpeed;
    f.warp.keyframes = bursts.isEmpty ? [] : keys(g.tearCalm, (b, i) => g.tearBurst * b.k * (0.5 + 0.5 * r.nextDouble()));
    f.warp.defaultValue = g.tearCalm;
  }
  if (g.flicker && bursts.any((b) => b.flash)) {
    f.negative.keyframes = keys(0, (b, i) => i == 0 ? 1.0 : (r.nextBool() ? 1.0 : 0.0), only: (b) => b.flash);
  }
}

/// Puts preset `id` on the layer; another `seed` makes other bursts.
void applyGlitchPreset(Layer layer, String id, {int seed = 1}) {
  final g = glitchPreset(id);
  if (g == null) return;
  applyGlitch(layer, g..seed = seed);
}
