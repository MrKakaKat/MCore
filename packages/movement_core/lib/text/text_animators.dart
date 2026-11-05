/// Text animators (After Effects style): a range selector picks which
/// units of a text (letters, words or lines) are affected and by how much
/// (an amount 0..1 each); the animator's properties (offset, rotation,
/// scale, opacity, colour, tracking, blur, scramble) apply to them in that
/// measure. Everything is a pure function of the frame.
///
/// - Units come from ONE layout of the whole text (kerning and wrapping
///   kept): a letter is a grapheme cluster (emoji, combining marks stay
///   whole), a word a run between spaces, a line a laid-out line.
/// - Each unit turns / scales about its own anchor (bottom centre by
///   default) and is placed through [placeUnit] - the one spot a path
///   (text on a line) or physics (letters as bodies) can take over later.
/// - Several animators add up, in list order.
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';

import '../core/interpolation.dart' show evaluateTrack;
import '../model/project.dart';
import '../model/project_json.dart' show trackToJson, trackFromJson;
import 'open_type_font.dart';
import 'text_layout.dart';

/// The range selector.
class TextRange {
  /// Percent of the units (0..100), keyable.
  Track start, end, offset;

  /// 'square' | 'rampUp' | 'rampDown' | 'triangle' | 'round' | 'smooth'.
  String shape;

  /// Ease, 0..100 %: high flattens the amount near 1, low near 0.
  double easeHigh, easeLow;

  /// 'forward' | 'reverse' | 'random' | 'fromCenter' | 'fromEdges'.
  String order;
  int seed;

  /// The range wraps around past 100 % (loops, waves).
  bool wrap;

  /// Whole units: each is either in the range or not (by its middle) - a
  /// letter appears at once instead of fading in.
  bool whole;
  TextRange({
    Track? start,
    Track? end,
    Track? offset,
    this.shape = 'square',
    this.easeHigh = 0,
    this.easeLow = 0,
    this.order = 'forward',
    this.seed = 1,
    this.wrap = false,
    this.whole = false,
  })  : start = start ?? Track(0.0, false),
        end = end ?? Track(100.0, false),
        offset = offset ?? Track(0.0, false);

  TextRange copy() => TextRange(
      start: cloneTrack(start),
      end: cloneTrack(end),
      offset: cloneTrack(offset),
      shape: shape,
      easeHigh: easeHigh,
      easeLow: easeLow,
      order: order,
      seed: seed,
      wrap: wrap,
      whole: whole);
}

/// The properties an animator can set (null: not set).
/// liveScale: each unit stretches wider at random, only ever up (this
/// much at most - a living, breathing text); jitter: each unit shakes at
/// random by this many px, all at the same pace (charged, trembling
/// text); roll: each unit rocks round by this many degrees either way,
/// all with the same swing, each at its own random moment (a tumbling,
/// rolling text). They move at `liveSpeed` (changes per second) - or,
/// `liveStatic`, stay still where they are at `liveStaticAt` (seconds):
/// a frozen pose picked anywhere.
const textAnimatorProps = [
  'position', 'rotation', 'scale', 'opacity', 'fillColor', 'tracking', 'blur', 'scramble', 'liveScale', 'jitter', 'roll'
];

class TextAnimator {
  String name;

  /// 'char' | 'word' | 'line'.
  String unit;

  /// Letters: spaces count as units too.
  bool includeSpaces;
  TextRange range;

  /// Set properties: position [dx, dy] px, rotation (degrees), scale
  /// [sx, sy] (1 = as is), opacity (0..1), tracking (px between units),
  /// blur (px) - Tracks; fillColor ('#rrggbb'); scramble (units in the
  /// range show random letters, changing every `scrambleEvery` frames).
  Map<String, Track> props;
  String? fillColor;
  bool scramble;
  int scrambleEvery;
  String scrambleChars;

  /// Anchor of each unit: 'bottom' (centre of its base) | 'center' |
  /// 'baseline' (its left end on the baseline).
  String anchor;
  bool enabled;

  /// liveScale / jitter: how fast they change (per second).
  double liveSpeed;

  /// liveScale: stretch taller instead of wider.
  bool liveVertical;

  /// The live properties (liveScale, jitter, roll) held still at
  /// `liveStaticAt` seconds instead of moving.
  bool liveStatic;
  double liveStaticAt;

  TextAnimator({
    this.liveVertical = false,
    this.liveStatic = false,
    this.liveStaticAt = 0,
    this.name = 'Animator',
    this.unit = 'char',
    this.includeSpaces = false,
    TextRange? range,
    Map<String, Track>? props,
    this.fillColor,
    this.scramble = false,
    this.scrambleEvery = 2,
    this.scrambleChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
    this.anchor = 'bottom',
    this.enabled = true,
    this.liveSpeed = 3,
  })  : range = range ?? TextRange(),
        props = props ?? {};

  TextAnimator copy() => TextAnimator(
      name: name,
      unit: unit,
      includeSpaces: includeSpaces,
      range: range.copy(),
      props: {for (final e in props.entries) e.key: cloneTrack(e.value)},
      fillColor: fillColor,
      scramble: scramble,
      scrambleEvery: scrambleEvery,
      scrambleChars: scrambleChars,
      anchor: anchor,
      enabled: enabled,
      liveSpeed: liveSpeed,
      liveVertical: liveVertical,
      liveStatic: liveStatic,
      liveStaticAt: liveStaticAt);

  /// Its keyable tracks, named (the timeline shows them in the Text row).
  Map<String, Track> get tracks => {
        'start': range.start,
        'end': range.end,
        'offset': range.offset,
        ...props,
      };

  /// A property's default when added.
  static Track defaultProp(String name) => switch (name) {
        'position' => Track([0.0, 0.0], false),
        'scale' => Track([1.0, 1.0], false),
        'opacity' => Track(1.0, false),
        'liveScale' => Track(0.3, false),
        'jitter' => Track(3.0, false),
        'roll' => Track(20.0, false),
        _ => Track(0.0, false),
      };

  Map<String, dynamic> toJson() => {
        'name': name,
        'unit': unit,
        if (includeSpaces) 'includeSpaces': true,
        'range': {
          'start': trackToJson(range.start),
          'end': trackToJson(range.end),
          'offset': trackToJson(range.offset),
          'shape': range.shape,
          'easeHigh': range.easeHigh,
          'easeLow': range.easeLow,
          'order': range.order,
          'seed': range.seed,
          if (range.wrap) 'wrap': true,
          if (range.whole) 'whole': true,
        },
        'props': {for (final e in props.entries) e.key: trackToJson(e.value)},
        if (fillColor != null) 'fillColor': fillColor,
        if (scramble) 'scramble': {'every': scrambleEvery, 'chars': scrambleChars},
        if (anchor != 'bottom') 'anchor': anchor,
        if (!enabled) 'enabled': false,
        if (liveSpeed != 3) 'liveSpeed': liveSpeed,
        if (liveVertical) 'liveVertical': true,
        if (liveStatic) 'liveStatic': true,
        if (liveStaticAt != 0) 'liveStaticAt': liveStaticAt,
      };

  static TextAnimator fromJson(Map<String, dynamic> j) {
    final r = j['range'] as Map<String, dynamic>? ?? const {};
    Track t(Object? v, double d) => v is Map ? trackFromJson(v as Map<String, dynamic>) : Track(d, false);
    final sc = j['scramble'] as Map<String, dynamic>?;
    return TextAnimator(
      name: j['name'] as String? ?? 'Animator',
      unit: j['unit'] as String? ?? 'char',
      includeSpaces: j['includeSpaces'] as bool? ?? false,
      range: TextRange(
        start: t(r['start'], 0),
        end: t(r['end'], 100),
        offset: t(r['offset'], 0),
        shape: r['shape'] as String? ?? 'square',
        easeHigh: (r['easeHigh'] as num?)?.toDouble() ?? 0,
        easeLow: (r['easeLow'] as num?)?.toDouble() ?? 0,
        order: r['order'] as String? ?? 'forward',
        seed: (r['seed'] as num?)?.toInt() ?? 1,
        wrap: r['wrap'] as bool? ?? false,
        whole: r['whole'] as bool? ?? false,
      ),
      props: {
        for (final e in ((j['props'] as Map?) ?? const {}).entries)
          e.key as String: trackFromJson(e.value as Map<String, dynamic>)
      },
      fillColor: j['fillColor'] as String?,
      scramble: sc != null,
      scrambleEvery: (sc?['every'] as num?)?.toInt() ?? 2,
      scrambleChars: sc?['chars'] as String? ?? 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
      anchor: j['anchor'] as String? ?? 'bottom',
      enabled: j['enabled'] as bool? ?? true,
      liveSpeed: (j['liveSpeed'] as num?)?.toDouble() ?? 3,
      liveVertical: j['liveVertical'] as bool? ?? false,
      liveStatic: j['liveStatic'] as bool? ?? false,
      liveStaticAt: (j['liveStaticAt'] as num?)?.toDouble() ?? 0,
    );
  }
}

// ===== units =====

/// A unit of the text: its letters (indices into layout.glyphs).
class TextUnit {
  final List<int> glyphs;
  final int line;
  const TextUnit(this.glyphs, this.line);
}

/// Grapheme clusters of `text` as code point index ranges [start, end).
List<(int, int)> graphemeRanges(String text) {
  final out = <(int, int)>[];
  var at = 0;
  for (final g in text.characters) {
    final n = g.runes.length;
    out.add((at, at + n));
    at += n;
  }
  return out;
}

bool _isSpace(int rune) => rune == 0x20 || rune == 0x09 || rune == 0x0a || rune == 0xa0;

/// The units of a laid-out text for `unit` ('char' | 'word' | 'line').
List<TextUnit> textUnits(String text, TextLayout layout, String unit, {bool includeSpaces = false}) {
  final byIndex = <int, int>{for (var i = 0; i < layout.glyphs.length; i++) layout.glyphs[i].index: i};
  final runes = text.runes.toList();
  final out = <TextUnit>[];
  switch (unit) {
    case 'line':
      final lines = <int, List<int>>{};
      for (var i = 0; i < layout.glyphs.length; i++) {
        if (!includeSpaces && _isSpace(layout.glyphs[i].rune)) continue;
        (lines[layout.glyphs[i].line] ??= []).add(i);
      }
      for (final l in (lines.keys.toList()..sort())) {
        out.add(TextUnit(lines[l]!, l));
      }
    case 'word':
      var cur = <int>[];
      var line = 0;
      for (var r = 0; r <= runes.length; r++) {
        final space = r == runes.length || _isSpace(runes[r]);
        final gi = r < runes.length ? byIndex[r] : null;
        // a word also ends where its line wraps.
        if (gi != null && cur.isNotEmpty && layout.glyphs[gi].line != line) {
          out.add(TextUnit(cur, line));
          cur = [];
        }
        if (space) {
          if (cur.isNotEmpty) out.add(TextUnit(cur, line));
          cur = [];
          continue;
        }
        if (gi != null) {
          if (cur.isEmpty) line = layout.glyphs[gi].line;
          cur.add(gi);
        }
      }
    default:
      for (final (a, b) in graphemeRanges(text)) {
        if (!includeSpaces && b - a == 1 && _isSpace(runes[a])) continue;
        final gs = [for (var r = a; r < b; r++) if (byIndex[r] != null) byIndex[r]!];
        if (gs.isEmpty) continue;
        out.add(TextUnit(gs, layout.glyphs[gs.first].line));
      }
  }
  return out;
}

// ===== the range selector =====

/// Unit `i` of `n` remapped by the order (seeded for random).
List<int> unitOrder(int n, String order, int seed) {
  final idx = List<int>.generate(n, (i) => i);
  switch (order) {
    case 'reverse':
      return [for (var i = 0; i < n; i++) n - 1 - i];
    case 'random':
      final perm = [...idx];
      final rnd = math.Random(seed);
      for (var i = n - 1; i > 0; i--) {
        final j = rnd.nextInt(i + 1);
        final t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
      }
      return perm;
    case 'fromCenter':
    case 'fromEdges':
      // rank by distance from the middle (outer first for fromEdges).
      final c = (n - 1) / 2;
      final ranked = [...idx]..sort((a, b) {
          final da = (a - c).abs(), db = (b - c).abs();
          final cmp = order == 'fromCenter' ? da.compareTo(db) : db.compareTo(da);
          return cmp != 0 ? cmp : a.compareTo(b);
        });
      final out = List<int>.filled(n, 0);
      for (var r = 0; r < n; r++) {
        out[ranked[r]] = r;
      }
      return out;
    default:
      return idx;
  }
}

double _ease(double a, double high, double low) {
  a = a.clamp(0.0, 1.0);
  if (low > 0) a = math.pow(a, 1 + 2 * low / 100).toDouble();
  if (high > 0) a = 1 - math.pow(1 - a, 1 + 2 * high / 100).toDouble();
  return a;
}

/// The amount (0..1) of a unit covering [u0, u1] (percent of all units)
/// for a range [s, e] (percent) of `shape`.
double rangeAmount(double u0, double u1, double s, double e, String shape) {
  if (e < s) {
    final t = s;
    s = e;
    e = t;
  }
  final mid = (u0 + u1) / 2;
  if (shape == 'square') {
    // the share of the unit inside the range.
    final w = u1 - u0;
    if (w <= 0) return mid >= s && mid < e ? 1 : 0;
    return ((math.min(u1, e) - math.max(u0, s)) / w).clamp(0.0, 1.0);
  }
  final span = e - s;
  if (span <= 0) {
    return switch (shape) { 'rampUp' => mid >= e ? 1 : 0, 'rampDown' => mid < s ? 1 : 0, _ => 0 };
  }
  final u = (mid - s) / span;
  switch (shape) {
    case 'rampUp':
      return u.clamp(0.0, 1.0);
    case 'rampDown':
      return (1 - u).clamp(0.0, 1.0);
  }
  if (u < 0 || u > 1) return 0;
  return switch (shape) {
    'triangle' => 1 - (2 * u - 1).abs(),
    'round' => math.sqrt(math.max(0, 1 - math.pow(2 * u - 1, 2))),
    'smooth' => 0.5 - 0.5 * math.cos(2 * math.pi * u),
    _ => 1,
  };
}

/// Each unit's amount at local frame `f` (in unit order).
List<double> selectorAmounts(TextRange r, int n, num f) {
  if (n == 0) return const [];
  double v(Track t) => (evaluateTrack(null, t, f.toDouble()) as num).toDouble();
  final o = v(r.offset);
  final s = v(r.start) + o, e = v(r.end) + o;
  final order = unitOrder(n, r.order, r.seed);
  return [
    for (var i = 0; i < n; i++)
      () {
        final k = order[i];
        final u0 = k / n * 100, u1 = (k + 1) / n * 100;
        // whole units: judged by their middle only.
        final m = (u0 + u1) / 2;
        final (a0, a1) = r.whole ? (m, m) : (u0, u1);
        var a = rangeAmount(a0, a1, s, e, r.shape);
        if (r.wrap) {
          a = math.max(a, math.max(rangeAmount(a0 + 100, a1 + 100, s, e, r.shape), rangeAmount(a0 - 100, a1 - 100, s, e, r.shape)));
        }
        if (r.whole) a = a >= 0.5 ? 1.0 : 0.0;
        return _ease(a, r.easeHigh, r.easeLow);
      }()
  ];
}

// ===== the animated result =====

/// A unit as drawn: its letters' outlines (transformed), opacity, colour
/// (null: its own) and blur.
class UnitState {
  final List<PathCmd> cmds;
  final double opacity;

  /// Per letter colour blend: the target and how far (0..1).
  final String? tint;
  final double tintAmount;
  final double blur;

  /// Letter-style colour of the unit's first letter (null: the text's).
  final String? baseColor;

  /// The unit's box, content-local (for the selector overlay).
  final List<List<double>> box;

  /// The animator's amount for this unit (the selected animator's).
  final double amount;

  /// The unit's middle where it is drawn (box middle + its animated
  /// offset), content-local - what a lagging shadow trails.
  final List<double> centre;
  const UnitState(this.cmds, this.opacity, this.tint, this.tintAmount, this.blur, this.baseColor, this.box, this.amount,
      [this.centre = const [0, 0]]);
}

/// One function places a unit: offset, rotation (degrees) and scale about
/// its anchor `a`. Text on a path, or letters as bodies, take over here.
PathCmd placeUnit(PathCmd c, List<double> a, double dx, double dy, double rot, double sx, double sy) {
  final r = rot * math.pi / 180;
  final cs = math.cos(r), sn = math.sin(r);
  // p' = a + R * S * (p - a) + d  ->  as an affine on the command.
  final m00 = cs * sx, m01 = -sn * sy, m10 = sn * sx, m11 = cs * sy;
  final tx = a[0] + dx - (m00 * a[0] + m01 * a[1]), ty = a[1] + dy - (m10 * a[0] + m11 * a[1]);
  return c.transformed(m00, m10, m01, m11, tx, ty);
}

/// The units of `spec` (shown text at local frame `f`) after its
/// animators, for a box at `offset` / `size`. `selected`: whose amounts
/// go in UnitState.amount (overlay). Null: no enabled animators.
List<UnitState>? animatedTextUnits(TextSpec spec, List<double> offset, List<double> size, num f, {int? selected}) {
  final anims = [for (final a in spec.animators) if (a.enabled) a];
  final moving = [for (final sp in spec.spans) if (sp.moves && sp.activeAt(f)) sp];
  if (anims.isEmpty && selected == null && moving.isEmpty) return null;
  final layout = layoutText(spec, offset, size);
  final glyphs = layout.glyphs;
  final text = spec.text;
  // per letter: offsets, rotation, scale, opacity, tint, tracking shift.
  final n = glyphs.length;
  final dx = List<double>.filled(n, 0), dy = List<double>.filled(n, 0), rot = List<double>.filled(n, 0);
  final sx = List<double>.filled(n, 1), sy = List<double>.filled(n, 1), op = List<double>.filled(n, 1);
  final blur = List<double>.filled(n, 0), track = List<double>.filled(n, 0), tintA = List<double>.filled(n, 0);
  final tint = List<String?>.filled(n, null);
  final scrambled = List<int?>.filled(n, null);
  final amountOf = List<double>.filled(n, 0);
  // the units the overlay / grouping uses: the selected animator's (or
  // the first one's), else letters.
  final groupBy = selected != null && selected < spec.animators.length ? spec.animators[selected] : (anims.isEmpty ? null : anims.first);
  final groups = textUnits(text, layout, groupBy?.unit ?? 'char', includeSpaces: groupBy?.includeSpaces ?? false);
  for (var ai = 0; ai < spec.animators.length; ai++) {
    final an = spec.animators[ai];
    if (!an.enabled && ai != selected) continue;
    final units = textUnits(text, layout, an.unit, includeSpaces: an.includeSpaces);
    final amounts = selectorAmounts(an.range, units.length, f);
    double num1(String k) => (evaluateTrack(null, an.props[k]!, f.toDouble()) as num).toDouble();
    List<double> vec(String k) => [for (final v in evaluateTrack(null, an.props[k]!, f.toDouble()) as List) (v as num).toDouble()];
    for (var u = 0; u < units.length; u++) {
      final a = amounts[u];
      for (final g in units[u].glyphs) {
        if (ai == selected) amountOf[g] = a;
        if (!an.enabled || a <= 0) continue;
        if (an.props.containsKey('position')) {
          final p = vec('position');
          dx[g] += p[0] * a;
          dy[g] += p[1] * a;
        }
        if (an.props.containsKey('rotation')) rot[g] += num1('rotation') * a;
        if (an.props.containsKey('scale')) {
          final s = vec('scale');
          sx[g] *= 1 + (s[0] - 1) * a;
          sy[g] *= 1 + (s[1] - 1) * a;
        }
        if (an.props.containsKey('opacity')) op[g] *= 1 + (num1('opacity') - 1) * a;
        if (an.props.containsKey('blur')) blur[g] += num1('blur') * a;
        if (an.props.containsKey('tracking')) track[g] += num1('tracking') * a;
        if (an.fillColor != null) {
          tint[g] = an.fillColor;
          tintA[g] = math.max(tintA[g], a);
        }
        if (an.scramble && a > 0) {
          final step = (f / math.max(1, an.scrambleEvery)).floor();
          final chars = an.scrambleChars.runes.toList();
          if (chars.isNotEmpty) {
            final rnd = math.Random(an.range.seed * 7919 + g * 104729 + step * 15485863);
            var ch = String.fromCharCode(chars[rnd.nextInt(chars.length)]);
            // small letters scramble into small ones, capitals into capitals.
            final own = String.fromCharCode(glyphs[g].rune);
            if (own != own.toUpperCase()) {
              ch = ch.toLowerCase();
            } else if (own != own.toLowerCase()) {
              ch = ch.toUpperCase();
            }
            scrambled[g] = ch.runes.first;
          }
        }
        // living text: smooth random per unit, at one pace for all.
        final t = an.liveStatic ? an.liveStaticAt * an.liveSpeed : f / (fps <= 0 ? 60 : fps) * an.liveSpeed;
        if (an.props.containsKey('liveScale')) {
          final k = 1 + num1('liveScale') * a * (0.5 + 0.5 * _noise(u * 2 + 1, t, an.range.seed));
          an.liveVertical ? sy[g] *= k : sx[g] *= k;
        }
        if (an.props.containsKey('roll')) {
          // the same swing for all, each at its own random moment.
          final phase = math.Random(an.range.seed * 6151 + u * 9973).nextDouble();
          rot[g] += num1('roll') * a * math.sin(2 * math.pi * (t * 0.5 + phase));
        }
        if (an.props.containsKey('jitter')) {
          final j = num1('jitter') * a;
          dx[g] += j * _noise(u * 2 + 1, t, an.range.seed + 17);
          dy[g] += j * _noise(u * 2 + 1, t, an.range.seed + 31);
        }
      }
    }
  }
  // text parts: their own motion, on top of the animators.
  for (final sp in moving) {
    double one(Track? t, double d) => t == null ? d : (evaluateTrack(null, t, f.toDouble()) as num).toDouble();
    List<double> two(Track? t) =>
        t == null ? const [0.0, 0.0] : [for (final v in evaluateTrack(null, t, f.toDouble()) as List) (v as num).toDouble()];
    final mv = two(sp.move), tr = one(sp.turn, 0), op1 = one(sp.opacity, 1);
    final sc = sp.scale == null ? const [1.0, 1.0] : two(sp.scale);
    // the part turns and scales as one, about its middle.
    final mine = [for (var g = 0; g < n; g++) if (sp.covers(glyphs[g].index)) g];
    if (mine.isEmpty) continue;
    List<double> mid(int g) => [glyphs[g].x + glyphs[g].advance / 2, glyphs[g].baseline - glyphs[g].ascent / 2];
    var px = 0.0, py = 0.0;
    for (final g in mine) {
      px += mid(g)[0];
      py += mid(g)[1];
    }
    px /= mine.length;
    py /= mine.length;
    final a = tr * math.pi / 180, ca = math.cos(a), sa = math.sin(a);
    for (final g in mine) {
      final c = mid(g);
      final vx = (c[0] - px) * sc[0], vy = (c[1] - py) * sc[1];
      dx[g] += px + vx * ca - vy * sa - c[0] + mv[0];
      dy[g] += py + vx * sa + vy * ca - c[1] + mv[1];
      rot[g] += tr;
      sx[g] *= sc[0];
      sy[g] *= sc[1];
      op[g] *= op1.clamp(0.0, 1.0);
    }
    // its own effects.
    final bl = one(sp.blur, 0), spc = one(sp.spacing, 0), sh = one(sp.shake, 0), wb = one(sp.wobble, 0);
    final ti = one(sp.tint, 0).clamp(0.0, 1.0);
    final t = f / (fps <= 0 ? 60 : fps);
    final seed = spec.spans.indexOf(sp) * 7 + 3;
    for (final g in mine) {
      blur[g] += math.max(0.0, bl);
      track[g] += spc;
      if (sh != 0) {
        dx[g] += sh * _noise(g * 2 + 1, t, seed + 17);
        dy[g] += sh * _noise(g * 2 + 1, t, seed + 31);
      }
      if (wb != 0) {
        final phase = math.Random(seed * 6151 + g * 9973).nextDouble();
        rot[g] += wb * math.sin(2 * math.pi * (t * 0.5 + phase));
      }
      if (ti > 0) {
        tint[g] = sp.tintColor ?? '#ffffff';
        tintA[g] = math.max(tintA[g], ti);
      }
    }
  }
  // tracking pushes the letters after it along their line.
  final shift = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    shift[i] = glyphs[i].line == glyphs[i - 1].line ? shift[i - 1] + track[i - 1] : 0;
  }
  final out = <UnitState>[];
  final ranks = <int>[];
  for (final unit in groups) {
    final cmds = <PathCmd>[];
    var o = 0.0, bl = 0.0, ta = 0.0, am = 0.0;
    String? t;
    var x0 = double.infinity, x1 = -double.infinity, y0 = double.infinity, y1 = -double.infinity;
    for (final gi in unit.glyphs) {
      final g = glyphs[gi];
      x0 = math.min(x0, g.x + shift[gi]);
      x1 = math.max(x1, g.x + g.advance + shift[gi]);
      y0 = math.min(y0, g.baseline - g.ascent);
      y1 = math.max(y1, g.baseline + g.descent);
    }
    for (final gi in unit.glyphs) {
      final g = glyphs[gi];
      final anchor = switch (groupBy?.anchor) {
        'center' => [(x0 + x1) / 2, (y0 + y1) / 2],
        'baseline' => [x0, g.baseline],
        _ => [(x0 + x1) / 2, g.baseline],
      };
      final src = scrambled[gi] == null
          ? layout.path.sublist(g.cmdStart, g.cmdEnd)
          : _glyphCmds(g, scrambled[gi]!);
      for (final c in src) {
        cmds.add(placeUnit(c, anchor, dx[gi] + shift[gi], dy[gi], rot[gi], sx[gi], sy[gi]));
      }
      o = math.max(o, op[gi]);
      bl = math.max(bl, blur[gi]);
      if (tint[gi] != null) {
        t = tint[gi];
        ta = math.max(ta, tintA[gi]);
      }
      am = math.max(am, amountOf[gi]);
    }
    var mx = 0.0, my = 0.0;
    for (final gi in unit.glyphs) {
      mx += dx[gi];
      my += dy[gi];
    }
    final gn = unit.glyphs.isEmpty ? 1 : unit.glyphs.length;
    out.add(UnitState(
        cmds,
        o.clamp(0.0, 1.0),
        t,
        ta,
        bl,
        glyphs[unit.glyphs.first].color,
        [
          [x0, y0],
          [x1, y0],
          [x1, y1],
          [x0, y1],
        ],
        am,
        [(x0 + x1) / 2 + mx / gn, (y0 + y1) / 2 + my / gn]));
    ranks.add(unit.glyphs.isEmpty ? 0 : _partRank(spec, glyphs[unit.glyphs.first].index));
  }
  // parts draw in their order: a later part over an earlier one (and all
  // over the letters in no part) where they meet.
  if (spec.spans.isNotEmpty && ranks.any((r) => r > 0)) {
    final order = [for (var i = 0; i < out.length; i++) i]..sort((a, b) {
        final c = ranks[a].compareTo(ranks[b]);
        return c != 0 ? c : a.compareTo(b);
      });
    return [for (final i in order) out[i]];
  }
  return out;
}

/// 1 + the index of the last part covering letter `index` (0: none).
int _partRank(TextSpec spec, int index) {
  var r = 0;
  for (var i = 0; i < spec.spans.length; i++) {
    if (spec.spans[i].covers(index)) r = i + 1;
  }
  return r;
}

/// Smooth noise in -1..1 for unit `k` at time `t` (seeded): a few sines
/// with random phases - the same pace for every unit.
double _noise(int k, double t, int seed) {
  final r = math.Random(seed * 1000003 + k * 7919);
  var v = 0.0;
  for (final w in const [1.0, 1.7, 2.9]) {
    v += math.sin(2 * math.pi * (t * w + r.nextDouble()));
  }
  return v / 3;
}

// another letter drawn where `g` is (scramble).
List<PathCmd> _glyphCmds(GlyphBox g, int rune) {
  final font = g.font;
  final gid = font.glyphIndex(rune);
  final s = g.fontSize / font.unitsPerEm;
  return [for (final c in font.glyphPath(gid)) c.transformed(s, 0, 0, -s, g.x, g.baseline)];
}

/// The animated text's outline commands (for Contour / Outline / Collide):
/// the units that show, after their animators. Null: no animators.
List<PathCmd>? animatedTextPath(TextSpec spec, List<double> offset, List<double> size, num f) {
  final units = animatedTextUnits(spec, offset, size, f);
  if (units == null) return null;
  return [for (final u in units) if (u.opacity > 0.01) ...u.cmds];
}

// ===== presets =====

const textAnimatorPresets = [
  'Typewriter', 'Fade in by letter', 'Wave', 'Drop in', 'Scale pop', 'Line by line', 'Scramble', 'Breathe', 'Jitter', 'Roll'
];

// keyed from -> to; without its keys (deleted) the track rests on the
// end state, so the text is left as the animation finishes it.
Track _keys(double from, double to, int f0, int f1, {Easing? ease, double? rest}) => Track(rest ?? to, false)
  ..keyframes = [
    Keyframe(frame: f0, value: from, temporal: ease ?? const Easing(0, 0, 1, 1)),
    Keyframe(frame: f1, value: to, temporal: ease ?? const Easing(0, 0, 1, 1)),
  ];

/// A preset as an animator, its keys from local frame `f0` over `frames`.
TextAnimator textAnimatorPreset(String name, {int f0 = 0, int frames = 60}) {
  final int f1 = f0 + math.max(1, frames);
  switch (name) {
    case 'Typewriter':
      // the units before the range's start show; the start sweeps on.
      return TextAnimator(
          name: name,
          unit: 'char',
          range: TextRange(start: _keys(0, 100, f0, f1), whole: true),
          props: {'opacity': Track(0.0, false)});
    case 'Fade in by letter':
      return TextAnimator(
          name: name,
          unit: 'char',
          range: TextRange(start: Track(0.0, false), end: Track(20.0, false), offset: _keys(-20, 100, f0, f1), shape: 'rampUp'),
          props: {'opacity': Track(0.0, false), 'position': Track([0.0, 12.0], false)});
    case 'Wave':
      return TextAnimator(
          name: name,
          unit: 'char',
          range: TextRange(
              start: Track(0.0, false),
              end: Track(30.0, false),
              // without its keys the wave parks off the text (no letter left up).
              offset: _keys(0, 100, f0, f0 + 30, rest: 300)..loop = true,
              shape: 'triangle',
              wrap: true),
          props: {'position': Track([0.0, -20.0], false)});
    case 'Drop in':
      return TextAnimator(
          name: name,
          unit: 'char',
          range: TextRange(
              start: Track(0.0, false), end: Track(25.0, false), offset: _keys(-25, 100, f0, f1), shape: 'rampUp', easeHigh: 60),
          props: {'position': Track([0.0, -200.0], false), 'opacity': Track(0.0, false)});
    case 'Scale pop':
      return TextAnimator(
          name: name,
          unit: 'word',
          range: TextRange(
              start: Track(0.0, false), end: Track(40.0, false), offset: _keys(-40, 100, f0, f1), shape: 'rampUp', easeLow: 50),
          props: {'scale': Track([0.0, 0.0], false)});
    case 'Line by line':
      return TextAnimator(
          name: name,
          unit: 'line',
          range: TextRange(start: _keys(0, 100, f0, f1)),
          props: {'position': Track([0.0, 30.0], false), 'opacity': Track(0.0, false)});
    case 'Breathe':
      return TextAnimator(name: name, unit: 'char', props: {'liveScale': Track(0.3, false)}, liveSpeed: 1.5);
    case 'Jitter':
      return TextAnimator(name: name, unit: 'char', props: {'jitter': Track(3.0, false)}, liveSpeed: 8);
    case 'Roll':
      return TextAnimator(name: name, unit: 'char', anchor: 'center', props: {'roll': Track(20.0, false)}, liveSpeed: 2);
    case 'Scramble':
      return TextAnimator(name: name, unit: 'char', range: TextRange(start: _keys(0, 100, f0, f1)), scramble: true);
  }
  return TextAnimator(name: 'Animator');
}

/// The outline commands of text part `part` (spec.spans[part]) at local
/// frame `f`, with its motion and the animators - for using one part as a
/// mask source or showing it on the stage.
List<PathCmd> textPartCmds(TextSpec spec, List<double> offset, List<double> size, num f, int part) {
  if (part < 0 || part >= spec.spans.length) return const [];
  final sp = spec.spans[part];
  final layout = layoutText(spec, offset, size);
  final units = animatedTextUnits(spec, offset, size, f);
  if (units == null) {
    return [
      for (final g in layout.glyphs)
        if (sp.covers(g.index)) ...layout.path.sublist(g.cmdStart, g.cmdEnd)
    ];
  }
  // units come in their drawing order: pick them by their letters' boxes.
  final out = <PathCmd>[];
  final glyphs = layout.glyphs;
  final mine = {for (final g in glyphs) if (sp.covers(g.index)) g.index};
  if (mine.isEmpty) return const [];
  final groups = textUnits(spec.text, layout, 'char');
  final unitOf = <int, int>{};
  for (final u in groups) {
    for (final gi in u.glyphs) {
      unitOf[glyphs[gi].index] = gi;
    }
  }
  // the units are per letter when only parts move; with animators by
  // word / line, a unit is in the part when its first letter is.
  for (final u in units) {
    for (final idx in mine) {
      final gi = unitOf[idx];
      if (gi == null) continue;
      final g = glyphs[gi];
      final bx0 = u.box[0][0], bx1 = u.box[1][0];
      if (g.x + g.advance / 2 >= bx0 - 0.5 && g.x + g.advance / 2 <= bx1 + 0.5) {
        out.addAll(u.cmds);
        break;
      }
    }
  }
  return out;
}
