/// Which contour a layer has: vector content (shapes, compound paths,
/// text) has its exact geometry, in content-local space; raster content
/// (images, video, GIF) has none here - the app extracts it from pixels.
library;

import 'dart:convert';

import '../core/interpolation.dart' show evaluateTrack;
import '../core/math.dart' show applyAffine, invertAffine;
import '../core/stage_size.dart';
import '../core/state_cache.dart' show getLayerStateAt;
import '../model/project.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;
import 'polygon_boolean.dart';
import 'region_episodes.dart' show regionEpisodes, regionOpacityAt, RegionBake;
import '../model/line_path.dart' show isNodeLine, lineOutlineRings;
import '../text/open_type_font.dart' show flattenPath;
import '../text/text_layout.dart' show layoutText;
import '../text/text_animators.dart' show animatedTextPath, textPartCmds;
import 'shapes.dart';

/// The layer's vector outline rings (content-local), or null for raster
/// content (and for content with nothing to outline: null points, sound,
/// the camera). Shapes give their outline AFTER their own deforming
/// effects, so the stroke bends with them.
List<List<List<double>>>? layerVectorRings(Project project, Layer layer, int globalFrame) {
  final base = layerBaseRings(project, layer, globalFrame);
  if (base == null) return null;
  return _withMasksAndCuts(project, layer, globalFrame, base);
}

/// The layer's own outline, before its masks and cuts.
List<List<List<double>>>? layerBaseRings(Project project, Layer layer, int globalFrame) {
  final c = layer.content;
  // a line: the band it draws, not its box.
  if (isNodeLine(c)) return lineOutlineRings(c, frame: layerLocalFrame(layer, globalFrame));
  if (isMediaShape(c.shape) || isAudioShape(c.shape) || isCameraShape(c.shape) || c.shape == 'null') return null;
  if (c.shape == 'text') {
    final t = c.text;
    if (t == null) return null;
    final lf = layerLocalFrame(layer, globalFrame);
    final shown = t.atFrame(lf);
    // animated letters: the outline of what is drawn.
    return flattenPath(animatedTextPath(shown, c.offset, c.size, lf) ?? layoutText(shown, c.offset, c.size).path);
  }
  if (c.shape == 'compound') return [for (final r in c.contours ?? const <List<List<double>>>[]) if (r.length >= 3) r];
  // origami: its folded pieces (a single folded outline can cancel itself).
  final pieces = origamiRingPieces(layer, layerFlatOutline(layer, globalFrame: globalFrame, project: project), globalFrame,
      project: project);
  if (pieces != null) return pieces;
  final ring = getContentOutline(c, layer, globalFrame, project: project);
  return ring.length >= 3 ? [ring] : const [];
}

/// Whether the layer's contour comes from pixels (the app's job).
bool hasRasterContour(Layer layer) => isMediaShape(layer.content.shape);


// ===== masks and Cut by layer, as exact vector booleans =====

/// "Everything" for the mask logic: a box just past all of `sets` (the
/// layer and its sources). A huge box (1e6) lost precision in the
/// booleans - masks that start full (Equivalence...) came and went.
List<List<List<double>>> _universe(Iterable<List<List<List<double>>>> sets) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final rings in sets) {
    for (final r in rings) {
      for (final p in r) {
        if (p[0] < x0) x0 = p[0];
        if (p[0] > x1) x1 = p[0];
        if (p[1] < y0) y0 = p[1];
        if (p[1] > y1) y1 = p[1];
      }
    }
  }
  if (!x0.isFinite) return const [];
  const m = 16.0;
  return [
    [
      [x0 - m, y0 - m],
      [x1 + m, y0 - m],
      [x1 + m, y1 + m],
      [x0 - m, y1 + m]
    ]
  ];
}

/// The masks' region (frame px) from the world sources (null: none),
/// inside `everything`.
/// What a layer's mask stack lets show, in the layer's own space (null:
/// no vector masks - nothing to clip; empty: nothing shows). For text,
/// whose letters aren't an outline here (SVG clips them with it).
List<List<List<double>>>? layerMaskClipLocal(Project project, Layer layer, int globalFrame) {
  final lf = layerLocalFrame(layer, globalFrame);
  final masks = [for (final m in layer.masks) if (m.enabled && m.activeAt(lf) && m.sourceLayerId != null) m];
  if (masks.isEmpty) return null;
  final srcs = <List<List<List<double>>>>[];
  for (final mk in masks) {
    final r = maskSourceRings(project, mk, globalFrame);
    if (r == null) return null; // a picture source: not a vector clip
    srcs.add(r);
  }
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  final box = [
    [-1e5, -1e5], [1e5, -1e5], [1e5, 1e5], [-1e5, 1e5]
  ];
  final world = _map([box], m);
  final region = _maskRegion(masks, srcs, _universe([world, ...srcs]));
  return _map(region, invertAffine(m));
}

List<List<List<double>>> _maskRegion(
    List<Mask> masks, List<List<List<List<double>>>> sources, List<List<List<double>>> everything,
    [void Function(int i, List<List<List<double>>> before, List<List<List<double>>> after)? step]) {
  List<List<List<double>>> not(List<List<List<double>>> r) =>
      r.isEmpty ? everything : polygonBoolean(everything, r, BoolOp.subtract);
  List<List<List<double>>>? region;
  for (var i = 0; i < masks.length; i++) {
    final src = masks[i].invert ? not(sources[i]) : sources[i];
    final before = region ?? (maskStartsFull(masks[i].mode) ? everything : const <List<List<double>>>[]);
    final after = switch (masks[i].mode) {
      'subtract' => before.isEmpty ? before : polygonBoolean(before, src, BoolOp.subtract),
      'intersect' => before.isEmpty || src.isEmpty ? const <List<List<double>>>[] : polygonBoolean(before, src, BoolOp.intersect),
      'exclude' => before.isEmpty ? src : (src.isEmpty ? before : polygonBoolean(before, src, BoolOp.exclude)),
      'implication' => src.isEmpty ? not(before) : polygonBoolean(not(before), src, BoolOp.union),
      'equivalence' => not(before.isEmpty ? src : (src.isEmpty ? before : polygonBoolean(before, src, BoolOp.exclude))),
      _ => before.isEmpty ? src : (src.isEmpty ? before : polygonBoolean(before, src, BoolOp.union)),
    };
    step?.call(i, before, after);
    region = after;
  }
  return region ?? const [];
}

final Map<String, List<List<List<double>>>> _cutCache = {};
final Set<String> _cutBusy = {};

/// Forgets the cut results (tests; a new project).
void clearCutCaches() => _cutCache.clear();

/// Whether `layer` cutting with `cutterId` would make layers cut each
/// other in a circle (or cut itself).
bool cutWouldCycle(Project project, Layer layer, String cutterId) {
  final seen = <String>{};
  bool reaches(String id) {
    if (id == layer.id) return true;
    if (!seen.add(id)) return false;
    final l = findLayer(project, id);
    if (l == null) return false;
    for (final c in l.cuts) {
      if (c.cutterId != null && reaches(c.cutterId!)) return true;
    }
    return false;
  }

  return reaches(cutterId);
}

const cutCycleMessage = 'This would make layers cut each other in a circle';

/// The layers some enabled cut hides (Hide cutter).
Set<String> hiddenCutters(Project project) => {
      for (final l in project.layers)
        for (final c in l.cuts)
          if (c.enabled && c.hideCutter && c.cutterId != null) c.cutterId!
    };

/// Whether the layer's outline is changed by masks or cuts (the fill is
/// then clipped to it).
bool layerHasCuts(Layer layer) => layer.cuts.any((c) => c.enabled && c.cutterId != null);

BoolOp _op(String mode) => switch (mode) {
      'intersect' => BoolOp.intersect,
      'union' => BoolOp.union,
      'exclude' => BoolOp.exclude,
      _ => BoolOp.subtract,
    };

OffsetJoin _join(String j) => switch (j) {
      'round' => OffsetJoin.round,
      'bevel' => OffsetJoin.bevel,
      _ => OffsetJoin.miter,
    };

List<List<List<double>>> _map(List<List<List<double>>> rings, List<double> m) => [
      for (final r in rings) [for (final p in r) applyAffine(m, p)]
    ];

/// A layer's rings in frame px (its outline after its own cuts), or null
/// when it has no vector outline.
/// A mask's shape in frame space: all its sources together (null when
/// one of them is a picture - drawn, not outlined).
List<List<List<double>>>? maskSourceRings(Project project, Mask mk, int globalFrame) {
  List<List<List<double>>>? all;
  for (final id in mk.sourceIds) {
    final src = findLayer(project, id);
    if (src == null) continue;
    // one part of a text.
    final t = src.content.text;
    final r = mk.sourcePart != null && id == mk.sourceLayerId && t != null
        ? _map(
            flattenPath(textPartCmds(t.atFrame(layerLocalFrame(src, globalFrame)), src.content.offset, src.content.size,
                layerLocalFrame(src, globalFrame), mk.sourcePart!)),
            toFrameMatrix(getLayerStateAt(project, src.id, globalFrame).matrix))
        : _worldRings(project, src, globalFrame);
    if (r == null) return null;
    all = all == null ? r : polygonBoolean(all, r, BoolOp.union);
  }
  return all;
}

List<List<List<double>>>? _worldRings(Project project, Layer layer, int globalFrame) {
  final r = layerVectorRings(project, layer, globalFrame);
  if (r == null) return null;
  return _map(r, toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix));
}

List<List<List<double>>> _withMasksAndCuts(
    Project project, Layer layer, int globalFrame, List<List<List<double>>> base) {
  final lf = layerLocalFrame(layer, globalFrame);
  // (a shape's own mask regions don't change it as a source of regions.)
  final regionsOn = _noRegions == 0 &&
      layer.maskRegions != null &&
      layer.maskRegions!.enabled &&
      layer.maskRegions!.sources.isNotEmpty;
  final masks = regionsOn
      ? <Mask>[]
      : [for (final m in layer.masks) if (m.enabled && m.activeAt(lf) && m.sourceLayerId != null) m];
  final cuts = [for (final c in layer.cuts) if (c.enabled && c.cutterId != null) c];
  if (masks.isEmpty && cuts.isEmpty && !regionsOn) return base;
  final key = '${identityHashCode(project)}|${layer.id}';
  // a circle (refused when picked; a restore could bring one): as is.
  if (!_cutBusy.add(key)) return base;
  try {
    final m = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
    var world = _map(base, m);
    // the masks with vector sources: the outline follows them (a picture
    // source stays a picture mask, drawn only).
    final sources = <List<List<List<double>>>?>[for (final mk in masks) maskSourceRings(project, mk, globalFrame)];
    if (masks.isNotEmpty && sources.every((s) => s != null)) {
      final srcs = [for (final s in sources) s!];
      final k0 = jsonEncode(['r', world, srcs, [for (final mk in masks) '${mk.mode}${mk.invert}']]);
      final region = _cutCache[k0] ??= _maskRegion(masks, srcs, _universe([world, ...srcs]));
      final k = jsonEncode(['m', world, region]);
      world = _cutCache[k] ??= polygonBoolean(world, region, BoolOp.intersect);
    }
    // mask regions instead of the stack: what the shown regions cover.
    if (regionsOn) {
      final shown = maskRegionsShown(project, layer, globalFrame);
      if (shown != null) world = shown.isEmpty ? const [] : polygonBoolean(world, shown, BoolOp.intersect);
    }
    for (final c in cuts) {
      final cutter = findLayer(project, c.cutterId);
      if (cutter == null || identical(cutter, layer)) continue;
      final cw = _worldRings(project, cutter, globalFrame);
      if (cw == null) continue; // a picture can't cut (yet)
      // only while they touch: the cutter itself (grown by a hair, so an
      // edge-on touch counts) must overlap this layer.
      if (c.onlyWhenTouching) {
        final tk = jsonEncode(['t', world, cw]);
        final touching = _cutCache[tk] ??=
            polygonBoolean(world, offsetRings(cw, 0.5), BoolOp.intersect).isEmpty ? const [] : [const []];
        if (touching.isEmpty) continue;
      }
      final gap = (evaluateTrack(project, c.gap, lf, layer) as num).toDouble();
      final k = jsonEncode([world, cw, gap, c.mode, c.join]);

      final cached = _cutCache[k];
      if (cached != null) {
        world = cached;
        continue;
      }
      if (_cutCache.length > 512) _cutCache.clear();
      final grown = offsetRings(cw, gap, join: _join(c.join));
      world = _cutCache[k] = polygonBoolean(world, grown, _op(c.mode));
    }
    return _map(world, invertAffine(m));
  } finally {
    _cutBusy.remove(key);
  }
}


/// One mask's effect, for showing it on the stage (frame px): the parts
/// of the layer it lets through that weren't before, the parts it hides
/// that were shown, and its source's own outline. Neither: it changes
/// nothing here (covered by the masks before it). A picture source has
/// no outline here: `raster`, with only where its layer is (`at`).
class MaskStep {
  final int index;
  final List<List<List<double>>> gained;
  final List<List<List<double>>> lost;
  final List<List<List<double>>> source;
  final bool raster;
  final List<double>? at;
  MaskStep(this.index, this.gained, this.lost, this.source, {this.raster = false, this.at});
  bool get unchanged => !raster && gained.isEmpty && lost.isEmpty;
}

double _ringsArea(List<List<List<double>>> rings) {
  var a = 0.0;
  for (final r in rings) {
    var s = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      s += p[0] * q[1] - q[0] * p[1];
    }
    a += s / 2;
  }
  return a.abs();
}

final Map<String, List<MaskStep>> _stepCache = {};

/// Each enabled mask of `layer` and what it does, in order, within the
/// layer's own outline. Kept for the same shapes, modes and frame, so the
/// stage doesn't redo the booleans on every repaint.
List<MaskStep> maskSteps(Project project, Layer layer, int globalFrame) {
  final base = layerBaseRings(project, layer, globalFrame);
  if (base == null) return const [];
  final lf = layerLocalFrame(layer, globalFrame);
  final shape = _map(base, toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix));
  final masks = <Mask>[], idx = <int>[], srcs = <List<List<List<double>>>>[];
  final raster = <MaskStep>[];
  for (var i = 0; i < layer.masks.length; i++) {
    final mk = layer.masks[i];
    if (!mk.enabled || !mk.activeAt(lf) || mk.sourceLayerId == null) continue;
    final srcLayer = findLayer(project, mk.sourceLayerId);
    if (srcLayer == null) continue;
    final r = maskSourceRings(project, mk, globalFrame);
    if (r == null) {
      final m = getLayerStateAt(project, srcLayer.id, globalFrame).matrix;
      raster.add(MaskStep(i, const [], const [], const [],
          raster: true, at: [m[4] * stageSize.width, m[5] * stageSize.height]));
      continue;
    }
    masks.add(mk);
    idx.add(i);
    srcs.add(r);
  }
  final key = jsonEncode([shape, srcs, idx, [for (final mk in masks) '${mk.mode}${mk.invert}']]);
  final cached = _stepCache[key];
  if (cached != null) return [...cached, ...raster];
  final everything = _universe([shape, ...srcs]);
  List<List<List<double>>> clip(List<List<List<double>>> r) =>
      r.isEmpty ? const [] : polygonBoolean(r, shape, BoolOp.intersect);
  final out = <MaskStep>[];
  _maskRegion(masks, srcs, everything, (i, before, after) {
    var gained = clip(after.isEmpty ? after : (before.isEmpty ? after : polygonBoolean(after, before, BoolOp.subtract)));
    var lost = clip(before.isEmpty ? before : (after.isEmpty ? before : polygonBoolean(before, after, BoolOp.subtract)));
    if (_ringsArea(gained) < 1) gained = const [];
    if (_ringsArea(lost) < 1) lost = const [];
    out.add(MaskStep(idx[i], gained, lost, srcs[i]));
  });
  if (_stepCache.length > 64) _stepCache.clear();
  _stepCache[key] = out;
  return [...out, ...raster];
}


// ===== mask regions (signatures) =====

/// One region of a layer's mask regions, in frame px: where exactly the
/// sources of `sig` are (and none of the others). `exists`: it has area on
/// this frame.
class MaskRegion {
  final int sig;
  final List<List<List<double>>> rings;
  final bool exists;
  MaskRegion(this.sig, this.rings, this.exists);
}

final Map<String, List<MaskRegion>> _regionCache = {};

/// While > 0: shapes are taken without their own mask regions (a source's
/// shape is the shape, whatever it shows - and A and B each splitting the
/// other mustn't go round in circles).
int _noRegions = 0;

/// A source's outline as a shape of regions (frame px): its own cuts and
/// masks, not its own regions. Null: no outline (a picture) or missing.
List<List<List<double>>>? regionSourceRings(Project project, String id, int globalFrame) {
  final l = findLayer(project, id);
  if (l == null) return null;
  _noRegions++;
  try {
    return _worldRings(project, l, globalFrame);
  } finally {
    _noRegions--;
  }
}

/// The cells of the sources `ids` (2^N, bit i: inside source i) at the
/// frame, inside a box just past them (and `extra`, e.g. the masked layer's
/// own shape). Null when a source has no outline or is missing. Cached.
List<MaskRegion>? regionCells(Project project, List<String> ids, int globalFrame,
    [List<List<List<double>>> extra = const []]) {
  final srcs = <List<List<List<double>>>>[];
  for (final id in ids) {
    final r = regionSourceRings(project, id, globalFrame);
    if (r == null) return null;
    srcs.add(r);
  }
  final key = jsonEncode([extra, srcs]);
  final cached = _regionCache[key];
  if (cached != null) return cached;
  final everything = _universe([extra, ...srcs]);
  // split source by source: every region in two (inside / outside), an
  // empty one stops there - most of 2^N are empty and cost nothing.
  final rings = List<List<List<List<double>>>>.filled(1 << srcs.length, const []);
  final boxes = [for (final x in srcs) _ringsBox(x)];
  void split(int i, int sig, List<List<List<double>>> r) {
    if (i == srcs.length) {
      rings[sig] = r;
      return;
    }
    if (r.isEmpty) return;
    final s = srcs[i];
    // apart (their boxes don't meet): all of it is outside this source.
    if (s.isEmpty || !_boxesMeet(_ringsBox(r), boxes[i])) {
      split(i + 1, sig, r);
      return;
    }
    split(i + 1, sig | (1 << i), polygonBoolean(r, s, BoolOp.intersect));
    split(i + 1, sig, polygonBoolean(r, s, BoolOp.subtract));
  }

  split(0, 0, everything);
  final out = [
    for (var sig = 0; sig < rings.length; sig++) MaskRegion(sig, rings[sig], _ringsArea(rings[sig]) >= 1)
  ];
  if (_regionCache.length > 4096) _regionCache.clear(); // a whole bake's frames fit
  _regionCache[key] = out;
  return out;
}

/// Every signature's region (2^N) of `layer`'s mask regions at the frame,
/// inside a box just past the layer and its sources. Null when a source
/// has no outline (a picture - its regions are drawn per pixel instead) or
/// is missing. Cached by the shapes.
List<MaskRegion>? maskRegionGeometry(Project project, Layer layer, int globalFrame) {
  final mr = layer.maskRegions;
  if (mr == null) return null;
  final base = layerBaseRings(project, layer, globalFrame) ?? const <List<List<double>>>[];
  final shape = _map(base, toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix));
  return regionCells(project, mr.sources, globalFrame, shape);
}

// ===== ownership: a layer's own regions =====

/// The layer's place among its region sources (it is one of the shapes
/// itself), or null (it is content masked by others' shapes).
int? regionSelfIndex(Layer layer) {
  final i = layer.maskRegions?.sources.indexOf(layer.id) ?? -1;
  return i < 0 ? null : i;
}

/// Whether the layer's Outer (outside every shape) has no pixels of it: a
/// plain shape that is one of the sources. It is listed, but off.
bool regionOuterEmpty(Layer layer) => regionSelfIndex(layer) != null && !isMediaShape(layer.content.shape);

/// The regions the layer owns: every cell where it is (its own bit set,
/// the overlaps first), then Outer (0). A layer that isn't one of the
/// shapes owns every cell.
List<int> ownedRegionSigs(Layer layer) {
  final mr = layer.maskRegions;
  if (mr == null) return const [];
  final k = regionSelfIndex(layer);
  int bits(int s) => s == 0 ? 0 : (s & 1) + bits(s >> 1);
  final all = [for (var s = mr.signatureCount - 1; s >= 0; s--) s]
    ..sort((a, b) => bits(b) != bits(a) ? bits(b).compareTo(bits(a)) : b.compareTo(a));
  if (k == null) return all;
  return [for (final s in all) if ((s >> k) & 1 == 1) s, 0];
}

/// The opacity the layer's pixels in cell `sig` get: its own regions as
/// set; a cell that isn't its own (another shape's ground, where only its
/// outline or shadow may reach) as Outer when Outer has pixels, else as is.
double regionShownOpacity(Project project, Layer layer, RegionBake bake, int sig, int? number, int globalFrame) {
  final k = regionSelfIndex(layer);
  if (k != null && (sig >> k) & 1 == 0) {
    if (regionOuterEmpty(layer)) return 1.0;
    return regionOpacityAt(project, layer, bake, 0, null, globalFrame);
  }
  return regionOpacityAt(project, layer, bake, sig, number, globalFrame);
}

/// What the layer shows through its regions (frame px): every region with
/// opacity above 0, joined - the outline, collisions and cuts follow it.
List<List<List<double>>>? maskRegionsShown(Project project, Layer layer, int globalFrame) {
  final mr = layer.maskRegions;
  final geo = maskRegionGeometry(project, layer, globalFrame);
  if (mr == null || geo == null) return null;
  // with commands: the opacity they leave (see region_episodes.dart).
  final bake = mr.commands.isNotEmpty ? regionEpisodes(project, layer) : RegionBake.empty;
  var shown = <List<List<double>>>[];
  for (final g in geo) {
    if (g.rings.isEmpty) continue;
    if (regionShownOpacity(project, layer, bake, g.sig, null, globalFrame) <= 0) continue;
    shown = shown.isEmpty ? g.rings : polygonBoolean(shown, g.rings, BoolOp.union);
  }
  return shown;
}

/// The region opacities (0 or 1 per signature) that give exactly what a
/// mask stack gives: step i works with source i (its mode and invert),
/// in order - the same logic as the stack (see _maskRegion).
Map<int, double> regionPresetFromStack(List<({String mode, bool invert})> steps) {
  final out = <int, double>{};
  for (var sig = 0; sig < (1 << steps.length); sig++) {
    bool? r;
    for (var i = 0; i < steps.length; i++) {
      var s = (sig >> i) & 1 == 1;
      if (steps[i].invert) s = !s;
      final before = r ?? maskStartsFull(steps[i].mode);
      r = switch (steps[i].mode) {
        'subtract' => before && !s,
        'intersect' => before && s,
        'exclude' => before != s,
        'implication' => !before || s,
        'equivalence' => before == s,
        _ => before || s,
      };
    }
    out[sig] = (r ?? true) ? 1.0 : 0.0;
  }
  return out;
}

/// The presets: two sources A, B (Invert: A alone).
Map<int, double> regionPreset(String name) => switch (name) {
      'invert' => regionPresetFromStack([(mode: 'add', invert: true)]),
      _ => regionPresetFromStack([(mode: 'add', invert: false), (mode: name, invert: false)]),
    };

List<double> _ringsBox(List<List<List<double>>> r) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final ring in r) {
    for (final p in ring) {
      if (p[0] < x0) x0 = p[0];
      if (p[0] > x1) x1 = p[0];
      if (p[1] < y0) y0 = p[1];
      if (p[1] > y1) y1 = p[1];
    }
  }
  return [x0, y0, x1, y1];
}

bool _boxesMeet(List<double> a, List<double> b) => a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3];
