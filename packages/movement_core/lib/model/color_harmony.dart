/// Colour harmonies (Palettes tab): from one colour, the colours that go
/// with it - turned round the colour wheel (HSL hue), or its own shades.
library;

import 'dart:math' as math;

/// The kinds, with their names.
const colorHarmonies = <String, String>{
  'complementary': 'Complementary',
  'analogous': 'Analogous',
  'triadic': 'Triadic',
  'split': 'Split complementary',
  'tetradic': 'Tetradic (square)',
  'monochrome': 'Shades of it',
};

/// `hex` ("#rrggbb") and the colours of harmony `kind` that go with it.
List<String> harmonyColors(String hex, String kind) {
  final (h, s, l) = _hsl(hex);
  String at(double dh, [double? ll, double? ss]) => _hex((h + dh) % 360, ss ?? s, ll ?? l);
  return switch (kind) {
    'complementary' => [at(0), at(180)],
    'analogous' => [at(-30), at(0), at(30)],
    'triadic' => [at(0), at(120), at(240)],
    'split' => [at(0), at(150), at(210)],
    'tetradic' => [at(0), at(90), at(180), at(270)],
    'monochrome' => [for (final ll in [0.15, 0.3, 0.45, 0.6, 0.75, 0.9]) at(0, ll)],
    _ => [at(0)],
  };
}

(double, double, double) _hsl(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', '').padRight(6, '0').substring(0, 6), radix: 16) ?? 0;
  final r = ((v >> 16) & 0xFF) / 255, g = ((v >> 8) & 0xFF) / 255, b = (v & 0xFF) / 255;
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final l = (mx + mn) / 2;
  if (mx == mn) return (0, 0, l);
  final d = mx - mn;
  final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
  double h;
  if (mx == r) {
    h = (g - b) / d + (g < b ? 6 : 0);
  } else if (mx == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  return (h * 60, s, l);
}

String _hex(double h, double s, double l) {
  final c = (1 - (2 * l - 1).abs()) * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = l - c / 2;
  final (r, g, b) = switch ((h / 60).floor() % 6) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  String two(double v) => ((v + m) * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(r)}${two(g)}${two(b)}';
}
