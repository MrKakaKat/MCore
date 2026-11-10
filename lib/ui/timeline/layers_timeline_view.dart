import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:movement_core/movement_core.dart' hide Transform;

import '../../app_state.dart';
import '../common/tool_guide.dart';
import 'layer_detail_rows.dart';

/// Ported from movement-core/src/ui/timeline/timelinePanel.js - a
/// multi-layer timeline: one row per layer, showing its active range
/// (startFrame..startFrame+durationFrames) and its own keyframes,
/// draggable to move the whole layer or trim either end.
///
/// drove several deliberate, disclosed departures from a straight port:
/// - JS draws each layer as a filled, opaque bar. draw layers as thin LINES
///   (matching the main scrub track's own visual style) with their two
///   boundary points as dots and their keyframes as diamonds ON the line - so
///   this file's `_LayerLane` paints a line+dots+diamonds instead of
///   `tl-bar`'s filled rect.
/// - JS's whole bar is one pointerdown/pointermove listener that infers
///   move-vs-trim purely from where the initial touch landed (a 10px
///   edge zone). On a touchscreen sharing a scrollable ancestor (this
///   view needs horizontal scroll once zoomed in), an immediate-drag
///   "move" gesture would fight the scroll view for every sideways
///   swipe - so "move" here requires a LONG PRESS first (Flutter's
///   LongPressGestureRecognizer coexists cleanly with a Scrollable's
///   own pan recognizer in the gesture arena: an immediate drag is
///   claimed by the scroll view, a hold-then-drag is claimed by the
///   long-press instead), while the two edge dots stay small, precise,
///   immediate-drag targets for trimming (matching JS - a deliberate
///   press directly on a boundary dot is never ambiguous with a scroll
///   swipe the way dragging anywhere on a wide bar would be).
/// - Zoom is a real 2-finger pinch, tracked via a raw `Listener`
///   wrapping the whole scrollable/zoomable area - the same technique
///   `stage_gesture_controller.dart` uses for the main canvas. A
///   `Listener` receives every pointer event regardless of which
///   recognizer wins the gesture arena, so it coexists with the
///   horizontal `SingleChildScrollView`'s own pan recognizer and every
///   per-lane `GestureDetector` below without fighting any of them:
///   with 0-1 pointers down it does nothing and those own gestures
///   behave exactly as before; a SECOND pointer landing starts pinch
///   tracking purely from the raw distance-ratio between the two
///   pointers, independent of whatever the first pointer's own
///   recognizer is doing with it.
/// - growing the timeline (`extendedMaxFrameForLayer`, triggered by dragging a
///   layer past the current end) used to visually COMPRESS everything already
///   drawn, because frame->pixel position was computed as a FRACTION of
///   maxFrame (`frame/maxFrame*contentWidth`) - growing maxFrame shrank that
///   fraction for every existing frame. Frame->pixel position is now `frame *
///   pixelsPerFrame` directly, with `pixelsPerFrame` derived only from the
///   current zoom level - never from maxFrame - so growing maxFrame only ever
///   EXTENDS `contentWidth` to the right; every already-drawn frame's own
///   screen position is untouched.
/// - The playhead within this zoomable/scrollable area is its own
///   separate, explicit indicator, with no other widget's coordinate
///   space to contrast against (the old fixed-unzoomed-range scrub
///   bar, timeline_view.dart, was later removed as redundant).
/// - the two trim dots stayed visible on every layer's line at all times, and
///   a stray press near any layer's own edge could easily start trimming
///   instead of the intended move/ scroll. Trim dots are now hidden by
///   default; tapping a line's body FOCUSES that layer (shows its own dots,
///   and every other layer's line dims and stops responding to any input at
///   all) until the SAME line is tapped again, which returns every line to
///   normal - UNLESS AppState.layerQuickSwitchEnabled is on (a toggle in
///   TimelineToolbar, left of undo/redo -), in which case a dimmed line stays
///   tappable too and switches focus straight to it, no unfocus-first step
///   needed.
/// - zooming out was capped at the same ~3s default view, and the content ran
///   flush to the screen's own edges with frame 0 pinned at the scroll area's
///   literal left edge - jarring, and unlike (classic mobile editors).
///   `_minZoom` now goes much lower (real zoom-OUT range, not just zoom-in),
///   and the scrollable content gets half-a-viewport of leading/trailing blank
///   space plus an edge fade (ShaderMask gradient) - frame 0 sits at the
///   viewport's horizontal CENTER by default (scroll offset 0 already lands
///   there, given the leading padding), with room to scroll further right,
///   matching. Deliberately NOT a full rewrite to the "drag the filmstrip,
///   fixed center playhead" scrub model those editors actually use - the
///   existing draggable _Playhead widget stays as-is; only the
///   framing/padding/fade changed. See this round's own report for that
///   disclosed scope choice.
/// - dragging the playhead could send it flying far outside the visible area
///   for a small finger movement. Root cause: the horizontal
///   SingleChildScrollView's own pan recognizer was STILL free to scroll in
///   response to the very same drag (a disclosed trade-off from the
///   trim-dot/playhead arena-bypass fix above) - since the playhead's own
///   screen position is `currentFrame * pixelsPerFrame`, every pointer-move
///   event compounded TWO shifts at once (the genuine frame change AND the
///   scroll view sliding underneath the same finger), a positive feedback loop
///   that ran away well past the actual gesture. Fixed by disabling the scroll
///   view's physics (`_dragBlockingScrollPhysics`) for the duration of any
///   playhead or trim drag - `ClampingScrollPhysics` as the base (not the
///   Material default `BouncingScrollPhysics`+stretch) specifically because an
///   earlier attempt at this exact fix, using the default physics, crashed
///   with a real Flutter framework reentrancy bug inside the
///   stretch-overscroll indicator's own listener when `canDrag` flipped
///   mid-layout; Clamping physics has no such indicator/listener to reenter.
/// - (moving a layer to the edge of the timeline should scroll the whole
///   thing) - a toggle (AppState.timelineEdgeAutoScrollEnabled, default off,
///   same pattern as layerQuickSwitchEnabled). The horizontal
///   SingleChildScrollView gained an explicit ScrollController (previously
///   none at all, relying entirely on its own internal default position) so
///   _LayerLane's own move-drag handler can nudge it directly. Scoped to the
///   MOVE drag only (not trim, not the playhead) - a Timer.periodic
///   started/stopped from onLongPressMoveUpdate/ onLongPressEnd, active only
///   while the pointer's LOCAL x (via a GlobalKey on the outer Listener +
///   RenderBox.globalToLocal) sits within an edge zone of the viewport. Since
///   _dxFrames is computed from raw GLOBAL pointer delta (not scroll offset),
///   auto-scrolling the view underneath an active drag doesn't perturb the
///   existing move math at all - purely "now more of the timeline is
///   reachable" convenience.
/// - the handle lives in its own reserved 28px strip at the right edge
///   (_ReorderColumn - where the very first reorder column was), outside the
///   horizontal scroll, never drawn over the lanes; shown only for the focused
///   layer, vertical-only drag clamped to the rows, one moveLayer on release.
/// - the cursor is a literal fixed position (`halfViewport - 8`), and the
///   filmstrip under it moves in whole-frame steps only (_FrameQuantized),
///   never sub-frame.
/// - The focused layer's edge lines span the whole timeline height (drawn
///   at the content-Stack level, not inside the lane's own 12px row).
///
/// UNVERIFIED like the rest of ui/.
class LayersTimelineView extends StatefulWidget {
  final AppState app;
  const LayersTimelineView({super.key, required this.app});

  @override
  State<LayersTimelineView> createState() => _LayersTimelineViewState();
}

class _LayersTimelineViewState extends State<LayersTimelineView> {
  // zoom-in worked but zoom-OUT stayed capped at the same default ~3s view -
  // _minZoom is now much lower, a real zoom-out range rather than just a floor
  // equal to the starting zoom.
  static const double _minZoom = 0.1;
  static const double _maxZoom = 8.0;
  // (bring the lines three times closer together) - was 36.
  static const double _rowHeight = 12;
  static const double _rulerHeight = 18;
  // frame->pixel density at zoom 1 - deliberately independent of
  // maxFrame (see this file's own doc comment on the compression fix).
  static const double _pixelsPerFrameAtZoom1 = 2.0;
  // reserved right-edge strip for the reorder handle (see _ReorderColumn).
  static const double _reorderColumnWidth = 28;

  double _zoom = 1.0;
  String? _focusedLayerId;

  // see this file's own top-level doc comment on the playhead-runaway
  // fix - true for the duration of any playhead or trim drag, which
  // disables the horizontal scroll view's own physics so it can't ALSO
  // react to the same finger movement.
  bool _scrubDragActive = false;
  void _setScrubDragActive(bool v) {
    if (v != _scrubDragActive) setState(() => _scrubDragActive = v);
  }

  // half-width of each full-height trim column's touch area - see
  // _trimColumns.
  static const double _trimHitRadius = 30;
  // blank room on BOTH sides of the content box, so the edge lines, the
  // playhead and their hit areas at frame 0 and at the end aren't cut in
  // half by it. The scroll padding shrinks by the same amount on each
  // side, so on-screen positions and the scroll extent are unchanged.
  static const double _edgeSlack = _trimHitRadius;

  // the focused layer's row tint (behind the lanes and the reorder strip).
  static const double _focusBandOpacity = 0.18;

  // keyframes on the focused layer: each is a tap target this wide (full
  // timeline height); the selected one(s) draw like the playhead and drag.
  static const double _keyHitWidth = 24;
  static const Color _keyColor = Color(0xFFE0D47F);
  int? _kfDragOriginFrame;
  double? _kfDragStartX;
  bool _kfDragStarted = false;

  List<Widget> _keyframeColumns(Layer layer, double ppf, double height) {
    final selected = kfSelectedFrames.toList()..sort();
    return [
      for (final f in collectVisibleLayerKeyframeFrames(layer))
        if (!kfSelectedFrames.contains(f))
          Positioned(
            key: ValueKey('kf-$f'),
            left: _edgeSlack + f * ppf - _keyHitWidth / 2,
            top: 0,
            width: _keyHitWidth,
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => widget.app.selectKeyframeFrame(f),
            ),
          ),
      // keyed by position in the selection, not by frame, so the Listener
      // survives the rebuilds that move it while it's dragged.
      for (var i = 0; i < selected.length; i++)
        Positioned(
          key: ValueKey('kf-selected-$i'),
          left: _edgeSlack + selected[i] * ppf - _keyHitWidth / 2,
          top: 0,
          width: _keyHitWidth,
          height: height,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (d) {
              // a second finger (pinch-zoom) never grabs an indicator.
              if (_activePointers.isNotEmpty) return;
              _kfDragOriginFrame = selected[i];
              _kfDragStartX = d.position.dx;
              _kfDragStarted = false;
              _setScrubDragActive(true);
            },
            onPointerMove: (d) {
              final origin = _kfDragOriginFrame, startX = _kfDragStartX;
              if (origin == null || startX == null) return;
              final dx = d.position.dx - startX;
              if (!_kfDragStarted) {
                if (dx.abs() < 3) return;
                _kfDragStarted = true;
                widget.app.beginKeyframeDrag(origin);
              }
              widget.app.updateKeyframeDrag(origin + (dx / ppf).round());
            },
            onPointerUp: (_) {
              if (_kfDragStarted) {
                widget.app.endKeyframeDrag();
              } else if (_kfDragOriginFrame != null) {
                // a plain tap on the selected key deselects it.
                widget.app.selectKeyframeFrame(_kfDragOriginFrame!);
              }
              _endKfPointer();
            },
            onPointerCancel: (_) {
              if (_kfDragStarted) widget.app.endKeyframeDrag();
              _endKfPointer();
            },
            child: CustomPaint(
                painter:
                    _MarkerLinePainter(color: _keyColor, x: _keyHitWidth / 2)),
          ),
        ),
    ];
  }

  void _endKfPointer() {
    _kfDragOriginFrame = null;
    _kfDragStartX = null;
    _kfDragStarted = false;
    _setScrubDragActive(false);
  }

  double? _trimStartGlobalX;

  // The focused layer's two edge lines, each a full-height trim handle.
  // Raw Listener (not a GestureDetector) for the same reason as the
  // playhead: the horizontal scroll view's own pan recognizer would
  // otherwise compete for - and could win - the drag. Each column's hit
  // area stops at the layer's own midpoint so the two can never overlap
  // on a short layer. Keyed so the Listener survives the rebuilds that
  // move it while it's being dragged.
  static const double _trimTapSlop = 6;
  // the edge-column press in progress (state, not locals: the column is
  // rebuilt while the finger is down).
  Offset? _trimDownAt;
  Duration? _trimDownTime;
  bool _trimMoved = false;
  static const Duration _trimTapTimeout = Duration(milliseconds: 350);

  /// Which lane is at a content point (x from the timeline start, y from
  /// the top) - set by build() for the current rows.
  String? Function(Offset contentPos)? _laneAt;

  /// A tap that landed on an edge column: the layer under it gets it, as
  /// if its own lane had been tapped.
  void _tapLaneAt(Offset contentPos) {
    final id = _laneAt?.call(contentPos);
    if (id == null) return;
    // picking several: a tap here adds / removes that layer, as on its lane.
    if (widget.app.timelineGroupPick && id != _focusedLayerId) {
      widget.app.toggleMultiSelect(id);
      return;
    }
    if (id == _focusedLayerId) {
      _toggleFocus(id);
    } else if (widget.app.layerQuickSwitchEnabled) {
      widget.app.selectLayer(id);
      _toggleFocus(id);
    }
  }

  ({double x, int frame, bool start})? _rangeDrag;
  ({double x, int frame, bool start})? _effectDrag;

  /// The edited effect's two edge indicators (whole height, its colour):
  /// drag one to move that edge of its time range.
  List<Widget> _effectColumns(Layer layer, String id, double ppf, double height) {
    final span = effectSpans(layer).where((s) => s.id == id).firstOrNull;
    if (span == null) return const [];
    final color = effectSpanColor(layer, id);
    Widget column(bool start) {
      final x = (layer.startFrame + (start ? span.start : span.end)) * ppf;
      return Positioned(
        key: ValueKey(start ? 'effect-start-line' : 'effect-end-line'),
        left: _edgeSlack + x - _trimHitRadius,
        top: 0,
        width: 2 * _trimHitRadius,
        height: height,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (d) {
            // a second finger (pinch-zoom) never grabs an indicator.
            if (_activePointers.isNotEmpty) return;
            widget.app.pushUndo();
            _effectDrag = (x: d.position.dx, frame: start ? span.start : span.end, start: start);
            _setScrubDragActive(true);
          },
          onPointerMove: (d) {
            final g = _effectDrag;
            if (g == null) return;
            final f = g.frame + ((d.position.dx - g.x) / ppf).round();
            final cur = effectSpans(layer).firstWhere((s) => s.id == id);
            setEffectRange(layer, id, g.start ? f : cur.start, g.start ? cur.end : f);
            widget.app.commitEdit();
          },
          onPointerUp: (_) {
            _effectDrag = null;
            _setScrubDragActive(false);
          },
          onPointerCancel: (_) {
            _effectDrag = null;
            _setScrubDragActive(false);
          },
          child: CustomPaint(painter: _MarkerLinePainter(color: color, x: _trimHitRadius)),
        ),
      );
    }

    return [column(true), column(false)];
  }

  /// A selected key line's two indicators: drag either to move that key;
  /// a tap (no drag) leaves the selection first, like a layer's edges.
  List<Widget> _keySpanColumns(Layer layer, double ppf, double height) {
    final sel = widget.app.keyDetailSelection!;
    final color = keyDetailColor(sel.tab);
    Widget column(bool start) {
      final x = (layer.startFrame + (start ? sel.a : sel.b)) * ppf;
      return Positioned(
        key: ValueKey(start ? 'keyspan-start-line' : 'keyspan-end-line'),
        left: _edgeSlack + x - _trimHitRadius,
        top: 0,
        width: 2 * _trimHitRadius,
        height: height,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (d) {
            if (_activePointers.isNotEmpty) return;
            _effectDrag = (x: d.position.dx, frame: 0, start: start);
            _keySpanMoved = 0;
          },
          onPointerMove: (d) {
            final g = _effectDrag;
            if (g == null) return;
            final total = ((d.position.dx - g.x) / ppf).round();
            if (total == _keySpanMoved) return;
            if (_keySpanMoved == 0 && (d.position.dx - g.x).abs() < 6) return;
            if (!_scrubDragActive) {
              widget.app.pushUndo();
              _setScrubDragActive(true);
            }
            final step = total - _keySpanMoved;
            _keySpanMoved = total;
            g.start ? widget.app.moveSelectedKeySpan(step, 0) : widget.app.moveSelectedKeySpan(0, step);
          },
          onPointerUp: (_) {
            // a tap: leaving the selection comes first.
            if (_effectDrag != null && !_scrubDragActive) widget.app.selectKeyDetailSpan(null);
            _effectDrag = null;
            _setScrubDragActive(false);
          },
          onPointerCancel: (_) {
            _effectDrag = null;
            _setScrubDragActive(false);
          },
          child: CustomPaint(painter: _MarkerLinePainter(color: color, x: _trimHitRadius)),
        ),
      );
    }

    return [column(true), column(false)];
  }

  int _keySpanMoved = 0;

  /// The edited mask's two indicators: drag either to move that edge of
  /// its time.
  List<Widget> _maskColumns(Layer layer, int index, double ppf, double height) {
    final span = maskSpans(layer)[index];
    Widget column(bool start) {
      final x = (layer.startFrame + (start ? span.start : span.end)) * ppf;
      return Positioned(
        key: ValueKey(start ? 'mask-start-line' : 'mask-end-line'),
        left: _edgeSlack + x - _trimHitRadius,
        top: 0,
        width: 2 * _trimHitRadius,
        height: height,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (d) {
            // a second finger (pinch-zoom) never grabs an indicator.
            if (_activePointers.isNotEmpty) return;
            widget.app.pushUndo();
            _effectDrag = (x: d.position.dx, frame: start ? span.start : span.end, start: start);
            _setScrubDragActive(true);
          },
          onPointerMove: (d) {
            final g = _effectDrag;
            if (g == null || index >= layer.masks.length) return;
            final f = g.frame + ((d.position.dx - g.x) / ppf).round();
            final cur = maskSpans(layer)[index];
            setMaskRange(layer, index, g.start ? f : cur.start, g.start ? cur.end : f);
            widget.app.commitEdit();
          },
          onPointerUp: (_) {
            _effectDrag = null;
            _setScrubDragActive(false);
          },
          onPointerCancel: (_) {
            _effectDrag = null;
            _setScrubDragActive(false);
          },
          child: CustomPaint(painter: _MarkerLinePainter(color: maskSpanColor.withOpacity(1), x: _trimHitRadius)),
        ),
      );
    }

    return [column(true), column(false)];
  }

  /// The range's two indicators (Timeline tab, "Range"): drag either to
  /// move that edge.
  List<Widget> _rangeColumns(double ppf, double height) {
    final r = widget.app.timeRange!;
    const color = Color(0xFF64B5F6);
    Widget column(bool start) {
      final x = (start ? r.a : r.b) * ppf;
      return Positioned(
        key: ValueKey(start ? 'range-start-line' : 'range-end-line'),
        left: _edgeSlack + x - _trimHitRadius,
        top: 0,
        width: 2 * _trimHitRadius,
        height: height,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (d) {
            // a second finger (pinch-zoom) never grabs an indicator.
            if (_activePointers.isNotEmpty) return;
            // kept on the state: the drag rebuilds this widget.
            _rangeDrag = (x: d.position.dx, frame: start ? widget.app.timeRange!.a : widget.app.timeRange!.b, start: start);
            widget.app.beginRangeEdgeDrag();
            _setScrubDragActive(true);
          },
          onPointerMove: (d) {
            final g = _rangeDrag;
            if (g == null) return;
            widget.app.setTimeRangeEdgeAt(start: g.start, frame: g.frame + ((d.position.dx - g.x) / ppf).round());
          },
          onPointerUp: (_) {
            _rangeDrag = null;
            _setScrubDragActive(false);
          },
          onPointerCancel: (_) {
            _rangeDrag = null;
            _setScrubDragActive(false);
          },
          child: CustomPaint(painter: _MarkerLinePainter(color: color, x: _trimHitRadius)),
        ),
      );
    }

    // holding the range between its edges and dragging moves it with
    // every layer in it.
    final body = Positioned(
      key: const ValueKey('range-body'),
      left: _edgeSlack + r.a * ppf + _trimHitRadius,
      top: 0,
      width: math.max(0.0, (r.b - r.a) * ppf - 2 * _trimHitRadius),
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: (d) {
          _rangeMoveX = d.globalPosition.dx;
          widget.app.beginRangeMove();
          _setScrubDragActive(true);
        },
        onLongPressMoveUpdate: (d) =>
            widget.app.updateRangeMove(((d.globalPosition.dx - _rangeMoveX) / ppf).round()),
        onLongPressEnd: (_) {
          widget.app.endRangeMove();
          _setScrubDragActive(false);
        },
        onLongPressCancel: () {
          widget.app.endRangeMove();
          _setScrubDragActive(false);
        },
      ),
    );
    return [body, column(true), column(false)];
  }

  double _rangeMoveX = 0;

  // the action row's layer and place, kept while it fades out.
  ({Layer layer, double top})? _actionGhost;

  List<Widget> _trimColumns(Layer layer, double ppf, double height) {
    final startX = layer.startFrame * ppf;
    final endX = (layer.startFrame + layer.durationFrames) * ppf;
    final midX = (startX + endX) / 2;
    final color = laneColor(context, widget.app, layer);

    Widget column(String key, double x, LayerDragMode mode, bool isLeft) {
      final left =
          isLeft ? x - _trimHitRadius : math.max(x - _trimHitRadius, midX);
      final right =
          isLeft ? math.min(x + _trimHitRadius, midX) : x + _trimHitRadius;
      void end() {
        _trimStartGlobalX = null;
        widget.app.endLayerDrag();
        _setScrubDragActive(false);
      }

      // after a split the layer is short, its edge columns cover it, and
      // tapping it again no longer unfocused it (the edge handles took every
      // touch). A quick tap that doesn't move goes to the layer under it - the
      // focused one (unfocus), or with quick switch another lane there;
      // pressing and sliding is the trim.

      return Positioned(
        key: ValueKey(key),
        left: _edgeSlack + left,
        top: 0,
        width: math.max(0.0, right - left),
        height: height,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (d) {
            // a second finger (pinch-zoom) never grabs an indicator.
            if (_activePointers.isNotEmpty) return;
            _trimStartGlobalX = d.position.dx;
            _trimDownAt = Offset(left + d.localPosition.dx, d.localPosition.dy);
            _trimDownTime = d.timeStamp;
            _trimMoved = false;
            widget.app.beginLayerDrag(layer.id, mode);
            _setScrubDragActive(true);
          },
          onPointerMove: (d) {
            final start = _trimStartGlobalX;
            if (start == null) return;
            if (!_trimMoved && (d.position.dx - start).abs() < _trimTapSlop) return;
            _trimMoved = true;
            widget.app.updateLayerDrag(((d.position.dx - start) / ppf).round());
          },
          onPointerUp: (d) {
            final at = _trimDownAt, t0 = _trimDownTime;
            if (!_trimMoved && at != null && t0 != null && d.timeStamp - t0 < _trimTapTimeout) {
              _trimStartGlobalX = null;
              widget.app.cancelLayerDrag(); // nothing changed, no undo step
              _setScrubDragActive(false);
              _tapLaneAt(at);
              return;
            }
            end();
          },
          onPointerCancel: (_) => end(),
          child: CustomPaint(
              painter: _MarkerLinePainter(color: color, x: x - left)),
        ),
      );
    }

    return [
      column('trim-left', startX, LayerDragMode.trimLeft, true),
      column('trim-right', endX, LayerDragMode.trimRight, false),
    ];
  }

  // drag-to-edge auto-scroll (see this file's own top-level doc
  // comment) - the controller lets _LayerLane's move-drag nudge the
  // scroll position directly; the key lets it convert a drag's global
  // pointer position into local viewport coordinates to detect edge
  // proximity.
  final ScrollController _hScrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();

  // AppState.timelineCenterPlayheadEnabled reframes this view into "the
  // filmstrip scrolls under a fixed-center playhead" once turned on: this
  // listener converts a user's own scroll into `setFrame` calls, and `build`
  // below does the symmetric conversion (currentFrame -> scroll position)
  // whenever the frame changes from anywhere else. The two guard flags prevent
  // them from fighting each other in a issue loop (standard two-way-binding
  // pattern) - each is true only for the duration of the OTHER side's own
  // synchronous write, since both `ScrollPosition.jumpTo` and
  // `ChangeNotifier.notifyListeners` call their listeners synchronously.
  //
  // Given this view's own leading/trailing halfViewport padding (see
  // the frame-0-at-center doc comment below), the frame currently
  // sitting at the viewport's horizontal center is simply
  // `scrollPixels / pixelsPerFrame` - the padding is a pure translation
  // applied identically to both "what frame lands where" and "what
  // scroll offset means," so it cancels out of this formula regardless
  // of its own magnitude (confirmed algebraically, not copied from
  // guesswork: screenX(frame F) = halfViewport + F*pixelsPerFrame -
  // scrollPixels; solving screenX = halfViewport, the viewport's own
  // center, leaves F = scrollPixels / pixelsPerFrame with the padding
  // term already cancelled).
  bool _centerPinSyncingFromScroll = false;
  bool _centerPinSyncingFromFrame = false;

  // (scrolling still gets interrupted at high zoom) - root cause, confirmed
  // against Flutter's own AnimatedBuilder/setState source: this flag used to
  // be reset to false SYNCHRONOUSLY right after setFrame returned, on the
  // (wrong) assumption that AnimatedBuilder's own rebuild happens
  // synchronously inside ChangeNotifier.notifyListeners. It doesn't -
  // notifyListeners calls AnimatedBuilder's listener synchronously, but that
  // listener only calls setState({}), which just marks the element dirty; the
  // actual build call (which reads this flag) happens later, at the NEXT
  // frame's build phase - by which point the flag had already been reset. So
  // the "skip the corrective jumpTo, this build was caused by our own scroll"
  // guard never actually fired: every scroll-driven frame change also
  // scheduled build's own corrective jumpTo to the nearest frame-aligned pixel
  // (up to pixelsPerFrame/2 away - worse at high zoom), and ANY jumpTo kills
  // the scroll view's in-flight drag for good (ScrollPosition.jumpTo -> goIdle
  // -> disposes the active drag -> Scrollable._drag = null; the recognizer
  // stays "accepted" so onStart never fires again until every finger lifts).
  // Fixed by clearing the flag in a post-frame callback instead, so it's still
  // true when the asynchronous rebuild actually checks it.
  void _onHScrollChanged() {
    if (!widget.app.timelineCenterPlayheadEnabled) return;
    if (_centerPinSyncingFromFrame) {
      return; // this scroll change was OUR OWN jumpTo below - not a real user scroll
    }
    if (!_hScrollController.hasClients) return;
    final pixelsPerFrame = _pixelsPerFrameAtZoom1 * _zoom;
    final pos = _hScrollController.position;
    final frame =
        (pos.pixels / pixelsPerFrame).round().clamp(0, widget.app.maxFrame);
    if (frame == widget.app.currentFrame) return;
    _centerPinSyncingFromScroll = true;
    widget.app.setFrame(frame, quiet: true);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _centerPinSyncingFromScroll = false);
  }

  // Symmetric half of _onHScrollChanged's two-way binding, made SYNCHRONOUS -
  // fires directly off widget.app's own notifyListeners, in the SAME call
  // stack as whatever changed currentFrame (setFrame, a playback tick, etc.),
  // so the corrective jumpTo lands before this frame's own layout/paint
  // instead of one frame later. This replaces an earlier version that lived
  // inline inside build's own AnimatedBuilder callback and deferred its jumpTo
  // via addPostFrameCallback - during playback, the Timer-driven tick changes
  // currentFrame and notifies BEFORE the corrective scroll lands, so the frame
  // that's about to be painted shows the NEW playhead position against the OLD
  // scroll offset (the correction, deferred to postFrameCallbacks, only takes
  // effect on the NEXT frame) - a one-rendered-frame overshoot-then-snap-back
  // on every tick, worse at high zoom. Same bug class, and same fix, as
  // _onPointerMove's own pinch-zoom correction two rounds ago.
  void _onAppFrameChangedForCenterPin() {
    if (!widget.app.timelineCenterPlayheadEnabled) return;
    if (_centerPinSyncingFromScroll) {
      return; // this frame change was OUR OWN setFrame from a user scroll
    }
    if (!_hScrollController.hasClients) return;
    final pos = _hScrollController.position;
    if (!pos.hasContentDimensions) return; // not laid out yet
    final pixelsPerFrame = _pixelsPerFrameAtZoom1 * _zoom;
    final targetFrame = widget.app.currentFrame;
    // the scroll already shows this frame (a user scroll set it, or a
    // late notification about it): moving it would end the user's drag.
    if ((pos.pixels / pixelsPerFrame).round() == targetFrame) return;
    // computed by hand (not pos.maxScrollExtent, which may be stale if
    // this same notification also changed maxFrame) - same formula
    // _onPointerMove's own pinch correction already uses.
    final maxScrollExtent = widget.app.maxFrame * pixelsPerFrame;
    // low-confidence, cheap, disclosed hardening: round to the nearest
    // whole physical pixel before jumpTo - NOT a proven fix (tracing
    // this method's own call chain shows the correction already lands
    // in the same rendered frame as the currentFrame change it's
    // reacting to, with no remaining sync bug), just consistency with
    // how integer-frame * pixelsPerFrame and Positioned values already
    // tend to land on whole-pixel boundaries at typical zoom levels, in
    // case any sub-pixel rounding mismatch between how Positioned.left
    // and ScrollPosition.jumpTo each snap to physical pixels is
    // otherwise maximally perceptible here - center-pin's own cursor
    // position is algebraically a constant once synced, so any jitter
    // that would be invisible riding along with the non-pinned case's
    // real motion has nothing else to mask it here.
    final target = (targetFrame * pixelsPerFrame)
        .clamp(0.0, maxScrollExtent)
        .roundToDouble();
    if ((pos.pixels - target).abs() < 0.5) return; // already there
    _centerPinSyncingFromFrame = true;
    pos.jumpTo(target);
    _centerPinSyncingFromFrame = false;
  }

  /// Unpinned: which side of the view the playhead went off to (-1 left,
  /// 1 right, 0 on screen) - the toolbar's way back to it.
  /// screenX(F) = halfViewport + F * ppf - scroll.
  void _updatePlayheadSide() {
    var side = 0;
    if (!widget.app.timelineCenterPlayheadEnabled && _hScrollController.hasClients) {
      final pos = _hScrollController.position;
      if (pos.hasContentDimensions) {
        final w = pos.viewportDimension;
        final x = w / 2 + widget.app.currentFrame * _pixelsPerFrameAtZoom1 * _zoom - pos.pixels;
        side = x < 0 ? -1 : x > w ? 1 : 0;
      }
    }
    if (widget.app.playheadSide.value != side) widget.app.playheadSide.value = side;
  }

  /// Scrolls the playhead to the middle of the view.
  void _scrollToPlayhead() {
    if (!_hScrollController.hasClients) return;
    final pos = _hScrollController.position;
    final target = (widget.app.currentFrame * _pixelsPerFrameAtZoom1 * _zoom).clamp(0.0, pos.maxScrollExtent);
    _hScrollController.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// A scroll can end in the middle of a layout (its physics swapped out
  /// for a playhead drag): the panels catch up after that frame.
  void _settleFrame() {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      widget.app.frameSettled();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => widget.app.frameSettled());
    }
  }

  @override
  void initState() {
    super.initState();
    _hScrollController.addListener(_onHScrollChanged);
    widget.app.addListener(_onAppFrameChangedForCenterPin);
    _hScrollController.addListener(_updatePlayheadSide);
    widget.app.addListener(_updatePlayheadSide);
    widget.app.frameNotifier.addListener(_updatePlayheadSide);
    widget.app.scrollToPlayheadRequest.addListener(_scrollToPlayhead);
    widget.app.frameNotifier.addListener(_onAppFrameChangedForCenterPin);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointerEvent);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter
        .removeGlobalRoute(_onGlobalPointerEvent);
    _hScrollController.removeListener(_onHScrollChanged);
    widget.app.removeListener(_onAppFrameChangedForCenterPin);
    widget.app.frameNotifier.removeListener(_onAppFrameChangedForCenterPin);
    widget.app.removeListener(_updatePlayheadSide);
    widget.app.frameNotifier.removeListener(_updatePlayheadSide);
    widget.app.scrollToPlayheadRequest.removeListener(_scrollToPlayhead);
    _hScrollController.dispose();
    super.dispose();
  }

  // defensive, GUARANTEED cleanup of _activePointers - real device
  // report: the (now-removed, see _ReorderHandleCell's own history)
  // reorder-handle column "stopped working entirely after some time" -
  // root cause traced to a stale entry surviving in _activePointers
  // forever whenever a pointer's up/cancel event failed to reach the
  // LOCAL _onPointerUp/_onPointerCancel callbacks below cleanly (e.g. a
  // mid-gesture rebuild racing with a LongPressDraggable's own
  // recognizer accepting) - one ghost entry there permanently biases
  // ALL future 1-vs-2-finger gesture classification on the whole
  // timeline. GestureBinding's global pointer router receives every
  // pointer event system-wide regardless of which local widget's
  // Listener captured (or failed to capture) it - strictly more robust
  // than relying on the local callbacks alone. Purely additive/
  // idempotent: those callbacks still run their own additional
  // pinch-state resets; this is just a safety net that guarantees the
  // map can never leak.
  void _onGlobalPointerEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _activePointers.remove(event.pointer);
    }
  }

  // raw pointer tracking for 2-finger pinch-zoom - see doc comment.
  final Map<int, Offset> _activePointers = {};
  double? _pinchStartDistance;
  double? _pinchStartZoom;
  // the frame sitting at the viewport's own center, captured ONCE when
  // the pinch gesture starts (not re-derived on every move) - see
  // _onPointerMove's own doc comment for why re-deriving it mid-gesture
  // is fragile: two pointer-move events (one per finger) can land in
  // the same frame, and the second one would read a scroll position
  // whose own correction from the first is still pending in a not-yet-
  // run postFrameCallback, producing a stale/wrong center.
  double? _pinchCenteredFrame;

  // (at high zoom, a scroll swipe starting on the playhead's own touch column
  // steals the gesture and kills the scroll) - the playhead's
  // Listener.onPointerDown starts a scrub for ANY touch in its column,
  // unconditionally, which flips the scroll view to
  // NeverScrollableScrollPhysics and cancels its in-flight drag recognizer
  // outright. _Playhead ignores touches entirely whenever center-pin is on
  // (scrolling already scrubs in that mode - dragging the playhead adds
  // nothing there).
  //
  // A previous round ALSO tried extending this ignore to any active 2-finger
  // pinch (a new `_isPinching` getter + `setState` in
  // `_onPointerDown`/`_onPointerUp`, to make it reactive), on the theory that
  // a finger resting on the playhead mid-pinch was independently calling
  // setFrame, fighting the pinch's own zoom math. Verified this round to be
  // both ineffective AND actively harmful, so removed: hit-testing for pointer
  // N happens BEFORE `_onPointerDown` runs, against the tree as built after
  // pointer N-1 - by the time `_isPinching` becomes true and a rebuild
  // eventually reflects it, the pointer that triggered it has already
  // established its hit-test path, so it never actually protected pointers 1
  // or 2 of any pinch. Meanwhile the added `setState` calls made EVERY touch
  // (not just pinches) trigger a rebuild, which in center-pin mode could
  // schedule the rounding-driven corrective jumpTo from `_onHScrollChanged`'s
  // own doc comment - i.e. a second finger landing anywhere during an ordinary
  // scroll could kill it too. `timelineCenterPlayheadEnabled` alone is a
  // correct guard (stable across a gesture, read at build time); the
  // pinch-anchor math itself was independently re-verified this round to
  // already be finger-position-independent (see `_onPointerMove`'s own doc
  // comment) - the perception traced back to a real bug, but a different one
  // (the one-frame lag fixed in `_onPointerMove` below), not to this.

  /// Ends any edge / key / range drag in progress (a pinch started).
  void _cancelIndicatorDrags() {
    if (_trimStartGlobalX != null) {
      _trimStartGlobalX = null;
      widget.app.cancelLayerDrag();
    }
    _effectDrag = null;
    _rangeDrag = null;
    _kfDragOriginFrame = null;
    _setScrubDragActive(false);
  }

  void _onPointerDown(PointerDownEvent e) {
    _activePointers[e.pointer] = e.position;
    if (_activePointers.length == 2) {
      // a pinch: whatever indicator the first finger held lets go.
      _cancelIndicatorDrags();
      final pts = _activePointers.values.toList();
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _pinchStartZoom = _zoom;
      _pinchCenteredFrame = _hScrollController.hasClients
          ? _hScrollController.position.pixels /
              (_pixelsPerFrameAtZoom1 * _zoom)
          : null;
    }
  }

  // (anchor pinch-zoom to the middle point; at an edge, the edge itself
  // becomes that middle point) - per the choice, the FIXED viewport center
  // (not the pinch's own focal point). Previously the pinch handler only
  // rescaled `_zoom`, never touching scroll offset, so content visibly slid
  // out from under both fingers on every zoom gesture.
  //
  // The anchor math itself (`_pinchCenteredFrame`, derived purely from scroll
  // position, never from either finger's own screen position) is correct and
  // was re-verified this round. traced to a real bug, but a TIMING one, not a
  // math one: the scroll correction below used to run in
  // `WidgetsBinding.instance.addPostFrameCallback`, which only takes effect
  // AFTER a frame is already built/laid out/painted. With move events arriving
  // roughly every frame during an active pinch, every frame actually shown
  // paired the NEW zoom with the PREVIOUS frame's (not-yet-corrected) scroll
  // offset - the visible center drifted by roughly `centeredFrame *
  // (newPixelsPerFrame - oldPixelsPerFrame)` px on every single move event,
  // only snapping back once the fingers stopped moving. Fixed by computing the
  // new max-scroll-extent directly (the same formula the LayoutBuilder below
  // uses) instead of waiting for a fresh layout pass to expose it via
  // `pos.maxScrollExtent`, so the correction lands in the SAME synchronous
  // call as the zoom change - every rendered frame now shows the new zoom
  // already paired with the corrected offset.
  void _onPointerMove(PointerMoveEvent e) {
    if (!_activePointers.containsKey(e.pointer)) return;
    _activePointers[e.pointer] = e.position;
    final startDist = _pinchStartDistance, startZoom = _pinchStartZoom;
    if (_activePointers.length == 2 &&
        startDist != null &&
        startDist > 0 &&
        startZoom != null) {
      final pts = _activePointers.values.toList();
      final dist = (pts[0] - pts[1]).distance;
      final newZoom =
          (startZoom * (dist / startDist)).clamp(_minZoom, _maxZoom);
      final newPixelsPerFrame = _pixelsPerFrameAtZoom1 * newZoom;
      // fixed for the whole gesture (see _pinchCenteredFrame's own doc
      // comment) - see _onHScrollChanged's own doc comment for why this
      // formula needs no halfViewport term despite this view's leading/
      // trailing padding (it cancels algebraically). Composes for free
      // with center-pin: if that's on, this already equals currentFrame
      // (kept in sync at all times), so zooming keeps the pinned frame
      // centered automatically, no special-casing needed.
      final centeredFrame = _pinchCenteredFrame;

      setState(() => _zoom = newZoom);

      if (centeredFrame != null && _hScrollController.hasClients) {
        final pos = _hScrollController.position;
        // same formula as `contentWidth` in the LayoutBuilder below -
        // computed by hand instead of read from `pos.maxScrollExtent`,
        // since that only reflects the NEW zoom after a fresh layout
        // pass, which hasn't happened yet at this point in the frame.
        // `viewportDimension` is stable across zoom (screen size only).
        final newMaxScrollExtent = widget.app.maxFrame * newPixelsPerFrame;
        // `.clamp` is exactly "the edge becomes the middle point" when
        // the ideal offset to keep centeredFrame centered would fall
        // outside the scrollable range.
        final target =
            (centeredFrame * newPixelsPerFrame).clamp(0.0, newMaxScrollExtent);
        pos.jumpTo(target);
      }
    }
  }

  void _onPointerUp(PointerEvent e) {
    _activePointers.remove(e.pointer);
    if (_activePointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartZoom = null;
      _pinchCenteredFrame = null;
    }
  }

  /// The selection last seen (see build: focus follows it).
  String? _seenSelected;

  void _toggleFocus(String layerId) {
    setState(() {
      final leaving = _focusedLayerId;
      _focusedLayerId = _focusedLayerId == layerId ? null : layerId;
      // leaving the layer ends picking others to go with it - else the
      // next taps would only add to that group, never focus a layer.
      if (_focusedLayerId == null) widget.app.timelineGroupPick = false;

      // keyframe selection belongs to the focused layer - kept (glowing)
      // on the one left when "keep selected keys" is on.
      widget.app.switchKeySelection(leaving, _focusedLayerId);
    });
  }

  // live reorder preview (the reorder handle's drag): the dragged layer,
  // the row it would land in (counted with the layer taken out) and
  // whether it joins that row or becomes a new row there, and the
  // finger's y.
  String? _reorderId;
  int? _reorderTarget;
  bool _reorderJoin = false;
  double? _reorderY;

  void _onReorderPreview(String? id, int? target, bool join, double? y) {
    setState(() {
      _reorderId = id;
      _reorderTarget = target;
      _reorderJoin = join;
      _reorderY = y;
    });
  }

  // the layer action row (split / start to playhead / fit to playhead):
  // it appears under the focused lane, as far below it as the first lane
  // is below the toolbar, and pushes the lanes after it down.
  static const double _actionRowHeight = 28;
  static const double _actionRowGap = _rulerHeight;
  static const double _actionRowSpace = _actionRowGap + _actionRowHeight + 4;

  /// Timeline rows on screen (several layers can share a row - see
  /// movement_core's timeline_rows.dart): the project's, or - while the
  /// reorder handle is dragged - the rows the drop would produce.
  List<List<Layer>> _displayRows(List<List<Layer>> rows) {
    final id = _reorderId, target = _reorderTarget;
    if (id == null || target == null) return rows;
    final layer = rows.expand((r) => r).where((l) => l.id == id).firstOrNull;
    if (layer == null) return rows;
    final out = [
      for (final r in rows) [...r]..remove(layer)
    ]..removeWhere((r) => r.isEmpty);
    if (_reorderJoin && target < out.length && fitsInTimelineRow(out[target], layer)) {
      out[target].add(layer);
    } else {
      out.insert(target.clamp(0, out.length), [layer]);
    }
    return out;
  }

  /// Folders on the timeline: a hollow fold row over each run of rows
  /// whose layers all sit in one folder; a folded folder hides its rows.
  /// Fold rows are empty rows here; `headers` maps their index to the
  /// folder.
  ({List<List<Layer>> rows, Map<int, String> headers}) _foldFolders(List<List<Layer>> rows) {
    final collapsed = widget.app.collapsedTimelineFolders;
    String? folderOf(List<Layer> r) {
      final f = r.isEmpty ? null : r.first.folder;
      return f != null && r.every((l) => l.folder == f) ? f : null;
    }

    final out = <List<Layer>>[];
    final headers = <int, String>{};
    var i = 0;
    while (i < rows.length) {
      final f = folderOf(rows[i]);
      if (f == null) {
        out.add(rows[i]);
        i++;
        continue;
      }
      var j = i;
      while (j < rows.length && folderOf(rows[j]) == f) {
        j++;
      }
      headers[out.length] = f;
      out.add(<Layer>[]);
      if (!collapsed.contains(f)) out.addAll(rows.sublist(i, j));
      i = j;
    }
    return (rows: out, headers: headers);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.app,
      builder: (context, _) {
        final layers = widget.app.project.layers;
        final maxFrame = widget.app.maxFrame;
        final pixelsPerFrame = _pixelsPerFrameAtZoom1 * _zoom;
        // a layer list change mid-drag (undo, delete) drops the preview.
        if (_reorderId != null && !layers.any((l) => l.id == _reorderId)) {
          _reorderId = _reorderTarget = null;
          _reorderY = null;
        }
        final rows = timelineRows(widget.app.project);
        final folded = _foldFolders(_displayRows(rows));
        final displayRows = folded.rows;
        final modelFolded = _foldFolders(rows);
        final rowOf = <String, int>{
          for (var r = 0; r < displayRows.length; r++)
            for (final l in displayRows[r]) l.id: r
        };
        final display = [for (final r in displayRows) ...r];
        // the focused layer's ROW (the action row goes under it).
        final focusedIndex = _focusedLayerId == null ? -1 : (rowOf[_focusedLayerId] ?? -1);
        // hidden while layers are dragged: they go over its place.
        final showActionRow = focusedIndex >= 0 && _reorderId == null && widget.app.layerDragDy == 0;
        // detail rows (effect ranges / expanded keys) under the action row.
        final focusedForDetail = showActionRow ? findLayer(widget.app.project, _focusedLayerId) : null;
        final detailRows = focusedForDetail == null ? 0 : detailRowCount(widget.app, focusedForDetail);
        final detailSpace = detailRows == 0 ? 0.0 : detailRows * detailRowHeight + 6;
        final belowSpace = _actionRowSpace + detailSpace;
        // the action row goes under the LOWEST selected layer, so every
        // layer selected together stays above it.
        final groupRows = [
          for (final id in widget.app.selectedGroup)
            if (rowOf[id] != null) rowOf[id]!
        ];
        final actionIndex = focusedIndex < 0 ? -1 : [focusedIndex, ...groupRows].reduce(math.max);
        double rowTop(int i) =>
            _rulerHeight +
            i * _rowHeight +
            (showActionRow && i > actionIndex ? belowSpace : 0);
        if (showActionRow) {
          _actionGhost = (layer: findLayer(widget.app.project, _focusedLayerId)!, top: _rulerHeight + actionIndex * _rowHeight + _rowHeight + (_actionRowSpace - _actionRowHeight) / 2);
        }
        final totalHeight = _rulerHeight +
            _rowHeight * displayRows.length +
            (showActionRow ? belowSpace : 0);
        final ppfNow = _pixelsPerFrameAtZoom1 * _zoom;
        _laneAt = (p) {
          final frame = p.dx / ppfNow;
          for (var r = 0; r < displayRows.length; r++) {
            final top = rowTop(r);
            if (p.dy < top || p.dy >= top + _rowHeight) continue;
            for (final l in displayRows[r]) {
              if (frame >= l.startFrame && frame <= l.startFrame + l.durationFrames) return l.id;
            }
          }
          return null;
        };

        // (deleting the focused layer permanently dims every other layer) -
        // confirmed root cause: `dimmed` below is `_focusedLayerId != null &&
        // _focusedLayerId != layer.id`, so once the focused layer is deleted,
        // the stale id matches NO remaining layer, dimming all of them (dimmed
        // lanes are non-interactive by design). Self- heals here rather than
        // requiring every deletion call site to know about this widget's own
        // local state.
        if (_focusedLayerId != null &&
            !layers.any((l) => l.id == _focusedLayerId)) {
          _focusedLayerId = null;
        }
        // the selection changed from elsewhere (a new or copied layer,
        // the Layers tab, the stage): a focused timeline follows it, so
        // it never stays on the old layer with the new one dimmed.
        final sel = widget.app.selection.selectedLayer;
        if (sel != _seenSelected) {
          _seenSelected = sel;
          if (_focusedLayerId != null && sel != null && layers.any((l) => l.id == sel)) _focusedLayerId = sel;
        }


        // center-pin's frame->scroll correction now lives in
        // _onAppFrameChangedForCenterPin, a direct synchronous
        // widget.app listener (see its own doc comment) - no longer
        // computed here inside build().

        // (the playhead should reach the very bottom of the visible area, not
        // just grow with layer count) - this outer LayoutBuilder captures the
        // REAL fixed height main.dart's own Expanded gives this whole widget,
        // BEFORE the vertical SingleChildScrollView below loosens it to
        // unbounded (the innermost LayoutBuilder, inside that scroll view,
        // only ever sees an unbounded height, so it could never read this).
        // `effectiveHeight` below is `max(totalHeight, viewportHeight)`: with
        // few layers, the playhead reaches the actually-visible bottom instead
        // of stopping partway; with enough layers to need vertical scrolling,
        // it's just `totalHeight` again - unaffected, still grows to cover
        // every layer.
        return LayoutBuilder(
          builder: (context, outerConstraints) {
            final viewportHeight = outerConstraints.maxHeight;
            final effectiveHeight = viewportHeight.isFinite
                ? math.max(totalHeight, viewportHeight)
                : totalHeight;
            return Listener(
              key: _viewportKey,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerUp,
              // vertical SingleChildScrollView: this view's natural content
              // height (ruler + one fixed-height row per layer) can exceed
              // whatever height main.dart's layout actually has room for -
              // e.g. a real keyboard opening shrinks the whole Scaffold
              // body, same mechanism params_panel_focus_test.dart already
              // covers for the params panel. Scrolling to see more layers,
              // rather than a hard vertical overflow, is what makes this
              // view gracefully tolerate a squeezed viewport instead of
              // erroring.
              child: SingleChildScrollView(
                // the reorder handle belongs where the very first reorder
                // column was - its own reserved strip at the right edge,
                // outside the scrolling/fading content, never drawn over the
                // layer lines. Outside the horizontal scroll (never moves
                // sideways), inside this vertical one (stays aligned with the
                // rows). laid OVER the timeline's right edge (not beside it),
                // so the timeline's middle - the playhead - is the screen's.
                child: Stack(
                  children: [
                    SizedBox(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // exactly the timeline's own length - no floor at
                          // the viewport width. with a viewport-wide floor, a
                          // short (deeply zoomed- out) timeline ran the ruler
                          // past its end, and the end stopped right of center
                          // instead of at it.
                          final contentWidth = maxFrame * pixelsPerFrame;
                          // half a viewport of blank space on each side, so
                          // frame 0 sits at the viewport's horizontal CENTER at
                          // the default scroll offset (0) - see this file's own
                          // top-level doc comment.
                          final halfViewport = constraints.maxWidth / 2;
                          final pinned =
                              widget.app.timelineCenterPlayheadEnabled;
                          final focusedLayer = _focusedLayerId == null
                              ? null
                              : layers
                                  .firstWhere((l) => l.id == _focusedLayerId);
                          // _edgeSlack on both sides - see its own comment.
                          // Every Positioned child below adds _edgeSlack to
                          // its frame-based x.
                          final content = SizedBox(
                            width: _edgeSlack + contentWidth + _edgeSlack,
                            height: effectiveHeight,
                            child: Stack(
                              children: [
                                // lanes are positioned (not a Column) so a
                                // reorder can slide them into their new rows
                                // - the dragged one follows the finger.
                                Positioned(
                                  left: _edgeSlack,
                                  top: 0,
                                  width: contentWidth + _edgeSlack,
                                  height: effectiveHeight,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned(
                                        left: 0,
                                        top: 0,
                                        height: _rulerHeight,
                                        width: contentWidth,
                                        // a tap: the playhead a step toward it.
                                        child: GestureDetector(
                                          key: const ValueKey('ruler-step'),
                                          behavior: HitTestBehavior.opaque,
                                          onTapUp: widget.app.rulerTapSteps
                                              ? (d) {
                                                  final app = widget.app;
                                                  final at = app.currentFrame * pixelsPerFrame;
                                                  final dir = d.localPosition.dx >= at ? 1 : -1;
                                                  app.setFrame((app.currentFrame + dir * app.rulerStepFrames)
                                                      .clamp(0, math.max(0, maxFrame)));
                                                }
                                              : null,
                                          child: _AnimatedRuler(
                                              pixelsPerFrame: pixelsPerFrame,
                                              maxFrame: maxFrame,
                                              inFrames: widget.app.rulerInFrames),
                                        ),
                                      ),
                                      for (var i = 0; i < display.length; i++)
                                        AnimatedPositioned(
                                          key: ValueKey(display[i].id),
                                          duration: display[i].id == _reorderId
                                              ? Duration.zero
                                              : const Duration(
                                                  milliseconds: 150),
                                          curve: Curves.easeOut,
                                          left: 0,
                                          top: display[i].id == _reorderId &&
                                                  _reorderY != null
                                              ? _reorderY! - _rowHeight / 2
                                              : rowTop(rowOf[display[i].id]!),
                                          height: _rowHeight,
                                          // editing an effect's range: the
                                          // layer dims under its line.
                                          child: Opacity(
                                            opacity: ((widget.app.editingEffectId != null && widget.app.showEffectRows) ||
                                                        (widget.app.editingMaskIndex != null && widget.app.showMaskRows)) &&
                                                    display[i].id == _focusedLayerId
                                                ? 0.35
                                                : 1,
                                            child: _LayerLane(
                                            app: widget.app,
                                            layer: display[i],
                                            pixelsPerFrame: pixelsPerFrame,
                                            height: _rowHeight,
                                            selected: display[i].id ==
                                                widget.app.selection
                                                    .selectedLayer,
                                            focused: _focusedLayerId ==
                                                display[i].id,
                                            // the layers selected with the
                                            // focused one light up with it.
                                            dimmed: _focusedLayerId != null &&
                                                _focusedLayerId != display[i].id &&
                                                !(widget.app.selectedGroup.length > 1 &&
                                                    widget.app.selectedGroup.contains(display[i].id)),
                                            quickSwitchEnabled: widget
                                                .app.layerQuickSwitchEnabled,
                                            onToggleFocus: () =>
                                                _toggleFocus(display[i].id),
                                            onDragActiveChanged:
                                                _setScrubDragActive,
                                            hScrollController:
                                                _hScrollController,
                                            viewportKey: _viewportKey,
                                          ),
                                          ),
                                        ),
                                      // text parts with a time of their own: a
                                      // thin line each along the text's lane.
                                      for (final l in display)
                                        if (l.content.text case final t? when t.spans.any((p) => p.from != null || p.to != null))
                                          for (var k = 0; k < t.spans.length; k++)
                                            if (t.spans[k].from != null || t.spans[k].to != null)
                                              Positioned(
                                                key: ValueKey('text-part-span-${l.id}-$k'),
                                                left: (l.startFrame + (t.spans[k].from ?? 0)) * pixelsPerFrame,
                                                top: rowTop(rowOf[l.id]!) + _rowHeight - 5 - (k % 3) * 3,
                                                width: math.max(
                                                    2.0,
                                                    ((t.spans[k].to ?? l.durationFrames) - (t.spans[k].from ?? 0)) *
                                                        pixelsPerFrame),
                                                height: 2,
                                                child: const IgnorePointer(child: ColoredBox(color: Color(0xFFBA68C8))),
                                              ),
                                      // folders: a hollow line from the first
                                      // of its layers to the end of the last;
                                      // a tap folds / unfolds it.
                                      for (final e in folded.headers.entries)
                                        () {
                                          final members = [for (final l in layers) if (l.folder == e.value) l];
                                          final a0 = members.isEmpty ? 0 : members.map((l) => l.startFrame).reduce(math.min);
                                          final b0 = members.isEmpty
                                              ? 0
                                              : members.map((l) => l.startFrame + l.durationFrames).reduce(math.max);
                                          final open = !widget.app.collapsedTimelineFolders.contains(e.value);
                                          return Positioned(
                                            key: ValueKey('timeline-folder-${e.value}-${e.key}'),
                                            left: a0 * pixelsPerFrame,
                                            top: rowTop(e.key) + 5,
                                            width: math.max(24.0, (b0 - a0) * pixelsPerFrame),
                                            height: _rowHeight - 10,
                                            child: GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () => widget.app.toggleTimelineFolder(e.value),
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  border: Border.all(color: Colors.white54, width: 1.5),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                                child: Row(children: [
                                                  Icon(open ? Icons.expand_more : Icons.chevron_right,
                                                      size: 14, color: Colors.white70),
                                                  Flexible(
                                                    child: Text(
                                                      open ? e.value : '${e.value} (${members.length})',
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                                                    ),
                                                  ),
                                                ]),
                                              ),
                                            ),
                                          );
                                        }(),
                                      // range selection: outside it dims,
                                      // inside it lights up like a
                                      // selected layer's band.
                                      // as a selection (Settings): only the
                                      // layers' stretches inside it light up.
                                      if (widget.app.timeRange != null && widget.app.rangeAsSelection)
                                        for (final l in display)
                                          if (l.startFrame < widget.app.timeRange!.b &&
                                              l.startFrame + l.durationFrames > widget.app.timeRange!.a)
                                            Positioned(
                                              key: ValueKey('range-sel-${l.id}'),
                                              left: math.max(l.startFrame, widget.app.timeRange!.a) * pixelsPerFrame,
                                              top: rowTop(rowOf[l.id]!),
                                              width: (math.min(l.startFrame + l.durationFrames, widget.app.timeRange!.b) -
                                                      math.max(l.startFrame, widget.app.timeRange!.a)) *
                                                  pixelsPerFrame,
                                              height: _rowHeight,
                                              child: IgnorePointer(
                                                child: ColoredBox(
                                                    color: laneColor(context, widget.app, l)
                                                        .withOpacity(_focusBandOpacity)),
                                              ),
                                            ),
                                      if (widget.app.timeRange != null && !widget.app.rangeAsSelection) ...[
                                        Positioned(
                                          key: const ValueKey('range-band'),
                                          left: widget.app.timeRange!.a * pixelsPerFrame,
                                          top: 0,
                                          width: (widget.app.timeRange!.b - widget.app.timeRange!.a) * pixelsPerFrame,
                                          height: effectiveHeight,
                                          child: const IgnorePointer(
                                            child: ColoredBox(color: Color(0x2264B5F6)),
                                          ),
                                        ),
                                        for (final (from, to) in [
                                          (0, widget.app.timeRange!.a),
                                          (widget.app.timeRange!.b, maxFrame),
                                        ])
                                          if (to > from)
                                            Positioned(
                                              key: ValueKey('range-dim-$from'),
                                              left: from * pixelsPerFrame,
                                              top: 0,
                                              width: (to - from) * pixelsPerFrame,
                                              height: effectiveHeight,
                                              // outside the range fades
                                              // out (see-through), not dark.
                                              child: IgnorePointer(
                                                child: ColoredBox(
                                                    color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.6)),
                                              ),
                                            ),
                                      ],
                                      if (detailRows > 0)
                                        Positioned(
                                          key: const ValueKey('layer-detail-rows'),
                                          left: 0,
                                          top: rowTop(actionIndex) + _rowHeight + _actionRowSpace,
                                          width: contentWidth + _edgeSlack,
                                          height: detailRows * detailRowHeight,
                                          child: Stack(clipBehavior: Clip.none, children: [
                                            if (widget.app.showEffectRows)
                                              Positioned.fill(
                                                child: EffectSpanRows(
                                                    app: widget.app,
                                                    layer: focusedForDetail!,
                                                    pixelsPerFrame: pixelsPerFrame,
                                                    onDragActiveChanged: _setScrubDragActive),
                                              ),
                                            // mask time lines under the effect lines
                                            // (mask regions: their areas, always).
                                            if (widget.app.showMaskRows || regionRowsOn(focusedForDetail!))
                                              Positioned(
                                                left: 0,
                                                right: 0,
                                                top: effectRowCount(widget.app, focusedForDetail!) * detailRowHeight,
                                                height: maskRowCount(widget.app, focusedForDetail) * detailRowHeight,
                                                child: focusedForDetail.maskRegions?.enabled == true &&
                                                        focusedForDetail.maskRegions!.sources.isNotEmpty
                                                    ? RegionEpisodeRows(
                                                        app: widget.app,
                                                        layer: focusedForDetail,
                                                        pixelsPerFrame: pixelsPerFrame)
                                                    : MaskSpanRows(
                                                        app: widget.app,
                                                        layer: focusedForDetail,
                                                        pixelsPerFrame: pixelsPerFrame),
                                              ),
                                            // the key rows under them.
                                            if (widget.app.showKeyRows)
                                              Positioned(
                                                left: 0,
                                                right: 0,
                                                top: (effectRowCount(widget.app, focusedForDetail) +
                                                        maskRowCount(widget.app, focusedForDetail)) *
                                                    detailRowHeight,
                                                bottom: 0,
                                                child: KeyDetailRows(
                                                    key: ValueKey('key-detail-${focusedForDetail.id}'),
                                                    app: widget.app,
                                                    layer: focusedForDetail,
                                                    pixelsPerFrame: pixelsPerFrame),
                                              ),
                                          ]),
                                        ),
                                    ],
                                  ),
                                ),
                                // the focused layer's edge lines run the WHOLE
                                // timeline height (same painter/thickness as
                                // the playhead), and the whole line is a trim
                                // handle, not just where it crosses the
                                // layer's row. hidden while an effect's range
                                // is edited: its end handles sit on the same
                                // lines.
                                if (focusedLayer != null &&
                                    !widget.app.timelineHandlesLocked &&
                                    !(widget.app.editingEffectId != null && widget.app.showEffectRows) &&
                                    !(widget.app.editingMaskIndex != null && widget.app.showMaskRows))
                                  ..._trimColumns(focusedLayer, pixelsPerFrame,
                                      effectiveHeight),
                                // a selected key line: its two keys' indicators.
                                if (focusedLayer != null &&
                                    widget.app.showKeyRows &&
                                    widget.app.keyDetailSelection?.layerId == focusedLayer.id)
                                  ..._keySpanColumns(focusedLayer, pixelsPerFrame, effectiveHeight),
                                if (widget.app.timeRange != null)
                                  ..._rangeColumns(pixelsPerFrame, effectiveHeight),
                                if (focusedLayer != null &&
                                    widget.app.editingMaskIndex != null &&
                                    widget.app.showMaskRows &&
                                    widget.app.editingMaskIndex! < focusedLayer.masks.length)
                                  ..._maskColumns(focusedLayer, widget.app.editingMaskIndex!, pixelsPerFrame, effectiveHeight),
                                // ...and the masked time on the lane itself in
                                // the mask's colour, over the dimmed layer.
                                if (focusedLayer != null &&
                                    widget.app.editingMaskIndex != null &&
                                    widget.app.showMaskRows &&
                                    widget.app.editingMaskIndex! < focusedLayer.masks.length &&
                                    rowOf[focusedLayer.id] != null)
                                  () {
                                    final sp = maskSpans(focusedLayer)[widget.app.editingMaskIndex!];
                                    return Positioned(
                                      key: const ValueKey('mask-span-on-lane'),
                                      left: _edgeSlack + (focusedLayer.startFrame + sp.start) * pixelsPerFrame,
                                      top: rowTop(rowOf[focusedLayer.id]!) + 3,
                                      width: math.max(2.0, (sp.end - sp.start) * pixelsPerFrame),
                                      height: _rowHeight - 6,
                                      child: IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: maskSpanColor,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                        ),
                                      ),
                                    );
                                  }(),
                                if (focusedLayer != null && widget.app.editingEffectId != null && widget.app.showEffectRows)
                                  ..._effectColumns(focusedLayer, widget.app.editingEffectId!, pixelsPerFrame, effectiveHeight),
                                // draggable only when center-pin is OFF - when
                                // it's on, the fixed, non-interactive playhead
                                // beside ShaderMask below is used instead.
                                if (!pinned)
                                  _Playhead(
                                      app: widget.app,
                                      pixelsPerFrame: pixelsPerFrame,
                                      totalHeight: effectiveHeight,
                                      originX: _edgeSlack,
                                      ignoreTouch: false,
                                      onDragActiveChanged: _setScrubDragActive,
                                      hScrollController: _hScrollController,
                                      viewportKey: _viewportKey),
                                // above the playhead: selecting a key moves
                                // the playhead onto it, and the key must
                                // still be the thing you grab there.
                                if (focusedLayer != null && !widget.app.timelineHandlesLocked)
                                  ..._keyframeColumns(focusedLayer,
                                      pixelsPerFrame, effectiveHeight),
                              ],
                            ),
                          );
                          return Stack(
                            children: [
                              // third "this layer is selected" cue (beside the
                              // edge lines and the dimming): the focused row is
                              // tinted in the layer's color across the whole
                              // visible width.
                              // the layers selected with it: the same band.
                              if (focusedLayer != null)
                                for (final id in widget.app.selectedGroup)
                                  if (id != focusedLayer.id && rowOf[id] != null)
                                    Positioned(
                                      key: ValueKey('group-band-$id'),
                                      left: 0,
                                      right: 0,
                                      top: rowTop(rowOf[id]!),
                                      height: _rowHeight,
                                      child: IgnorePointer(
                                        child: ColoredBox(
                                            color: laneColor(context, widget.app, findLayer(widget.app.project, id)!)
                                                .withOpacity(_focusBandOpacity)),
                                      ),
                                    ),
                              if (focusedLayer != null)
                                Positioned(
                                  key: const ValueKey('focus-band'),
                                  left: 0,
                                  right: 0,
                                  top: rowTop(focusedIndex),
                                  height: _rowHeight,
                                  child: IgnorePointer(
                                    child: ColoredBox(
                                        color: laneColor(context, widget.app, focusedLayer)
                                            .withOpacity(_focusBandOpacity)),
                                  ),
                                ),
                              // keyed: the focus band before it and the
                              // action row after it come and go, and an
                              // unkeyed scroll view would be rebuilt (losing
                              // its scroll position) when they do.
                              ShaderMask(
                                key: const ValueKey('timeline-hscroll'),
                                shaderCallback: (bounds) =>
                                    const LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black,
                                    Colors.black,
                                    Colors.transparent
                                  ],
                                  stops: [0.0, 0.04, 0.96, 1.0],
                                ).createShader(bounds),
                                blendMode: BlendMode.dstIn,
                                // `overscroll: false` removes Android's stretch
                                // indicator (and its reentrant listener) - see
                                // this file's own top-level doc comment.
                                // a center-pin scroll moved the frame quietly
                                // (AppState.setFrame) - the rest of the UI
                                // catches up once the scroll stops.
                                child: NotificationListener<ScrollEndNotification>(
                                  onNotification: (_) {
                                    _settleFrame();
                                    return false;
                                  },
                                  child: ScrollConfiguration(
                                  behavior: ScrollConfiguration.of(context)
                                      .copyWith(overscroll: false),
                                  child: SingleChildScrollView(
                                    controller: _hScrollController,
                                    scrollDirection: Axis.horizontal,
                                    physics: _scrubDragActive
                                        ? const NeverScrollableScrollPhysics()
                                        : null,
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                          left: math.max(
                                              0.0, halfViewport - _edgeSlack),
                                          right: math.max(
                                              0.0, halfViewport - _edgeSlack)),
                                      child: pinned
                                          ? _FrameQuantized(
                                              controller: _hScrollController,
                                              app: widget.app,
                                              pixelsPerFrame: pixelsPerFrame,
                                              child: content,
                                            )
                                          : content,
                                    ),
                                  ),
                                ),
                                ),
                              ),
                              // center-pin: a literal constant position, never
                              // derived from currentFrame/scroll offset.
                              if (pinned)
                                Positioned(
                                  key: const ValueKey('pinned-playhead'),
                                  left: halfViewport - 8,
                                  top: 0,
                                  width: 16,
                                  height: effectiveHeight,
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                        painter: _PlayheadPainter()),
                                  ),
                                ),
                              // pinned: the whole playhead is an (invisible)
                              // play / pause button.
                              if (pinned && widget.app.playOnPlayheadTap)
                                Positioned(
                                  key: const ValueKey('playhead-play'),
                                  left: halfViewport - 12,
                                  top: 0,
                                  width: 24,
                                  height: effectiveHeight,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTap: widget.app.togglePlay,
                                  ),
                                ),
                              // the layer action row, under the focused lane.
                              // fades in when a layer is picked, and out
                              // (where it was) when it's let go.
                              if (_actionGhost != null)
                                Positioned(
                                  key: const ValueKey('layer-action-row'),
                                  left: 4,
                                  // all its buttons reachable: it scrolls
                                  // sideways when they don't fit.
                                  right: 4,
                                  top: _actionGhost!.top,
                                  height: _actionRowHeight,
                                  child: IgnorePointer(
                                    ignoring: !showActionRow,
                                    child: TweenAnimationBuilder<double>(
                                      key: ValueKey('action-fade-${_actionGhost!.layer.id}-$showActionRow'),
                                      tween: showActionRow ? Tween(begin: 0, end: 1) : Tween(begin: 1, end: 0),
                                      duration: const Duration(milliseconds: 200),
                                      onEnd: () {
                                        if (!showActionRow && mounted) setState(() => _actionGhost = null);
                                      },
                                      builder: (context, t, child) => Opacity(opacity: t, child: child),
                                      child: _LayerActionRow(
                                          app: widget.app,
                                          layer: _actionGhost!.layer),
                                    ),
                                  ),
                                ),
                              // selected keys: their own bin under the layer's
                              // one - a bare icon that fades in with them.
                              if (_actionGhost != null)
                                Positioned(
                                  key: const ValueKey('keys-bin'),
                                  left: 4,
                                  top: _actionGhost!.top + _actionRowHeight,
                                  child: IgnorePointer(
                                    ignoring: kfSelectedFrames.isEmpty,
                                    child: AnimatedOpacity(
                                      opacity: kfSelectedFrames.isEmpty ? 0 : 1,
                                      duration: const Duration(milliseconds: 200),
                                      child: IconButton(
                                        key: const ValueKey('delete-selected-keys'),
                                        icon: const Icon(Icons.delete_outline, size: 18, color: _keyColor),
                                        tooltip: 'delete the selected keys',
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.all(4),
                                        constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                                        onPressed: widget.app.deleteSelectedKfs,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      width: _reorderColumnWidth,
                      height: effectiveHeight,
                      child: _ReorderColumn(
                        app: widget.app,
                        rows: modelFolded.rows,
                        headers: modelFolded.headers.keys.toSet(),
                        focusedLayerId: _focusedLayerId,
                        rulerHeight: _rulerHeight,
                        rowHeight: _rowHeight,
                        onPreview: _onReorderPreview,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// individual FRAME ticks, absent at low zoom (only whole-second ticks are
// useful there), fading in once zoomed in enough that frames are actually
// distinguishable on screen, and getting denser (showing more of them) the
// further in you zoom.
//
// a plain top-level function (not a CustomPainter method) so a test can call
// it directly with its own fresh Canvas/PictureRecorder - matches
// stage_painter.dart's own paintStage, the established pattern for real
// pixel-level test coverage in this app; calling.paint on a CustomPainter
// instance pulled live out of an already-mounted widget tree (tried first
// here) hung the test runner during teardown for reasons not worth chasing
// further once this simpler, already-proven alternative was available. (the
// frame-tick ruler isn't visible) - root cause: these thresholds required zoom
// > 2x to show anything at all, but this file's own default zoom is 1.0 -
// unreachable without pinching in, and even at max zoom (8x) they never
// reached full opacity (needed 10x, above _maxZoom). Lowered to values
// actually reachable near the default zoom.
const double _frameTicksFadeInAt =
    1.0; // px/frame - first frame ticks appear (zoom ~0.5x)
const double _frameTicksFullyVisibleAt =
    6.0; // px/frame - fully opaque (zoom = 3x, well within _maxZoom=8)
const double _minPxBetweenFrameTicks = 14.0;
const List<int> _frameTickStepCandidates = [1, 2, 5, 10, 15, 30];

/// `secondOpacity`: second marks drawn fainter (the ones a length change
/// is bringing in or taking away).
void paintTimelineRuler(Canvas canvas, Size size,
    {required double pixelsPerFrame, required int maxFrame, Map<int, double> secondOpacity = const {}, bool inFrames = false}) {
  if (inFrames) {
    // frame numbers: every 10th, every 100th when they'd crowd.
    final every = 10 * pixelsPerFrame >= 28 ? 10 : 100;
    final tickPaint = Paint()..color = const Color(0xFF6A6A6A);
    const textStyle = TextStyle(fontSize: 9, color: Color(0xFF8A8A8A));
    for (var f = 0; f <= maxFrame; f += every) {
      final x = f * pixelsPerFrame;
      canvas.drawLine(Offset(x, size.height - 6), Offset(x, size.height), tickPaint);
      (TextPainter(text: TextSpan(text: '$f', style: textStyle), textDirection: TextDirection.ltr)..layout())
          .paint(canvas, Offset(x + 2, 2));
    }
  }
  for (var sec = 0; !inFrames && sec * fps <= maxFrame; sec++) {
    final x = sec * fps * pixelsPerFrame;
    final o = secondOpacity[sec] ?? 1.0;
    final tickPaint = Paint()..color = const Color(0xFF6A6A6A).withOpacity(o);
    final textStyle = TextStyle(fontSize: 9, color: const Color(0xFF8A8A8A).withOpacity(o));
    canvas.drawLine(
        Offset(x, size.height - 6), Offset(x, size.height), tickPaint);
    final tp = TextPainter(
        text: TextSpan(text: '${sec}s', style: textStyle),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(x + 2, 2));
  }

  // zoomed in: half seconds get a tick like the seconds' (no label).
  final half = fps * pixelsPerFrame;
  if (!inFrames && fps.isEven && half >= 90) {
    final o = ((half - 90) / 40).clamp(0.0, 1.0);
    final p = Paint()..color = const Color(0xFF6A6A6A).withOpacity(o);
    for (var sec = 0; (sec + 0.5) * fps <= maxFrame; sec++) {
      final x = (sec + 0.5) * fps * pixelsPerFrame;
      canvas.drawLine(Offset(x, size.height - 6), Offset(x, size.height), p);
    }
  }

  if (pixelsPerFrame <= _frameTicksFadeInAt) return;
  final opacity = ((pixelsPerFrame - _frameTicksFadeInAt) /
          (_frameTicksFullyVisibleAt - _frameTicksFadeInAt))
      .clamp(0.0, 1.0);
  var step = _frameTickStepCandidates.last;
  for (final candidate in _frameTickStepCandidates) {
    if (candidate * pixelsPerFrame >= _minPxBetweenFrameTicks) {
      step = candidate;
      break;
    }
  }
  final framePaint = Paint()
    ..color = const Color(0xFF8E8E8E).withOpacity(opacity * 0.9);
  for (var f = 0; f <= maxFrame; f += step) {
    if (f % fps == 0) {
      continue; // whole seconds already have their own (brighter) tick above
    }
    final x = f * pixelsPerFrame;
    canvas.drawLine(
        Offset(x, size.height - 3), Offset(x, size.height), framePaint);
  }
}

class _RulerPainter extends CustomPainter {
  final double pixelsPerFrame;
  final int maxFrame;
  final Map<int, double> secondOpacity;
  final bool inFrames;
  _RulerPainter(
      {required this.pixelsPerFrame, required this.maxFrame, this.secondOpacity = const {}, this.inFrames = false});

  @override
  void paint(Canvas canvas, Size size) => paintTimelineRuler(canvas, size,
      pixelsPerFrame: pixelsPerFrame, maxFrame: maxFrame, secondOpacity: secondOpacity, inFrames: inFrames);

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) =>
      oldDelegate.inFrames != inFrames ||
      oldDelegate.pixelsPerFrame != pixelsPerFrame ||
      oldDelegate.maxFrame != maxFrame ||
      oldDelegate.secondOpacity.isNotEmpty ||
      secondOpacity.isNotEmpty;
}

/// The ruler; when the length changes, only the second marks it brings
/// in (or takes away) fade in (out), quickly - the rest stay put. Each
/// mark fades on its own, so a length dragged on and on still fades every
/// mark it passes.
class _AnimatedRuler extends StatefulWidget {
  final double pixelsPerFrame;
  final int maxFrame;
  final bool inFrames;
  const _AnimatedRuler({required this.pixelsPerFrame, required this.maxFrame, this.inFrames = false});

  @override
  State<_AnimatedRuler> createState() => _AnimatedRulerState();
}

class _AnimatedRulerState extends State<_AnimatedRuler> with SingleTickerProviderStateMixin {
  static const _fadeMs = 120.0;
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
  }
  Duration _last = Duration.zero;
  // second -> opacity, for the marks fading in or out.
  final Map<int, double> _fading = {};

  int get _lastSec => widget.maxFrame ~/ fps;

  @override
  void didUpdateWidget(_AnimatedRuler old) {
    super.didUpdateWidget(old);
    final was = old.maxFrame ~/ fps, now = _lastSec;
    if (was == now) return;
    for (var s = math.min(was, now) + 1; s <= math.max(was, now); s++) {
      _fading[s] ??= now > was ? 0 : 1;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration t) {
    final dt = _last == Duration.zero ? 16.0 : (t - _last).inMicroseconds / 1000;
    _last = t;
    setState(() {
      for (final s in _fading.keys.toList()) {
        final target = s <= _lastSec ? 1.0 : 0.0;
        final v = _fading[s]!;
        final next = target > v ? math.min(1.0, v + dt / _fadeMs) : math.max(0.0, v - dt / _fadeMs);
        if (next == target) {
          _fading.remove(s);
        } else {
          _fading[s] = next;
        }
      }
    });
    if (_fading.isEmpty) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final outer = _fading.keys.fold(_lastSec, math.max);
    return CustomPaint(
        painter: _RulerPainter(
            pixelsPerFrame: widget.pixelsPerFrame,
            maxFrame: math.max(widget.maxFrame, outer * fps),
            secondOpacity: Map.of(_fading),
            inFrames: widget.inFrames));
  }
}

/// Shared drag-to-edge auto-scroll, used by both _LayerLaneState (move-
/// drag) and _PlayheadState (playhead drag) - previously duplicated (and
/// desynced) per-widget.
///
/// (dragging a layer near the edge auto-scrolls the timeline, but the layer
/// visually lags behind and is eventually lost). Root cause: the old
/// per-widget Timer nudged the scroll position independently of the drag's own
/// baseline (`_moveStartGlobalX`/ `_dragStartGlobalX`, captured once at
/// drag-start) - since the dragged frame position is computed as
/// `(currentGlobalX - startGlobalX) / pixelsPerFrame`, and the Timer changed
/// what's *visible* without changing that baseline, the two drift apart for as
/// long as auto-scroll runs. It also meant a perfectly stationary finger held
/// at the edge produced no further drag update at all once auto-scroll started
/// (no pointer-move event fires for a motionless finger), even though the
/// scrollbar kept advancing underneath it - the layer visibly "lost" the drag.
///
/// Fix: every time the Timer actually moves scroll by some
/// `actualDeltaPixels` (clamped, so it can be less than the nominal step
/// near an edge), it immediately calls `onAutoScrollApplied` so the
/// consumer can (a) re-anchor its own drag baseline by the same amount
/// and (b) re-apply the drag/frame-set using the last-known pointer
/// position against that shifted baseline - so scroll offset and the
/// drag's own frame math advance by the IDENTICAL amount on every tick,
/// by construction, and can never desync. This also fixes the
/// stationary-finger case: the re-apply happens from the Timer itself,
/// not from a pointer-move event, so the drag keeps advancing even
/// while the finger doesn't move at all.
mixin _EdgeAutoScrollDrag<T extends StatefulWidget> on State<T> {
  static const double _autoScrollEdgeZone = 48;
  // speed: starts slow and smoothly speeds up the longer the finger stays
  // at the edge (and the deeper into the edge zone it is), up to a cap.
  static const double _autoScrollMinStep = 3;
  static const double _autoScrollMaxStep = 40;
  static const double _autoScrollAccelSeconds = 1.5; // to full speed
  Timer? _autoScrollTimer;
  final Stopwatch _autoScrollHeld = Stopwatch();
  double _autoScrollDepth = 0; // 0 at the zone's inner side .. 1 at the very edge
  double? _autoScrollDirection;

  ScrollController get autoScrollController;
  GlobalKey get autoScrollViewportKey;
  bool get autoScrollEnabled;

  /// called every time the Timer actually moves the scroll position,
  /// with the REAL delta actually applied (may be less than the nominal
  /// step once clamped near an edge) - the consumer re-anchors its own
  /// drag baseline and re-applies the drag using its last-known pointer
  /// position against that shifted baseline.
  void onAutoScrollApplied(double actualDeltaPixels);

  void updateAutoScroll(Offset globalPosition) {
    if (!autoScrollEnabled) {
      stopAutoScroll();
      return;
    }
    final box =
        autoScrollViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    final width = box.size.width;
    if (local.dx < _autoScrollEdgeZone) {
      _autoScrollDirection = -1;
      _autoScrollDepth = (1 - local.dx / _autoScrollEdgeZone).clamp(0.0, 1.0);
    } else if (local.dx > width - _autoScrollEdgeZone) {
      _autoScrollDirection = 1;
      _autoScrollDepth = (1 - (width - local.dx) / _autoScrollEdgeZone).clamp(0.0, 1.0);
    } else {
      _autoScrollDirection = null;
    }
    if (_autoScrollDirection == null) {
      stopAutoScroll();
      return;
    }
    if (_autoScrollTimer == null) _autoScrollHeld..reset()..start();
    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final dir = _autoScrollDirection;
      final controller = autoScrollController;
      if (dir == null || !controller.hasClients) return;
      final pos = controller.position;
      // ease-in over time, scaled by how deep in the edge the finger is.
      final t = (_autoScrollHeld.elapsedMilliseconds / 1000 / _autoScrollAccelSeconds).clamp(0.0, 1.0);
      final eased = t * t * (3 - 2 * t);
      final step = _autoScrollMinStep +
          (_autoScrollMaxStep - _autoScrollMinStep) * eased * (0.4 + 0.6 * _autoScrollDepth);
      final next = (pos.pixels + dir * step).clamp(0.0, pos.maxScrollExtent);
      final actualDelta = next - pos.pixels;
      if (actualDelta == 0) {
        return; // already at the scroll extent - nothing moved, nothing to re-anchor
      }
      controller.jumpTo(next);
      onAutoScrollApplied(actualDelta);
    });
  }

  void stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollHeld.stop();
    _autoScrollDirection = null;
  }

  void disposeAutoScroll() {
    _autoScrollTimer?.cancel();
  }
}

/// one layer's row: a thin line spanning [startFrame, startFrame+
/// durationFrames], its own keyframes as diamond markers, and - only
/// once FOCUSED (see this file's own top-level doc comment) - its two
/// boundary points as draggable trim dots. A long-press-and-drag hit
/// area along the line's body moves the whole layer, available whenever
/// this lane isn't DIMMED (another layer is focused instead).
class _LayerLane extends StatefulWidget {
  final AppState app;
  final Layer layer;
  final double pixelsPerFrame;
  final double height;
  final bool selected;
  final bool focused;
  final bool dimmed;
  final bool quickSwitchEnabled;
  final VoidCallback onToggleFocus;
  final ValueChanged<bool> onDragActiveChanged;
  final ScrollController hScrollController;
  final GlobalKey viewportKey;
  const _LayerLane({
    required this.app,
    required this.layer,
    required this.pixelsPerFrame,
    required this.height,
    required this.selected,
    required this.focused,
    required this.dimmed,
    required this.quickSwitchEnabled,
    required this.onToggleFocus,
    required this.onDragActiveChanged,
    required this.hScrollController,
    required this.viewportKey,
  });

  @override
  State<_LayerLane> createState() => _LayerLaneState();
}

class _LayerLaneState extends State<_LayerLane>
    with _EdgeAutoScrollDrag<_LayerLane> {
  double? _moveStartGlobalX;
  // the move-drag's own last-known pointer position - needed so the
  // auto-scroll Timer can re-apply the drag itself (see
  // _EdgeAutoScrollDrag's own doc comment) even when the finger is
  // perfectly stationary, which produces no onLongPressMoveUpdate event
  // at all.
  Offset? _lastMoveGlobalPosition;
  int? _movePointer;

  // whether the held lane went anywhere (else the hold deselects it).
  bool _moved = false;
  bool _wasFocused = false;
  bool _wasSelected = false;

  /// The finger is up after a hold: a drag ends; a hold that went
  /// nowhere toggles the selection (the thick line, the stage's) - it
  /// picks a layer, or lets the picked one go.
  void _finishHold() {
    final moved = _moved;
    _endMove();
    if (moved) {
      widget.app.endLayerDrag();
      return;
    }
    widget.app.cancelLayerDrag();
    if (_wasFocused) widget.onToggleFocus();
    widget.app.selectLayer(_wasSelected ? null : widget.layer.id);
  }

  void _endMove() {
    _moveStartGlobalX = null;
    _lastMoveGlobalPosition = null;
    stopAutoScroll();
  }

  double _frameToX(int frame) => frame * widget.pixelsPerFrame;

  int _dxFrames(double startGlobalX, double currentGlobalX) =>
      ((currentGlobalX - startGlobalX) / widget.pixelsPerFrame).round();

  // (the trim handle's hitbox conflicts with scrolling - widen it 2-3x) - was
  // 12 (a 24x12px touch column). The drawn dot itself (see _LaneLinePainter, a
  // literal radius-4 circle) is a separate value and is unaffected by this.
  static const double _dotHitRadius = 30;

  @override
  ScrollController get autoScrollController => widget.hScrollController;
  @override
  GlobalKey get autoScrollViewportKey => widget.viewportKey;
  @override
  bool get autoScrollEnabled => widget.app.timelineEdgeAutoScrollEnabled;

  @override
  void onAutoScrollApplied(double actualDeltaPixels) {
    final start = _moveStartGlobalX;
    final lastPos = _lastMoveGlobalPosition;
    if (start == null || lastPos == null) return;
    // re-anchor the drag's own baseline by the SAME amount the scroll
    // view just moved, then re-apply the drag against the shifted
    // baseline using the last-known pointer position - scroll offset
    // and frame math now advance identically, by construction.
    _moveStartGlobalX = start - actualDeltaPixels;
    widget.app.updateLayerDrag(_dxFrames(_moveStartGlobalX!, lastPos.dx));
  }

  @override
  void dispose() {
    disposeAutoScroll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final startX = _frameToX(widget.layer.startFrame);
    final endX =
        _frameToX(widget.layer.startFrame + widget.layer.durationFrames);
    final color = laneColor(context, widget.app, widget.layer);
    final keyframeFrames = collectVisibleLayerKeyframeFrames(widget.layer);
    // loop repeats: drawn after the end up to the loop limit (or the
    // timeline end).
    final loopEnd = layerLoops(widget.layer)
        ? math.min(layerVisibleEnd(widget.layer) ?? widget.app.maxFrame, widget.app.maxFrame)
        : null;
    final loopEndX = loopEnd != null && loopEnd > widget.layer.startFrame + widget.layer.durationFrames
        ? _frameToX(loopEnd)
        : null;
    // move area reserves room for the trim dots only while they're
    // actually shown (focused) - otherwise the line's full body is a
    // move target, with no invisible dot-shaped gaps.
    final moveLeft = widget.focused ? startX + _dotHitRadius : startX;
    final moveWidth = widget.focused
        ? math.max(0.0, endX - startX - 2 * _dotHitRadius)
        : math.max(0.0, endX - startX);

    return SizedBox(
      child: SizedBox(
      height: widget.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // IgnorePointer: several lanes can share a row, and a painted
          // lane mustn't swallow the touches meant for its row mates.
          // its own layer: scrolling and the playhead don't repaint it.
          IgnorePointer(child: RepaintBoundary(child: CustomPaint(
            // sized with room for the right trim dot's own (possibly
            // widened) hitbox - see _dotHitRadius's own doc comment -
            // so a wider hitbox is never itself clipped by this Stack's
            // hit-testable bounds.
            // ...and for keys left outside the layer after shortening it:
            // the RepaintBoundary clips to this size, which cut such a key
            // in half just past the end.
            size: Size(
                [endX, loopEndX ?? 0, for (final f in keyframeFrames) _frameToX(f)].reduce(math.max) +
                    _dotHitRadius + 8,
                widget.height),
            painter: _LaneLinePainter(
              startX: startX,
              endX: endX,
              loopEndX: loopEndX,
              loopStepX: widget.layer.durationFrames * widget.pixelsPerFrame,
              color: color,
              selected: widget.selected,
              dimmed: widget.dimmed,
              keyframeXs: keyframeFrames.map(_frameToX).toList(),
              // keys outside the layer's range (after shortening it) stay,
              // dimmed - the animation is cut off there.
              frameCounts: widget.app.timelineFrameCounts
                  ? (duration: widget.layer.durationFrames, keys: keyframeFrames)
                  : null,
              keyframeCounts: [
                for (final f in keyframeFrames) _tracksKeyedAt(widget.layer, f)
              ],
              // keys kept selected on a layer that is not the active one
              // glow instead of dimming.
              keyframeHeld: [
                for (final f in keyframeFrames) widget.app.heldKeys[widget.layer.id]?.contains(f) ?? false
              ],
              keyframeOutside: [
                for (final f in keyframeFrames)
                  f < widget.layer.startFrame || f > widget.layer.startFrame + widget.layer.durationFrames
              ],
              // text keys (only text keyed there): orange.
              keyframeText: [
                for (final f in keyframeFrames) _onlyTextKeyedAt(widget.layer, f)
              ],
              // audio: the waveform, so the sound can be lined up by eye.
              peaks: widget.layer.content.shape == 'audio'
                  ? widget.app.audioPeaks(widget.layer.content.audioAssetId)
                  : null,
              sourceIn: widget.layer.content.sourceIn,
              pixelsPerFrame: widget.pixelsPerFrame,
              linked: widget.layer.linkId != null,
            ),
          ))),
          // inertia: a thin line from where contact ended to where the
          // layer comes to rest, a ring at its end.
          if (widget.layer.physics.collide)
            for (final (a, b) in physicsWorldOf(widget.app.project).inertiaSpans(widget.layer.id))
              Positioned(
                key: ValueKey('inertia-marker-${widget.layer.id}-$a'),
                left: _frameToX(a),
                top: widget.height / 2 - 4,
                width: math.max(1.0, _frameToX(b) - _frameToX(a)) + 4,
                height: 8,
                child: IgnorePointer(child: CustomPaint(painter: _InertiaPainter(color))),
              ),
          // contour physics: a square where a push starts and where it
          // ends (not keys: nothing to drag or ease).
          if (widget.layer.physics.collide)
            for (final f in physicsWorldOf(widget.app.project).contactMarkers(widget.layer.id))
              Positioned(
                key: ValueKey('push-marker-${widget.layer.id}-$f'),
                left: _frameToX(f) - 3,
                top: widget.height / 2 - 3,
                width: 6,
                height: 6,
                child: IgnorePointer(
                  // the colour of the layer's keys.
                  child: ColoredBox(color: color),
                ),
              ),
          // dimmed lanes are otherwise fully non-interactive (see this
          // file's own top-level doc comment) - UNLESS quick-switch is
          // on, in which case a plain tap area still exists so tapping
          // straight through to a different layer works without
          // unfocusing the currently-focused one first. It's tap-only:
          // no move/trim on a still-dimmed lane, only a focus switch.
          // picking layers to select together: a tap adds / removes one.
          if (widget.dimmed && widget.app.timelineGroupPick)
            Positioned(
              key: ValueKey('group-pick-${widget.layer.id}'),
              left: startX,
              top: 0,
              width: math.max(0.0, endX - startX),
              height: widget.height,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => widget.app.toggleMultiSelect(widget.layer.id),
              ),
            ),
          if (widget.dimmed && widget.quickSwitchEnabled && !widget.app.timelineGroupPick)
            Positioned(
              left: startX,
              top: 0,
              width: math.max(0.0, endX - startX),
              height: widget.height,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  widget.app.selectLayer(widget.layer.id);
                  widget.onToggleFocus();
                },
              ),
            ),
          if (!widget.dimmed)
            Positioned(
              left: moveLeft,
              top: 0,
              width: moveWidth,
              height: widget.height,
              // raw pointer safety net around the move gesture: a long
              // press rejected after it was accepted resets silently (no
              // End, no Cancel) - end the drag on the pointer's own up,
              // and revert it on the pointer's cancel.
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  // the finger a move would start from (not a second one).
                  if (_moveStartGlobalX == null) _movePointer = e.pointer;
                },
                onPointerUp: (e) {
                  if (_moveStartGlobalX == null || e.pointer != _movePointer) {
                    return;
                  }
                  _finishHold();
                },
                onPointerCancel: (e) {
                  if (_moveStartGlobalX == null || e.pointer != _movePointer) {
                    return;
                  }
                  _endMove();
                  widget.app.cancelLayerDrag();
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    // picking: a selected-together layer leaves the group.
                    if (widget.app.timelineGroupPick && !widget.focused) {
                      widget.app.toggleMultiSelect(widget.layer.id);
                      return;
                    }
                    widget.app.selectLayer(widget.layer.id);
                    widget.onToggleFocus();
                  },
                  // another gesture winning the arena mid-move left the layer
                  // following the finger until the other finger lifted. A
                  // cancelled move now reverts.
                  onLongPressCancel: () {
                    if (_moveStartGlobalX == null) return;
                    _endMove();
                    widget.app.cancelLayerDrag();
                  },
                  onLongPressStart: (d) {
                    if (widget.app.timelineHandlesLocked) return; // handles off
                    _moved = false;
                    _wasFocused = widget.focused;
                    _wasSelected = widget.app.selection.selectedLayer == widget.layer.id;
                    _moveStartGlobalX = d.globalPosition.dx;
                    _lastMoveGlobalPosition = d.globalPosition;
                    widget.app
                        .beginLayerDrag(widget.layer.id, LayerDragMode.move);
                  },
                  onLongPressMoveUpdate: (d) {
                    final start = _moveStartGlobalX;
                    if (start == null) return;
                    _lastMoveGlobalPosition = d.globalPosition;
                    // along its own row only (rows change with the
                    // reorder handle).
                    final dx = _dxFrames(start, d.globalPosition.dx);
                    if (dx != 0) _moved = true;
                    widget.app.updateLayerDrag(dx);
                    updateAutoScroll(d.globalPosition);
                  },
                  onLongPressEnd: (d) {
                    if (_moveStartGlobalX == null) return;
                    _finishHold();
                  },
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }
}

const Color _defaultLayerColor = Color(0xFF7FA8C9);

/// A layer's colour on the timeline - or, with layer colours switched off
/// in Settings, one neutral colour that follows the light / dark theme.
Color laneColor(BuildContext context, AppState app, Layer layer) => app.timelineLayerColors
    ? _parseColor(layer.color) ?? _defaultLayerColor
    : Theme.of(context).colorScheme.onSurface.withOpacity(0.75);

// Drawn exactly like _PlayheadPainter (1.5px line + a downward triangle
// on top), in any color, at `x` within its box - used for the focused
// layer's edge lines and the selected keyframe.
class _MarkerLinePainter extends CustomPainter {
  final Color color;
  final double x;
  _MarkerLinePainter({required this.color, required this.x});

  @override
  void paint(Canvas canvas, Size size) {
    paintMarkerLine(canvas, size, x, color);
  }

  @override
  bool shouldRepaint(covariant _MarkerLinePainter old) =>
      old.color != color || old.x != x;
}

Color? _parseColor(String? hex) {
  if (hex == null) return null;
  final h = hex.replaceFirst('#', '');
  final v = int.tryParse(h.length == 8 ? h.substring(0, 6) : h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

void paintMarkerLine(Canvas canvas, Size size, double x, Color color) {
  canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 1.5);
  canvas.drawPath(
      Path()
        ..moveTo(x - 5, 0)
        ..lineTo(x + 5, 0)
        ..lineTo(x, 7)
        ..close(),
      Paint()..color = color);
}

class _LaneLinePainter extends CustomPainter {
  final double startX;
  final double endX;
  // loop repeats: a thinner line from endX to loopEndX with a tick at
  // every restart.
  final double? loopEndX;
  final double loopStepX;
  final Color color;
  final bool selected;
  final bool dimmed;
  final List<double> keyframeXs;
  final List<bool> keyframeOutside;
  final List<bool> keyframeHeld;

  /// Keys of the text alone (drawn birch-coloured).
  final List<bool> keyframeText;

  /// How many parameters have a key at each of keyframeXs.
  final List<int> keyframeCounts;

  /// Settings > frame counts: the layer's length and the frames between
  /// neighbouring keys (global key frames), or null.
  final ({int duration, List<int> keys})? frameCounts;

  /// An audio layer's waveform (computePeaks), drawn along its body from
  /// its in-point; null for everything else.
  final Uint8List? peaks;
  final double sourceIn;
  final double pixelsPerFrame;

  /// Linked in time to other layers (a small chain at its start).
  final bool linked;
  _LaneLinePainter({
    required this.startX,
    required this.endX,
    this.loopEndX,
    this.loopStepX = 0,
    required this.color,
    required this.selected,
    required this.dimmed,
    required this.keyframeXs,
    this.keyframeOutside = const [],
    this.keyframeHeld = const [],
    this.keyframeText = const [],
    this.keyframeCounts = const [],
    this.frameCounts,
    this.peaks,
    this.sourceIn = 0,
    this.pixelsPerFrame = 1,
    this.linked = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final alpha = dimmed ? 0.35 : 1.0;
    final midY = size.height / 2;
    final wave = peaks;
    if (wave != null && pixelsPerFrame > 0 && endX > startX) {
      canvas.save();
      canvas.translate(startX, 0);
      canvas.drawPicture(_waveformPicture(
          wave, sourceIn, pixelsPerFrame, endX - startX, size.height, color.withOpacity(alpha * 0.55)));
      canvas.restore();
    }
    final linePaint = Paint()
      ..color = color.withOpacity(alpha)
      ..strokeWidth = selected ? 3 : 1.5;
    canvas.drawLine(Offset(startX, midY), Offset(endX, midY), linePaint);
    final loopEnd = loopEndX;
    if (loopEnd != null && loopStepX > 0.5) {
      final repeatPaint = Paint()
        ..color = color.withOpacity(alpha * 0.45)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(endX, midY), Offset(loopEnd, midY), repeatPaint);
      for (var x = endX; x < loopEnd; x += loopStepX) {
        canvas.drawLine(Offset(x, midY - 3), Offset(x, midY + 3), repeatPaint);
      }
    }

    if (linked) {
      final chain = Paint()
        ..color = Colors.white.withOpacity(alpha * 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      final x = startX + 6;
      canvas.drawOval(Rect.fromCenter(center: Offset(x - 2, midY), width: 6, height: 4), chain);
      canvas.drawOval(Rect.fromCenter(center: Offset(x + 2, midY), width: 6, height: 4), chain);
    }

    final diamondPaint = Paint()
      ..color = const Color(0xFFE0D47F).withOpacity(alpha);
    final outsidePaint = Paint()
      ..color = const Color(0xFFE0D47F).withOpacity(alpha * 0.35);
    final heldPaint = Paint()..color = const Color(0xFFE0D47F);
    const r = 4.0;
    // keys stay on the layer's line, however close (zoomed out).
    for (var i = 0; i < keyframeXs.length; i++) {
      final x = keyframeXs[i];
      final y = midY;
      final held = i < keyframeHeld.length && keyframeHeld[i];
      final text = i < keyframeText.length && keyframeText[i];
      final paint = held
          ? heldPaint
          : i < keyframeOutside.length && keyframeOutside[i]
              ? (text ? (Paint()..color = textKeyColor.withOpacity(alpha * 0.35)) : outsidePaint)
              : (text ? (Paint()..color = textKeyColor.withOpacity(alpha)) : diamondPaint);
      // kept selected on a layer that isn't the active one: a square
      // around it (like the ring of keys shared by several parameters).
      if (held) {
        canvas.drawRect(
            Rect.fromCenter(center: Offset(x, y), width: 2 * r + 5, height: 2 * r + 5),
            Paint()
              ..color = const Color(0xFFE0D47F)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2);
      }
      // several parameters keyed on this frame: a ring around the diamond.
      if (i < keyframeCounts.length && keyframeCounts[i] > 1) {
        canvas.drawCircle(
            Offset(x, y),
            r + 2,
            Paint()
              ..color = paint.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1);
      }
      final path = Path()
        ..moveTo(x, y - r)
        ..lineTo(x + r, y)
        ..lineTo(x, y + r)
        ..lineTo(x - r, y)
        ..close();
      canvas.drawPath(path, paint);
    }
    final counts = frameCounts;
    if (counts != null) _paintFrameCounts(canvas, size, counts, alpha);
  }

  /// Small numbers in the layer's / keys' colour: the length after the
  /// layer's end, and between two keys the frames from one to the other -
  /// each left out where it doesn't fit or would overlap another.
  void _paintFrameCounts(Canvas canvas, Size size, ({int duration, List<int> keys}) counts, double alpha) {
    final drawn = <Rect>[];
    void label(String text, Color c, double centerX, {bool after = false}) {
      final tp = TextPainter(
          text: TextSpan(text: text, style: TextStyle(fontSize: 7, color: c.withOpacity(alpha), height: 1)),
          textDirection: TextDirection.ltr)
        ..layout();
      final left = after ? centerX : centerX - tp.width / 2;
      final rect = Rect.fromLTWH(left, 0, tp.width, tp.height);
      if (drawn.any((r) => r.inflate(1).overlaps(rect))) return;
      drawn.add(rect);
      tp.paint(canvas, rect.topLeft);
    }

    final keys = counts.keys;
    for (var i = 0; i + 1 < keys.length && i + 1 < keyframeXs.length; i++) {
      final span = keys[i + 1] - keys[i];
      final width = keyframeXs[i + 1] - keyframeXs[i];
      if (span <= 0 || width < 14) continue;
      label('$span', const Color(0xFFE0D47F), (keyframeXs[i] + keyframeXs[i + 1]) / 2);
    }
    label('${counts.duration}', color, endX + 3, after: true);
  }

  @override
  bool shouldRepaint(covariant _LaneLinePainter oldDelegate) =>
      oldDelegate.startX != startX ||
      oldDelegate.endX != endX ||
      oldDelegate.loopEndX != loopEndX ||
      oldDelegate.loopStepX != loopStepX ||
      oldDelegate.color != color ||
      oldDelegate.selected != selected ||
      oldDelegate.dimmed != dimmed ||
      !_sameList(oldDelegate.keyframeXs, keyframeXs) ||
      !_sameList(oldDelegate.keyframeOutside, keyframeOutside) ||
      !_sameList(oldDelegate.keyframeHeld, keyframeHeld) ||
      !_sameList(oldDelegate.keyframeCounts, keyframeCounts) ||
      oldDelegate.frameCounts?.duration != frameCounts?.duration ||
      !_sameList(oldDelegate.frameCounts?.keys ?? const [], frameCounts?.keys ?? const []) ||
      oldDelegate.peaks != peaks ||
      oldDelegate.sourceIn != sourceIn ||
      oldDelegate.pixelsPerFrame != pixelsPerFrame ||
      oldDelegate.linked != linked;
}

/// Recorded waveforms, so a lane's bars are drawn once - not again on
/// every repaint (scroll, playhead, focus). A new picture only when the
/// audio, its in-point, the zoom, the lane's length or colour change.
final LinkedHashMap<(Uint8List, double, double, double, double, int, int), ui.Picture> _waveforms = LinkedHashMap();

ui.Picture _waveformPicture(Uint8List wave, double sourceIn, double pixelsPerFrame, double width, double height, Color color) {
  final key = (wave, sourceIn, pixelsPerFrame, width, height, color.value, fps);
  final have = _waveforms.remove(key);
  if (have != null) return _waveforms[key] = have; // most recently used last
  waveformRecordings++;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final midY = height / 2;
  final barPaint = Paint()
    ..color = color
    ..strokeWidth = 1.5;
  const step = 2.0; // one bar per 2 px
  for (var x = 0.0; x < width; x += step) {
    final t0 = sourceIn + x / pixelsPerFrame / fps;
    final t1 = sourceIn + (x + step) / pixelsPerFrame / fps;
    final h = peakBetween(wave, t0, t1) * (midY - 0.5);
    if (h < 0.3) continue;
    canvas.drawLine(Offset(x, midY - h), Offset(x, midY + h), barPaint);
  }
  final picture = rec.endRecording();
  _waveforms[key] = picture;
  while (_waveforms.length > 24) {
    _waveforms.remove(_waveforms.keys.first)!.dispose();
  }
  return picture;
}

/// How many waveform pictures have been recorded (tests).
@visibleForTesting
int waveformRecordings = 0;

@visibleForTesting
void clearWaveformPictures() {
  for (final p in _waveforms.values) {
    p.dispose();
  }
  _waveforms.clear();
}

/// draggable indicator for the current frame, within this view's own
/// zoomed/scrolled coordinate space.
class _Playhead extends StatefulWidget {
  final AppState app;
  final double pixelsPerFrame;
  final double totalHeight;
  // content-box x of frame 0 (the leading edge slack).
  final double originX;
  // true whenever the playhead shouldn't compete for touches at all:
  // center-pin is on (scrolling already scrubs in that mode) or a 2-finger
  // pinch is in progress (a finger resting on the playhead mid-pinch was
  // independently calling setFrame, fighting the pinch's own zoom math).
  final bool ignoreTouch;
  final ValueChanged<bool> onDragActiveChanged;
  final ScrollController hScrollController;
  final GlobalKey viewportKey;
  const _Playhead(
      {required this.app,
      required this.pixelsPerFrame,
      required this.totalHeight,
      this.originX = 0,
      required this.ignoreTouch,
      required this.onDragActiveChanged,
      required this.hScrollController,
      required this.viewportKey});

  @override
  State<_Playhead> createState() => _PlayheadState();
}

class _PlayheadState extends State<_Playhead>
    with _EdgeAutoScrollDrag<_Playhead> {
  double? _dragStartGlobalX;
  int? _dragStartFrame;
  // (the playhead should get the same auto-scroll behavior as layer-drag) -
  // the playhead had NO auto-scroll wiring at all before this. Same
  // last-known-position tracking as _LayerLaneState, for the same reason
  // (letting the auto-scroll Timer re-apply the drag on a stationary finger).
  Offset? _lastGlobalPosition;

  @override
  ScrollController get autoScrollController => widget.hScrollController;
  @override
  GlobalKey get autoScrollViewportKey => widget.viewportKey;
  @override
  bool get autoScrollEnabled => widget.app.timelineEdgeAutoScrollEnabled;

  @override
  void onAutoScrollApplied(double actualDeltaPixels) {
    final startX = _dragStartGlobalX, startFrame = _dragStartFrame;
    final lastPos = _lastGlobalPosition;
    if (startX == null || startFrame == null || lastPos == null) return;
    _dragStartGlobalX = startX - actualDeltaPixels;
    final dxFrames =
        ((lastPos.dx - _dragStartGlobalX!) / widget.pixelsPerFrame).round();
    widget.app.setFrame(startFrame + dxFrames, quiet: true);
  }

  @override
  void dispose() {
    disposeAutoScroll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // the playhead follows the frame on its own (AppState.frameNotifier):
    // playback and scrubbing move this line, nothing else in the timeline
    // rebuilds, and its own RepaintBoundary keeps the repaint to the line.
    return ValueListenableBuilder<int>(
      valueListenable: widget.app.frameNotifier,
      child: RepaintBoundary(child: _hitArea()),
      builder: (context, frame, child) => Positioned(
        left: widget.originX + frame * widget.pixelsPerFrame - 8,
        top: 0,
        width: 16,
        height: widget.totalHeight,
        child: child!,
      ),
    );
  }

  Widget _hitArea() {
    // raw Listener capture, not a GestureDetector - see _trimDot's own
    // doc comment: the horizontal SingleChildScrollView always has
    // SOME scrollable range now (the leading/trailing centering
    // padding), so its own pan recognizer genuinely competes for this
    // single-pointer drag and can win the arena outright.
    // onDragActiveChanged disables the scroll view's own physics for
    // the duration of the drag - see this file's own top-level doc
    // comment on the playhead-runaway fix.
    return IgnorePointer(
        ignoring: widget.ignoreTouch,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (d) {
            _dragStartGlobalX = d.position.dx;
            _dragStartFrame = widget.app.currentFrame;
            _lastGlobalPosition = d.position;
            widget.onDragActiveChanged(true);
          },
          onPointerMove: (d) {
            final startX = _dragStartGlobalX, startFrame = _dragStartFrame;
            if (startX == null || startFrame == null) {
              return;
            }
            _lastGlobalPosition = d.position;
            final dxFrames =
                ((d.position.dx - startX) / widget.pixelsPerFrame).round();
            widget.app.setFrame(startFrame + dxFrames, quiet: true);
            updateAutoScroll(d.position);
          },
          onPointerUp: (_) {
            _dragStartGlobalX = null;
            _dragStartFrame = null;
            _lastGlobalPosition = null;
            widget.onDragActiveChanged(false);
            stopAutoScroll();
            widget.app.frameSettled();
          },
          onPointerCancel: (_) {
            _dragStartGlobalX = null;
            _dragStartFrame = null;
            _lastGlobalPosition = null;
            widget.onDragActiveChanged(false);
            stopAutoScroll();
            widget.app.frameSettled();
          },
          child: CustomPaint(painter: _PlayheadPainter()),
        ),
    );
  }
}

class _PlayheadPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // was a red (0xFFE05A5A) line + handle triangle.
    paintMarkerLine(canvas, size, size.width / 2, Colors.white);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter oldDelegate) => false;
}

/// Center-pin only: the filmstrip must move under the pinned cursor (in
/// whole-frame steps), not glide with the finger. Snapping the scroll position
/// itself mid-drag would kill the drag (any jumpTo ends it), so the scroll
/// position stays continuous and this just shifts the painted content by the
/// sub-frame remainder: visible offset = -currentFrame * pixelsPerFrame
/// exactly, changing only when the frame does.
class _FrameQuantized extends StatelessWidget {
  final ScrollController controller;
  final AppState app;
  final double pixelsPerFrame;
  final Widget child;
  const _FrameQuantized(
      {required this.controller,
      required this.app,
      required this.pixelsPerFrame,
      required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, app.frameNotifier]),
      child: child,
      builder: (context, child) {
        final pixels = controller.hasClients ? controller.position.pixels : 0.0;
        return Transform.translate(
          offset: Offset(pixels - app.currentFrame * pixelsPerFrame, 0),
          child: child,
        );
      },
    );
  }
}

/// Reserved right-edge strip holding the focused layer's reorder handle - back
/// where the very first reorder column was, not drawn over the layer lines.
/// Drag is vertical-only and clamped to the rows. Released over the middle of
/// another row that has room in time, the layer JOINS that row (several layers
/// per row); released nearer a row edge, it becomes a new row there. The
/// target is highlighted and the layer moves once, on release (a single undo
/// step).
class _ReorderColumn extends StatefulWidget {
  final AppState app;
  final List<List<Layer>> rows;

  /// Indexes of folder rows in `rows` (empty, never joined; they don't
  /// count as rows of the project).
  final Set<int> headers;
  final String? focusedLayerId;
  final double rulerHeight;
  final double rowHeight;
  // reports the live preview (dragged id, target row, join, finger y) so
  // the lanes can slide into place while dragging; nulls when it ends.
  final void Function(String? id, int? target, bool join, double? y) onPreview;
  const _ReorderColumn(
      {required this.app,
      required this.rows,
      this.headers = const {},
      required this.focusedLayerId,
      required this.rulerHeight,
      required this.rowHeight,
      required this.onPreview});

  @override
  State<_ReorderColumn> createState() => _ReorderColumnState();
}

/// Where a reorder drop lands: `row` counts rows with the dragged layer
/// taken out; `join` = into that row, else a new row there. `highlight`
/// is the original row to tint (join) and `boundary` the original row
/// edge to mark (new row).
typedef _ReorderSlot = ({int row, bool join, int? highlight, int? boundary});

class _ReorderColumnState extends State<_ReorderColumn> {
  static const double _handleSize = 24;
  double? _dragY;

  double _rowCenter(int i) =>
      widget.rulerHeight + i * widget.rowHeight + widget.rowHeight / 2;

  double _clampY(double y) =>
      y.clamp(widget.rulerHeight, widget.rulerHeight + widget.rows.length * widget.rowHeight - 0.01);

  _ReorderSlot _slotAt(double y, Layer layer, int own) {
    final rel = (_clampY(y) - widget.rulerHeight) / widget.rowHeight;
    final r = rel.floor().clamp(0, widget.rows.length - 1);
    final frac = rel - r;
    final alone = widget.rows[own].length == 1;
    // shown rows to the project's: folder rows don't count.
    int post(int i) {
      var m = 0;
      for (var k = 0; k < i && k < widget.rows.length; k++) {
        if (!widget.headers.contains(k)) m++;
      }
      if (i > widget.rows.length) m += i - widget.rows.length;
      return alone && i > own ? m - 1 : m;
    }

    if (r != own && !widget.headers.contains(r) && frac > 0.25 && frac < 0.75 && fitsInTimelineRow(widget.rows[r], layer)) {
      return (row: post(r), join: true, highlight: r, boundary: null);
    }
    final boundary = frac < 0.5 ? r : r + 1;
    return (row: post(boundary), join: false, highlight: null, boundary: boundary);
  }

  bool _isNoop(_ReorderSlot slot, int own) =>
      !slot.join && widget.rows[own].length == 1 && slot.row == own;

  @override
  Widget build(BuildContext context) {
    final id = widget.focusedLayerId;
    final own = id == null ? -1 : widget.rows.indexWhere((r) => r.any((l) => l.id == id));
    if (own < 0) return const SizedBox.shrink();
    final layer = widget.rows[own].firstWhere((l) => l.id == id);

    final y = _dragY == null ? _rowCenter(own) : _clampY(_dragY!);
    final slot = _dragY == null ? null : _slotAt(y, layer, own);

    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: widget.rulerHeight + own * widget.rowHeight,
            height: widget.rowHeight,
            // the lane's glow shows through; only the handle has a shadow.
            child: const SizedBox.shrink(),
          ),
          if (slot?.highlight != null)
            Positioned(
              key: const ValueKey('reorder-join-target'),
              left: 0,
              right: 0,
              top: widget.rulerHeight + slot!.highlight! * widget.rowHeight,
              height: widget.rowHeight,
              child: const ColoredBox(color: Colors.white24),
            ),
          if (slot?.boundary != null && !_isNoop(slot!, own))
            Positioned(
              key: const ValueKey('reorder-insert-line'),
              left: 0,
              right: 0,
              top: widget.rulerHeight + slot.boundary! * widget.rowHeight - 1,
              height: 2,
              child: const ColoredBox(color: Colors.white70),
            ),
          // keyed: the target highlights above it appear once the drag
          // starts, and an unkeyed handle would be rebuilt then - killing
          // the drag in progress.
          Positioned(
            key: const ValueKey('reorder-handle'),
            left: (constraints.maxWidth - _handleSize) / 2,
            top: y - _handleSize / 2,
            width: _handleSize,
            height: _handleSize,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (_) {
                setState(() => _dragY = _rowCenter(own));
                widget.onPreview(null, null, false, null);
              },
              onVerticalDragUpdate: (d) {
                setState(() => _dragY = _clampY((_dragY ?? _rowCenter(own)) + d.delta.dy));
                final s = _slotAt(_dragY!, layer, own);
                if (_isNoop(s, own)) {
                  widget.onPreview(id, null, false, _dragY);
                } else {
                  widget.onPreview(id, s.row, s.join, _dragY);
                }
              },
              onVerticalDragEnd: (_) {
                final s = _slotAt(_dragY ?? _rowCenter(own), layer, own);
                setState(() => _dragY = null);
                if (!_isNoop(s, own)) widget.app.placeLayerInRow(id!, s.row, join: s.join);
                widget.onPreview(null, null, false, null);
              },
              onVerticalDragCancel: () {
                setState(() => _dragY = null);
                widget.onPreview(null, null, false, null);
              },
              child: const Icon(Icons.drag_handle,
                  size: _handleSize, color: Colors.white70, shadows: [Shadow(blurRadius: 6)]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Split / move-start-to-playhead / fit-edge-to-playhead for the focused
/// layer - shown under its lane (see _actionRowGap).
/// The layer row's guide (the field under a picked layer).
const actionGuideSteps = [
  ('a-delete', 'Delete this layer.'),
  ('a-split', 'Split the layer in two at the playhead.'),
  ('a-start', 'Move the layer so it starts at the playhead.'),
  ('a-fit', 'Stretch or trim its nearest end to the playhead.'),
  ('a-link', 'Link it with another layer: they move together in time.'),
  ('a-merge', 'Merge still shapes into one.'),
  ('a-group', 'Select several layers: tap other lanes to add them.'),
  ('a-effects', 'Show the effects\' time ranges under the layer.'),
  ('a-masks', 'Show the masks\' time under the layer.'),
  ('a-keys', 'Expanded keys: every parameter\'s keys on its own line.'),
];

class _LayerActionRow extends StatelessWidget {
  final AppState app;
  final Layer layer;
  const _LayerActionRow({required this.app, required this.layer});

  @override
  Widget build(BuildContext context) {
    final f = app.currentFrame;
    final start = layer.startFrame,
        end = layer.startFrame + layer.durationFrames;
    final inside = f > start && f < end;
    final sel = app.keyDetailSelection;
    final span = app.showKeyRows && sel != null && sel.layerId == layer.id ? sel : null;
    Widget button(IconData icon, String tooltip, VoidCallback? onPressed, [String? guide]) => KeyedSubtree(
          key: guide == null ? null : guideKey(guide),
          child: IconButton(
            icon: Icon(icon, size: 18),
            tooltip: tooltip,
            onPressed: onPressed,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
          ),
        );
    if (!app.guideActionSeen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted || app.guideActionSeen) return;
        showToolGuide(context, actionGuideSteps, () => app.setAppPreference('guideActionSeen', true));
      });
    }
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.9),
      borderRadius: BorderRadius.circular(6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // a selected key line takes the row's tools: they act on its keys.
          if (span != null) ...[
            button(Icons.delete_outline, 'delete both keys of the line', app.deleteSelectedKeyDetailSpan),
            button(Icons.first_page, 'move the line\'s start to playhead',
                f - start != span.a ? () => app.selectedKeySpanToPlayhead() : null),
            button(Icons.settings_ethernet, 'nearest key of the line to playhead',
                f - start != span.a && f - start != span.b ? () => app.selectedKeySpanToPlayhead(nearest: true) : null),
          ] else ...[
          // first: delete this layer (one undo step).
          button(Icons.delete_outline, 'delete layer', () => app.deleteLayerById(layer.id), 'a-delete'),
          button(Icons.content_cut, 'split at playhead',
              inside ? () => app.splitLayerAtPlayhead(layer.id) : null, 'a-split'),
          button(Icons.first_page, 'move start to playhead',
              f != start ? () => app.moveLayerStartToPlayhead(layer.id) : null, 'a-start'),
          button(
              Icons.settings_ethernet,
              f > end || f < start
                  ? 'extend to playhead'
                  : 'shrink to playhead (nearest edge)',
              f != start && f != end
                  ? () => app.fitLayerEdgeToPlayhead(layer.id)
                  : null,
              'a-fit'),
          ],
          if (span == null) ...[
          // timeline link: linked layers move together in time.
          button(Icons.link, layer.linkId == null ? 'link to another layer (move together)' : 'link one more layer',
              app.project.layers.length > 1 ? () => _pickLink(context) : null, 'a-link'),
          if (layer.linkId != null)
            button(Icons.link_off, 'unlink from ${_partnerNames()}', () => app.unlinkLayerInTime(layer.id)),
          // merge still shapes into one contour.
          button(Icons.merge_type, mergeBlocker(layer) == null ? 'merge with other layers' : "can't merge: ${mergeBlocker(layer)}",
              mergeBlocker(layer) == null && app.project.layers.length > 1 ? () => _pickMerge(context) : null,
              'a-merge'),
          // the selected layers to the very top / bottom of the stack.
          button(Icons.vertical_align_top, 'to the top', () => app.moveLayersToEdge(app.selectedGroup, top: true), 'a-top'),
          button(Icons.vertical_align_bottom, 'to the bottom', () => app.moveLayersToEdge(app.selectedGroup, top: false),
              'a-bottom'),
          ],
          // select several: then a tap on another lane adds it (they move
          // together and light up together).
          KeyedSubtree(
            key: guideKey('a-group'),
            child: IconButton(
            key: const ValueKey('group-pick'),
            icon: const Icon(Icons.library_add_check_outlined, size: 18),
            tooltip: 'select several layers',
            isSelected: app.timelineGroupPick,
            onPressed: app.toggleTimelineGroupPick,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
          ),
          ),
          // a selected key line: a way out of it right here.
          if (span != null)
            button(Icons.close, 'leave the key line', () => app.selectKeyDetailSpan(null))
          else ...[
          // detail rows under the layer: effect ranges, expanded keys.
          KeyedSubtree(
            key: guideKey('a-effects'),
            child: IconButton(
            key: const ValueKey('detail-effects'),
            icon: const Icon(Icons.auto_awesome, size: 18),
            tooltip: 'effect time ranges',
            isSelected: app.showEffectRows,
            onPressed: () => app.setTimelineDetail('effects'),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
          ),
          ),
          KeyedSubtree(
            key: guideKey('a-masks'),
            child: IconButton(
            key: const ValueKey('detail-masks'),
            icon: const Icon(Icons.gradient, size: 18),
            tooltip: 'mask time',
            isSelected: app.showMaskRows,
            onPressed: app.toggleMaskRows,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
          ),
          ),
          KeyedSubtree(
            key: guideKey('a-keys'),
            child: IconButton(
            key: const ValueKey('detail-keys'),
            icon: const Icon(Icons.view_agenda_outlined, size: 18),
            tooltip: 'expanded keys',
            isSelected: app.showKeyRows,
            onPressed: () => app.setTimelineDetail('keys'),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
          ),
          ),
          ],
        ],
      ),
      ),
    );
  }

  String _partnerNames() =>
      timeLinkGroup(app.project, layer).where((l) => !identical(l, layer)).map((l) => l.name).join(', ');

  /// Which layers to merge this one with: the mergeable ones can be
  /// ticked, the others show why not.
  Future<void> _pickMerge(BuildContext context) async {
    final others = [for (final l in app.project.layers) if (!identical(l, layer)) l];
    // what is selected on the timeline now comes ticked.
    final picked = <String>{
      for (final l in others)
        if (app.selectedGroup.contains(l.id) && mergeBlocker(l) == null) l.id
    };
    final folders = {for (final l in app.project.layers) if (l.folder != null) l.folder!}.toList()..sort();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Merge ${layer.name} with...'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // a whole folder at once.
              for (final f in folders) () {
                final members = [for (final l in others) if (l.folder == f && mergeBlocker(l) == null) l.id];
                final all = members.isNotEmpty && members.every(picked.contains);
                return CheckboxListTile(
                  key: ValueKey('merge-folder-$f'),
                  dense: true,
                  secondary: const Icon(Icons.folder_outlined, size: 18),
                  title: Text('Whole folder: $f'),
                  value: all,
                  onChanged: members.isEmpty
                      ? null
                      : (v) => setState(() => v == true ? picked.addAll(members) : picked.removeAll(members)),
                );
              }(),
              if (folders.isNotEmpty) const Divider(),
              for (final l in others)
                CheckboxListTile(
                  key: ValueKey('merge-${l.id}'),
                  dense: true,
                  title: Text(l.folder == null ? l.name : '${l.name}  ·  ${l.folder}'),
                  subtitle: mergeBlocker(l) != null
                      ? Text(mergeBlocker(l)!)
                      : mergeWarning(l) == null
                          ? null
                          : Text(mergeWarning(l)!),
                  value: picked.contains(l.id),
                  onChanged: mergeBlocker(l) != null
                      ? null
                      : (v) => setState(() => v == true ? picked.add(l.id) : picked.remove(l.id)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            TextButton(
              key: const ValueKey('merge-confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Merge'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && picked.isNotEmpty) app.mergeLayersById([layer.id, ...picked]);
  }

  Future<void> _pickLink(BuildContext context) async {
    final others = [
      for (final l in app.project.layers)
        if (!identical(l, layer) && !areTimeLinked(l, layer)) l
    ];
    final id = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Link ${layer.name} with...'),
        children: [
          if (others.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Every layer is already linked to it.')),
          for (final l in others)
            SimpleDialogOption(
              key: ValueKey('link-${l.id}'),
              onPressed: () => Navigator.pop(dialogContext, l.id),
              child: Text(l.name),
            ),
        ],
      ),
    );
    if (id != null) app.linkLayersInTime(layer.id, id);
  }
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// How many of the layer's (visible) parameters have a key at global frame `f`.
int _tracksKeyedAt(Layer layer, int f) {
  var n = 0;
  visitLayerTracks(layer, (trk) {
    if (!trk.hidden && trk.keyframes.any((k) => k.frame + layer.startFrame == f)) n++;
  });
  return n;
}

/// Text keys on the timeline: orange (the expanded Text row's colour).
const textKeyColor = Color(0xFFFF9800);

/// Whether only the text (its keys, its animators) has a key at global
/// frame `f` on `layer`.
bool _onlyTextKeyedAt(Layer layer, int f) {
  if (layer.content.text == null) return false;
  var text = false, other = false;
  visitLayerTracksNamed(layer, (name, trk) {
    if (!trk.keyframes.any((k) => k.frame + layer.startFrame == f)) return;
    keyDetailTabOf(name) == 'Text' ? text = true : other = true;
  });
  return text && !other;
}

/// An inertia span on a lane: a dashed line ending in a ring.
class _InertiaPainter extends CustomPainter {
  final Color color;
  _InertiaPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2, end = size.width - 4;
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (var x = 4.0; x < end - 4; x += 6) {
      canvas.drawLine(Offset(x, cy), Offset(math.min(x + 3, end - 4), cy), p);
    }
    canvas.drawCircle(
        Offset(end, cy),
        3,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_InertiaPainter old) => old.color != color;
}
