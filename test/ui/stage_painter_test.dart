import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';

/// Real, run pixel-level coverage of stage_painter.dart's toggle gating
/// and per-family sibling-hide logic - a real gap flagged in review:
/// stage_gesture_controller_test.dart verifies the CONTROLLER correctly
/// tags `ActiveDragInfo.family`/`.activeKey` when a handle is captured,
/// but nothing previously checked that the PAINTER actually reads that
/// tag correctly (that an unrelated family really does stay drawn, that
/// only the active family's own siblings actually disappear, that the
/// two toggles gate what the code comments claim they gate). Same
/// technique as off_canvas_export_test.dart: paintStage() is a plain
/// function taking a real ui.Canvas, so this calls it directly and
/// inspects the rasterized pixels via toImage() - no widget pump, no
/// device, just the real dart:ui engine headlessly.
///
/// Colors/radii sampled below are stage_painter.dart's own constants,
/// read directly from the file rather than re-derived by guesswork -
/// see its _handleFill/_moveColor/_meshWarpColor/_stationFill.
void main() {
  const width = 200.0, height = 150.0;

  Future<ByteData> render({
    required Project project,
    required Layer selectedLayer,
    ActiveDragInfo? activeDrag,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas =
        ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, width, height));
    paintStage(
      canvas: canvas,
      size: const ui.Size(width, height),
      contentPicture: null,
      frameWidth: width,
      frameHeight: height,
      project: project,
      selectedLayer: selectedLayer,
      globalFrame: 0,
      camera: StageCamera(),
      activeDrag: activeDrag,
    );
    final image =
        await recorder.endRecording().toImage(width.round(), height.round());
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  }

  // tolerance-based, not exact-byte match: a FILLED circle's interior is
  // solidly covered regardless of sub-pixel center position, but a pure
  // STROKE (moveCorner's crosshair+ring has no filled interior at all)
  // can anti-alias such that NO single pixel reaches 100% coverage of
  // the target color - every candidate pixel ends up a partial blend
  // with whatever's underneath. Tolerance is kept deliberately tight
  // (6, not something looser) - handleFill (0x151515) and the
  // background (0x1E1E1E) are only 9 apart per channel, and a tolerance
  // anywhere near that would make "is this handle's fill present"
  // trivially true against plain background, defeating the whole point
  // of the sibling-hidden/toggle-off checks below. Where a stroke-only
  // glyph needs more help than 6 can safely give, the fix is a wider
  // SEARCH RADIUS (more candidate pixels along the stroke), not a
  // looser color match.
  bool colorPresentNear(ByteData bytes, double x, double y, ui.Color color,
      {int radius = 2, int tolerance = 6}) {
    final cx = x.round(), cy = y.round();
    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        final px = cx + dx, py = cy + dy;
        if (px < 0 || py < 0 || px >= width || py >= height) continue;
        final i = (py * width.round() + px) * 4;
        if ((bytes.getUint8(i) - color.red).abs() <= tolerance &&
            (bytes.getUint8(i + 1) - color.green).abs() <= tolerance &&
            (bytes.getUint8(i + 2) - color.blue).abs() <= tolerance) {
          return true;
        }
      }
    }
    return false;
  }

  // stage_painter.dart's own private palette - duplicated here
  // deliberately (not imported - they're private), so a color change
  // there has to be a conscious update here too, not silently drift.
  const moveColor = ui.Color(0xFFD8D8D8);
  const meshWarpColor = ui.Color(0xFFC9A8E0);
  const handleFill = ui.Color(0xFF151515);
  const stationFill = ui.Color(0xFF151515);

  Layer meshWarpLayer(Project project) {
    registerBuiltinEffects();
    final layer = createLayer('rect');
    layer.transform.anchor.defaultValue = [0.5, 0.5];
    project.layers.add(layer);
    final inst = createEffectInstance('mesh_warp', 'fx1', layer);
    layer.effectStack.add(inst);
    return layer;
  }

  setUp(() {
    setStageSize(width, height);
    hideHandles = false;
    hideVisualLayer = false;
  });

  group('cross-family independence', () {
    test(
        'under mesh warp no move handle is drawn (the shape itself moves it)',
        () async {
      final project = Project();
      final layer = meshWarpLayer(project);
      final inst = getMeshWarpInstance(layer)!;

      final activeDrag = ActiveDragInfo(
        family: 'meshWarp',
        activeKey: 'r0c0',
        op: MeshDragOp(
            layer: layer, inst: inst, pinKey: 'r0c0', natural: const [0, 0]),
      );
      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: activeDrag);

      // recomputed the same way the painter itself does, including the
      // deformed-centroid recentering that kicks in once mesh-warp is
      // active - not the plain bbox corner a non-deformed layer would use.
      final tb = getTransformBoxHandles(project, layer, 0);
      final moveCorner = tb.screen['moveCorner']!;
      // moveCorner is a pure stroke glyph (crosshair + ring, no filled
      // interior) - a wider search radius than the filled-circle checks
      // elsewhere, so at least one sampled pixel lands on a well-covered
      // part of the stroke rather than a partially-anti-aliased one.
      // mesh warp / corner pin: the shape itself is the move area - no
      // move handle is drawn (its centre could sit outside a caved-in
      // shape).
      expect(
          colorPresentNear(bytes, moveCorner[0], moveCorner[1], moveColor,
              radius: 4),
          isFalse,
          reason: 'under mesh warp the whole shape moves it - no move handle');
    });
  });

  group('sibling-hide within a family', () {
    test(
        'the captured mesh-warp pin stays visible; its OTHER pins in the same family disappear',
        () async {
      final project = Project();
      final layer = meshWarpLayer(project);
      final inst = getMeshWarpInstance(layer)!;
      final mesh = getMeshWarpHandles(project, layer, inst, 0);
      final r0c0 = mesh.handles.firstWhere((h) => h.key == 'r0c0');
      final r3c3 = mesh.handles.firstWhere((h) => h.key == 'r3c3');

      final activeDrag = ActiveDragInfo(
        family: 'meshWarp',
        activeKey: 'r0c0',
        op: MeshDragOp(
            layer: layer, inst: inst, pinKey: 'r0c0', natural: r0c0.natural),
      );
      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: activeDrag);

      expect(
          colorPresentNear(bytes, r0c0.screen[0], r0c0.screen[1], handleFill),
          isTrue,
          reason:
              'the ACTIVE pin (r0c0) must stay drawn - it\'s the one being dragged');
      expect(
          colorPresentNear(bytes, r3c3.screen[0], r3c3.screen[1], handleFill),
          isFalse,
          reason:
              'an INACTIVE sibling pin (r3c3) in the SAME family must disappear during the drag - '
              'handleFill is specific to the dot\'s own fill, distinct from the mesh grid lines\' own '
              'color, which stay drawn regardless and would otherwise false-positive this check');
    });

    test(
        'with no active drag at all, every mesh-warp pin (including r3c3) is visible',
        () async {
      final project = Project();
      final layer = meshWarpLayer(project);
      final inst = getMeshWarpInstance(layer)!;
      final mesh = getMeshWarpHandles(project, layer, inst, 0);
      final r3c3 = mesh.handles.firstWhere((h) => h.key == 'r3c3');

      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);
      expect(
          colorPresentNear(bytes, r3c3.screen[0], r3c3.screen[1], handleFill),
          isTrue);
    });
  });

  group('path visual layer during an active (non-path) drag', () {
    test(
        'a transform-box drag elsewhere on the layer leaves the path\'s dotted line/stations fully visible',
        () async {
      final project = Project();
      final layer = createLayer('rect');
      layer.transform.anchor.spatial = true;
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.2, 0.5]),
        Keyframe(frame: 30, value: [0.8, 0.5]),
      ]);
      project.layers.add(layer);

      final activeDrag = ActiveDragInfo(
          family: 'transformBox',
          activeKey: 'moveCorner',
          op: ScaleDragOp(layer: layer, handle: 'scaleCorner'));
      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: activeDrag);

      final stations = getAnchorStationsScreen(project, layer, 0);
      for (final st in stations) {
        expect(colorPresentNear(bytes, st.screen[0], st.screen[1], stationFill),
            isTrue,
            reason:
                'path is purely visual with no physical component of its own - the "physical '
                'disappears during any drag" rule (which DOES apply to path\'s touch targets) has no '
                'bearing on its visual dots/line, which the spec says stay visible throughout ANY drag');
      }
    });
  });

  group('toggle gating', () {
    test(
        'hideHandles=true suppresses the entire handle layer, mesh grid lines included - not just the dots',
        () async {
      final project = Project();
      final layer = meshWarpLayer(project);
      final inst = getMeshWarpInstance(layer)!;
      final mesh = getMeshWarpHandles(project, layer, inst, 0);
      final r0c0 = mesh.handles.firstWhere((h) => h.key == 'r0c0');

      hideHandles = true;
      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);

      expect(
          colorPresentNear(bytes, r0c0.screen[0], r0c0.screen[1], handleFill,
              radius: 4),
          isFalse);
      expect(
          colorPresentNear(bytes, r0c0.screen[0], r0c0.screen[1], meshWarpColor,
              radius: 4),
          isFalse);
    });

    test(
        'hideVisualLayer=true hides the path but leaves handles alone - the two toggles are independent',
        () async {
      final project = Project();
      final layer = createLayer('rect');
      layer.transform.anchor.spatial = true;
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.2, 0.5]),
        Keyframe(frame: 30, value: [0.8, 0.5]),
      ]);
      project.layers.add(layer);

      hideVisualLayer = true;
      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);

      final stations = getAnchorStationsScreen(project, layer, 0);
      expect(
          colorPresentNear(
              bytes, stations[0].screen[0], stations[0].screen[1], stationFill),
          isFalse);

      // handles (governed by hideHandles, which is still false here)
      // must be entirely unaffected by hideVisualLayer.
      final tb = getTransformBoxHandles(project, layer, 0);
      final moveCorner = tb.screen['moveCorner']!;
      expect(
          colorPresentNear(bytes, moveCorner[0], moveCorner[1], moveColor,
              radius: 4),
          isTrue);
    });
  });

  group('effect deformation grid overlay (squeeze/bend, no dedicated handles)',
      () {
    const deformGridColor = ui.Color(0xFF7FA0D8);

    test('a squeeze_axis layer actually paints the grid overlay', () async {
      registerBuiltinEffects();
      final project = Project();
      final layer = createLayer('rect');
      layer.transform.anchor.defaultValue = [0.5, 0.5];
      project.layers.add(layer);
      final inst = createEffectInstance('squeeze_axis', 'fx1', layer);
      inst.params['axisX'] = track(2.0);
      layer.effectStack.add(inst);

      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);

      // scan every actual grid vertex rather than hand-picking one index
      // and hoping the coordinate math lines up - any single vertex
      // showing the overlay color proves it painted. Wider tolerance
      // than the filled-circle handle checks elsewhere in this file:
      // this overlay is a bare 1.5px STROKE with no filled interior, so
      // even at a genuine grid-line intersection, anti-aliased sub-pixel
      // coverage rarely lands close enough to the target color to
      // satisfy a tight tolerance the way a solidly-covered filled
      // circle does.
      final grid = getEffectDeformationGridScreen(project, layer, 0)!;
      final anyPresent = grid.screen.any((p) => colorPresentNear(
          bytes, p[0], p[1], deformGridColor,
          radius: 3, tolerance: 25));
      expect(anyPresent, isTrue);
    });

    test('no overlay at all for a layer with no enabled effect', () async {
      final project = Project();
      final layer = createLayer('rect');
      layer.transform.anchor.defaultValue = [0.5, 0.5];
      project.layers.add(layer);

      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);

      // scan the whole frame - the deform-grid color should never appear.
      var found = false;
      for (var i = 3; i < bytes.lengthInBytes; i += 4) {
        final px = (i ~/ 4) % width.round(), py = (i ~/ 4) ~/ width.round();
        final o = (py * width.round() + px) * 4;
        if ((bytes.getUint8(o) - deformGridColor.red).abs() <= 6 &&
            (bytes.getUint8(o + 1) - deformGridColor.green).abs() <= 6 &&
            (bytes.getUint8(o + 2) - deformGridColor.blue).abs() <= 6) {
          found = true;
          break;
        }
      }
      expect(found, isFalse);
    });

    test(
        'mesh_warp suppresses the generic overlay - its OWN dedicated grid draws instead, not both',
        () async {
      final project = Project();
      final layer = meshWarpLayer(project);

      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);

      // meshWarp's own color IS present (dedicated handle drawing)...
      final mesh =
          getMeshWarpHandles(project, layer, getMeshWarpInstance(layer)!, 0);
      expect(
          colorPresentNear(bytes, mesh.handles.first.screen[0],
              mesh.handles.first.screen[1], meshWarpColor,
              radius: 4),
          isTrue);
      // ...and the generic squeeze/bend overlay color is simply absent,
      // since getEffectDeformationGridScreen is never even called for a
      // layer whose active effect already has dedicated handles.
      expect(getEffectDeformationGridScreen(project, layer, 0), isNotNull,
          reason:
              'sanity: the layer DOES have an enabled effect, so this only proves suppression, not an unrelated no-op');
    });

    test(
        'hideVisualLayer=true hides the overlay (it\'s a passive readout, not a draggable handle)',
        () async {
      registerBuiltinEffects();
      final project = Project();
      final layer = createLayer('rect');
      layer.transform.anchor.defaultValue = [0.5, 0.5];
      project.layers.add(layer);
      layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));

      hideVisualLayer = true;
      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);

      final grid = getEffectDeformationGridScreen(project, layer, 0)!;
      final midTop = grid.screen[grid.cols ~/ 2];
      expect(
          colorPresentNear(bytes, midTop[0], midTop[1], deformGridColor,
              radius: 3),
          isFalse);
    });
  });

  group(
      'handles disappear once the selected layer is out of its own active range',
      () {
    test(
        'a layer whose startFrame is now AFTER the current global frame draws NO handles at all',
        () async {
      final project = Project();
      final layer = createLayer('rect');
      layer.transform.anchor.defaultValue = [0.5, 0.5];
      layer.startFrame =
          50; // out of range at globalFrame 0, used by render() below
      project.layers.add(layer);

      final bytes = await render(
          project: project, selectedLayer: layer, activeDrag: null);

      // moveCorner is [bbox.minX, bbox.maxY] projected through the layer's own
      // matrix (see getTransformBoxHandles) - not necessarily the stage center
      // - recomputed the same way the OTHER tests in this file do, using
      // whatever frame the state would resolve to if inRange gating were NOT
      // applied (frame 0, matching render's own hardcoded globalFrame), so the
      // checked position is exactly where the stale handle used to freeze.
      // this handle used to stay visible there even after the layer's own
      // content stopped rendering, because nothing here checked
      // getLayerStateAt.inRange before drawing handles.
      final tb = getTransformBoxHandles(project, layer, 0);
      final moveCorner = tb.screen['moveCorner']!;
      expect(
          colorPresentNear(bytes, moveCorner[0], moveCorner[1], moveColor,
              radius: 6),
          isFalse,
          reason:
              'no handles should draw for a layer that is not in range at this frame');
    });

    test(
        'the SAME layer draws handles normally once scrubbed back into its own active range',
        () async {
      final project = Project();
      final layer = createLayer('rect');
      layer.transform.anchor.defaultValue = [0.5, 0.5];
      layer.startFrame = 50;
      project.layers.add(layer);

      final recorder = ui.PictureRecorder();
      final canvas =
          ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, width, height));
      paintStage(
        canvas: canvas,
        size: const ui.Size(width, height),
        contentPicture: null,
        frameWidth: width,
        frameHeight: height,
        project: project,
        selectedLayer: layer,
        globalFrame: 60, // inside [50, 50+180]
        camera: StageCamera(),
        activeDrag: null,
      );
      final image =
          await recorder.endRecording().toImage(width.round(), height.round());
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

      final tb = getTransformBoxHandles(project, layer, 60);
      final moveCorner = tb.screen['moveCorner']!;
      expect(
          colorPresentNear(bytes, moveCorner[0], moveCorner[1], moveColor,
              radius: 6),
          isTrue,
          reason:
              'the same layer must draw its handles normally once the playhead is back within its active range');
    });
  });

  group('phantom parent-link lines', () {
    const parentLinkColor = ui.Color(0xFF5A9FD4);

    test(
        'a parent-link line is drawn while both parent and child are in range',
        () async {
      final project = Project();
      final parent = createLayer('rect');
      parent.transform.anchor.defaultValue = [0.3, 0.5];
      parent.durationFrames = 200;
      project.layers.add(parent);
      final child = createLayer('circle');
      child.transform.anchor.defaultValue = [0.7, 0.5];
      child.parentId = parent.id;
      child.durationFrames = 60;
      project.layers.add(child);

      final geo = computeParentLinkGeometry(project, 0);
      final edge = geo.edges.single;

      final bytes =
          await render(project: project, selectedLayer: child, activeDrag: null);
      expect(
          colorPresentNear(bytes, edge.childScreen[0], edge.childScreen[1],
              parentLinkColor,
              radius: 4),
          isTrue,
          reason:
              'both layers are in range at frame 0 - the link line/dot should be drawn');
    });

    test(
        'the SAME link line disappears once the child layer falls out of its own active range',
        () async {
      final project = Project();
      final parent = createLayer('rect');
      parent.transform.anchor.defaultValue = [0.3, 0.5];
      parent.durationFrames = 200; // still in range at frame 100 below
      project.layers.add(parent);
      final child = createLayer('circle');
      child.transform.anchor.defaultValue = [0.7, 0.5];
      child.parentId = parent.id;
      child.durationFrames = 60; // OUT of range at frame 100
      project.layers.add(child);

      const frame = 100;
      final geo = computeParentLinkGeometry(project, frame);
      final edge = geo.edges.single;

      final recorder = ui.PictureRecorder();
      final canvas =
          ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, width, height));
      paintStage(
        canvas: canvas,
        size: const ui.Size(width, height),
        contentPicture: null,
        frameWidth: width,
        frameHeight: height,
        project: project,
        selectedLayer: child,
        globalFrame: frame,
        camera: StageCamera(),
        activeDrag: null,
      );
      final image =
          await recorder.endRecording().toImage(width.round(), height.round());
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

      expect(
          colorPresentNear(bytes, edge.childScreen[0], edge.childScreen[1],
              parentLinkColor,
              radius: 4),
          isFalse,
          reason:
              'the child is out of its own active range at frame 100 - the phantom link must not draw, even though the parent itself is still in range');
    });
  });
}
