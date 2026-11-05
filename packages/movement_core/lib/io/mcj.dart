/// MCJ: a compact, documented project format a chatbot can write (and
/// read): `{ "mcore": 1, "canvas": {...}, "layers": [...] }`. The app
/// expands it into a full project, reporting everything it dropped or
/// clamped; and compacts a project into it for "edit with AI".
///
/// No code: there is no expression field, and none is ever run. Media
/// can't be written by a model - they're placeholders.
///
/// The effect / parameter table below (mcjEffects) is the one the
/// validator, the prompt and the agent guide are all built from.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/stage_size.dart';
import '../effects/geometry_effect_registry.dart';
import '../geometry/shapes.dart' show isAudioShape, isCameraShape, isMediaShape;
import '../model/line_path.dart';
import '../model/project.dart';
import '../text/text_animators.dart';
import '../text/text_layout.dart' show createTextLayer;

const mcjVersion = 1;

/// One parameter: its unit / range / default and whether it takes keys.
class McjParam {
  final String name;

  /// 'number' | 'int' | 'bool' | 'enum' | 'layer' | 'string' | 'color'
  final String kind;
  final double? min, max;
  final Object? def;
  final List<String>? options;
  final bool keys;
  final String doc;
  const McjParam(this.name, this.kind,
      {this.min, this.max, this.def, this.options, this.keys = false, this.doc = ''});
}

/// One effect type MCJ knows.
class McjEffect {
  final String type;
  final String group;
  final String doc;
  final List<McjParam> params;
  const McjEffect(this.type, this.group, this.doc, this.params);
}

/// The layer shapes.
const mcjShapes = ['rect', 'circle', 'triangle', 'ngon', 'polygon', 'text', 'line', 'placeholder'];

/// Ease names (keys also take [x1, y1, x2, y2]).
const mcjEases = ['linear', 'easeIn', 'easeOut', 'easeInOut', 'overshoot', 'anticipate'];

Easing? _ease(Object? e) {
  if (e is String) {
    if (e == 'overshoot') return const Easing(0, 0, 0.58, 1, kind: 'overshoot', amount: 0.2, bounces: 1);
    if (e == 'anticipate') return const Easing(0.42, 0, 1, 1, kind: 'anticipate', amount: 0.2, bounces: 0);
    return easingPresets[e];
  }
  if (e is List && e.length == 4 && e.every((v) => v is num)) {
    final v = [for (final x in e) (x as num).toDouble()];
    return Easing(v[0].clamp(0.0, 1.0), v[1], v[2].clamp(0.0, 1.0), v[3]);
  }
  return null;
}

/// Every effect type: the app's own (motion, physics, follow, cut, text
/// animators) and every registered shape effect, from its registry.
List<McjEffect> mcjEffects() {
  final p = Pendulum(), sw = Swing(), w = Wiggle(), mb = MotionBlur(), ph = PhysicsSettings();
  return [
    McjEffect('pendulum', 'Physics', 'swings like a pendulum when the layer moves', [
      McjParam('maxAngle', 'number', min: 0, max: 90, def: p.maxAngle),
      McjParam('frequency', 'number', min: 0, max: 100, def: p.frequency),
      McjParam('damping', 'number', min: 0, max: 100, def: p.damping),
      McjParam('freeze', 'number', min: 0, max: 100, def: p.freeze),
      McjParam('sensitivity', 'number', min: 0, max: 100, def: p.sensitivity),
    ]),
    McjEffect('swing', 'Physics', 'rocks between two angles, a sine', [
      McjParam('minAngle', 'number', min: -180, max: 180, def: sw.minAngle, doc: 'degrees'),
      McjParam('maxAngle', 'number', min: -180, max: 180, def: sw.maxAngle, doc: 'degrees'),
      McjParam('frequency', 'number', min: 0.05, max: 10, def: sw.frequency, doc: 'Hz'),
      McjParam('phase', 'number', min: 0, max: 360, def: sw.phase, doc: 'degrees'),
      McjParam('damping', 'number', min: 0, max: 5, def: sw.damping, doc: 'per second'),
    ]),
    McjEffect('wiggle', 'Physics', 'jitters its position randomly', [
      McjParam('speed', 'number', min: 0, max: 100, def: w.speed),
      McjParam('amplitude', 'number', min: 0, max: 100, def: w.amplitude),
      McjParam('smoothness', 'number', min: 0, max: 100, def: w.smoothness),
    ]),
    const McjEffect('follow', 'Physics', 'lazily trails another layer on a spring', [
      McjParam('target', 'layer', doc: 'name of the layer followed'),
      McjParam('position', 'bool', def: true),
      McjParam('rotation', 'bool', def: false),
      McjParam('scale', 'bool', def: false),
      McjParam('speed', 'number', min: 1, max: 500, def: 60.0, keys: true),
      McjParam('bounciness', 'number', min: 0, max: 100, def: 30.0, keys: true, doc: '%'),
      McjParam('amount', 'number', min: 0, max: 1, def: 1.0, keys: true),
    ]),
    McjEffect('collide', 'Physics', 'layers of one group can\'t overlap: one pushes the other', [
      const McjParam('group', 'enum', options: ['1', '2', '3', '4'], def: '1'),
      McjParam('role', 'enum', options: const ['pushable', 'immovable'], def: ph.role),
      McjParam('weight', 'number', min: 0.1, max: 10, def: ph.weight),
      McjParam('gap', 'number', min: 0, max: 50, def: ph.gap, doc: 'px'),
    ]),
    McjEffect('motionBlur', 'Look', 'smears fast motion', [
      McjParam('shutterAngle', 'number', min: 0, max: 360, def: mb.shutterAngle),
      McjParam('samples', 'int', min: 2, max: 32, def: mb.samples.toDouble()),
    ]),
    const McjEffect('cut', 'Contour / Outline / Cut', 'cuts this layer with another, live (a boolean with a gap)', [
      McjParam('cutter', 'layer', doc: 'name of the cutting layer'),
      McjParam('mode', 'enum', options: ['subtract', 'intersect', 'union', 'exclude'], def: 'subtract'),
      McjParam('gap', 'number', min: -200, max: 200, def: 0.0, keys: true, doc: 'px the cutter grows first'),
      McjParam('join', 'enum', options: ['miter', 'round', 'bevel'], def: 'miter'),
      McjParam('hideCutter', 'bool', def: false),
      McjParam('onlyWhenTouching', 'bool', def: false, doc: 'cut only while the cutter touches'),
    ]),
    const McjEffect('mask', 'Contour / Outline / Cut',
        'shows this layer only where its masks let it through - masks combine in list order, as logic on "shown"', [
      McjParam('source', 'layer', doc: 'name of the layer whose shape is the mask'),
      McjParam('mode', 'enum', options: maskModes, def: 'add',
          doc: 'add = OR, subtract = AND NOT, intersect = AND, exclude = XOR, implication = NOT R OR S, '
              'equivalence = R IFF S; a first mask other than add / exclude starts from all shown'),
      McjParam('invert', 'bool', def: false, doc: 'everything but the source counts'),
      McjParam('feather', 'number', min: 0, max: 500, def: 0.0, keys: true, doc: 'soft edge, px'),
      McjParam('hideSource', 'bool', def: true, doc: 'hide the source layer itself'),
    ]),
    McjEffect('textAnimator', 'Text animators', 'animates a text letter by letter (text layers)', [
      McjParam('preset', 'enum', options: textAnimatorPresets, def: textAnimatorPresets.first),
      const McjParam('start', 'int', min: 0, max: 100000, def: 0.0, doc: 'frame it starts'),
      const McjParam('frames', 'int', min: 1, max: 100000, def: 60.0, doc: 'how long it takes'),
    ]),
    for (final d in effectRegistry.values)
      McjEffect(d.id, d.id == 'outline' ? 'Contour / Outline / Cut' : 'Deform', d.name, [
        for (final pd in d.params)
          if (pd.type != 'vec2')
            McjParam(
              pd.key,
              switch (pd.type) {
                'enum' => 'enum',
                'int' => 'int',
                'color' => 'color',
                'bool' => 'bool',
                _ => 'number',
              },
              min: pd.range == null || pd.range!.isEmpty ? null : pd.range![0],
              max: pd.range == null || pd.range!.length < 2 ? null : pd.range![1],
              def: pd.defaultValue is num ? (pd.defaultValue as num).toDouble() : pd.defaultValue,
              options: pd.options,
              keys: pd.animatable && (pd.type == 'float' || pd.type == 'int'),
            ),
      ]),
  ];
}

/// What came of an import.
class McjResult {
  final Project project;
  final double width, height;
  final int fps, duration;

  /// '#rrggbb' or null (transparent).
  final String? background;

  /// Everything dropped / clamped / fixed, one line each.
  final List<String> report;
  McjResult(this.project, this.width, this.height, this.fps, this.duration, this.background, this.report);
}

/// The JSON object in a chatbot's reply: fences and prose around it
/// stripped, // and /* */ comments and trailing commas tolerated.
/// Throws FormatException with a readable message.
Map<String, dynamic> extractMcjJson(String reply) {
  final start = reply.indexOf('{');
  if (start < 0) throw const FormatException('No JSON object in the text - paste the whole reply.');
  // the outermost object: braces counted outside strings; comments and
  // trailing commas dropped on the way.
  final out = StringBuffer();
  var depth = 0;
  var inString = false;
  var end = -1;
  for (var i = start; i < reply.length; i++) {
    final c = reply[i];
    if (inString) {
      out.write(c);
      if (c == '\\' && i + 1 < reply.length) {
        out.write(reply[++i]);
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '/' && i + 1 < reply.length && reply[i + 1] == '/') {
      while (i < reply.length && reply[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < reply.length && reply[i + 1] == '*') {
      final e = reply.indexOf('*/', i + 2);
      i = e < 0 ? reply.length : e + 1;
      continue;
    }
    if (c == '"') inString = true;
    if (c == '{' || c == '[') depth++;
    if (c == '}' || c == ']') {
      depth--;
      // a trailing comma before it goes.
      final s = out.toString().trimRight();
      if (s.endsWith(',')) {
        out.clear();
        out.write(s.substring(0, s.length - 1));
      }
    }
    out.write(c);
    if (depth == 0) {
      end = i;
      break;
    }
  }
  if (end < 0) {
    throw const FormatException('The reply looks cut off - ask the AI to continue, or send it again.');
  }
  try {
    final v = jsonDecode(out.toString());
    if (v is! Map<String, dynamic>) throw const FormatException('not an object');
    return v;
  } on FormatException catch (e) {
    throw FormatException('The JSON in the reply can\'t be read (${e.message}).');
  }
}

/// MCJ -> a project, with its report. Never throws on content (bad parts
/// are dropped and listed).
McjResult expandMcj(Map<String, dynamic> j) {
  final report = <String>[];
  double num_(Object? v, double def, double min, double max, String what) {
    if (v == null) return def;
    if (v is! num) {
      report.add('$what: "$v" is not a number - default used');
      return def;
    }
    final d = v.toDouble();
    if (d < min || d > max) {
      report.add('$what: $d clamped to ${d < min ? min : max}');
      return d.clamp(min, max);
    }
    return d;
  }

  if (j['mcore'] != null && j['mcore'] != mcjVersion) report.add('format version ${j['mcore']} read as $mcjVersion');
  final canvas = j['canvas'] is Map ? Map<String, dynamic>.from(j['canvas'] as Map) : <String, dynamic>{};
  const canvasKeys = {'width', 'height', 'fps', 'duration', 'background'};
  for (final k in canvas.keys) {
    if (!canvasKeys.contains(k)) report.add('canvas.$k: unknown - ignored');
  }
  for (final k in j.keys) {
    if (!const {'mcore', 'canvas', 'layers'}.contains(k)) report.add('$k: unknown - ignored');
  }
  final width = num_(canvas['width'], 1080, 16, 8192, 'canvas.width').roundToDouble();
  final height = num_(canvas['height'], 1080, 16, 8192, 'canvas.height').roundToDouble();
  final fps_ = num_(canvas['fps'], 60, 1, 120, 'canvas.fps').round();
  final duration = num_(canvas['duration'], 180, 1, 100000, 'canvas.duration').round();
  String? background;
  final bg = canvas['background'];
  if (bg is String && bg != 'transparent') {
    if (RegExp(r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(bg)) {
      background = bg.substring(0, 7).toLowerCase();
    } else {
      report.add('canvas.background "$bg" not a colour - transparent');
    }
  }
  setStageSize(width, height);

  final effects = {for (final e in mcjEffects()) e.type: e};
  final layers = <Layer>[];
  final byName = <String, Layer>{};
  final parents = <Layer, String>{};
  final targets = <(Layer, String, String)>[]; // (layer, kind, name)
  final raw = j['layers'] is List ? j['layers'] as List : const [];
  if (j['layers'] is! List) report.add('no "layers" list');

  int frame(Object? f, String what) {
    final d = num_(f, 0, -1e9, 1e9, what).round();
    if (d < 0 || d > duration) {
      report.add('$what: frame $d outside 0-$duration - clamped');
      return d.clamp(0, duration);
    }
    return d;
  }

  /// A value or a key list -> a Track. `dims`: 1 (number) or 2 ([x, y]).
  Track? track(Object? v, int dims, double def, double min, double max, String what) {
    Object? value(Object? x, String w) {
      if (dims == 1) return num_(x, def, min, max, w);
      if (x is List && x.length == 2 && x.every((e) => e is num)) {
        return <double>[num_(x[0], def, min, max, w), num_(x[1], def, min, max, w)];
      }
      report.add('$w: "$x" is not [x, y] - skipped');
      return null;
    }

    if (v == null) return null;
    final isKeys = v is List && v.isNotEmpty && v.first is List && (dims == 1 || (v.first as List).length >= 2 && (v.first as List)[1] is! num);
    if (!isKeys) {
      final x = value(v, what);
      return x == null ? null : Track(x, dims == 2);
    }
    final byFrame = <int, Keyframe>{};
    final eases = <int, Easing>{};
    for (final k in v) {
      if (k is! List || k.length < 2) {
        report.add('$what: key "$k" is not [frame, value, ease?] - skipped');
        continue;
      }
      final f = frame(k[0], '$what key');
      final x = value(k[1], '$what at $f');
      if (x == null) continue;
      if (byFrame.containsKey(f)) report.add('$what: two keys at frame $f - the last kept');
      byFrame[f] = Keyframe(frame: f, value: x, temporal: easingPresets['linear']);
      if (k.length > 2) {
        final e = _ease(k[2]);
        if (e == null) {
          report.add('$what at $f: ease "${k[2]}" unknown - linear');
        } else {
          eases[f] = e;
        }
      }
    }
    final keys = byFrame.values.toList()..sort((a, b) => a.frame.compareTo(b.frame));
    if (keys.isEmpty) return null;
    // an ease written on a key shapes the move INTO it (the segment from
    // the key before).
    for (var i = 1; i < keys.length; i++) {
      final e = eases[keys[i].frame];
      if (e != null) keys[i - 1].temporal = e;
    }
    return Track(keys.first.value, dims == 2)..keyframes = keys;
  }

  for (var li = 0; li < raw.length; li++) {
    final m = raw[li];
    if (m is! Map) {
      report.add('layers[$li]: not an object - skipped');
      continue;
    }
    final name0 = m['name'] is String && (m['name'] as String).trim().isNotEmpty ? (m['name'] as String).trim() : 'layer ${li + 1}';
    var name = name0;
    for (var n = 2; byName.containsKey(name); n++) {
      name = '$name0 $n';
    }
    if (name != name0) report.add('layer "$name0": the name is taken - renamed "$name"');
    final w = 'layer "$name"';
    final shape = m['shape'];
    if (shape is! String || !mcjShapes.contains(shape)) {
      report.add('$w: shape "$shape" unknown - skipped');
      continue;
    }
    if (m.containsKey('expression')) report.add('$w: expressions are not allowed - ignored');
    const known = {
      'name', 'shape', 'size', 'color', 'parent', 'start', 'end', 'anchor', 'rotation', 'scale', 'opacity',
      'effects', 'points', 'sides', 'text', 'line', 'expression',
    };
    for (final k in m.keys) {
      if (!known.contains(k)) report.add('$w.$k: unknown - ignored');
    }
    final size = m['size'] is List && (m['size'] as List).length == 2
        ? [num_((m['size'] as List)[0], 100, 1, 20000, '$w.size'), num_((m['size'] as List)[1], 100, 1, 20000, '$w.size')]
        : null;
    Layer l;
    switch (shape) {
      case 'text':
        final t = m['text'] is Map ? m['text'] as Map : const {};
        l = createTextLayer(
            text: t['text'] is String ? t['text'] as String : 'Text', fontSize: num_(t['fontSize'], 48, 4, 1000, '$w.text.fontSize'));
        final align = t['align'];
        if (align is String && const ['left', 'center', 'right'].contains(align)) l.content.text!.align = align;
        if (t['color'] is String) l.content.text!.color = t['color'] as String;
        if (t['font'] is String && (t['font'] as String).isNotEmpty) l.content.text!.fontId = t['font'] as String;
        if (size != null) l.content.size = size;
      case 'line':
        l = createLayer('line');
        final ln = m['line'] is Map ? m['line'] as Map : const {};
        final pts = ln['points'];
        if (pts is List && pts.length >= 2 && pts.every((p) => p is List && p.length == 2 && p.every((e) => e is num))) {
          l.content.lineNodes = [for (final p in pts) LineNode(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())];
        } else if (pts != null) {
          report.add('$w.line.points: needs [[x, y], ...] (2 or more) - a default line');
        }
        l.content.lineWidth = num_(ln['width'], 6, 0.5, 500, '$w.line.width');
        l.content.lineClosed = ln['closed'] == true;
        final reveal = track(ln['reveal'], 1, 1, 0, 1, '$w.line.reveal');
        if (reveal != null) l.content.lineTrimEnd = reveal;
      case 'placeholder':
        l = createLayer('rect')
          ..color = '#9e9e9e'
          ..content.placeholder = true;
      default:
        l = createLayer(shape == 'ngon' ? 'ngon' : shape);
        if (size != null) l.content.size = size;
        if (shape == 'ngon') l.content.sides = num_(m['sides'], 6, 3, 64, '$w.sides').round();
        if (shape == 'polygon') {
          final pts = m['points'];
          if (pts is List && pts.length >= 3 && pts.every((p) => p is List && p.length == 2 && p.every((e) => e is num))) {
            l.content.points = [for (final p in pts) [((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()]];
            final xs = [for (final p in l.content.points!) p[0]], ys = [for (final p in l.content.points!) p[1]];
            l.content.size = [xs.reduce(math.max) - xs.reduce(math.min), ys.reduce(math.max) - ys.reduce(math.min)];
          } else {
            report.add('$w.points: a polygon needs [[x, y], ...] (3 or more) - skipped');
            continue;
          }
        }
    }
    if (shape == 'placeholder' && size != null) l.content.size = size;
    l.name = name;
    layerCounter++;
    l.id = 'L_mcj_${li}_$layerCounter';
    final color = m['color'];
    if (color is String) {
      if (RegExp(r'^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(color)) {
        l.color = color.substring(0, 7).toLowerCase();
      } else {
        report.add('$w.color "$color" not #RRGGBB - default');
      }
    }
    final start = frame(m['start'] ?? 0, '$w.start');
    final end = frame(m['end'] ?? duration, '$w.end');
    l.startFrame = start;
    l.durationFrames = math.max(1, end - start);
    l.transform.anchor = track(m['anchor'], 2, 0.5, -10, 10, '$w.anchor') ?? Track(<double>[0.5, 0.5], true);
    l.transform.rotation = track(m['rotation'], 1, 0, -36000, 36000, '$w.rotation') ?? Track(0.0, false);
    l.transform.scale = track(m['scale'], 2, 1, -100, 100, '$w.scale') ?? Track(<double>[1.0, 1.0], false);
    l.transform.opacity = track(m['opacity'], 1, 1, 0, 1, '$w.opacity') ?? Track(1.0, false);
    // keys are frames of the project; the layer's own clock starts at
    // its start.
    for (final t in [l.transform.anchor, l.transform.rotation, l.transform.scale, l.transform.opacity]) {
      for (final k in t.keyframes) {
        k.frame -= start;
      }
    }
    if (m['parent'] is String) parents[l] = m['parent'] as String;

    // effects
    final fx = m['effects'];
    if (fx != null && fx is! List) report.add('$w.effects: not a list - ignored');
    for (final e in fx is List ? fx : const []) {
      if (e is! Map || e['type'] is! String) {
        report.add('$w.effects: "$e" has no type - skipped');
        continue;
      }
      final type = e['type'] as String;
      final def = effects[type];
      if (def == null) {
        report.add('$w: effect "$type" unknown - skipped');
        continue;
      }
      final ew = '$w.$type';
      final params = {for (final p in def.params) p.name: p};
      for (final k in e.keys) {
        if (k != 'type' && !params.containsKey(k)) report.add('$ew.$k: unknown - ignored');
      }
      double n(String k) {
        final p = params[k]!;
        return num_(e[k], (p.def as num?)?.toDouble() ?? 0, p.min ?? -1e9, p.max ?? 1e9, '$ew.$k');
      }

      Track nt(String k) {
        final p = params[k]!;
        final t = track(e[k], 1, (p.def as num?)?.toDouble() ?? 0, p.min ?? -1e9, p.max ?? 1e9, '$ew.$k') ??
            Track((p.def as num?)?.toDouble() ?? 0, false);
        for (final key in t.keyframes) {
          key.frame -= start;
        }
        return t;
      }

      String en(String k) {
        final p = params[k]!;
        final v = e[k];
        if (v == null) return p.def as String;
        if (p.options!.contains('$v')) return '$v';
        report.add('$ew.$k: "$v" not one of ${p.options!.join(', ')} - ${p.def}');
        return p.def as String;
      }

      bool b(String k) => e[k] is bool ? e[k] as bool : params[k]!.def as bool;

      switch (type) {
        case 'pendulum':
          l.pendulum
            ..enabled = true
            ..maxAngle = n('maxAngle')
            ..frequency = n('frequency')
            ..damping = n('damping')
            ..freeze = n('freeze')
            ..sensitivity = n('sensitivity');
        case 'swing':
          l.swing
            ..enabled = true
            ..minAngle = n('minAngle')
            ..maxAngle = n('maxAngle')
            ..frequency = n('frequency')
            ..phase = n('phase')
            ..damping = n('damping');
        case 'wiggle':
          l.wiggle
            ..enabled = true
            ..speed = n('speed')
            ..amplitude = n('amplitude')
            ..smoothness = n('smoothness');
        case 'motionBlur':
          l.motionBlur
            ..enabled = true
            ..shutterAngle = n('shutterAngle')
            ..samples = n('samples').round();
        case 'follow':
          l.follow
            ..enabled = true
            ..position = b('position')
            ..rotation = b('rotation')
            ..scale = b('scale')
            ..speed = nt('speed')
            ..bounciness = nt('bounciness')
            ..amount = nt('amount');
          if (e['target'] is String) {
            targets.add((l, 'follow', e['target'] as String));
          } else {
            report.add('$ew: no target - it follows nothing');
          }
        case 'collide':
          l.physics
            ..collide = true
            ..group = en('group')
            ..role = en('role')
            ..weight = n('weight')
            ..gap = n('gap');
        case 'cut':
          final c = CutByLayer(
              mode: en('mode'),
              gap: nt('gap'),
              join: en('join'),
              hideCutter: b('hideCutter'),
              onlyWhenTouching: b('onlyWhenTouching'));
          l.cuts.add(c);
          if (e['cutter'] is String) {
            targets.add((l, 'cut:${l.cuts.length - 1}', e['cutter'] as String));
          } else {
            report.add('$ew: no cutter - it cuts nothing');
          }
        case 'mask':
          l.masks.add(Mask(mode: en('mode'), invert: b('invert'), feather: nt('feather')));
          if (e['source'] is String) {
            targets.add((l, '${b('hideSource') ? 'maskH' : 'mask'}:${l.masks.length - 1}', e['source'] as String));
          } else {
            report.add('$ew: no source - it masks nothing');
          }
        case 'textAnimator':
          if (l.content.text == null) {
            report.add('$ew: only for text layers - skipped');
            continue;
          }
          l.content.text!.animators
              .add(textAnimatorPreset(en('preset'), f0: n('start').round() - start, frames: n('frames').round()));
        default:
          final inst = createEffectInstance(type, 'fx_${l.id}_${l.effectStack.length}', l);
          for (final p in def.params) {
            if (!e.containsKey(p.name)) continue;
            final cur = inst.params[p.name];
            if (cur is Track) {
              inst.params[p.name] = nt(p.name);
            } else if (p.kind == 'enum') {
              inst.params[p.name] = en(p.name);
            } else if (p.kind == 'color' || p.kind == 'string') {
              final v = e[p.name];
              if (v is String && (p.kind != 'color' || RegExp(r'^#[0-9a-fA-F]{6}').hasMatch(v))) {
                inst.params[p.name] = p.kind == 'color' ? v.substring(0, 7) : v;
              } else {
                report.add('$ew.${p.name}: "$v" not valid - default');
              }
            } else if (p.kind == 'bool') {
              inst.params[p.name] = b(p.name);
            } else {
              inst.params[p.name] = p.kind == 'int' ? n(p.name).round() : n(p.name);
            }
          }
          l.effectStack.add(inst);
      }
    }
    layers.add(l);
    byName[name] = l;
  }

  // relations, by name.
  for (final e in parents.entries) {
    final p = byName[e.value];
    if (p == null || identical(p, e.key)) {
      report.add('layer "${e.key.name}": parent "${e.value}" not found - none');
      continue;
    }
    // a circle: the later link breaks.
    var cur = p;
    var circle = false;
    for (var guard = 0; guard < layers.length + 1; guard++) {
      if (identical(cur, e.key)) {
        circle = true;
        break;
      }
      final up = cur.parentId == null ? null : layers.where((x) => x.id == cur.parentId).firstOrNull;
      if (up == null) break;
      cur = up;
    }
    if (circle) {
      report.add('layer "${e.key.name}": parent "${e.value}" would make a circle - none');
      continue;
    }
    e.key.parentId = p.id;
  }
  final project = Project(layers: layers);
  for (final (l, kind, name) in targets) {
    final t = byName[name];
    if (t == null || identical(t, l)) {
      report.add('layer "${l.name}": ${kind == 'follow' ? 'follow target' : kind.startsWith('mask') ? 'mask source' : 'cutter'} "$name" not found - none');
      continue;
    }
    if (kind.startsWith('mask')) {
      l.masks[int.parse(kind.substring(kind.indexOf(':') + 1))].sourceLayerId = t.id;
      if (kind.startsWith('maskH')) t.hidden = true;
    } else if (kind == 'follow') {
      l.follow.targetId = t.id;
      if (_followCircle(project, l)) {
        l.follow.targetId = null;
        report.add('layer "${l.name}": following "$name" would make a circle - none');
      }
    } else {
      final c = l.cuts[int.parse(kind.substring(4))];
      c.cutterId = t.id;
      if (_cutCircle(project, l)) {
        c.cutterId = null;
        report.add('layer "${l.name}": cut by "$name" would make a circle - none');
      }
    }
  }
  project.fps = fps_;
  return McjResult(project, width, height, fps_, duration, background, report);
}

bool _followCircle(Project p, Layer l) {
  final seen = <String>{};
  String? id = l.follow.targetId;
  while (id != null && seen.add(id)) {
    if (id == l.id) return true;
    final t = p.layers.where((x) => x.id == id).firstOrNull;
    id = t != null && t.follow.enabled ? t.follow.targetId : null;
  }
  return false;
}

bool _cutCircle(Project p, Layer l) {
  final seen = <String>{};
  bool reaches(String id) {
    if (id == l.id) return true;
    if (!seen.add(id)) return false;
    final t = p.layers.where((x) => x.id == id).firstOrNull;
    if (t == null) return false;
    return t.cuts.any((c) => c.cutterId != null && reaches(c.cutterId!));
  }

  return l.cuts.any((c) => c.cutterId != null && reaches(c.cutterId!));
}

// ===== project -> MCJ =====

/// A project as MCJ (for "edit with AI"). Media become placeholders named
/// like their layer; text animators come back as their preset names only
/// when made from one.
Map<String, dynamic> compactToMcj(Project project,
    {required double width, required double height, int fps = 60, required int duration, String? background}) {
  final names = <String, String>{};
  final used = <String>{};
  for (final l in project.layers) {
    var n = l.name.trim().isEmpty ? 'layer' : l.name.trim();
    final base = n;
    for (var k = 2; used.contains(n); k++) {
      n = '$base $k';
    }
    used.add(n);
    names[l.id] = n;
  }
  Object? keys(Track t, int start, {bool vec = false}) {
    List<double> v2(Object? v) => [for (final x in v as List) _r((x as num).toDouble())];
    Object? val(Object? v) => vec ? v2(v) : _r((v as num).toDouble());
    if (t.keyframes.isEmpty) return val(t.defaultValue);
    final ks = t.keyframes;
    return [
      for (var i = 0; i < ks.length; i++)
        [
          ks[i].frame + start,
          val(ks[i].value),
          if (i > 0) _easeName(ks[i - 1].temporal),
        ]
    ];
  }

  final layers = <Map<String, dynamic>>[];
  for (final l in project.layers) {
    if (l.mirrorProbe || isAudioShape(l.content.shape) || isCameraShape(l.content.shape)) continue;
    final c = l.content;
    final start = l.startFrame;
    final media = isMediaShape(c.shape) || c.placeholder;
    final shape = media
        ? 'placeholder'
        : c.shape == 'text'
            ? 'text'
            : isNodeLine(c)
                ? 'line'
                : mcjShapes.contains(c.shape)
                    ? c.shape
                    : c.shape == 'compound'
                        ? 'polygon'
                        : 'rect';
    final m = <String, dynamic>{
      'name': names[l.id],
      'shape': shape,
      if (shape != 'line') 'size': [_r(c.size[0]), _r(c.size[1])],
      if (l.color != null && !media) 'color': l.color,
      if (l.parentId != null && names.containsKey(l.parentId)) 'parent': names[l.parentId],
      'start': start,
      'end': start + l.durationFrames,
      'anchor': keys(l.transform.anchor, start, vec: true),
      if (l.transform.rotation.keyframes.isNotEmpty || l.transform.rotation.defaultValue != 0.0)
        'rotation': keys(l.transform.rotation, start),
      if (l.transform.scale.keyframes.isNotEmpty || '${l.transform.scale.defaultValue}' != '[1.0, 1.0]')
        'scale': keys(l.transform.scale, start, vec: true),
      if (l.transform.opacity.keyframes.isNotEmpty || l.transform.opacity.defaultValue != 1.0)
        'opacity': keys(l.transform.opacity, start),
      if (shape == 'ngon') 'sides': c.sides,
      if (shape == 'polygon')
        'points': c.shape == 'compound'
            ? [for (final p in (c.contours?.firstOrNull ?? const <List<double>>[])) [_r(p[0]), _r(p[1])]]
            : [for (final p in c.points ?? const <List<double>>[]) [_r(p[0]), _r(p[1])]],
      if (shape == 'text')
        'text': {
          'text': c.text!.text,
          'fontSize': c.text!.fontSize,
          'align': c.text!.align,
          'color': c.text!.color,
          'font': c.text!.fontId,
        },
      if (shape == 'line')
        'line': {
          'points': [for (final n in c.lineNodes!) [_r(n.x), _r(n.y)]],
          'width': c.lineWidth,
          if (c.lineClosed) 'closed': true,
          if (c.lineTrimEnd != null) 'reveal': keys(c.lineTrimEnd!, start),
        },
      'effects': [
        if (l.pendulum.enabled)
          {
            'type': 'pendulum',
            'maxAngle': l.pendulum.maxAngle,
            'frequency': l.pendulum.frequency,
            'damping': l.pendulum.damping,
            'freeze': l.pendulum.freeze,
            'sensitivity': l.pendulum.sensitivity,
          },
        if (l.swing.enabled)
          {
            'type': 'swing',
            'minAngle': l.swing.minAngle,
            'maxAngle': l.swing.maxAngle,
            'frequency': l.swing.frequency,
            'phase': l.swing.phase,
            'damping': l.swing.damping,
          },
        if (l.wiggle.enabled)
          {'type': 'wiggle', 'speed': l.wiggle.speed, 'amplitude': l.wiggle.amplitude, 'smoothness': l.wiggle.smoothness},
        if (l.motionBlur.enabled)
          {'type': 'motionBlur', 'shutterAngle': l.motionBlur.shutterAngle, 'samples': l.motionBlur.samples},
        if (l.follow.enabled && names.containsKey(l.follow.targetId))
          {
            'type': 'follow',
            'target': names[l.follow.targetId],
            'position': l.follow.position,
            'rotation': l.follow.rotation,
            'scale': l.follow.scale,
            'speed': keys(l.follow.speed, start),
            'bounciness': keys(l.follow.bounciness, start),
            'amount': keys(l.follow.amount, start),
          },
        if (l.physics.collide)
          {'type': 'collide', 'group': l.physics.group, 'role': l.physics.role, 'weight': l.physics.weight, 'gap': l.physics.gap},
        for (final cut in l.cuts)
          if (cut.enabled && names.containsKey(cut.cutterId))
            {
              'type': 'cut',
              'cutter': names[cut.cutterId],
              'mode': cut.mode,
              'gap': keys(cut.gap, start),
              'join': cut.join,
              if (cut.hideCutter) 'hideCutter': true,
              if (cut.onlyWhenTouching) 'onlyWhenTouching': true,
            },
        for (final mk in l.masks)
          if (mk.enabled && names.containsKey(mk.sourceLayerId))
            {
              'type': 'mask',
              'source': names[mk.sourceLayerId],
              'mode': mk.mode,
              if (mk.invert) 'invert': true,
              'feather': keys(mk.feather, start),
              'hideSource': findLayer(project, mk.sourceLayerId)?.hidden ?? false,
            },
        for (final a in c.text?.animators ?? const <TextAnimator>[])
          if (textAnimatorPresets.contains(a.name))
            {'type': 'textAnimator', 'preset': a.name, 'start': start + _firstKey(a), 'frames': _span(a)},
        for (final inst in l.effectStack)
          if (inst.enabled && effectRegistry.containsKey(inst.effectId))
            {
              'type': inst.effectId,
              for (final pd in effectRegistry[inst.effectId]!.params)
                if (pd.type != 'vec2' && inst.params[pd.key] != null)
                  pd.key: inst.params[pd.key] is Track ? keys(inst.params[pd.key] as Track, start) : inst.params[pd.key],
            },
      ],
    };
    if ((m['effects'] as List).isEmpty) m.remove('effects');
    layers.add(m);
  }
  return {
    'mcore': mcjVersion,
    'canvas': {
      'width': width.round(),
      'height': height.round(),
      'fps': fps,
      'duration': duration,
      'background': background ?? 'transparent',
    },
    'layers': layers,
  };
}

double _r(double v) => (v * 1000).roundToDouble() / 1000;

Object _easeName(Easing e) {
  if (e.kind == 'overshoot') return 'overshoot';
  if (e.kind == 'anticipate') return 'anticipate';
  for (final p in easingPresets.entries) {
    final v = p.value;
    if (v.x1 == e.x1 && v.y1 == e.y1 && v.x2 == e.x2 && v.y2 == e.y2) return p.key;
  }
  return [_r(e.x1), _r(e.y1), _r(e.x2), _r(e.y2)];
}

int _firstKey(TextAnimator a) {
  var f = 1 << 30;
  for (final t in a.tracks.values) {
    for (final k in t.keyframes) {
      f = math.min(f, k.frame);
    }
  }
  return f == 1 << 30 ? 0 : f;
}

int _span(TextAnimator a) {
  var lo = 1 << 30, hi = -(1 << 30);
  for (final t in a.tracks.values) {
    for (final k in t.keyframes) {
      lo = math.min(lo, k.frame);
      hi = math.max(hi, k.frame);
    }
  }
  return hi > lo ? hi - lo : 60;
}
