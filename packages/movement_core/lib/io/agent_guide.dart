/// The guide an AI agent gets to write an MCore project on its own (and
/// the prompt the app copies): generated from the same tables the MCJ
/// importer validates with (mcjEffects, mcjShapes, mcjEases), so it can't
/// drift from the app.
library;

import 'dart:convert';

import 'mcj.dart';

enum GuideLevel { compact, full }

/// A complete, importable example.
class McjRecipe {
  final String title;
  final String note;
  final String json;
  const McjRecipe(this.title, this.note, this.json);
}

const mcjRecipes = [
  McjRecipe('Scale pop with overshoot', 'A square pops in, overshoots and settles.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 90, "background": "#ffffff"},
 "layers": [
  {"name": "pop", "shape": "rect", "size": [300, 300], "color": "#e04040",
   "anchor": [0.5, 0.5],
   "scale": [[0, [0, 0]], [24, [1, 1], "overshoot"]]}
 ]}'''),
  McjRecipe('Text typewriter', 'Letters appear one by one.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 120, "background": "#101418"},
 "layers": [
  {"name": "title", "shape": "text", "size": [900, 200], "anchor": [0.5, 0.5],
   "text": {"text": "Hello, MCore", "fontSize": 96, "align": "center", "color": "#ffffff"},
   "effects": [{"type": "textAnimator", "preset": "Typewriter", "start": 0, "frames": 60}]}
 ]}'''),
  McjRecipe('Notched diamond', 'Cut by layer with a 20 px gap; the notch follows the small diamond.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 90, "background": "#ffffff"},
 "layers": [
  {"name": "small", "shape": "rect", "size": [99, 99], "color": "#ffffff", "rotation": 45,
   "anchor": [[0, [0.5, 0.685]], [60, [0.639, 0.546], "easeInOut"]],
   "effects": [{"type": "outline", "width": 16, "position": "center", "join": "miter", "color": "#000000", "smoothness": 0}]},
  {"name": "big", "shape": "rect", "size": [282.84, 282.84], "color": "#ffffff", "rotation": 45, "anchor": [0.5, 0.5],
   "effects": [
    {"type": "cut", "cutter": "small", "mode": "subtract", "gap": 20, "join": "miter"},
    {"type": "outline", "width": 16, "position": "center", "join": "miter", "color": "#000000", "smoothness": 0}]}
 ]}'''),
  McjRecipe('Masks: a photo in a ring', 'Mask logic: add the big circle, subtract the moving small one.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 120, "background": "#101418"},
 "layers": [
  {"name": "ring", "shape": "circle", "size": [600, 600], "color": "#ffffff", "anchor": [0.5, 0.5]},
  {"name": "hole", "shape": "circle", "size": [250, 250], "color": "#ffffff",
   "anchor": [[0, [0.35, 0.5]], [100, [0.65, 0.5], "easeInOut"]]},
  {"name": "photo", "shape": "placeholder", "size": [1080, 1080], "anchor": [0.5, 0.5],
   "effects": [
    {"type": "mask", "source": "ring", "mode": "add"},
    {"type": "mask", "source": "hole", "mode": "subtract", "feather": 6}]}
 ]}'''),
  McjRecipe('Pendulum chain', 'Two arms hang from a moving bar and swing.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 180, "background": "#f4f1ea"},
 "layers": [
  {"name": "bar", "shape": "rect", "size": [240, 30], "color": "#333333",
   "anchor": [[0, [0.3, 0.2]], [60, [0.7, 0.2], "easeInOut"], [120, [0.3, 0.2], "easeInOut"]]},
  {"name": "arm1", "shape": "rect", "size": [24, 200], "color": "#3060c0", "parent": "bar", "anchor": [0, 0.1],
   "effects": [{"type": "pendulum", "maxAngle": 40, "frequency": 20}]},
  {"name": "arm2", "shape": "rect", "size": [24, 160], "color": "#e09030", "parent": "arm1", "anchor": [0, 0.18],
   "effects": [{"type": "pendulum", "maxAngle": 50, "frequency": 25}]}
 ]}'''),
  McjRecipe('Lazy-follow shadow', 'A soft shadow trails a moving ball.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 150, "background": "#ffffff"},
 "layers": [
  {"name": "shadow", "shape": "circle", "size": [180, 180], "color": "#000000", "opacity": 0.3, "anchor": [0.22, 0.52],
   "effects": [{"type": "follow", "target": "ball", "speed": 40, "bounciness": 20}]},
  {"name": "ball", "shape": "circle", "size": [180, 180], "color": "#40a0e0",
   "anchor": [[0, [0.2, 0.5]], [60, [0.8, 0.5], "easeInOut"], [120, [0.5, 0.3], "easeInOut"]]}
 ]}'''),
  McjRecipe('A cube pushing a cube', 'The moving square shoves the other one (Collide, one group).', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 120, "background": "#ffffff"},
 "layers": [
  {"name": "box", "shape": "rect", "size": [160, 160], "color": "#e0a030", "anchor": [0.55, 0.5],
   "effects": [{"type": "collide", "group": "1", "role": "pushable"}]},
  {"name": "pusher", "shape": "rect", "size": [160, 160], "color": "#3060c0",
   "anchor": [[0, [0.15, 0.5]], [90, [0.6, 0.5], "linear"]],
   "effects": [{"type": "collide", "group": "1", "role": "immovable"}]}
 ]}'''),
  McjRecipe('Sticker outline on a picture', 'A placeholder for your image with a white sticker edge.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 60, "background": "#202020"},
 "layers": [
  {"name": "photo", "shape": "placeholder", "size": [600, 400], "anchor": [0.5, 0.5], "rotation": -4,
   "effects": [{"type": "outline", "width": 14, "position": "outside", "color": "#ffffff"}]}
 ]}'''),
  McjRecipe('A line drawing itself', 'A three-point line appears from start to end.', '''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 90, "background": "#ffffff"},
 "layers": [
  {"name": "stroke", "shape": "line", "color": "#202020", "anchor": [0.5, 0.5],
   "line": {"points": [[-300, 100], [0, -150], [300, 100]], "width": 10, "reveal": [[0, 0], [45, 1, "easeOut"]]}}
 ]}'''),
];

String _num(Object? v) {
  if (v is double && v == v.roundToDouble()) return v.round().toString();
  return '$v';
}

String _param(McjParam p) {
  final parts = <String>[
    if (p.kind == 'enum') p.options!.join(' | ') else if (p.kind == 'layer') 'layer name' else p.kind,
    if (p.min != null && p.max != null) '${_num(p.min)}..${_num(p.max)}',
    if (p.def != null) 'default ${_num(p.def)}',
    if (p.keys) 'keys ok',
    if (p.doc.isNotEmpty) p.doc,
  ];
  return '`${p.name}` (${parts.join(', ')})';
}

/// The guide, as Markdown. `compact` fits a phone chat (about 1,500
/// words at most); `full` has everything.
String buildAgentGuide({GuideLevel level = GuideLevel.full}) {
  final full = level == GuideLevel.full;
  final effects = mcjEffects();
  final b = StringBuffer();
  b.writeln('# MCore project guide (MCJ format v$mcjVersion)');
  b.writeln();
  b.writeln('## Contract');
  b.writeln('Reply with only one JSON code block in the MCJ format below - no prose, no expressions, no code, '
      'no URLs. Pictures and video are placeholders (shape "placeholder"); the user fills them in. '
      'Use only the fields documented here.');
  b.writeln();
  b.writeln('## Units');
  b.writeln('- size, points, line points, gaps, widths: canvas pixels (points are relative to the layer centre).');
  b.writeln('- anchor (the layer centre): fractions of the canvas, [0, 0] top-left, [1, 1] bottom-right, y goes down.');
  b.writeln('- rotation: degrees, positive turns clockwise.');
  b.writeln('- time: frames at the canvas fps; start / end / key frames are project frames, 0..duration.');
  b.writeln('- colors: "#RRGGBB" (layers ignore an alpha pair; use opacity).');
  b.writeln('- opacity, amounts: 0..1. scale: [x, y], 1 = as is.');
  b.writeln();
  b.writeln('## Skeleton');
  b.writeln('```json');
  b.writeln('{"mcore": $mcjVersion, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 180, '
      '"background": "transparent"},');
  b.writeln(' "layers": [{"name": "box", "shape": "rect", "size": [200, 200], "color": "#e04040", "anchor": [0.5, 0.5]}]}');
  b.writeln('```');
  b.writeln('Layers draw in list order: the first is at the back. Every field but `shape` is optional.');
  b.writeln();
  b.writeln('## Layers');
  b.writeln('Common fields: `name` (unique; others refer to it), `shape` (${mcjShapes.join(' | ')}), `size` [w, h], '
      '`color`, `parent` (a layer name: moves, turns and scales with it), `start`, `end` (frames; default the whole '
      'duration), `anchor`, `rotation`, `scale`, `opacity` (a value or keys), `effects` (a list).');
  b.writeln('- rect, circle, triangle: `size`. ngon: `size`, `sides` (3..64). polygon: `points` [[x, y], ...] (3 or more).');
  b.writeln('- text: `text` {`text`, `fontSize` (4..1000, default 48), `align` left | center | right, `color`, `font` (an id from the Fonts list, if given)}; `size` is its box.');
  b.writeln('- line: `line` {`points` [[x, y], ...] (2 or more), `width` (default 6), `closed` (bool), '
      '`reveal` (0..1 how much is drawn; keys ok)}; `color` is the stroke.');
  b.writeln('- placeholder: `size` - a box for a picture or video the user adds later.');
  b.writeln();
  b.writeln('## Keys');
  b.writeln('A value, or keys `[[frame, value, ease?], ...]`. The ease on a key shapes the move into it: '
      '${mcjEases.join(' | ')} or a bezier [x1, y1, x2, y2] (x1, x2 in 0..1). Between keys values blend; '
      'before the first and after the last they hold.');
  if (full) {
    b.writeln('Keys here are the final values. The app\'s key modes (base / order / layer) and its animation '
        'layers are editing views over these same keys; MCJ writes one set of keys per value.');
  }
  b.writeln();
  b.writeln('## Effects');
  if (full) {
    b.writeln('Each effect is `{"type": "<type>", ...params}`. Params left out take their default.');
    final groups = <String, List<McjEffect>>{};
    for (final e in effects) {
      (groups[e.group] ??= []).add(e);
    }
    for (final g in groups.entries) {
      b.writeln();
      b.writeln('### ${g.key}');
      b.writeln('| type | what it does | params |');
      b.writeln('|---|---|---|');
      for (final e in g.value) {
        b.writeln('| `${e.type}` | ${e.doc} | ${e.params.map(_param).join('; ')} |');
      }
    }
  } else {
    b.writeln('`{"type": "<type>", ...params}`; params left out take defaults.');
    for (final e in effects) {
      b.writeln('- `${e.type}`: ${e.doc} - ${e.params.map((p) => p.name).join(', ')}');
    }
  }
  b.writeln();
  if (full) {
    b.writeln('## Relations');
    b.writeln('- `parent`: a layer name. The child moves, turns and scales with its parent; its anchor is then '
        'relative to the parent.');
    b.writeln('- `follow.target`, `cut.cutter`, `mask.source`: layer names.');
    b.writeln('- Masks: a layer\'s `mask` effects run top to bottom on what is shown. A first `add` / `exclude` '
        'starts from nothing, any other first mode from everything; each next one combines with the result '
        '(add OR, subtract AND NOT, intersect AND, exclude XOR, implication NOT R OR S, equivalence R IFF S). '
        '`invert` flips its source. The source layer is hidden unless `hideSource` is false.');
    b.writeln('- Collide: layers with `collide` in the same `group` push each other; `immovable` ones only push.');
    b.writeln('- Project references aren\'t written in MCJ; use a placeholder.');
    b.writeln('- No circles: a layer can\'t be its own parent / target / cutter, directly or through others.');
    b.writeln();
  }
  b.writeln('## Recipes');
  for (final r in full ? mcjRecipes : mcjRecipes.take(3)) {
    b.writeln();
    b.writeln('### ${r.title}');
    b.writeln(r.note);
    b.writeln('```json');
    b.writeln(r.json.trim());
    b.writeln('```');
  }
  b.writeln();
  if (full) {
    b.writeln('## What the importer does');
    b.writeln('- Unknown fields, shapes and effect types: dropped (and listed to the user).');
    b.writeln('- Numbers out of range: clamped to the range. Not a number: the default.');
    b.writeln('- Key frames below 0 or past `duration`: clamped. Two keys at one frame: the last wins. Keys sorted.');
    b.writeln('- Names that don\'t exist (parent, target, cutter) or would make a circle: dropped.');
    b.writeln('- An `expression` field: ignored.');
    b.writeln();
  }
  b.writeln('## Before you reply, check');
  b.writeln('- It is valid JSON, one code block, nothing around it.');
  b.writeln('- Every parent, target, cutter and mask source names a layer in the list; names are unique.');
  b.writeln('- Every frame is within 0..duration.');
  b.writeln('- Only documented fields and effect types are used.');
  return b.toString();
}

/// What "Copy prompt" puts on the clipboard: the guide (compact or full),
/// the request, and for "edit with AI" the current project.
String buildAiPrompt(String request,
    {Map<String, dynamic>? current, GuideLevel level = GuideLevel.compact, Map<String, String> fonts = const {}}) {
  final b = StringBuffer();
  b.writeln(current == null
      ? 'Build an MCore animation project. Reply with only the JSON in the MCJ format described below.'
      : 'Edit this MCore project. Reply with only the full modified project, as JSON in the MCJ format described below.');
  b.writeln();
  b.writeln(buildAgentGuide(level: level));
  // the fonts this phone has (used before or added): a text may take one.
  if (fonts.isNotEmpty) {
    b.writeln();
    b.writeln('## Fonts');
    b.writeln('A text may set `"font"` to one of these ids (anything else keeps the default):');
    for (final e in fonts.entries) {
      b.writeln('- `${e.key}`: ${e.value}');
    }
  }
  if (current != null) {
    b.writeln();
    b.writeln('## The current project');
    b.writeln('```json');
    b.writeln(const JsonEncoder.withIndent(' ').convert(current));
    b.writeln('```');
  }
  b.writeln();
  b.writeln('## What I want');
  b.writeln(request.trim().isEmpty ? '(describe it here)' : request.trim());
  return b.toString();
}
