/// ============================================================
/// TEMPORARY GROUPING (null-parenting, AE's Null Object pattern)
/// - masks are the wrong tool for this (visibility, not transform).
///   the actual AE analog is a Null Object: children parented to it
///   move/rotate/scale together via the SAME matrix chain that
///   already exists, nothing new to render.
/// - reparentPreservingWorldPosition is the general primitive: whenever
///   a layer's parentId changes, shift its ENTIRE anchor track by a
///   constant delta so today's on-screen position doesn't jump.
///
/// Ported from movement-core/src/model/layerOps.js, including the
/// clearStateCaches()-after-hierarchy-mutation hardening added there
/// (reparentPreservingWorldPosition/ungroupLayer/deleteLayer each self-
/// clear the cache before returning, rather than relying on every
/// caller re-rendering immediately afterward).
/// ============================================================
library;

import 'dart:math' as math;

import '../core/interpolation.dart';
import '../core/math.dart' as mm;
import '../core/state_cache.dart';
import '../ui_geometry/keyframe_strip.dart' show visitLayerTracks;
import 'project.dart';
import 'time_links.dart' show dissolveLonelyTimeLinks;

/// current selection - a plain mutable holder (not a Dart-global
/// singleton) so test code can create a fresh one per Project, the same
/// way it creates a fresh Project rather than reusing one shared
/// instance across tests.
class Selection {
  String? selectedLayer;
  final Set<String> groupSelection;
  Selection({this.selectedLayer, Set<String>? groupSelection}) : groupSelection = groupSelection ?? {};
}

// prevents reparenting from creating a cycle (X becomes an ancestor of
// itself through the chain) - walks UP from the candidate parent; if
// that walk ever reaches layerId, assigning it would close a loop and
// getLayerStateAt's recursion would spin forever.
bool wouldCreateCycle(Project project, String layerId, String? candidateParentId) {
  if (candidateParentId == layerId) return true;
  var cur = findLayer(project, candidateParentId);
  while (cur != null && cur.parentId != null) {
    if (cur.parentId == layerId) return true;
    cur = findLayer(project, cur.parentId);
  }
  return false;
}

/// copies everything animation/behavior-related from source onto
/// target: anchor/rotation/opacity/pathFollow tracks, content.offset,
/// masks, effectStack, motionBlur/wiggle/pendulum, renderMode, color.
/// deliberately EXCLUDES transform.scale and content.size/shape/sides.
/// Dart clones by constructing new instances (the JS clones via a JSON
/// round-trip - no functions/circular refs in this data either way, so
/// a field-by-field deep copy here is the equivalent).
void copyLayerParams(Layer source, Layer target) {
  target.transform.anchor = cloneTrack(source.transform.anchor);
  target.transform.rotation = cloneTrack(source.transform.rotation);
  target.transform.opacity = cloneTrack(source.transform.opacity);
  target.transform.pathFollow = PathFollow(
    enabled: source.transform.pathFollow.enabled,
    sourceLayerId: source.transform.pathFollow.sourceLayerId,
    t: cloneTrack(source.transform.pathFollow.t),
    parametrization: source.transform.pathFollow.parametrization,
  );
  target.content.offset = [...source.content.offset];
  target.masks = [
    for (final m in source.masks) Mask(enabled: m.enabled, mode: m.mode, sourceLayerId: m.sourceLayerId, feather: cloneTrack(m.feather), featherOutside: m.featherOutside, invert: m.invert, range: m.range == null ? null : [...m.range!], moreSources: [...m.moreSources], sourcePart: m.sourcePart),
  ];
  target.effectStack = [
    for (final i in source.effectStack)
      EffectInstance(id: i.id, effectId: i.effectId, enabled: i.enabled, params: {
        for (final entry in i.params.entries) entry.key: entry.value is Track ? cloneTrack(entry.value as Track) : entry.value,
      }),
  ];
  target.motionBlur = MotionBlur(enabled: source.motionBlur.enabled, shutterAngle: source.motionBlur.shutterAngle, samples: source.motionBlur.samples);
  target.wiggle = Wiggle(enabled: source.wiggle.enabled, speed: source.wiggle.speed, amplitude: source.wiggle.amplitude, smoothness: source.wiggle.smoothness, wiggleSeed: source.wiggle.wiggleSeed);
  target.pendulum = Pendulum(
    enabled: source.pendulum.enabled, frequency: source.pendulum.frequency, damping: source.pendulum.damping,
    sensitivity: source.pendulum.sensitivity, pivotOffset: cloneTrack(source.pendulum.pivotOffset),
    maxAngle: source.pendulum.maxAngle, freeze: source.pendulum.freeze, rotateWithLine: source.pendulum.rotateWithLine,
    weightPoint: source.pendulum.weightPoint == null ? null : [...source.pendulum.weightPoint!],
  );
  target.renderMode = source.renderMode;
  target.color = source.color;
  target.crop = [...source.crop];
  target.cropAspect = source.cropAspect;
  target.mirrorX = source.mirrorX;
  target.mirrorY = source.mirrorY;
  target.foldsIgnoreScale = source.foldsIgnoreScale;
}

// approximate x/y "how much bigger does this matrix make things" factors,
// from a 2x3 affine's linear part (length of the transformed unit
// vectors) - doesn't account for shear, but our matrices are built from
// rotation+scale only, never sheared, so this is exact for what we
// actually produce.
double _matrixRotationDeg(List<double> m) => math.atan2(m[1], m[0]) * 180 / math.pi;

/// -180..180, so a turn of 350 degrees is compensated as -10, not +350.
double _wrapDeg(double d) {
  var r = d % 360;
  if (r > 180) r -= 360;
  if (r < -180) r += 360;
  return r;
}

List<double> _matrixScaleMagnitude(List<double> m) {
  return [math.sqrt(m[0] * m[0] + m[1] * m[1]), math.sqrt(m[2] * m[2] + m[3] * m[3])];
}

void reparentPreservingWorldPosition(Project project, Layer layer, String? newParentId, int globalFrame) {
  final oldWorldMatrix = getLayerStateAt(project, layer.id, globalFrame).matrix; // BEFORE the parentId change
  final oldWorldPos = [oldWorldMatrix[4], oldWorldMatrix[5]];
  final oldWorldScale = _matrixScaleMagnitude(oldWorldMatrix);
  final oldWorldRot = _matrixRotationDeg(oldWorldMatrix);

  layer.parentId = newParentId;
  // a new link is for the whole time again.
  layer.parentFrom = layer.parentUntil = null;
  // the frame-scoped state cache doesn't know parentId just changed -
  // without clearing it here, the NEXT getLayerStateAt call below would
  // silently return the STALE pre-reparent result if something already
  // populated the cache for this frame beforehand.
  clearStateCaches();

  // ROTATION first (it doesn't move the anchor point, so the position
  // compensation below still sees the right translation): the new parent may
  // be turned differently from the old one, and the child inherits that turn -
  // shift the child's whole rotation track by the difference so its on-screen
  // angle stays the same. the child turned on reparenting.)
  final rotDelta = _wrapDeg(oldWorldRot - _matrixRotationDeg(getLayerStateAt(project, layer.id, globalFrame).matrix));
  if (rotDelta.abs() > 1e-9) {
    final rotTrk = layer.transform.rotation;
    rotTrk.defaultValue = (rotTrk.defaultValue as num).toDouble() + rotDelta;
    for (final k in rotTrk.keyframes) {
      k.value = (k.value as num).toDouble() + rotDelta;
    }
    clearStateCaches();
  }

  final newParentMatrix = newParentId != null
      ? parentMatrixFor(project, layer, globalFrame)
      : <double>[1, 0, 0, 1, 0, 0];
  final desiredAnchor = mm.applyAffine(mm.invertAffine(newParentMatrix), oldWorldPos);

  final localFrame = layerLocalFrame(layer, globalFrame);
  final existingAnchor = evaluateTrack(project, layer.transform.anchor, localFrame) as List<double>;
  final delta = [desiredAnchor[0] - existingAnchor[0], desiredAnchor[1] - existingAnchor[1]];

  final trk = layer.transform.anchor;
  final trkDefault = trk.defaultValue as List<double>;
  trk.defaultValue = [trkDefault[0] + delta[0], trkDefault[1] + delta[1]];
  for (final k in trk.keyframes) {
    final v = k.value as List<double>;
    k.value = [v[0] + delta[0], v[1] + delta[1]];
  }
  if (trk.spatial) autoComputeTangents(trk);

  // also preserve VISUAL SIZE, not just position - the new parent may
  // have its own scale, which the child inherits through the normal
  // matrix chain. compensate the child's OWN scale by the ratio needed
  // to cancel out whatever the new parent's contribution changed.
  final newWorldMatrix = getLayerStateAt(project, layer.id, globalFrame).matrix; // fresh, now WITH the new parentId
  final newWorldScale = _matrixScaleMagnitude(newWorldMatrix);
  final scaleRatio = [
    oldWorldScale[0] / math.max(1e-6, newWorldScale[0]),
    oldWorldScale[1] / math.max(1e-6, newWorldScale[1]),
  ];
  final scaleTrk = layer.transform.scale;
  final scaleDefault = scaleTrk.defaultValue as List<double>;
  scaleTrk.defaultValue = [scaleDefault[0] * scaleRatio[0], scaleDefault[1] * scaleRatio[1]];
  for (final k in scaleTrk.keyframes) {
    final v = k.value as List<double>;
    k.value = [v[0] * scaleRatio[0], v[1] * scaleRatio[1]];
  }

  // the newWorldMatrix read above cached (layer.id, globalFrame) BEFORE
  // this scale compensation was applied - clear again so the function
  // leaves the cache consistent with its own final output, rather than
  // relying on every caller happening to render() (which also clears
  // it) immediately afterward.
  clearStateCaches();
}

/// (changing the frame's resolution doesn't rescale objects to match) -
/// confirmed root cause: Transform.anchor is a [0,1] FRACTION of the stage, so
/// it already rescales for free every frame (canvas_renderer.dart multiplies
/// the matrix's translation by the current stage width/height); but
/// Content.offset/size/points are literal PIXEL counts, entirely independent
/// of stage size - doubling the frame leaves every shape's own pixel size
/// unchanged, so it visually shrinks to half its relative size. Media is
/// covered automatically (image content shares these same fields - see
/// geometry/shapes.dart's isRectLikeShape).
///
/// The same absolute-pixel-vs-stage-size pattern also affects mask
/// feather (a content-pixel blur radius), corner_pin's tl/tr/br/bl/
/// p0..pN and mesh_warp's r{r}c{c} pin offsets (pixel offsets added
/// onto the content geometry above), and pendulum's pivotOffset
/// (layer-local pixels, divided by the CURRENT stage size at evaluation
/// time - so leaving it untouched doesn't just fail to scale, it
/// silently shifts, exactly like content.size would). anchor tracks
/// themselves are deliberately left alone - they need no change.
///
/// Called from AppState.setFrameSize with the ratio between the old and
/// new frame dimensions, gated by AppState.scaleContentOnResize.
void rescaleProjectContent(Project project, double scaleX, double scaleY) {
  if (scaleX == 1.0 && scaleY == 1.0) return;
  final featherScale = math.sqrt(scaleX * scaleY);
  final cornerPinKeys = ['tl', 'tr', 'br', 'bl'];
  final pKeyPattern = RegExp(r'^p\d+$');
  final pinKeyPattern = RegExp(r'^r\d+c\d+$');

  for (final layer in project.layers) {
    final c = layer.content;
    c.offset = [c.offset[0] * scaleX, c.offset[1] * scaleY];
    c.size = [c.size[0] * scaleX, c.size[1] * scaleY];
    final points = c.points;
    if (points != null) {
      c.points = [for (final p in points) [p[0] * scaleX, p[1] * scaleY]];
    }
    final contours = c.contours;
    if (contours != null) {
      c.contours = [
        for (final ct in contours) [for (final p in ct) [p[0] * scaleX, p[1] * scaleY]]
      ];
    }
    final t = c.text;
    if (t != null) {
      // text keeps its proportions: sizes follow the mean scale.
      t.fontSize *= featherScale;
      t.letterSpacing *= featherScale;
      t.strokeWidth *= featherScale;
      t.shadow.dx *= scaleX;
      t.shadow.dy *= scaleY;
      t.background.padding *= featherScale;
    }

    for (final m in layer.masks) {
      _scaleTrackScalar(m.feather, featherScale);
    }

    for (final inst in layer.effectStack) {
      if (inst.effectId == 'corner_pin') {
        for (final key in inst.params.keys) {
          if (cornerPinKeys.contains(key) || pKeyPattern.hasMatch(key)) {
            final v = inst.params[key];
            if (v is Track) _scaleTrackVec2(v, scaleX, scaleY);
          }
        }
      } else if (inst.effectId == 'mesh_warp') {
        for (final key in inst.params.keys) {
          if (pinKeyPattern.hasMatch(key)) {
            final v = inst.params[key];
            if (v is Track) _scaleTrackVec2(v, scaleX, scaleY);
          }
        }
      }
    }

    _scaleTrackVec2(layer.pendulum.pivotOffset, scaleX, scaleY);

    // a vector line: its points and handles; its width with the mean.
    final nodes = c.lineNodes;
    if (nodes != null) {
      for (final n in nodes) {
        n
          ..x *= scaleX
          ..y *= scaleY
          ..hIn = [n.hIn[0] * scaleX, n.hIn[1] * scaleY]
          ..hOut = [n.hOut[0] * scaleX, n.hOut[1] * scaleY];
        if (n.w != null) n.w = n.w! * featherScale;
        n.round *= featherScale;
        if (n.posT != null) _scaleTrackVec2(n.posT!, scaleX, scaleY);
      }
      c.lineWidth *= featherScale;
    }
  }
}

/// The frame goes from `oldW` x `oldH` to `newW` x `newH` without
/// stretching anything: every object scales evenly by the smaller change
/// and keeps its place relative to the frame's middle (positions are
/// fractions of the frame, so they are moved to stay put in px).
void refitProjectEvenly(Project project, double oldW, double oldH, double newW, double newH) {
  if (oldW <= 0 || oldH <= 0 || newW <= 0 || newH <= 0) return;
  final k = math.min(newW / oldW, newH / oldH);
  rescaleProjectContent(project, k, k);
  final fx = oldW * k / newW, fy = oldH * k / newH;
  for (final l in project.layers) {
    final root = l.parentId == null;
    List<double> map(Object? v) {
      final a = v as List;
      final x = (a[0] as num).toDouble(), y = (a[1] as num).toDouble();
      return root ? [0.5 + (x - 0.5) * fx, 0.5 + (y - 0.5) * fy] : [x * fx, y * fy];
    }

    final t = l.transform.anchor;
    t.defaultValue = map(t.defaultValue);
    for (final kf in t.keyframes) {
      kf.value = map(kf.value);
    }
    // animation layers add to it: their amounts only scale.
    List<double> delta(Object? v) {
      final a = v as List;
      return [(a[0] as num).toDouble() * fx, (a[1] as num).toDouble() * fy];
    }

    for (final a in t.animLayers) {
      if (a.multiply) continue;
      a.track.defaultValue = delta(a.track.defaultValue);
      for (final kf in a.track.keyframes) {
        kf.value = delta(kf.value);
      }
    }
  }
}

void _scaleTrackScalar(Track trk, double scale) {
  trk.defaultValue = (trk.defaultValue as double) * scale;
  for (final k in trk.keyframes) {
    k.value = (k.value as double) * scale;
  }
}

void _scaleTrackVec2(Track trk, double scaleX, double scaleY) {
  final def = trk.defaultValue as List<double>;
  trk.defaultValue = [def[0] * scaleX, def[1] * scaleY];
  for (final k in trk.keyframes) {
    final v = k.value as List<double>;
    k.value = [v[0] * scaleX, v[1] * scaleY];
  }
  if (trk.spatial) autoComputeTangents(trk);
}

Layer groupLayers(Project project, List<String> selectedIds, int globalFrame) {
  if (selectedIds.length < 2) {
    throw ArgumentError('groupLayers needs at least 2 selected layers');
  }
  final positions = [
    for (final id in selectedIds) getLayerStateAt(project, id, globalFrame).matrix,
  ].map((m) => [m[4], m[5]]).toList();
  final cx = positions.map((p) => p[0]).reduce((a, b) => a + b) / positions.length;
  final cy = positions.map((p) => p[1]).reduce((a, b) => a + b) / positions.length;

  final nullLayer = createLayer('null'); // zero-size content -> shapePoints() returns [], nothing to draw
  nullLayer.name = 'group_$layerCounter';
  nullLayer.transform.anchor.defaultValue = [cx, cy];
  nullLayer.groupedChildren = [...selectedIds];
  nullLayer.precompose = false;
  project.layers.add(nullLayer);

  for (final id in selectedIds) {
    final child = findLayer(project, id)!;
    child.preGroupParentId = child.parentId;
    reparentPreservingWorldPosition(project, child, nullLayer.id, globalFrame);
  }

  return nullLayer;
}

void ungroupLayer(Project project, String nullId, int globalFrame) {
  final nullLayer = findLayer(project, nullId);
  if (nullLayer == null || nullLayer.groupedChildren == null) return;
  for (final id in nullLayer.groupedChildren!) {
    final child = findLayer(project, id);
    if (child == null) continue;
    reparentPreservingWorldPosition(project, child, child.preGroupParentId, globalFrame);
    child.preGroupParentId = null;
  }
  project.layers.removeWhere((l) => l.id == nullLayer.id);
  // nullLayer no longer exists in project.layers, but a still-cached
  // (nullLayer.id, frame) entry would make getLayerStateAt return that
  // stale matrix instead of correctly reporting "not found" (it only
  // falls through to findLayer on a cache miss) - clear so the function
  // is consistent with its own output regardless of caller behavior.
  clearStateCaches();
}

/// single entry point for removing ANY layer - never leaves other
/// layers pointing at a dead parentId. a group null ungroups (position-
/// preserving) instead of orphaning its children; any other layer with
/// children collapses one level (they inherit ITS parent, also
/// position-preserving) instead of being left dangling.
void deleteLayer(Project project, Selection selection, String layerId, int globalFrame) {
  final layer = findLayer(project, layerId);
  if (layer == null) return;
  if (layer.groupedChildren != null) {
    final firstChild = layer.groupedChildren!.isNotEmpty ? layer.groupedChildren!.first : null;
    ungroupLayer(project, layerId, globalFrame); // already removes it from project.layers
    selection.groupSelection.remove(layerId);
    if (selection.selectedLayer == layerId) {
      selection.selectedLayer = firstChild ?? (project.layers.isNotEmpty ? project.layers.first.id : null);
    }
    return;
  }
  for (final l in project.layers) {
    if (l.parentId == layerId) {
      reparentPreservingWorldPosition(project, l, layer.parentId, globalFrame);
    }
  }
  project.layers.removeWhere((l) => l.id == layerId);
  // a mirror goes with its probe copy; a deleted probe just ends the
  // mirror (it shows its own fill again).
  final probe = layer.mirrorSourceId == null ? null : findLayer(project, layer.mirrorSourceId);
  if (probe != null && probe.mirrorProbe) project.layers.remove(probe);
  for (final l in project.layers) {
    if (l.mirrorSourceId == layerId) l.mirrorSourceId = null;
  }
  // its time-link partner (e.g. a video's sound) is no longer linked.
  dissolveLonelyTimeLinks(project);
  // same reasoning as ungroupLayer's own trailing clear - layerId is
  // gone from project.layers, so a stale cache entry for it (most
  // likely when the loop above found no children to reparent, e.g.
  // deleting a leaf layer, and so never touched the cache at all) would
  // otherwise survive the removal.
  clearStateCaches();
  selection.groupSelection.remove(layerId);
  if (selection.selectedLayer == layerId) {
    selection.selectedLayer = project.layers.isNotEmpty ? project.layers.first.id : null;
  }
}

/// Frame rates the project can run at (Settings).
const projectFpsOptions = [12, 15, 24, 25, 30, 48, 50, 60];

/// Changes the project's frame rate, keeping every animation's real
/// timing: layer starts/lengths and all keyframes are re-timed from the
/// old rate to the new one (frames rounded; keys that land on the same
/// frame of one track merge, the later one wins). Wiggle and pendulum
/// already count in seconds, so they keep their speed.
void retimeProject(Project project, int newFps) {
  final oldFps = fps;
  if (newFps <= 0 || newFps == oldFps) {
    fps = newFps > 0 ? newFps : oldFps;
    project.fps = fps;
    return;
  }
  final k = newFps / oldFps;
  int t(int f) => (f * k).round();
  for (final layer in project.layers) {
    layer.startFrame = t(layer.startFrame);
    layer.durationFrames = math.max(1, t(layer.durationFrames));
    visitLayerTracks(layer, (trk) {
      if (trk.keyframes.isEmpty) return;
      final byFrame = <int, Keyframe>{};
      for (final kf in trk.keyframes) {
        kf.frame = t(kf.frame);
        byFrame[kf.frame] = kf;
      }
      trk.keyframes
        ..clear()
        ..addAll(byFrame.values.toList()..sort((a, b) => a.frame.compareTo(b.frame)));
      if (trk.spatial) autoComputeTangents(trk);
    });
  }
  fps = newFps;
  project.fps = newFps;
  clearStateCaches();
}
