import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import 'stage_camera.dart';
import 'stage_gesture_controller.dart';
import 'stage_painter.dart';

/// The stage widget: renders the current frame + the interactive
/// handle/visual overlay defined by movement-mobile-gesture-spec.md
/// (plus its addendum), and routes touch input through
/// StageGestureController. Ported logic (handle geometry, drag
/// mutation math) lives in movement_core's ui_geometry/ and is real-
/// tested; this file is purely the dart:ui/gesture glue, unverifiable
/// in this sandbox like the rest of ui/render.
///
/// The render FRAME size (`stageSize`, what canvas_renderer.dart
/// actually renders/exports at) and this WIDGET's on-screen viewport
/// size are two genuinely different things and must stay that way -
/// this file used to conflate them, which was a real, twice-caught bug:
/// an earlier version called `renderer.setSize(constraints.size)` from
/// this widget's OWN layout on every first build, and even after that
/// was restricted to only the first NON-degenerate layout (still not
/// enough - see stage_camera.dart's own doc comment for how that let a
/// device ROTATION redefine the project's coordinate system, making the
/// same anchor value land at a different physical position in portrait
/// vs landscape). The frame's actual size is now a fixed constant (see
/// AppState.frameWidth/frameHeight), set exactly once, never touched by
/// this widget at all. This widget's only job re: sizing is to hand the
/// CURRENT viewport size to StageCamera every build, so IT can letterbox
/// the fixed frame into whatever space is actually available -
/// recomputing that fit is cheap and safe to do unconditionally, unlike
/// the old setSize() call, because it never touches the frame's own
/// coordinate system, only how it's displayed.
class StageView extends StatefulWidget {
  final AppState app;
  const StageView({super.key, required this.app});

  @override
  State<StageView> createState() => _StageViewState();
}

class _StageViewState extends State<StageView> {
  late final StageCamera _camera;

  @visibleForTesting
  StageCamera get debugCamera => _camera;
  late final StageGestureController _controller;

  // (by default, the frame should sit a bit beyond the viewport's own borders)
  // - applied ONCE, the first time a real viewport size is known (see build's
  // own use of this flag). (leave zoom deliberately outside the vector/object
  // - only interacting with the object itself changes it): this is a fixed
  // STARTING state, never recomputed or tied to selection/object state - only
  // the pinch on the canvas (stage_gesture_controller.dart) changes it
  // afterward.
  static const double _initialZoomScale = 1.15;
  bool _appliedInitialZoom = false;

  @override
  void initState() {
    super.initState();
    // StageCamera's own default scale (1.0) is kept as-is - it's what
    // the dozens of pixel-precise tests that construct a bare
    // StageCamera() assume; this app's own camera instance is the one
    // place that needs the different starting value, applied in
    // build() below once real layout/frame data is available (needed
    // to compute a viewport-CENTERED zoom via applyScaleUpdate, not
    // just an anchored-at-the-origin one).
    _camera = StageCamera();
    _controller = StageGestureController(
        app: widget.app,
        camera: _camera,
        onNeedsRepaint: () => setState(() {}));
    // a selected line's handles cut their see-through parts from the line
    // itself (not from what's under it).
    widget.app.renderer.stageCuts = (project, layer, frame) {
      final app = widget.app;
      if (layer.id != app.selection.selectedLayer || app.hideStageIcons || !isNodeLine(layer.content)) {
        return const [];
      }
      _cutScale = stageHandleScale;
      return lineHandleCuts(project, layer, frame, activeKey: _controller.activeDrag?.activeKey);
    };
    widget.app.addListener(_onAppChanged);
    // playback and scrubbing move only the frame (see AppState.setFrame).
    widget.app.frameNotifier.addListener(_onAppChanged);
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    widget.app.frameNotifier.removeListener(_onAppChanged);
    super.dispose();
  }

  void _onAppChanged() => setState(() {});

  /// The handle size the cuts were last rendered at: a zoom re-renders.
  double _cutScale = 1;

  void _checkCutScale() {
    final l = findLayer(widget.app.project, widget.app.selection.selectedLayer);
    if (l == null || !isNodeLine(l.content)) return;
    if ((stageHandleScale - _cutScale).abs() > _cutScale * 0.02) {
      _cutScale = stageHandleScale;
      widget.app.rerender();
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkCutScale();
    });
    return LayoutBuilder(builder: (context, constraints) {
      final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
      _camera.lockSides = widget.app.stageZoomLock;
      _camera.clampToLock();
      if (!_appliedInitialZoom &&
          viewportSize.width > 0 &&
          viewportSize.height > 0) {
        _appliedInitialZoom = true;
        _camera.updateLayout(
            frame: Size(stageSize.width, stageSize.height),
            viewport: viewportSize);
        final center =
            Offset(viewportSize.width / 2, viewportSize.height / 2);
        // scaleDelta from the camera's own current scale (1.0) to
        // _initialZoomScale, with focalPointDelta=zero (the "pinch"
        // center IS the focal point, unmoved) - reuses the same
        // centered zoom-under-fingers math the real pinch gesture
        // uses, rather than a separate anchored-at-origin scale that
        // would shift the frame off-center instead of just cropping
        // its edges symmetrically.
        _camera.applyScaleUpdate(
            scaleDelta: _initialZoomScale,
            focalPointDelta: Offset.zero,
            focalPoint: center);
      }
      // AppState renders every change it makes (setFrame, commitEdit, ...);
      // drawing that picture again here was a second full render per
      // frame. The stage renders itself only when nothing did since its
      // last build (e.g. its own camera moved).
      if (!widget.app.takeFreshRender()) {
        widget.app.renderer.renderFrame(
            widget.app.project, widget.app.currentFrame,
            clipToFrame: !(widget.app.showOffCanvasContent || widget.app.cameraView),
            underlay: widget.app.contextUnderlay);
      }
      final selectedLayer =
          findLayer(widget.app.project, widget.app.selection.selectedLayer);

      // off-canvas content, handles and guides were painted past the stage's
      // own box, showing through the timeline below - the stage never draws
      // outside its area now.
      return ClipRect(
        child: Stack(children: [
        Listener(
        onPointerDown: _controller.onPointerDown,
        onPointerMove: _controller.onPointerMove,
        onPointerUp: _controller.onPointerUp,
        onPointerCancel: _controller.onPointerCancel,
        child: CustomPaint(
          size: viewportSize,
          painter: _StageCustomPainter(
            contentPicture: widget.app.renderer.currentPicture,
            frameWidth: stageSize.width,
            frameHeight: stageSize.height,
            project: widget.app.project,
            selectedLayer: selectedLayer,
            groupLayers: [
              // picking a parent's children: they light up instead.
              for (final id in widget.app.parentPickFor != null ? widget.app.parentPicked : widget.app.selectedGroup)
                if (id != selectedLayer?.id) findLayer(widget.app.project, id),
            ].whereType<Layer>().toList(),
            globalFrame: widget.app.currentFrame,
            camera: _camera,
            activeDrag: _controller.activeDrag,
            mirrorX: widget.app.stageMirrorX,
            mirrorY: widget.app.stageMirrorY,
            failedImageLayerIds: widget.app.failedImageLayerIds,
            loupe: _loupe(),
            contourOverlay: _contourOverlay(),
            physicsContacts: _physicsContacts(),
            projectOutlines: _projectOutlines(),
            hiddenLines: _hiddenLines(),
            unitOverlay: _unitOverlay(),
          ),
        ),
      ),
      // picking a parent's children: how many, done / cancel.
      if (widget.app.parentPickFor != null)
        Positioned(
          right: 8,
          bottom: 8,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(
              key: const ValueKey('parent-pick-cancel'),
              onPressed: () => widget.app.finishParentPick(apply: false),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              key: const ValueKey('parent-pick-done'),
              onPressed: () => widget.app.finishParentPick(),
              icon: const Icon(Icons.check, size: 18),
              label: Text('Link ${widget.app.parentPicked.length}'),
            ),
          ]),
        ),
      // a new shape waiting for its box: cancel.
      if (widget.app.pendingPlaceShape != null)
        Positioned(
          right: 8,
          bottom: 8,
          child: TextButton.icon(
            key: const ValueKey('place-cancel'),
            onPressed: widget.app.cancelPlacing,
            icon: const Icon(Icons.close, size: 18),
            label: const Text('Cancel'),
          ),
        ),
      // adding a line's points by tapping: done.
      if (widget.app.lineTapAdd)
        Positioned(
          right: 8,
          bottom: 8,
          child: FilledButton.icon(
            key: const ValueKey('line-tap-done'),
            onPressed: () => widget.app.setLineTapAdd(false),
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Done adding points'),
          ),
        ),
      // the selection rectangle while it is dragged.
      if (_controller.marqueeA != null && _controller.marqueeB != null)
        Positioned.fromRect(
          rect: Rect.fromPoints(_controller.marqueeA!, _controller.marqueeB!),
          child: IgnorePointer(
            child: Container(
              key: const ValueKey('stage-marquee'),
              decoration: BoxDecoration(
                color: const Color(0x2229B6F6),
                border: Border.all(color: const Color(0xFF29B6F6), width: 1),
              ),
            ),
          ),
        ),
      // a short note (a region in words after a long press), for a moment.
      Positioned(
        top: 8,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: ValueListenableBuilder<String?>(
            valueListenable: widget.app.stageNotice,
            builder: (context, note, _) {
              if (note == null) return const SizedBox.shrink();
              Future.delayed(const Duration(seconds: 3), () {
                if (widget.app.stageNotice.value == note) widget.app.stageNotice.value = null;
              });
              return Center(
                child: Container(
                  key: const ValueKey('stage-notice'),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(6)),
                  child: Text(note, style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              );
            },
          ),
        ),
      ),
      // who is selected, in the corner: the shape's name in one block, the
      // picked region (as the list names it) or "mask" in the next.
      if (selectedLayer != null)
        Positioned(
          key: const ValueKey('stage-selected-name'),
          left: 8,
          bottom: 6,
          child: IgnorePointer(child: _cornerBlocks(selectedLayer)),
        ),
      ]),
      );
    });
  }

  Widget _cornerBlocks(Layer layer) {
    final app = widget.app;
    Widget block(String text, {Color? edge, Key? key}) => Container(
          key: key,
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(4),
            border: edge == null ? null : Border(left: BorderSide(color: edge, width: 3)),
          ),
          child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        );
    final mr = layer.maskRegions;
    final sig = app.selectedRegionSig;
    final region = mr != null && mr.enabled && sig != null && sig < mr.signatureCount;
    // a layer that masks others: just "mask" after its name.
    final masks = !region &&
        app.project.layers.any((l) => l.id != layer.id && l.masks.any((m) => m.enabled && m.sourceLayerId == layer.id));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      block([
        layer.name,
        if (app.multiSelection.isNotEmpty) '+${app.multiSelection.length}',
        if (layer.locked) '(locked)',
      ].join(' ')),
      if (region)
        block(
            '${regionLabel(app.project, layer, sig)}${app.selectedRegionNumber == null ? '' : ' #${app.selectedRegionNumber}'}',
            edge: regionColor(sig),
            key: const ValueKey('stage-selected-region')),
      if (masks) block('mask', key: const ValueKey('stage-selected-mask')),
    ]);
  }

  /// "Show contour" (Effects tab): the rings of those layers, in frame
  /// space - outers and holes apart.
  List<({List<List<double>> points, bool hole})> _contourOverlay() {
    final app = widget.app;
    if (app.contourDebugLayers.isEmpty) return const [];
    final out = <({List<List<double>> points, bool hole})>[];
    for (final id in app.contourDebugLayers) {
      final layer = findLayer(app.project, id);
      if (layer == null) continue;
      final state = getLayerStateAt(app.project, id, app.currentFrame);
      if (!state.inRange) continue;
      final contour = app.renderer.layerContourDrawn(app.project, layer, app.currentFrame, const ContourParams());
      if (contour == null) continue;
      final m = toFrameMatrix(state.matrix);
      for (final r in contour.rings) {
        out.add((points: [for (final q in r.points) applyAffine(m, q)], hole: r.isHole));
      }
    }
    return out;
  }

  /// Text tab, an animator open: its units' boxes (frame space) with
  /// their amounts.
  List<(List<List<double>>, double)> _unitOverlay() {
    final app = widget.app;
    final i = app.showTextRangeOverlay ? app.selectedTextAnimator : null;
    final l = findLayer(app.project, app.selection.selectedLayer);
    final t = l?.content.text;
    if (i == null || l == null || t == null || i >= t.animators.length) return const [];
    final st = getLayerStateAt(app.project, l.id, app.currentFrame);
    if (!st.inRange) return const [];
    final lf = layerLocalFrame(l, app.currentFrame);
    final units = animatedTextUnits(t.atFrame(lf), l.content.offset, l.content.size, lf, selected: i) ?? const [];
    final m = toFrameMatrix(st.matrix);
    return [for (final u in units) ([for (final p in u.box) applyAffine(m, p)], u.amount)];
  }

  /// Invisible vector lines: where each runs, frame space.
  List<List<List<double>>> _hiddenLines() {
    final app = widget.app;
    final follower = app.editingEffectId == 'follow' ? findLayer(app.project, app.selection.selectedLayer) : null;
    final aim = follower == null ? null : followAimPoint(app.project, follower, app.currentFrame);
    return [
      // Follow selected: the follower to its target point.
      if (aim != null)
        () {
          final m = toFrameMatrix(getLayerStateAt(app.project, follower!.id, app.currentFrame).matrix);
          return [
            [m[4], m[5]],
            aim
          ];
        }(),
      for (final l in app.project.layers)
        if (isNodeLine(l.content) && l.content.lineHidden && !l.hidden)
          if (getLayerStateAt(app.project, l.id, app.currentFrame).inRange)
            lineFramePoints(app.project, l, app.currentFrame),
    ];
  }

  /// Stage settings "Outline added projects": each project reference's
  /// box corners in frame space.
  List<List<List<double>>> _projectOutlines() {
    final app = widget.app;
    return [
      // mirror probes: never drawn, so always outlined.
      for (final l in app.project.layers)
        if (l.mirrorProbe && !l.hidden)
          if (getLayerStateAt(app.project, l.id, app.currentFrame) case final st when st.inRange)
            () {
              final m = toFrameMatrix(st.matrix);
              return [
                for (final p in getContentOutline(l.content, l, app.currentFrame, project: app.project)) applyAffine(m, p)
              ];
            }(),
      if (app.showProjectOutlines) ...[
      for (final l in app.project.layers)
        if (l.content.shape == 'projectRef' && !l.hidden)
          if (getLayerStateAt(app.project, l.id, app.currentFrame) case final st when st.inRange)
            () {
              final m = toFrameMatrix(st.matrix);
              final c = l.content;
              final x0 = c.offset[0] - c.size[0] / 2, y0 = c.offset[1] - c.size[1] / 2;
              final x1 = x0 + c.size[0], y1 = y0 + c.size[1];
              return [for (final p in [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]) applyAffine(m, p)];
            }(),
      ],
    ];
  }

  /// Contour physics contacts of this frame, for layers whose contour is
  /// shown (debug view).
  List<PhysicsContact> _physicsContacts() {
    final app = widget.app;
    if (app.contourDebugLayers.isEmpty) return const [];
    return [
      for (final c in physicsWorldOf(app.project).contactsAt(app.currentFrame))
        if (app.contourDebugLayers.contains(c.a) || app.contourDebugLayers.contains(c.b)) c
    ];
  }

  /// The eyedropper loupe while the Chroma pick finger is down.
  ChromaLoupe? _loupe() {
    final finger = _controller.chromaPickScreen;
    final op = _controller.activeDrag?.op;
    if (finger == null || op is! ChromaPickDragOp || op.framePoint == null) return null;
    final app = widget.app;
    // a colour field's eyedropper: the whole frame.
    if (chromaTool == 'stagePick') {
      final rgb = app.stagePickRgbAt(op.framePoint!);
      return ChromaLoupe(
        finger: finger,
        image: app.stagePickImage,
        center: Offset(op.framePoint![0], op.framePoint![1]),
        color: rgb == null ? null : Color.fromARGB(255, rgb[0], rgb[1], rgb[2]),
      );
    }
    final uv = framePointToImageUv(app.project, op.layer, app.currentFrame, op.framePoint!);
    final image = app.renderer.decodedImageOf(op.layer, app.currentFrame);
    final inside = uv[0] >= 0 && uv[0] <= 1 && uv[1] >= 0 && uv[1] <= 1;
    final rgb = inside ? app.renderer.sampleImageRgbSync(op.layer, app.currentFrame, uv[0], uv[1]) : null;
    return ChromaLoupe(
      finger: finger,
      image: image,
      center: image == null ? Offset.zero : Offset(uv[0] * image.width, uv[1] * image.height),
      color: rgb == null ? null : Color.fromARGB(255, rgb[0], rgb[1], rgb[2]),
    );
  }
}

class _StageCustomPainter extends CustomPainter {
  final ui.Picture? contentPicture;
  final double frameWidth;
  final double frameHeight;
  final Project project;
  final Layer? selectedLayer;
  final int globalFrame;
  final StageCamera camera;
  final ActiveDragInfo? activeDrag;
  final bool mirrorX;
  final bool mirrorY;
  final List<String> failedImageLayerIds;
  final ChromaLoupe? loupe;
  final List<Layer> groupLayers;

  _StageCustomPainter({
    this.groupLayers = const [],
    this.loupe,
    this.mirrorX = false,
    this.mirrorY = false,
    this.failedImageLayerIds = const [],
    this.contourOverlay = const [],
    this.physicsContacts = const [],
    this.projectOutlines = const [],
    this.hiddenLines = const [],
    this.unitOverlay = const [],
    required this.contentPicture,
    required this.frameWidth,
    required this.frameHeight,
    required this.project,
    required this.selectedLayer,
    required this.globalFrame,
    required this.camera,
    required this.activeDrag,
  });

  @override
  void paint(Canvas canvas, Size size) {
    paintStage(
      canvas: canvas,
      size: size,
      contentPicture: contentPicture,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      project: project,
      selectedLayer: selectedLayer,
      globalFrame: globalFrame,
      camera: camera,
      activeDrag: activeDrag,
      mirrorX: mirrorX,
      mirrorY: mirrorY,
      failedImageLayerIds: failedImageLayerIds,
      loupe: loupe,
      groupLayers: groupLayers,
      contourOverlay: contourOverlay,
      physicsContacts: physicsContacts,
      projectOutlines: projectOutlines,
      hiddenLines: hiddenLines,
      unitOverlay: unitOverlay,
    );
  }

  final List<PhysicsContact> physicsContacts;

  final List<List<List<double>>> projectOutlines;
  final List<List<List<double>>> hiddenLines;
  final List<(List<List<double>>, double)> unitOverlay;

  final List<({List<List<double>> points, bool hole})> contourOverlay;

  // always repaint - matches the pull-model "recompute fresh every
  // call" philosophy already used throughout this project (render(frame)
  // itself has no dirty-tracking either); premature to hand-optimize
  // this without profiling on a real device, which isn't possible here.
  @override
  bool shouldRepaint(covariant _StageCustomPainter oldDelegate) => true;
}
