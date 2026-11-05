/// ============================================================
/// TIMELINE LAYER-EDGE SNAPPING - 1D, integer-frame-space snapping for
/// the multi-layer timeline's own move/trim drag (layer_track.dart),
/// deliberately separate from the 2D stage-object snapping system
/// (ui_geometry/snapping.dart) - a different drag entirely, with no
/// project/globalFrame/descendant-walk complexity needed (parentId is
/// a stage-space-only relationship, unused here).
///
/// (layers should snap to each other's edges in the timeline). No sensitivity
/// slider was requested - a single fixed integer-frame threshold, not a
/// configurable radius.
/// ============================================================
library;

import 'dart:math' as math;

import '../model/project.dart';
import 'layer_track.dart' show LayerDragMode;

/// Deliberately small relative to typical clip lengths so it only
/// catches genuinely-adjacent edges, not "roughly nearby" ones. Loosely
/// anchored to the 2D system's own snapFrameBoundaryFrameRadius default
/// (10) as this app's own established "a low double-digit number is a
/// reasonable snap distance" precedent, rounded down since there is no
/// slider here to let a user widen it themselves.
const int kLayerEdgeSnapThresholdFrames = 6;

int? _nearestWithinRadius(
    int proposed, Iterable<int> candidates, int thresholdFrames) {
  int? best;
  var bestDist = thresholdFrames + 1;
  for (final c in candidates) {
    final d = (c - proposed).abs();
    if (d <= thresholdFrames && d < bestDist) {
      bestDist = d;
      best = c;
    }
  }
  return best;
}

/// Edge-snaps `layer` against every OTHER layer in `allLayers` (self
/// excluded), AFTER LayerTrackDragOp.apply has already run for this
/// call - mutates layer.startFrame/durationFrames directly, mirroring
/// LayerTrackDragOp.apply's own direct-mutation convention (there is no
/// separate return-value channel for a caller to intercept there
/// either). Unconditional - the caller (AppState.updateLayerDrag)
/// decides whether to invoke this at all based on its own toggle; this
/// function itself has no notion of "enabled."
///
/// - trimLeft: only the new startFrame may snap (the end is fixed).
/// - trimRight: only the new end (startFrame + durationFrames) may snap.
/// - move: layer's own start OR end may attach to any other layer's
///   start or end - all four pairings are compared, the closest one
///   within threshold wins, and the whole layer shifts by that
///   pairing's delta (duration is preserved).
void applyLayerEdgeSnap(Layer layer, List<Layer> allLayers, LayerDragMode mode,
    {int thresholdFrames = kLayerEdgeSnapThresholdFrames}) {
  final otherEdges = <int>[];
  for (final l in allLayers) {
    if (l.id == layer.id) continue;
    otherEdges.add(l.startFrame);
    otherEdges.add(l.startFrame + l.durationFrames);
  }
  if (otherEdges.isEmpty) return;

  switch (mode) {
    case LayerDragMode.trimLeft:
      final snapped =
          _nearestWithinRadius(layer.startFrame, otherEdges, thresholdFrames);
      if (snapped == null) return;
      final end = layer.startFrame + layer.durationFrames;
      layer.startFrame = math.min(snapped, end - 1);
      layer.durationFrames = end - layer.startFrame;

    case LayerDragMode.trimRight:
      final end = layer.startFrame + layer.durationFrames;
      final snapped = _nearestWithinRadius(end, otherEdges, thresholdFrames);
      if (snapped == null) return;
      layer.durationFrames = math.max(1, snapped - layer.startFrame);

    case LayerDragMode.move:
      final start = layer.startFrame;
      final end = start + layer.durationFrames;
      int? bestDelta;
      var bestDist = thresholdFrames + 1;
      for (final other in otherEdges) {
        for (final ownEdge in [start, end]) {
          final d = (other - ownEdge).abs();
          if (d <= thresholdFrames && d < bestDist) {
            bestDist = d;
            bestDelta = other - ownEdge;
          }
        }
      }
      if (bestDelta != null) {
        layer.startFrame = math.max(0, start + bestDelta);
      }
  }
}
