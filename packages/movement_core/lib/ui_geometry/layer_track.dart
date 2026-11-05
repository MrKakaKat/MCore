/// ============================================================
/// LAYER TRACK DRAG - pure state layer for the multi-layer timeline
/// panel's own drag mechanics.
///
/// Ported from movement-core/src/ui/timeline/timelinePanel.js's
/// onDown/onMove/onUp: dragging the MIDDLE of a layer's duration bar
/// shifts the whole layer (startFrame changes, durationFrames doesn't);
/// dragging an EDGE trims that end - the left edge keeps the right edge
/// fixed (classic trim-in-point behavior: shrinking/growing from the
/// left changes both startFrame and durationFrames together), the right
/// edge only changes durationFrames.
///
/// One real split from JS: JS's `onDown` determines the drag MODE by
/// measuring the touch position against the bar's own on-screen pixel
/// width (an edgeZone of 10px) - that hit-test is a screen-space/pixel
/// concern, so it stays in the Flutter widget layer (same split as
/// stage_gesture_controller.dart's own magnet-capture hit-testing);
/// this file only owns what happens ONCE a mode is already known - pure
/// integer-frame math, real `dart test` coverage.
/// ============================================================
library;

import 'dart:math' as math;

import '../geometry/shapes.dart';
import '../model/project.dart';
import 'keyframe_strip.dart' show visitLayerTracks;

enum LayerDragMode { move, trimLeft, trimRight }

class LayerTrackDragOp {
  final Layer layer;
  final LayerDragMode mode;
  final int _dragStartStart;
  final int _dragStartDur;
  final double _dragStartSourceIn;

  /// Every key of the layer with its frame at the grab: trimming the start
  /// keeps them at their place in time (see apply).
  final Map<Keyframe, int> _keyFramesAtGrab = {};

  /// Neighbours in a shared timeline row (timelineRowLimits): the layer
  /// stops at them instead of overlapping.
  final int minStart;
  final int? maxEnd;

  /// Timeline-linked layers (time_links.dart) that a move takes along, at
  /// their grab starts; the shared shift stays within [minDelta, maxDelta]
  /// (timeLinkShiftLimits of the whole group).
  final Map<Layer, int> partners;
  final int minDelta;
  final int? maxDelta;

  LayerTrackDragOp.grab(this.layer, this.mode,
      {this.minStart = 0, this.maxEnd, List<Layer> partners = const [], this.minDelta = -(1 << 30), this.maxDelta})
      : _dragStartStart = layer.startFrame,
        _dragStartDur = layer.durationFrames,
        _dragStartSourceIn = layer.content.sourceIn,
        partners = {for (final p in partners) if (!identical(p, layer)) p: p.startFrame} {
    if (mode == LayerDragMode.trimLeft) {
      visitLayerTracks(layer, (trk) {
        for (final k in trk.keyframes) {
          _keyFramesAtGrab[k] = k.frame;
        }
      });
    }
  }

  bool isPartner(Layer l) => partners.containsKey(l);

  /// Moves the linked layers by as much as `layer` has moved since the
  /// grab, holding the whole group inside its limits (pulling `layer`
  /// back if needed). Call again after anything else moved `layer`
  /// (timeline snapping).
  void followLeader() {
    if (mode == LayerDragMode.trimLeft) {
      _keepContentInTime(); // the start was snapped elsewhere
      return;
    }
    if (mode != LayerDragMode.move || partners.isEmpty) return;
    var d = math.max(minDelta, layer.startFrame - _dragStartStart);
    if (maxDelta != null) d = math.min(d, maxDelta!);
    layer.startFrame = _dragStartStart + d;
    partners.forEach((p, start) => p.startFrame = start + d);
  }

  /// Start trim: what plays stays where it was in time - the start cuts
  /// the beginning off instead of sliding everything along.
  /// - video / audio: the in-point moves with the start;
  /// - keys (layer-local) shift back by as much as the start moved trimming
  ///   the start "did nothing" - the whole animation slid along with it). Keys
  ///   cut off sit before the layer's start and are kept.
  void _keepContentInTime() {
    final shift = layer.startFrame - _dragStartStart;
    if (isTimedMedia(layer.content.shape)) {
      layer.content.sourceIn = _dragStartSourceIn + shift / fps;
    }
    _keyFramesAtGrab.forEach((k, f) => k.frame = f - shift);
  }

  /// `dxFrames` is the CUMULATIVE delta from the drag's own start point
  /// (not incremental) - same convention as
  /// ui_geometry/keyframe_strip.dart's KeyframeGroupDragOp, so a widget
  /// can call this every pointer-move with the running total rather than
  /// needing to track its own incremental state.
  void apply(int dxFrames) {
    switch (mode) {
      case LayerDragMode.move:
        var start = math.max(minStart, _dragStartStart + dxFrames);
        if (maxEnd != null) start = math.min(start, math.max(minStart, maxEnd! - _dragStartDur));
        layer.startFrame = start;
        followLeader();
      case LayerDragMode.trimLeft:
        final oldEnd = _dragStartStart + _dragStartDur;
        final newStart = math.max(minStart, math.min(oldEnd - 1, _dragStartStart + dxFrames));
        layer.startFrame = newStart;
        layer.durationFrames = oldEnd - newStart;
        _keepContentInTime();
      case LayerDragMode.trimRight:
        var dur = math.max(1, _dragStartDur + dxFrames);
        if (maxEnd != null) dur = math.max(1, math.min(dur, maxEnd! - _dragStartStart));
        layer.durationFrames = dur;
    }
  }
}

/// JS's extendTimelineToFit(): if a layer's active range now extends
/// past the overall timeline length, grow the timeline to fit it rather
/// than letting its bar clip against a track that stayed the old size.
/// Pure function - returns the new maxFrame the caller should adopt, or
/// null if no growth is needed (the UI-side `scrub.max`/re-render calls
/// JS makes are the caller's own job, same split as everywhere else in
/// this file).
///
/// (the ruler tail past the dragged layer's own end sits far too far away -
/// make it flush). This used to add a full extra second (`+ fps`) of headroom
/// past the layer's own end, which grows with zoom (up to ~960px at zoom 8)
/// and, since `recomputeMaxFrameToFit` below runs live during a drag, visibly
/// followed the dragged layer the whole time. Now flush - no added headroom.
int? extendedMaxFrameForLayer(Layer layer, int currentMax) {
  final end = layer.startFrame + layer.durationFrames;
  return end > currentMax ? end : null;
}

/// the shrink-capable counterpart to extendedMaxFrameForLayer - dragging a
/// layer past the end grows the timeline (above), but dragging it back shorter
/// never shrunk it back, and there was no direct control either. Returns the
/// smallest maxFrame that still fits every layer's own extent, flush against
/// the furthest one (see extendedMaxFrameForLayer's own doc comment - no added
/// headroom), never smaller than `floor` - a caller-supplied lower bound so a
/// value the user explicitly set via a direct "timeline length" control
/// doesn't get silently shrunk out from under them the next time a layer drag
/// ends.
int recomputeMaxFrameToFit(List<Layer> layers, int floor) {
  var furthest = 0;
  for (final l in layers) {
    // a loop with a limit counts up to its limit; an endless one just
    // follows the timeline, so only its first pass counts.
    final end = layerVisibleEnd(l) ?? l.startFrame + l.durationFrames;
    if (end > furthest) furthest = end;
  }
  return math.max(floor, furthest);
}
