/// Whole-layer edits used by the timeline's layer action row and the
/// Layers tab: split at a frame, replace the content, and the parameter
/// snapshot shared by copy/paste parameters and presets.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/interpolation.dart';
import '../geometry/shapes.dart';
import '../ui_geometry/keyframe_strip.dart';
import 'project.dart';
import 'effect_panel.dart' show motionPanelIds;
import 'project_json.dart';
import 'layer_names.dart' show nextSplitPieceName;
import 'timeline_rows.dart' show newTimelineRowId;

/// Splits `layer` at `globalFrame` into two layers side by side. The
/// original keeps [start, cut); the returned right part (id `newId`,
/// inserted right after it) covers [cut, end). Every animated track
/// gets a key at the cut on both sides holding the value there, so the
/// animation is continuous across the cut. Returns null if the frame
/// isn't strictly inside the layer.
Layer? splitLayer(Project project, Layer layer, int globalFrame, String newId) {
  final s = globalFrame - layer.startFrame;
  if (s <= 0 || s >= layer.durationFrames) return null;

  // the two halves stay in one timeline row (a cut clip keeps its row).
  layer.rowId ??= newTimelineRowId();
  // pieces of one layer are numbered in order: rect_1, rect_1_2,
  // rect_1_3 ... (never rect_1_2_2), taking the first free number.
  final root = layer.splitRoot ??= layer.name;
  final right = cloneLayer(layer)
    ..id = newId
    ..name = nextSplitPieceName(project, root)
    ..startFrame = globalFrame
    ..durationFrames = layer.durationFrames - s;
  // video / audio: the right half continues the clip from the cut.
  if (isTimedMedia(right.content.shape)) right.content.sourceIn += s / fps;
  // effect instance ids only have to be unique per layer - the clone's
  // copies are fine as they are.

  // left part: keep keys up to the cut, pin the value at the cut.
  visitLayerTracks(layer, (trk) {
    if (trk.keyframes.isEmpty) return;
    _splitLeft(trk, s, _copy(evaluateTrackOwn(project, trk, s.toDouble(), layer)));
  });

  // right part: shift keys left by the cut, pin the value at its start.
  // Its tracks were cloned before the left part was cut, so the values at
  // the cut are evaluated on the untouched original (the clone).
  final rightTracks = <Track>[];
  visitLayerTracks(right, rightTracks.add);
  for (final trk in rightTracks) {
    if (trk.keyframes.isEmpty) continue;
    _splitRight(trk, s, _copy(evaluateTrackOwn(project, trk, s.toDouble(), right)));
  }

  layer.durationFrames = s;
  // a loop belongs to the end of the clip: the right part keeps it.
  layer.loopEnabled = false;
  project.layers.insert(project.layers.indexOf(layer) + 1, right);
  return right;
}

dynamic _copy(dynamic v) => v is List ? List<double>.from(v) : v;

bool _loops(Track trk) => trk.loop && trk.keyframes.length >= 2 && trk.keyframes.last.frame > trk.keyframes.first.frame;

/// The part before the cut at local frame `s` (`value`: the track's own
/// value there). A key at the cut only where keys lie on both sides.
void _splitLeft(Track trk, int s, dynamic value) {
  final ks = trk.keyframes;
  // a loop: everything before the cut stays exactly as it was.
  if (_loops(trk)) return;
  if (ks.every((k) => k.frame < s)) return;
  if (ks.every((k) => k.frame >= s)) {
    // not started yet: it holds its first value - no keys to show.
    trk.keyframes = [];
    trk.defaultValue = value;
    return;
  }
  final before = ks.where((k) => k.frame < s).toList();
  trk.keyframes.removeWhere((k) => k.frame >= s);
  trk.keyframes.add(Keyframe(frame: s, value: value, temporal: before.last.temporal));
  if (trk.spatial) autoComputeTangents(trk);
}

/// The part from the cut on, its keys moved to start at 0.
void _splitRight(Track trk, int s, dynamic value) {
  final ks = trk.keyframes;
  if (_loops(trk)) {
    // a loop goes on in step: the keys move by whole passes, so the
    // part starts mid-pass exactly where the original was (an offset
    // loop's values go on from the passes already made).
    final f = ks.first.frame, period = ks.last.frame - f;
    final n = s > f ? ((s - f) / period).floor() : 0;
    final delta = trk.loopMode == 'offset' ? residualValue(ks.last.value, ks.first.value, false) : null;
    for (final k in ks) {
      k.frame += n * period - s;
      if (delta != null && n > 0) {
        k.value = combineValues(_copy(k.value), delta is List ? [for (final d in delta) d * n] : delta * n, false);
      }
    }
    return;
  }
  if (ks.every((k) => k.frame <= s)) {
    // already over: it holds where it ended - no keys left to show.
    trk.keyframes = [];
    trk.defaultValue = value;
    return;
  }
  if (ks.every((k) => k.frame > s)) {
    for (final k in ks) {
      k.frame -= s;
    }
    return;
  }
  final before = ks.where((k) => k.frame <= s).toList();
  trk.keyframes.removeWhere((k) => k.frame <= s);
  for (final k in trk.keyframes) {
    k.frame -= s;
  }
  trk.keyframes.insert(0, Keyframe(frame: 0, value: value, temporal: before.last.temporal));
  if (trk.spatial) autoComputeTangents(trk);
}

/// Swaps the layer's content for `replacement`, keeping every parameter.
/// The new content takes the old one's place (offset) and is fitted to
/// the old bounding box: a shape takes the box's size, an image keeps its
/// own aspect ratio inside it.
void replaceLayerContent(Layer layer, Content replacement) {
  final box = shapeBoundingBox(layer.content);
  final w = math.max(1.0, box.maxX - box.minX), h = math.max(1.0, box.maxY - box.minY);
  final cx = (box.minX + box.maxX) / 2, cy = (box.minY + box.maxY) / 2;
  final c = replacement;
  if ((c.shape == 'image' || c.shape == 'video') &&
      (c.imageNaturalWidth ?? 0) > 0 &&
      (c.imageNaturalHeight ?? 0) > 0) {
    final k = math.min(w / c.imageNaturalWidth!, h / c.imageNaturalHeight!);
    c.size = [c.imageNaturalWidth! * k, c.imageNaturalHeight! * k];
    c.offset = [cx, cy];
  } else if (c.shape == 'polygon' && c.points != null && c.points!.isNotEmpty) {
    final src = shapeBoundingBox(c);
    final sw = math.max(1e-9, src.maxX - src.minX), sh = math.max(1e-9, src.maxY - src.minY);
    final scx = (src.minX + src.maxX) / 2, scy = (src.minY + src.maxY) / 2;
    c.points = [
      for (final p in c.points!) [cx + (p[0] - scx) * w / sw, cy + (p[1] - scy) * h / sh]
    ];
    c.offset = [0, 0];
    c.size = [w, h];
  } else {
    c.size = [w, h];
    c.offset = [cx, cy];
  }
  layer.content = c;
}

// ===== parameter snapshot (copy/paste parameters, presets) =====

/// Everything about a layer except its identity, its place in time and
/// its shape/media: movement (all transform tracks with their keys), the
/// content's offset, masks, effects, motion blur, wiggle, pendulum,
/// color and render mode (shapes only), crop and mirror. Plain JSON, so it can be kept in
/// a clipboard or a file and applied to any layer in any project.
Map<String, dynamic> layerParamsToJson(Layer l) =>
    jsonDecode(jsonEncode({
      'transform': transformToJson(l.transform),
      'contentOffset': l.content.offset,
      'masks': l.masks.map(maskToJson).toList(),
      'edgeMatte': {'on': l.edgeMatte, 'color': l.edgeMatteColor, 'strength': l.edgeMatteStrength},
      'effectStack': l.effectStack.map(effectInstanceToJson).toList(),
      'effectRanges': l.effectRanges,
      // colour/render mode mean nothing for media - a snapshot taken from an
      // image layer must not recolour the shape it's applied to
      if (!isMediaShape(l.content.shape)) 'color': l.color,
      if (!isMediaShape(l.content.shape)) 'renderMode': l.renderMode,
      if (!isMediaShape(l.content.shape)) 'fill': shapeFillToJson(l.fill),
      'motionBlur': motionBlurToJson(l.motionBlur),
      'wiggle': wiggleToJson(l.wiggle),
      'pendulum': pendulumToJson(l.pendulum),
      'timeQuantize': timeQuantizeToJson(l.timeQuantize),
      'swing': swingToJson(l.swing),
      // keying only means something for an image.
      if (chromaCapable(l.content.shape)) 'chromaKey': chromaKeyToJson(l.chromaKey),
      'crop': l.crop,
      'cropAspect': l.cropAspect,
      'mirrorX': l.mirrorX,
      'mirrorY': l.mirrorY,
    })) as Map<String, dynamic>;

int _paramsPasteCounter = 0;

/// Applies a `layerParamsToJson` snapshot to `target`. References to other
/// layers (mask sources, path-follow source) that don't exist in
/// `project` - e.g. a preset made in another project - are dropped;
/// effect instances get fresh ids.
void applyLayerParamsJson(Project project, Layer target, Map<String, dynamic> j) {
  // work on a private copy so the snapshot can be applied again later.
  final p = jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
  bool known(String? id) => id != null && id != target.id && findLayer(project, id) != null;

  final t = transformFromJson(p['transform'] as Map<String, dynamic>);
  if (!known(t.pathFollow.sourceLayerId)) {
    t.pathFollow.sourceLayerId = null;
    t.pathFollow.enabled = false;
  }
  target.transform = t;
  final offset = p['contentOffset'] as List?;
  if (offset != null) {
    target.content.offset = [for (final v in offset) (v as num).toDouble()];
  }
  target.masks = [
    for (final m in (p['masks'] as List? ?? const []))
      maskFromJson(m as Map<String, dynamic>)
  ];
  for (final m in target.masks) {
    if (!known(m.sourceLayerId)) m.sourceLayerId = null;
  }
  final matte = p['edgeMatte'] as Map?;
  if (matte != null) {
    target
      ..edgeMatte = matte['on'] as bool? ?? false
      ..edgeMatteColor = matte['color'] as String? ?? '#000000'
      ..edgeMatteStrength = (matte['strength'] as num?)?.toDouble() ?? 1;
  }
  final stamp = DateTime.now().microsecondsSinceEpoch;
  target.effectStack = [
    for (final e in (p['effectStack'] as List? ?? const []))
      effectInstanceFromJson(e as Map<String, dynamic>)
  ];
  // the time ranges follow the effects to their new ids.
  final ranges = effectRangesFromJson(p['effectRanges']);
  target.effectRanges = {
    for (final e in ranges.entries)
      if (motionPanelIds.contains(e.key)) e.key: e.value,
  };
  for (final inst in target.effectStack) {
    final old = inst.id;
    inst.id = 'fx_${stamp}_${_paramsPasteCounter++}';
    if (ranges[old] != null) target.effectRanges[inst.id] = ranges[old]!;
  }
  if (p.containsKey('color')) target.color = p['color'] as String?;
  if (p.containsKey('renderMode')) target.renderMode = p['renderMode'] as String? ?? 'fill';
  if (p['fill'] != null && !isMediaShape(target.content.shape)) {
    target.fill = shapeFillFromJson(p['fill'] as Map<String, dynamic>);
  }
  if (p['motionBlur'] != null) {
    target.motionBlur = motionBlurFromJson(p['motionBlur'] as Map<String, dynamic>);
  }
  if (p['wiggle'] != null) {
    target.wiggle = wiggleFromJson(p['wiggle'] as Map<String, dynamic>);
  }
  if (p['pendulum'] != null) {
    target.pendulum = pendulumFromJson(p['pendulum'] as Map<String, dynamic>);
  }
  if (p['swing'] != null) target.swing = swingFromJson(p['swing'] as Map<String, dynamic>);
  target.timeQuantize = p['timeQuantize'] != null
      ? timeQuantizeFromJson(p['timeQuantize'] as Map<String, dynamic>)
      : TimeQuantize();
  if (p['chromaKey'] != null && chromaCapable(target.content.shape)) {
    target.chromaKey = chromaKeyFromJson(p['chromaKey'] as Map<String, dynamic>);
  }
  final crop = p['crop'] as List?;
  target.crop = crop == null
      ? [0.0, 0.0, 0.0, 0.0]
      : [for (final v in crop) (v as num).toDouble()];
  target.cropAspect = p['cropAspect'] as String? ?? 'free';
  target.mirrorX = p['mirrorX'] as bool? ?? false;
  target.mirrorY = p['mirrorY'] as bool? ?? false;
}
