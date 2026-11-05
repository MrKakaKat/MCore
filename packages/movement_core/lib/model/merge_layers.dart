/// Merge layers into one contour: still vector shapes (no keys, no
/// effects, no motion add-ons) become one "compound" shape layer with all
/// their outlines, exactly where they were on screen, each in its own
/// colour. The render mode comes from the topmost of them.
library;

import 'dart:math' as math;

import '../core/math.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../geometry/contour_layer.dart' show layerVectorRings;
import '../geometry/shapes.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;
import '../ui_geometry/keyframe_strip.dart' show visitLayerTracks;
import '../core/interpolation.dart' show evaluateTrack;
import 'project.dart';
import 'layer_ops.dart' show reparentPreservingWorldPosition;
import 'timeline_rows.dart' show normalizeTimelineRows;

/// Why `layer` can't be merged, or null if it can.
String? mergeBlocker(Layer layer) {
  final shape = layer.content.shape;
  if (isMediaShape(shape) || shape == 'audio' || shape == 'text' || shape == 'null' || shape == 'camera') {
    return 'not a vector shape';
  }
  if (layer.mirrorSourceId != null || layer.mirrorProbe) return 'is a mirror';
  return null;
}

/// What merging `layer` gives up (it merges as it looks at the playhead):
/// null when nothing.
String? mergeWarning(Layer layer) {
  var keyed = false;
  visitLayerTracks(layer, (t) => keyed = keyed || t.keyframes.isNotEmpty);
  final lost = [
    if (keyed) 'keys',
    if (layer.effectStack.any((i) => i.enabled)) 'effects',
    if (layer.motionBlur.enabled || layer.wiggle.enabled || layer.pendulum.enabled || layer.swing.enabled) 'motion',
    if (layer.transform.pathFollow.enabled) 'path',
    if (layer.pieceClips.isNotEmpty) 'masks',
  ];
  return lost.isEmpty ? null : 'merges as it is now (drops its ${lost.join(', ')})';
}

/// "#rrggbb" (or "#rrggbbaa") with its alpha times `opacity`, as
/// "#rrggbbaa" (or as it was when fully opaque).
String? _withOpacity(String? hex, double opacity) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  final a0 = h.length == 8 ? int.parse(h.substring(6), radix: 16) / 255 : 1.0;
  final a = (a0 * opacity).clamp(0.0, 1.0);
  if (a >= 1) return '#${h.substring(0, 6)}';
  return '#${h.substring(0, 6)}${(a * 255).round().toRadixString(16).padLeft(2, '0')}';
}

/// Whether `layer` looks the same on every frame it's on (export draws
/// such a layer once and reuses it): no keys or expressions, no motion
/// add-ons, path, masks or group, not a video, and its parents still too.
bool layerIsStill(Project project, Layer layer, [Set<String>? seen]) {
  final s = seen ?? <String>{};
  if (!s.add(layer.id)) return false;
  final shape = layer.content.shape;
  if (shape == 'video' || shape == 'audio') return false;
  if ((layer.precompose ?? false) || layer.masks.isNotEmpty || layer.maskRegions != null || layer.transform.pathFollow.enabled) return false;
  if (layer.mirrorSourceId != null) return false; // shows what is below it
  if (layer.motionBlur.enabled || layer.wiggle.enabled || layer.pendulum.enabled || layer.swing.enabled) return false;
  var moving = false;
  visitLayerTracks(layer, (t) => moving = moving || t.keyframes.isNotEmpty || t.expression != null);
  if (moving) return false;
  final pid = layer.parentId;
  if (pid == null) return true;
  final parent = findLayer(project, pid);
  return parent != null && layerIsStill(project, parent, s);
}

/// A closed outline's signed area (positive: clockwise on screen).
double _area(List<List<double>> pts) {
  var a = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i], q = pts[(i + 1) % pts.length];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return a / 2;
}

/// How many of `rings` contain `p` (even-odd).
int _insideCount(List<double> p, List<List<List<double>>> rings) {
  var n = 0;
  for (final r in rings) {
    var inside = false;
    for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
      final a = r[i], b = r[j];
      if ((a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
    }
    if (inside) n++;
  }
  return n;
}

/// Merges `layers` (all mergeable, at least two) into a new layer `newId`
/// in their topmost one's place; returns it. Children of the merged
/// layers follow the new one.
Layer? mergeLayers(Project project, List<Layer> layers, String newId, int globalFrame) {
  if (layers.length < 2 || layers.any((l) => mergeBlocker(l) != null)) return null;
  final ordered = [...layers]..sort((a, b) => project.layers.indexOf(a).compareTo(project.layers.indexOf(b)));
  final top = ordered.last;
  clearStateCaches();
  // every outline in frame space (px), all wound the same way so the
  // non-zero fill unites them.
  final framePolys = <List<List<double>>>[];
  final colors = <String?>[];
  final join = <bool>[];
  for (final l in ordered) {
    final m = toFrameMatrix(getLayerStateAt(project, l.id, globalFrame).matrix);
    final c = l.content;
    // its opacity goes along as its colour's alpha - each keeps its own.
    final opacity = (evaluateTrack(project, l.transform.opacity, layerLocalFrame(l, globalFrame), l) as num)
        .toDouble()
        .clamp(0.0, 1.0);
    // masks and cuts stay: its outline after them, holes included.
    final cut = l.masks.any((k) => k.enabled) || l.cuts.any((k) => k.enabled && k.cutterId != null);
    final ownJoin = c.shape == 'compound' && c.contourJoin != null && c.contourJoin!.length == c.contours?.length;
    final locals = cut
        ? (layerVectorRings(project, l, globalFrame) ?? const <List<List<double>>>[])
        : c.shape == 'compound' && c.contours != null
            ? c.contours!
            : [getContentOutline(c, l, globalFrame, project: project)];
    var first = true;
    for (var li = 0; li < locals.length; li++) {
      final poly = locals[li];
      if (poly.length < 3) continue;
      var pts = [for (final p in poly) applyAffine(m, p)];
      // a hole (inside an odd number of its other rings) turns the other
      // way, so the non-zero fill leaves it open.
      final hole = cut && _insideCount(pts[0], [for (final o in locals) if (!identical(o, poly)) [for (final p in o) applyAffine(m, p)]]).isOdd;
      if ((_area(pts) < 0) != hole && !(ownJoin && c.contourJoin![li])) pts = pts.reversed.toList();
      framePolys.add(pts);
      join.add(ownJoin ? c.contourJoin![li] : (cut && !first));
      first = false;
      // every shape keeps its own colour.
      final base = !cut && c.contourColors != null && c.contourColors!.length == c.contours?.length
          ? c.contourColors![li] ?? l.color
          : l.color;
      colors.add(_withOpacity(base, opacity));
    }
  }
  if (framePolys.isEmpty) return null;
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final poly in framePolys) {
    for (final p in poly) {
      minX = math.min(minX, p[0]);
      maxX = math.max(maxX, p[0]);
      minY = math.min(minY, p[1]);
      maxY = math.max(maxY, p[1]);
    }
  }
  final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  final start = ordered.map((l) => l.startFrame).reduce(math.min);
  final end = ordered.map((l) => l.startFrame + l.durationFrames).reduce(math.max);
  final merged = createLayer('rect')
    ..id = newId
    ..name = '${top.name}_merged'
    ..color = top.color
    ..renderMode = top.renderMode
    ..fill = cloneLayer(top).fill
    ..startFrame = start
    ..durationFrames = end - start
    ..content = Content(
      shape: 'compound',
      offset: [0, 0],
      size: [math.max(1, maxX - minX), math.max(1, maxY - minY)],
      contours: [
        for (final poly in framePolys) [for (final p in poly) [p[0] - cx, p[1] - cy]]
      ],
    )
    ..content.contourColors = colors
    ..content.contourJoin = join.any((j) => j) ? join : null;
  merged.transform.anchor.defaultValue = [cx / stageSize.width, cy / stageSize.height];
  // the opacities live in the contour colours now.
  merged.transform.opacity.defaultValue = 1.0;
  final at = project.layers.indexOf(top);
  project.layers.insert(at + 1, merged);
  final gone = {for (final l in ordered) l.id};
  // children of a merged layer keep their place on screen, under no
  // parent (the merged layers were still, so nothing moves).
  for (final l in project.layers) {
    if (l.parentId != null && gone.contains(l.parentId)) {
      reparentPreservingWorldPosition(project, l, null, globalFrame);
    }
  }
  project.layers.removeWhere((l) => gone.contains(l.id));
  normalizeTimelineRows(project);
  clearStateCaches();
  return merged;
}
