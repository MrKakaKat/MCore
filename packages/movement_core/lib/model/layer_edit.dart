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
  if (isTimedMedia(right.content.shape)) right.content.sourceIn += s / fps * right.content.mediaSpeed;
  // effect instance ids only have to be unique per layer - the clone's
  // copies are fine as they are.

  // left part: keep keys up to the cut, pin the value at the cut.
  // animation layers' tracks: nothing before their first key.
  final layered = <Track>{
    for (final t in [layer.transform.anchor, layer.transform.rotation, layer.transform.scale, layer.transform.opacity])
      for (final a in t.animLayers) a.track
  };
  visitLayerTracks(layer, (trk) {
    if (trk.keyframes.isEmpty) return;
    _splitLeft(trk, s, _copy(evaluateTrackOwn(project, trk, s.toDouble(), layer)), layered: layered.contains(trk));
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
  joinPieceToGroup(project, layer, right);
  _retargetToPiece(project, layer, right);
  return right;
}

/// The piece that comes right after `layer` in time, on its timeline
/// row, that it can be joined with (see joinLayers) - null when none.
Layer? nextJoinable(Project project, Layer layer) {
  final end = layer.startFrame + layer.durationFrames;
  Layer? best;
  for (final l in project.layers) {
    if (identical(l, layer) || l.startFrame < end) continue;
    if ((l.rowId ?? l.id) != (layer.rowId ?? layer.id)) continue;
    if (best == null || l.startFrame < best.startFrame) best = l;
  }
  if (best == null || joinBlocker(layer, best) != null) return null;
  return best;
}

/// Why `a` and the later `b` can't be joined into one layer, or null.
/// They must show the same thing (pieces of one layer, a video going on
/// where it stopped) and be built alike.
String? joinBlocker(Layer a, Layer b) {
  if (b.startFrame < a.startFrame + a.durationFrames) return 'They overlap in time';
  final ca = contentToJson(a.content), cb = contentToJson(b.content);
  if (isTimedMedia(a.content.shape)) {
    final gap = (b.startFrame - a.startFrame) / fps * a.content.mediaSpeed;
    if ((b.content.sourceIn - (a.content.sourceIn + gap)).abs() > 0.5 / fps) return 'The clip does not go on there';
    ca.remove('sourceIn');
    cb.remove('sourceIn');
  }
  if (jsonEncode(ca) != jsonEncode(cb)) return 'They show different things';
  var na = 0, nb = 0;
  var loops = false;
  visitLayerTracks(a, (t) {
    na++;
    loops |= t.loop;
  });
  visitLayerTracks(b, (t) {
    nb++;
    loops |= t.loop;
  });
  if (na != nb) return 'They are built differently';
  if (loops) return 'A looping track can\'t be joined';
  return null;
}

/// Joins `b` (later on the timeline) onto `a`: one layer from a's start
/// to b's end, moving as the two did - a's keys, then b's, the value
/// jumping where b began (a border). Layers tied to b are tied to a.
/// Returns false (nothing changed) when they can't be joined.
bool joinLayers(Project project, Layer a, Layer b) {
  if (joinBlocker(a, b) != null) return false;
  final j = b.startFrame - a.startFrame;
  final ta = <Track>[], tb = <Track>[];
  visitLayerTracks(a, ta.add);
  visitLayerTracks(b, tb.add);
  const jump = Easing(0, 0, 1, 1, hold: true);
  final values = [
    for (var i = 0; i < ta.length; i++)
      (
        _copy(evaluateTrackOwn(project, ta[i], (j - 1).toDouble(), a)),
        _copy(evaluateTrackOwn(project, tb[i], 0, b)),
      )
  ];
  for (var i = 0; i < ta.length; i++) {
    final x = ta[i], y = tb[i];
    if (x.keyframes.isEmpty && y.keyframes.isEmpty && jsonEncode(values[i].$1) == jsonEncode(values[i].$2)) continue;
    final (va, vb) = values[i];
    final keep = [for (final k in x.keyframes) if (k.frame < j - 1) k];
    final next = x.keyframes.where((k) => k.frame >= j - 1).firstOrNull;
    final way = next == null ? easingPresets['linear']! : (next.frame == j - 1 ? next.temporal : (keep.isEmpty ? next.temporal : keep.last.temporal).withHold(false));
    x.keyframes = [
      ...keep,
      if (keep.isEmpty && j - 1 > 0) Keyframe(frame: 0, value: _copy(va)),
      Keyframe(frame: j - 1, value: va, temporal: way),
      Keyframe(frame: j, value: vb, temporal: jump),
      for (final k in y.keyframes)
        if (k.frame > 0) k..frame += j,
    ];
    if (x.spatial) autoComputeTangents(x);
  }
  a.durationFrames = j + b.durationFrames;
  a.loopEnabled = b.loopEnabled;
  // what was tied to b goes with a now.
  for (final l in project.layers) {
    if (identical(l, b)) continue;
    _swapRefs(l, b.id, a.id);
  }
  project.layers.remove(b);
  return true;
}

/// Every tie of `l` to layer `from` (parent, masks, cuts, mattes, links,
/// matches, effects tied to its time...) moved to layer `to`.
void swapLayerRefs(Layer l, String from, String to) => _swapRefs(l, from, to);

/// `piece` (cut out of `layer`) joins the group `layer` is in, right
/// after it - a group lists its members.
void joinPieceToGroup(Project project, Layer layer, Layer piece) {
  final g = findLayer(project, layer.parentId)?.groupedChildren;
  if (g == null || g.contains(piece.id)) return;
  final i = g.indexOf(layer.id);
  g.insert(i < 0 ? g.length : i + 1, piece.id);
}

void _swapRefs(Layer l, String from, String to) {
  String? swap(String? id) => id == from ? to : id;
  l.parentId = swap(l.parentId);
  l.mirrorSourceId = swap(l.mirrorSourceId);
  l.backSourceId = swap(l.backSourceId);
  l.filters.matteLayerId = swap(l.filters.matteLayerId);
  l.follow.targetId = swap(l.follow.targetId);
  final pf = l.transform.pathFollow;
  pf.sourceLayerId = swap(pf.sourceLayerId);
  for (final m in l.masks) {
    m.sourceLayerId = swap(m.sourceLayerId);
    for (var i = 0; i < m.moreSources.length; i++) {
      if (m.moreSources[i] == from) m.moreSources[i] = to;
    }
  }
  for (final c in l.cuts) {
    c.cutterId = swap(c.cutterId);
  }
  for (final k in l.links) {
    k.sourceId = swap(k.sourceId);
  }
  for (final m in l.filters.matches) {
    m.targetLayerId = swap(m.targetLayerId);
  }
  for (final e in l.effectBinds.entries.toList()) {
    if (e.value == from) l.effectBinds[e.key] = to;
  }
}

/// Layers tied to the cut layer (its children, masks and cuts by it,
/// followers, links, mirrors...) that live in the part after the cut are
/// tied to that part now: they stayed on the first one, which had ended
/// where they are - the tie came off.
void _retargetToPiece(Project project, Layer left, Layer right) {
  final from = left.id, to = right.id;
  final cut = right.startFrame;
  bool after(Layer l) {
    final s = l.startFrame, e = l.startFrame + l.durationFrames;
    final before = (cut < e ? cut : e) - s;
    final past = e - (cut > s ? cut : s);
    return past > 0 && past >= before;
  }

  for (final l in project.layers) {
    if (identical(l, left) || identical(l, right) || !after(l)) continue;
    _swapRefs(l, from, to);
  }
}

dynamic _copy(dynamic v) => v is List ? List<double>.from(v) : v;

bool _loops(Track trk) => trk.loop && trk.keyframes.length >= 2 && trk.keyframes.last.frame > trk.keyframes.first.frame;

/// The part before the cut at local frame `s` (`value`: the track's own
/// value there). A key at the cut only where keys lie on both sides.
void _splitLeft(Track trk, int s, dynamic value, {bool layered = false}) {
  final ks = trk.keyframes;
  // a loop: everything before the cut stays exactly as it was.
  if (_loops(trk)) return;
  if (ks.every((k) => k.frame < s)) return;
  if (ks.every((k) => k.frame >= s)) {
    // not started yet: it holds its first value - no keys to show (an
    // animation layer's does nothing yet: its plain value stays).
    trk.keyframes = [];
    if (!layered) trk.defaultValue = value;
    return;
  }
  // the way into the cut is the way into the key after it (a border
  // there: the value stays as it is up to the cut).
  final next = ks.firstWhere((k) => k.frame >= s);
  final last = ks.lastWhere((k) => k.frame < s);
  final way = next.frame == s && next.temporal.hold ? next.temporal : last.temporal.withHold(false);
  trk.keyframes.removeWhere((k) => k.frame >= s);
  trk.keyframes.add(Keyframe(frame: s, value: value, temporal: way));
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
  // (nothing comes into it: never a border - that is the key's own way in.)
  trk.keyframes.insert(0, Keyframe(frame: 0, value: value, temporal: before.last.temporal.withHold(false)));
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
