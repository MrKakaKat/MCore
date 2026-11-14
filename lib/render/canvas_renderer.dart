/// ============================================================
/// CustomPainter/Canvas implementation of the Renderer interface.
///
/// Ported from movement-core/src/render/{renderLayer,render,maskStack}.js.
/// Confidence varies a lot across this file, and it's worth being
/// honest about exactly where, since none of it has been compiled or
/// run in this session (no Flutter SDK available - see the migration
/// plan's own note on this):
///
/// - HIGH confidence: the plain rect/circle/triangle fill/stroke paths,
///   matrix setup via Matrix4, opacity via Paint.color alpha, the mask
///   stack's blend-mode mapping (BlendMode.srcOver/dstOut/dstIn/xor are
///   direct equivalents of the JS globalCompositeOperation strings
///   used here), motion blur via an isolated accumulation layer +
///   BlendMode.plus (the "lighter"/additive equivalent) - see the
///   inline comment at the saveLayer call in _drawLayer. JS's own
///   drawLayer() (movement-core/src/render/renderLayer.js) accumulates
///   into an isolated scratch canvas the same way, so this is now a
///   direct 1:1 port, not a deviation - the two engines used to differ
///   here (JS blended straight onto the real canvas) until JS was
///   brought in line with this file rather than the other way around.
/// - LOWER confidence, flagged inline: the textured/warped path
///   (non-rect shapes under an active effect, and precompose groups)
///   needs a rasterized source image warped per-grid-cell - ported here
///   via Canvas.drawVertices with UV-mapped triangles (a cleaner single
///   -call analog of the JS's many small per-cell drawImage calls, per
///   the migration plan's own note), fed by Picture.toImageSync(). That
///   method needs a reasonably recent stable Flutter (dart:ui's
///   Picture.toImage() is async; the sync variant is newer) - re-check
///   this against whatever Flutter version the app actually targets
///   before relying on it, and swap to precomputing images ahead of a
///   synchronous renderFrame() call if it's unavailable.
///
/// One remaining deliberate architecture change from the JS, disclosed
/// here rather than presented as a straight port: render() there also
/// draws the selected layer's interactive handles (transform box,
/// corner-pin, mesh-warp, pendulum pivot) as part of the SAME render()
/// call - meaning a PNG export literally includes on-screen handles
/// unless HIDE_HANDLES is manually enabled first. Here, CanvasRenderer
/// draws ONLY layer content; handle drawing is ui/stage/'s job, layered
/// on top by the widget that owns both. This is cleaner (matches the
/// plan's own "swap-friendly" goal - captureFrame() should never
/// accidentally include UI chrome) and was worth deviating for, rather
/// than porting the coupling forward on principle.
///
/// (Motion blur used to be a second documented deviation here - this
/// port isolated samples into an accumulation buffer while JS blended
/// straight onto the real canvas. That's no longer a deviation: JS's
/// drawLayer() was brought in line with this file's isolated-buffer
/// approach instead, so both engines now render motion blur identically.)
///
/// Image content (added for the image-import feature - no JS equivalent
/// to compare against): decodes via ui.instantiateImageCodec, cached by
/// source-data identity in _imageCache. This is UNVERIFIED like the
/// rest of the textured/warped path above - worse, actually: this
/// sandbox's headless flutter_tester was confirmed this session to hang
/// indefinitely inside instantiateImageCodec even for a trivial PNG
/// payload (see gif_encoder_test.dart's doc comment for the full
/// finding). A follow-up test (test/app_state_image_layer_test.dart)
/// sharpened that finding further: this environment can complete
/// exactly ONE instantiateImageCodec call per test file/process before
/// every subsequent call hangs, regardless of whether the bytes are
/// valid or garbage, or whether a referenced file even exists - so this
/// path couldn't be exercised via flutter test at all, not even to the
/// "compiles and pixel-checks in isolation" level most of this file's
/// other logic gets, and no test in this codebase may call
/// AppState.addImageLayer (or otherwise render a second image-shaped
/// layer) more than once per file. Written carefully against the
/// existing _rasterizeShapeSilhouette/_drawWarpedGrid pipeline (reused,
/// not reimplemented) and reviewed by inspection; real verification
/// needs an actual device, per the user's own "write code now, test
/// later" instruction for this export/import round.
/// ============================================================
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:movement_core/movement_core.dart';

import 'renderer.dart';
import '../perf/perf_monitor.dart';
import 'contour_cache.dart';
import 'video_frame_cache.dart';

class CanvasRenderer implements Renderer {
  /// Layers a Cut by layer hides (its cutter), this frame.
  Set<String> _hiddenCutters = const {};

  /// The stage's holes in a layer (frame px), cut from that layer's own
  /// drawing only - null for exports.
  List<ui.Path> Function(Project project, Layer layer, int globalFrame)? stageCuts;

  ui.Picture? _picture;
  double _width = 640;
  double _height = 400;

  /// the CustomPainter that owns the on-screen canvas reads this to
  /// blit the most recently rendered frame - NOT part of the Renderer
  /// interface (that only guarantees renderFrame/captureFrame/dispose),
  /// but a real concrete implementation needs some way to hand its
  /// result to whatever's actually painting the screen.
  ui.Picture? get currentPicture => _picture;

  /// fired once an async image decode (see _getDecodedImage) completes -
  /// the caller (AppState) wires this to trigger a re-render/rebuild so
  /// a freshly-imported/loaded image actually appears once ready,
  /// instead of staying blank until some unrelated later render call.
  void Function()? onImageDecoded;

  /// Whether the physics bake is behind the frame shown ("baking...").
  bool physicsBaking = false;

  /// Bakes contour physics up to `frame` (within `budget`); true while not
  /// there yet - another render is asked for.
  bool _bakePhysics(Project project, int frame, Duration? budget) {
    if (!project.layers.any((l) => l.physics.collide)) return false;
    enablePhysicsOffsets();
    final world = physicsWorldOf(project)..rings = _physicsRings;
    // export: fully baked.
    if (budget == null) {
      world.bakeTo(frame);
      return false;
    }
    // the frame shown first (up to 20 ms a render - dragging stays
    // smooth; a re-bake that takes longer finishes over the next renders),
    // then the rest of the timeline in the background.
    if (!world.bakeTo(frame, budget: const Duration(milliseconds: 20))) {
      Future<void>.delayed(Duration.zero, () => onImageDecoded?.call());
      return true;
    }
    final end = world.endFrame;
    if (!world.bakeTo(end, budget: budget)) Future<void>.delayed(Duration.zero, () => onImageDecoded?.call());
    return false;
  }

  // the same ring lists for the same contour (physics keeps their hulls).
  final Expando<List<List<List<double>>>> _outerRings = Expando('outer rings');

  /// The rings physics collides with: the layer's contour (outer rings)
  /// with its first Outline's threshold / offset / smoothness, else the
  /// defaults.
  List<List<List<double>>>? _physicsRings(Project project, Layer layer, int frame) {
    // a line collides as a line (its stretches), not its box.
    if (isNodeLine(layer.content)) return lineCollisionRings(layer.content, frame: layerLocalFrame(layer, frame));
    final outline = layer.effectStack.where((i) => i.enabled && i.effectId == 'outline').firstOrNull;
    var p = const ContourParams();
    if (outline != null) {
      final lf = layerLocalFrame(layer, frame).toDouble();
      final prm = resolveEffectParams(outline, lf);
      final sm = outlineSmoothness((prm['smoothness'] as num?)?.toDouble() ?? 1);
      p = ContourParams(
          threshold: ((prm['threshold'] as num?)?.toDouble() ?? 0.5).clamp(0.05, 0.95),
          simplify: sm.simplify,
          smooth: sm.smooth,
          offset: (prm['offset'] as num?)?.toDouble() ?? 0,
          sharp: prm['join'] == 'miter');
    }
    final c = layerContour(project, layer, frame, p);
    if (c == null) return null;
    // outer rings and holes: concave shapes split into convex parts.
    return _outerRings[c] ??= [for (final r in c.rings) r.points];
  }

  /// Layer silhouette contours (the Outline effect, the debug view).
  final ContourCache contours = ContourCache();

  /// The layer's contour in content-local space with these settings -
  /// exact geometry for vector content; for images / video extracted
  /// from the source pixels off the UI thread (null until the first one
  /// is ready, then the last one is held while the next is made).
  ///
  /// It is the contour of what is drawn: for images / video the alpha
  /// AFTER chroma key and edge matte (until the keyed picture is ready
  /// the last contour is held); crop applied (the outline runs along the
  /// cut) and the layer's mirror. Not deformed - see layerContourDrawn.
  Contour? layerContour(Project project, Layer layer, int globalFrame, ContourParams p) {
    final c = layer.content;
    // the kept box in the unmirrored content space (crop is applied to
    // the drawn - mirrored - content).
    List<double>? crop;
    if (layerHasCrop(layer)) {
      final b = croppedBox(layer);
      crop = [b.minX, b.minY, b.maxX, b.maxY];
      if (layer.mirrorX || layer.mirrorY) {
        final bb = shapeBoundingBox(c);
        final cx = (bb.minX + bb.maxX) / 2, cy = (bb.minY + bb.maxY) / 2;
        if (layer.mirrorX) crop = [2 * cx - crop[2], crop[1], 2 * cx - crop[0], crop[3]];
        if (layer.mirrorY) crop = [crop[0], 2 * cy - crop[3], crop[2], 2 * cy - crop[1]];
      }
    }
    final Contour? raw;
    if (hasRasterContour(layer)) {
      final src = _sourceImageOf(layer, globalFrame);
      if (src == null) return contours.held(layer.id);
      var image = src.image;
      var pixelKey = src.key;
      if (layer.chromaKey.active || _edgeMatteOn(layer)) {
        // the keyed picture (made off thread): its alpha is what shows.
        if (chromaMatteLayerId == layer.id) return contours.held(layer.id);
        final shown = _layerImage(layer, globalFrame);
        final k = _keyed[layer.id];
        if (k == null || !identical(shown, k.image)) return contours.held(layer.id);
        image = k.image;
        pixelKey = 'keyed|${k.sig}';
      }
      raw = contours.raster(
          layerId: layer.id,
          key: '$pixelKey|${c.offset}|${c.size}|$crop|${p.key}',
          pixels: () => _pixelsOf(pixelKey, image),
          offset: [...c.offset],
          size: [...c.size],
          params: p,
          crop: crop,
          onReady: () => onImageDecoded?.call());
    } else {
      raw = _vectorContour(project, layer, globalFrame, p, crop);
    }
    if (raw == null || !(layer.mirrorX || layer.mirrorY)) return raw;
    final bb = shapeBoundingBox(c);
    final cx = (bb.minX + bb.maxX) / 2, cy = (bb.minY + bb.maxY) / 2;
    return raw.map((q) => [layer.mirrorX ? 2 * cx - q[0] : q[0], layer.mirrorY ? 2 * cy - q[1] : q[1]]);
  }

  /// layerContour as drawn: images, video, text and merged shapes are
  /// also carried through the layer's deformation grid (mesh warp, bend,
  /// a parent's bend...), like their picture; shapes already give their
  /// deformed outline.
  Contour? layerContourDrawn(Project project, Layer layer, int globalFrame, ContourParams p) {
    final contour = layerContour(project, layer, globalFrame, p);
    if (contour == null || contour.rings.isEmpty) return contour;
    final shape = layer.content.shape;
    final pictureLike = isMediaShape(shape) || shape == 'text' || shape == 'textGroup' || shape == 'compound';
    if (!pictureLike) return contour;
    final deforms = layer.effectStack.any(isDeformingEffect) || deformingAncestors(project, layer, globalFrame).isNotEmpty;
    if (!deforms) return contour;
    final bbox = shapeBoundingBox(layer.content);
    final srcContent = Content(
      shape: 'rect',
      offset: [(bbox.minX + bbox.maxX) / 2, (bbox.minY + bbox.maxY) / 2],
      size: [bbox.maxX - bbox.minX, bbox.maxY - bbox.minY],
    );
    final srcGrid = buildEffectGrid(layer, srcContent, globalFrame, project: project, n: 10);
    final dstGrid = applyInheritedDeform(
        project,
        layer,
        applyEffectStack(layer, [for (final row in srcGrid) [for (final q in row) [...q]]], globalFrame, project: project),
        globalFrame);
    return contour.map((q) => warpPoint(q, srcGrid, dstGrid));
  }

  Contour _vectorContour(Project project, Layer layer, int globalFrame, ContourParams p, List<double>? crop) {
    final c = layer.content;
    // a deformed shape's outline changes frame by frame.
    final moves = layer.effectStack.any(isDeformingEffect);
    final t = c.text;
    final key = [
      layer.id, c.shape, c.offset, c.size, c.sides, c.points?.length, c.points?.firstOrNull,
      c.contours?.length, c.contours?.firstOrNull?.firstOrNull,
      layer.fill.cornerRadius, layer.fill.outerRadius, layer.fill.cornerShape,
      if (t != null) ...[t.text, t.fontId, t.fontSize, t.letterSpacing, t.lineSpacing, t.align],
      // a line: its points and look; animated texts / lines change by frame.
      if (c.lineNodes != null) ...[
        c.lineNodes!.map((n) => n.toJson()).join(),
        c.lineWidth,
        c.lineClosed,
        c.lineFilled,
        globalFrame,
      ],
      if (t != null && t.animators.isNotEmpty) globalFrame,
      if (moves) globalFrame,
      // cut / masked by other layers: changes when they move.
      if (layerHasCuts(layer) || layer.masks.any((m) => m.enabled && m.sourceLayerId != null))
        jsonEncode(layerVectorRings(project, layer, globalFrame)),
      crop,
      p.key,
    ].join('|');
    return contours.vector(key, () {
      var rings = layerVectorRings(project, layer, globalFrame);
      if (rings == null) return Contour.empty;
      if (crop != null) rings = clipRingsToRect(rings, crop);
      return contourOfVectorRings(rings, p);
    });
  }

  /// The Outline effects of a layer, drawn in its content-local space:
  /// `behind` the content ("outside" strokes) or over it ("center" /
  /// "inside"). Several stack: for the ones behind, the first in the list
  /// is drawn last (nearest the content).
  void _drawOutlines(ui.Canvas canvas, Project project, Layer layer, int globalFrame, {required bool behind}) {
    final lf = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
    final insts = [
      for (final i in layer.effectStack)
        if (i.enabled && i.effectId == 'outline' && effectActiveAt(layer, i.id, lf)) i
    ];
    for (final inst in behind ? insts.reversed : insts) {
      final prm = resolveEffectParams(inst, lf);
      final position = prm['position'] as String? ?? 'outside';
      // over or under the content: the setting, or by position.
      final layerMode = prm['layer'] as String? ?? 'auto';
      final under = layerMode == 'under media' || (layerMode == 'auto' && position == 'outside');
      if (behind != under) continue;
      final width = (prm['width'] as num?)?.toDouble() ?? 0;
      if (width <= 0) continue;
      final sm = outlineSmoothness((prm['smoothness'] as num?)?.toDouble() ?? 1);
      final contour = layerContourDrawn(
          project,
          layer,
          globalFrame,
          ContourParams(
              threshold: ((prm['threshold'] as num?)?.toDouble() ?? 0.5).clamp(0.05, 0.95),
              simplify: sm.simplify,
              smooth: sm.smooth,
              offset: (prm['offset'] as num?)?.toDouble() ?? 0,
              // miter join: sharp corners all the way (no rounding).
              sharp: prm['join'] == 'miter'));
      if (contour == null || contour.rings.isEmpty) continue;
      final holes = prm['holes'] != 'off';
      final path = ui.Path()..fillType = ui.PathFillType.evenOdd;
      for (final ring in contour.rings) {
        if (ring.isHole && !holes) continue;
        path.addPolygon([for (final q in ring.points) ui.Offset(q[0], q[1])], true);
      }
      final paint = ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..color = _parseColor(prm['color'] as String?) ?? const ui.Color(0xFFFFFFFF)
        ..strokeWidth = position == 'center' ? width : 2 * width
        ..strokeJoin = prm['join'] == 'miter' ? ui.StrokeJoin.miter : ui.StrokeJoin.round
        ..strokeCap = ui.StrokeCap.round;
      canvas.save();
      if (position == 'outside') {
        // only past the edge: everything but the silhouette.
        const big = 1e6;
        canvas.clipPath(ui.Path()
          ..fillType = ui.PathFillType.evenOdd
          ..addRect(const ui.Rect.fromLTRB(-big, -big, big, big))
          ..addPath(path, ui.Offset.zero));
      } else if (position == 'inside') {
        canvas.clipPath(path);
      }
      canvas.drawPath(path, paint);
      canvas.restore();
    }
  }

  /// Outlines in content space. The contour already carries the layer's
  /// crop, mirror and deformation, so the canvas gets none of them (a crop
  /// clip would cut the stroke off at the cut).
  void _outlinesAround(ui.Canvas canvas, Project project, Layer layer, int globalFrame, {required bool behind}) {
    if (layer.effectStack.any((i) => i.enabled && i.effectId == 'edge_glow')) {
      _drawEdgeGlows(canvas, project, layer, globalFrame, behind: behind);
    }
    if (!layer.effectStack.any((i) => i.enabled && i.effectId == 'outline')) return;
    _drawOutlines(canvas, project, layer, globalFrame, behind: behind);
  }

  /// Edge glow: the silhouette drawn soft in the glow's colour - behind
  /// the content (outside) or, kept to the silhouette, over it (inside).
  void _drawEdgeGlows(ui.Canvas canvas, Project project, Layer layer, int globalFrame, {required bool behind}) {
    final lf = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
    for (final inst in layer.effectStack) {
      if (!inst.enabled || inst.effectId != 'edge_glow' || !effectActiveAt(layer, inst.id, lf)) continue;
      final prm = resolveEffectParams(inst, lf);
      final position = prm['position'] as String? ?? 'outside';
      if (behind ? position == 'inside' : position == 'outside') continue;
      final r = (prm['radius'] as num?)?.toDouble() ?? 0;
      final strength = ((prm['strength'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
      if (r <= 0 || strength <= 0) continue;
      final contour = layerContourDrawn(project, layer, globalFrame, const ContourParams());
      if (contour == null || contour.rings.isEmpty) continue;
      final path = ui.Path()..fillType = ui.PathFillType.evenOdd;
      for (final ring in contour.rings) {
        if (ring.points.length >= 3) path.addPolygon([for (final q in ring.points) ui.Offset(q[0], q[1])], true);
      }
      final color = (_parseColor(prm['color'] as String?) ?? const ui.Color(0xFFFFFFFF)).withOpacity(strength);
      final blur = ui.MaskFilter.blur(ui.BlurStyle.normal, r / 2);
      if (behind) {
        // twice: a glow, not a faint haze.
        final paint = ui.Paint()
          ..color = color
          ..maskFilter = blur;
        canvas.drawPath(path, paint);
        canvas.drawPath(path, paint);
      } else {
        canvas.save();
        canvas.clipPath(path);
        canvas.drawPath(
            path,
            ui.Paint()
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = r
              ..color = color
              ..maskFilter = blur);
        canvas.restore();
      }
    }
  }

  /// Edge blur: the content (and its outlines) kept by its own contour
  /// drawn soft - the edge fades out over the radius.
  void _edgeBlur(ui.Canvas canvas, Project project, Layer layer, int globalFrame) {
    final lf = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame)).toDouble();
    final inst = layer.effectStack
        .where((i) => i.enabled && i.effectId == 'edge_blur' && effectActiveAt(layer, i.id, lf))
        .firstOrNull;
    if (inst == null) return;
    final prm = resolveEffectParams(inst, lf);
    final r = (prm['radius'] as num?)?.toDouble() ?? 0;
    if (r <= 0) return;
    final inside = prm['position'] != 'center';
    final contour = layerContourDrawn(project, layer, globalFrame, ContourParams(offset: inside ? -r / 2 : 0));
    if (contour == null || contour.rings.isEmpty) return;
    final path = ui.Path()..fillType = ui.PathFillType.evenOdd;
    for (final ring in contour.rings) {
      if (ring.points.length >= 3) path.addPolygon([for (final q in ring.points) ui.Offset(q[0], q[1])], true);
    }
    canvas.saveLayer(null, ui.Paint()..blendMode = ui.BlendMode.dstIn);
    canvas.drawPath(
        path,
        ui.Paint()
          ..color = const ui.Color(0xFFFFFFFF)
          ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, r / 2));
    canvas.restore();
  }

  final Map<String, ui.Image> _imageCache = {};
  final Set<String> _decodingKeys = {};

  /// Sources that failed to decode. Not retried a broken image was decoded
  /// again on every render) until the source changes - the key IS the source -
  /// or retryImage is called.
  final Set<String> _failedKeys = {};

  /// How many decodes have been started - for tests.
  @visibleForTesting
  int decodeAttempts = 0;

  bool isImageFailed(Content content) {
    final key = _imageCacheKey(content);
    return key != null && _failedKeys.contains(key);
  }

  /// Decoded pictures held in memory (images, keyed media, video frames),
  /// their estimated size (4 bytes a pixel), and sources that failed to
  /// decode - for the performance HUD.
  ({int count, int bytes, int failures}) imageStats() {
    var count = 0, bytes = 0;
    void add(ui.Image img) {
      count++;
      bytes += img.width * img.height * 4;
    }

    _imageCache.values.forEach(add);
    for (final k in _keyed.values) {
      add(k.image);
    }
    final v = videoFrames.imageStats();
    return (count: count + v.count, bytes: bytes + v.bytes, failures: _failedKeys.length + v.failures);
  }

  /// Forgets a failure so the next render tries decoding again.
  void retryImage(Content content) {
    final key = _imageCacheKey(content);
    if (key != null) _failedKeys.remove(key);
  }

  /// Stage mirror: flips the captured (exported) frame about its centre.
  /// The live stage applies the same flip in its camera instead, so its
  /// handles and gestures stay consistent with what's drawn.
  bool mirrorX = false;
  bool mirrorY = false;

  /// The canvas background, filled across exactly [0,w]x[0,h] before any
  /// layer - so exports get it too. null = transparent (no fill at all:
  /// PNG export keeps real alpha).
  ui.Color? backgroundColor;

  void setSize(double width, double height) {
    _width = width;
    _height = height;
    setStageSize(width, height);
  }

  @override
  void renderFrame(dynamic projectArg, int frame, {bool clipToFrame = true, void Function(ui.Canvas canvas)? underlay}) {
    final project = projectArg as Project;
    _radiiProject = project;
    _radiiFrame = frame;
    // contour physics: baked up to this frame, a little per render (the
    // rest follows on the next ones - dragging stays smooth); meanwhile
    // the previous bake is shown.
    physicsBaking = _bakePhysics(project, frame, const Duration(milliseconds: 10));
    // performance HUD: counting only, never anything drawn.
    final perf = perfInstrumentation;
    final perfWatch = perf ? (Stopwatch()..start()) : null;
    final layerCosts = perf ? <LayerCost>[] : null;
    if (perf) perfCounters.reset();
    // frames of videos no layer uses any more are the first to go.
    videoFrames.liveAssets = videoAssetIds(project);
    // frame-scoped memoization: cleared at the top of every render call,
    // so it never persists across edits or even across frames - purely
    // a within-this-one-render speedup (see core/state_cache.dart).
    clearStateCaches();

    // clipToFrame=false (AppState.showOffCanvasContent's toggle) is
    // ONLY ever used for the LIVE on-screen view - export/captureFrame
    // callers always take the default true, so PNG export stays
    // strictly bounded to the true frame exactly as before this
    // toggle existed. When content is allowed to draw off-canvas, the
    // recorder's own cull rect is widened too (a generous, fixed
    // multiple of the frame size) - it's only an internal recording/
    // perf hint, not itself a clip, but a cull rect tighter than what
    // actually gets drawn risks the backend discarding those commands.
    final cull = clipToFrame
        ? stageCullRect(_width, _height)
        : ui.Rect.fromLTWH(-_width, -_height, _width * 3, _height * 3);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, cull);
    if (clipToFrame) {
      canvas.clipRect(ui.Rect.fromLTWH(0, 0, _width, _height));
    }
    final bg = backgroundColor;
    if (bg != null) {
      canvas.drawRect(
          ui.Rect.fromLTWH(0, 0, _width, _height), ui.Paint()..color = bg);
    }
    // the stage only (never export): "Show in context" draws the host
    // project here, over the background and under every layer.
    underlay?.call(canvas);

    // a digging layer cuts down to the background, never through it:
    // the layers go into a group of their own over it.
    final digs = project.layers.any((l) => l.dig && !l.hidden);
    if (digs) canvas.saveLayer(null, ui.Paint());
    // the stage camera (export, the player, or "camera view"): the scene
    // as seen through its frame; the background stays put.
    final view = useStageCamera ? cameraViewMatrix(project, frame, _width, _height) : null;
    if (view != null) {
      canvas.save();
      canvas.transform(_toMatrix4(view));
    }
    // layers that draw what is under them: every layer's picture is kept
    // for this frame, so "under" is replayed, never drawn again.
    final keep = project.layers.any((l) => !l.hidden && _needsBelow(l)) ? <String, ui.Picture>{} : null;
    _framePictures = keep;
    _hiddenCutters = hiddenCutters(project);
    // layers that are another's back side: drawn only there.
    _hiddenCutters = {
      ..._hiddenCutters,
      for (final l in project.layers)
        if (l.backSourceId != null) l.backSourceId!,
    };
    // paint order = array order - every layer draws the same way, no
    // special-cased hardcoded first/last layer.
    for (final l in project.layers) {
      // a mirror: what its base covers below it, flipped, in its shape.
      if (l.mirrorSourceId != null) {
        if (!l.hidden) _drawMirror(canvas, project, l, frame, 0);
        continue;
      }
      if (l.mirrorProbe) continue; // a mirror's probe: never drawn
      if (_hiddenCutters.contains(l.id)) continue; // Cut by layer: hide cutter
      if (l.id == 'L_parent') {
        continue; // pure rig controller by convention, but any zero-content layer is fine to skip too
      }
      // a precomposed group's children are already baked into the
      // group's own single draw call - drawing them again here would
      // show a second, unmasked/undeformed copy on top.
      final parentGroup =
          l.parentId != null ? findLayer(project, l.parentId) : null;
      if (parentGroup != null &&
          (parentGroup.precompose ?? false) &&
          (parentGroup.groupedChildren?.contains(l.id) ?? false)) {
        continue;
      }
      if (l.hidden) continue; // explicit hide, independent of opacity
      // export: a still layer is drawn once and replayed on every frame.
      if (_stillIds.contains(l.id)) {
        if (frame < l.startFrame || frame > l.startFrame + l.durationFrames) continue;
        final pic = _stillPictures[l.id] ??= () {
          final rec = ui.PictureRecorder();
          _drawLayer(ui.Canvas(rec), project, l.id, frame);
          return rec.endRecording();
        }();
        keep?[l.id] = pic;
        canvas.drawPicture(pic);
        continue;
      }
      final t = perf ? (Stopwatch()..start()) : null;
      if (keep != null) {
        // drawn once into a picture of its own: the layers above that
        // need what is under them (glass, light wrap, a lens) replay it.
        final rec = ui.PictureRecorder();
        _drawLayer(ui.Canvas(rec, cull), project, l.id, frame);
        final pic = rec.endRecording();
        keep[l.id] = pic;
        canvas.drawPicture(pic);
      } else {
        _drawLayer(canvas, project, l.id, frame);
      }
      if (t != null) layerCosts!.add(LayerCost(l.name, t.elapsedMicroseconds / 1000));
    }
    _framePictures = null;

    if (view != null) canvas.restore();
    if (digs) canvas.restore();
    _picture = recorder.endRecording();
    if (project.layers.any((l) => l.filters.scope == 'scene' && l.filters.any)) {
      _picture = _sceneFilters(project, _picture!, frame, cull);
    }
    if (perf) {
      PerfMonitor.instance.recordRender(totalMs: perfWatch!.elapsedMicroseconds / 1000, layers: layerCosts!);
    }
  }

  // ===== mirror layers =====

  static const _maxMirrorDepth = 3;

  /// Draws every visible layer below `index` (mirrors among them a level
  /// deeper) - what a mirror reflects.
  void _drawLayersBelow(ui.Canvas canvas, Project project, int index, int frame, int depth, Layer skip) {
    for (var i = 0; i < index; i++) {
      final l = project.layers[i];
      if (l.hidden || l.mirrorProbe || _hiddenCutters.contains(l.id) || l.id == 'L_parent' || identical(l, skip)) {
        continue;
      }
      final g = l.parentId != null ? findLayer(project, l.parentId) : null;
      if (g != null && (g.precompose ?? false) && (g.groupedChildren?.contains(l.id) ?? false)) continue;
      if (l.mirrorSourceId != null) {
        if (depth + 1 < _maxMirrorDepth) _drawMirror(canvas, project, l, frame, depth + 1);
        continue;
      }
      // already drawn this frame: its picture again.
      final kept = _framePictures?[l.id];
      if (kept != null) {
        canvas.drawPicture(kept);
        continue;
      }
      _drawLayer(canvas, project, l.id, frame);
    }
  }

  /// This frame's layers as pictures (see renderFrame), while it is drawn.
  Map<String, ui.Picture>? _framePictures;

  static bool _needsBelow(Layer l) =>
      l.lens.enabled || (l.filters.any && (l.filters.scope == 'glass' || (l.filters.scope == 'self' && l.filters.lightWrap > 0)));

  void _drawMirror(ui.Canvas canvas, Project project, Layer mirror, int frame, int depth) {
    final t = mirrorTransform(project, mirror, frame);
    final state = getLayerStateAt(project, mirror.id, frame);
    if (t == null || !state.inRange) return;
    final m = toFrameMatrix(state.matrix);
    final outline = [for (final p in getContentOutline(mirror.content, mirror, frame, project: project)) applyAffine(m, p)];
    if (outline.length < 3) return;
    final rec = ui.PictureRecorder();
    // the base itself is part of what is reflected.
    _drawLayersBelow(ui.Canvas(rec), project,
        mirror.mirrorAllLayers ? project.layers.length : project.layers.indexOf(mirror), frame, depth, mirror);
    final scene = rec.endRecording();
    final localFrame = layerLocalFrame(mirror, frame);
    final opacity = (evaluateTrack(project, mirror.transform.opacity, localFrame, mirror) as double).clamp(0.0, 1.0);
    canvas.save();
    canvas.clipPath(_pathFromPoints(outline, close: true));
    canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity));
    canvas.transform(_toMatrix4(t));
    canvas.drawPicture(scene);
    canvas.restore();
    canvas.restore();
    scene.dispose();
  }

  // ===== export: still layers drawn once =====

  /// Draw through the stage camera (see model/stage_camera.dart). On for
  /// export and the player; on the stage only in "camera view" - its
  /// handles are for the scene itself.
  bool useStageCamera = true;

  /// Export resolution: the frame drawn this many times bigger (vector
  /// content stays sharp). 1 on the stage.
  double outputScale = 1;

  int _out(double v) => outputScale == 1 ? v.round() : math.max(2, (v * outputScale / 2).round() * 2);

  /// The output size in pixels.
  int get pixelWidth => _out(_width);
  int get pixelHeight => _out(_height);

  Set<String> _stillIds = {};
  final Map<String, ui.Picture> _stillPictures = {};

  /// Before an export: the layers that look the same on every frame are
  /// drawn once from here on and reused (see layerIsStill).
  void beginExportReuse(Project project) {
    endExportReuse();
    _stillIds = {for (final l in project.layers) if (layerIsStill(project, l)) l.id};
  }

  /// Export: whether `frame` draws exactly what `previous` drew - every
  /// layer there in both or in neither, and each one there still (see
  /// layerIsStill) - so it need not be drawn again.
  bool frameRepeats(Project project, int previous, int frame) {
    if (_stillIds.isEmpty) return false;
    for (final l in project.layers) {
      if (isAudioShape(l.content.shape)) continue;
      final a = getLayerStateAt(project, l.id, previous).inRange, b = getLayerStateAt(project, l.id, frame).inRange;
      if (a != b) return false;
      if (b && !l.hidden && !_stillIds.contains(l.id)) return false;
    }
    return true;
  }

  void endExportReuse() {
    _stillIds = {};
    for (final p in _stillPictures.values) {
      p.dispose();
    }
    _stillPictures.clear();
  }

  @override
  Future<ui.Image> captureFrame() async {
    final pic = _picture;
    if (pic == null) {
      throw StateError('renderFrame() must be called before captureFrame()');
    }
    if (!mirrorX && !mirrorY && outputScale == 1) return pic.toImage(_width.round(), _height.round());
    final w = pixelWidth, h = pixelHeight;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..scale(w / _width, h / _height)
      ..translate(mirrorX ? _width : 0, mirrorY ? _height : 0)
      ..scale(mirrorX ? -1 : 1, mirrorY ? -1 : 1)
      ..drawPicture(pic);
    return recorder.endRecording().toImage(w, h);
  }

  @override
  void dispose() {
    _picture = null;
    for (final img in _imageCache.values) {
      img.dispose();
    }
    _imageCache.clear();
    for (final k in _keyed.values) {
      k.image.dispose();
    }
    _keyed.clear();
    videoFrames.dispose();
  }

  // ============================================================
  // drawLayer - motion blur sampling, then the actual paint
  // ============================================================

  void _drawLayer(
      ui.Canvas canvas, Project project, String layerId, int globalFrame) {
    final layer = findLayer(project, layerId);
    if (layer == null) return;
    final mb = layer.motionBlur;

    // motion blur only where the layer moves across the shutter (a still
    // one would be drawn `samples` times for nothing).
    bool movesAcrossShutter() {
      final half = mb.shutterAngle / 360 / 2;
      // its ends and middle (a turn back at a key looks the same at both ends).
      final a = getLayerStateAt(project, layerId, globalFrame - half),
          m = getLayerStateAt(project, layerId, globalFrame),
          b = getLayerStateAt(project, layerId, globalFrame + half);
      if (a.inRange != b.inRange || a.inRange != m.inRange) return true;
      for (var i = 0; i < 6; i++) {
        if ((a.matrix[i] - b.matrix[i]).abs() > 1e-6 || (a.matrix[i] - m.matrix[i]).abs() > 1e-6) return true;
      }
      return false;
    }

    if (mb.enabled && mb.samples > 1 && effectActiveAt(layer, 'motionBlur', globalFrame - layer.startFrame) &&
        movesAcrossShutter()) {
      final shutterFrames = mb.shutterAngle /
          360; // shutter angle as a fraction of one frame's duration
      final samples = mb.samples;
      final sampleFrames = <double>[];
      for (var s = 0; s < samples; s++) {
        final t =
            (s / (samples - 1)) - 0.5; // centered across the shutter window
        sampleFrames.add(globalFrame + t * shutterFrames);
      }
      // normalize weight against however many samples actually land
      // in-range, not the requested count.
      final validFrames = sampleFrames
          .where((f) => getLayerStateAt(project, layerId, f).inRange)
          .toList();
      if (validFrames.isEmpty) return;
      final weight = 1 / validFrames.length;
      // matches movement-core/src/render/renderLayer.js's own
      // drawLayer(): opens an ISOLATED accumulation layer here (JS uses
      // a dedicated motionBlurScratch canvas for the same reason),
      // accumulates every sample into THAT via BlendMode.plus (see
      // _drawLayerInto's `blend` param), and only flattens the finished
      // accumulation onto the real destination below via plain srcOver
      // - so this layer's motion-blur streak never additively brightens
      // whatever is already on the canvas (earlier layers/background).
      // Both engines used to differ here (JS previously blended each
      // sample straight onto its real canvas); JS was brought in line
      // with this isolated-buffer approach rather than the reverse.
      canvas.saveLayer(null, ui.Paint());
      if (perfInstrumentation) perfCounters.blurSamples += validFrames.length;
      for (final sampleFrame in validFrames) {
        // motion blur looked like a static duplicate with a slight offset
        // instead of a smooth streak. Root cause: getLayerStateAt used to
        // require an int, so every fractional sampleFrame got rounded to the
        // nearest whole frame BEFORE computing its transform - with a
        // one-frame-wide shutter and several samples, nearly all of them round
        // to the SAME frame, collapsing the blur down to at most 1-2 distinct
        // positions. state_cache.dart's getLayerBaseStateAt/getLayerStateAt
        // now accept `num`, so the transform matrix reflects the sample's TRUE
        // sub-frame time - matching JS's own getLayerStateAt(layerId,
        // sampleFrame), which never rounded at all. Content/effects/opacity
        // below still evaluate at the rounded frame (unaffected by this fix) -
        // sub-frame precision matters for the transform (that's what "motion"
        // blur blurs), not for whatever the shape happens to look like that
        // frame.
        final state = getLayerStateAt(project, layerId, sampleFrame);
        final m = state.matrix;
        final mCanvas = [m[0], m[1], m[2], m[3], m[4] * _width, m[5] * _height];
        _drawLayerInto(
            canvas, project, layer, sampleFrame.round(), mCanvas, 0, weight,
            blend: ui.BlendMode.plus);
      }
      canvas.restore();
      return;
    }

    final state = getLayerStateAt(project, layerId, globalFrame);
    if (!state.inRange) return;
    // no blur of its own, but a parent's: blurred by the parent's motion
    // only - the parent's time runs across the shutter, the child's own
    // transform stays at this frame.
    final ancestor = blurringAncestor(project, layer, globalFrame);
    if (ancestor != null) {
      final amb = ancestor.motionBlur;
      final n = amb.samples;
      canvas.saveLayer(null, ui.Paint());
      for (var s = 0; s < n; s++) {
        final f = globalFrame + ((s / (n - 1)) - 0.5) * amb.shutterAngle / 360;
        final m = inheritedBlurMatrix(project, layer, f, globalFrame);
        _drawLayerInto(canvas, project, layer, globalFrame, [m[0], m[1], m[2], m[3], m[4] * _width, m[5] * _height], 0,
            1 / n,
            blend: ui.BlendMode.plus);
      }
      canvas.restore();
      return;
    }
    final m = state.matrix;
    final mCanvas = [m[0], m[1], m[2], m[3], m[4] * _width, m[5] * _height];
    _drawLayerInto(canvas, project, layer, globalFrame, mCanvas, 0, 1);
  }

  // ============================================================
  // drawLayerInto - the core per-layer renderer
  // ============================================================

  void _drawLayerInto(
    ui.Canvas destCanvas,
    Project project,
    Layer layer,
    int globalFrame,
    List<double> mCanvas,
    int depth,
    double sampleWeight, {
    ui.BlendMode? blend,
  }) {
    if (isAudioShape(layer.content.shape)) return; // heard, not seen
    if (isCameraShape(layer.content.shape)) return; // the stage camera: looks, isn't seen
    if (isTrailShape(layer.content.shape)) {
      _drawTrail(destCanvas, project, layer, globalFrame, sampleWeight);
      return;
    }
    final isPrecompose = (layer.precompose ?? false) &&
        layer.groupedChildren != null &&
        layer.groupedChildren!.isNotEmpty;
    // Objects: turned over about its vertical middle (its back shows).
    final baseM = mCanvas;
    final flipAbout = _flipMatrix(layer);
    if (layer.showBack) mCanvas = matMul(mCanvas, flipAbout);
    final backLayer = layer.backSourceId == null ? null : findLayer(project, layer.backSourceId);
    final hasBack = (backLayer != null && backLayer.id != layer.id) || layer.backSame;
    final flipped = mCanvas[0] * mCanvas[3] - mCanvas[1] * mCanvas[2] < 0;

    // triangle's 3-point corner pin is an EXACT affine solve on its 3
    // raw vertices - texture warping can't improve on exact, and that
    // effect's apply() expects to receive exactly those 3 points.
    final hasExactPointPin = layer.effectStack.any((i) =>
        i.enabled && i.effectId == 'corner_pin' && i.params.containsKey('p0'));
    // a parent's shape effects bend its children too.
    final inheritsDeform = deformingAncestors(project, layer, globalFrame).isNotEmpty;
    final needsSubdivision = layer.effectStack.any(isDeformingEffect) || inheritsDeform;
    // a gradient-filled rect under an effect goes through the texture
    // path too, so its glows bend with it.
    // a back side of its own: turned over (or with flaps folded over) it
    // goes through the texture path, back faces drawn from the back.
    final backTexture = hasBack && !isNodeLine(layer.content) && !isPrecompose && (flipped || needsSubdivision);
    final isTextured = !isNodeLine(layer.content) && (isPrecompose ||
        backTexture ||
        ((!(layer.content.shape == 'rect' || layer.content.shape == 'line') || layer.fill.active) &&
            !hasExactPointPin &&
            needsSubdivision));
    final deviceScale = math.sqrt((mCanvas[0] * mCanvas[3] - mCanvas[2] * mCanvas[1]).abs());

    final localFrameOp = math
        .min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame))
        .toDouble();
    final opacity = ((evaluateTrack(project, layer.transform.opacity, localFrameOp, layer) as double) +
                (layer.links.isEmpty ? 0.0 : linkOffset(project, layer, 'opacity', globalFrame)))
            .clamp(0.0, 1.0) *
        sampleWeight;
    if (opacity <= 0) return;

    // record this layer's own content into its own picture first (the
    // JS equivalent of contentScratch) so the mask stack can be
    // composited against it as a single unit before it's blitted onto
    // destCanvas - Canvas.saveLayer gives the same "isolated compositing
    // group" property the JS gets from a separate offscreen canvas.
    final contentRecorder = ui.PictureRecorder();
    final contentCanvas = ui.Canvas(contentRecorder);

    final outline = globalOutlineMode || layer.renderMode == 'outline';
    final color = _parseColor(layer.color) ?? const ui.Color(0xFF8AB4D8);
    final fillPaint = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.fill;
    final strokePaint = ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.5;

    contentCanvas.save();
    contentCanvas.transform(_toMatrix4(mCanvas));
    // crop + mirror: textured shapes/images get them inside their source
    // raster (before the effect warp, so a warped layer is cropped and
    // flipped as a texture and its effect handles stay on their
    // corners); everything else here, in content-local space.
    // Outline strokes "outside" go behind the content.
    if (!isPrecompose) _outlinesAround(contentCanvas, project, layer, globalFrame, behind: true);
    // the content itself, inside its own crop / mirror.
    contentCanvas.save();
    // Cut by layer: the fill keeps to the cut outline (unmirrored content
    // space - where the cutter really is); union / exclude also fill what
    // the cutter adds.
    if (layerHasCuts(layer) && !isTextured && !isPrecompose) {
      final cut = layerVectorRings(project, layer, globalFrame);
      if (cut != null) {
        final path = ui.Path();
        for (final r in cut) {
          if (r.length >= 3) path.addPolygon([for (final q in r) ui.Offset(q[0], q[1])], true);
        }
        contentCanvas.clipPath(path);
        if (layer.cuts.any((c) => c.enabled && (c.mode == 'union' || c.mode == 'exclude')) && !outline) {
          contentCanvas.drawPath(path, fillPaint);
        }
      }
    }
    if (!isTextured || isPrecompose) _applyCropAndMirror(contentCanvas, layer);

    // a shape's drop shadow (Fill tab), under it.
    if (layer.fill.shadow.enabled && !outline && !isTextured) {
      final sp = _shapeShadowPath(layer);
      if (sp != null) _drawShapeShadow(contentCanvas, layer, sp, project, globalFrame);
    }
    if (isNodeLine(layer.content)) {
      // a vector line: stroked through its points (the reveal trims it),
      // or - closed - a filled shape.
      final c = layer.content;
      final pts = sampleLine(c.lineNodes!, closed: c.lineClosed, frame: localFrameOp);
      final (t0, t1) = lineReveal(project, c, localFrameOp);
      final whole = t0 <= 0 && t1 >= 1;
      // an invisible line draws nothing (the stage shows a guide).
      if (!c.lineHidden) {
        _withGlows(contentCanvas, project, layer, globalFrame, deviceScale, () {
        if (isFilledLine(c) && !outline && whole) {
          contentCanvas.drawPath(_pathFromPoints(pts, close: true), fillPaint);
          // the fill keeps the line's width: to its outer edge (drawn on
          // top) or its inner one (the width taken out of the fill).
          if (c.lineFillMode != 'points' && c.lineWidth > 0) {
            final band = ui.Path()..fillType = ui.PathFillType.nonZero;
            for (final r in lineStrokeRings(c, frame: localFrameOp)) {
              band.addPolygon([for (final p in r) ui.Offset(p[0], p[1])], true);
            }
            contentCanvas.drawPath(
                band,
                c.lineFillMode == 'inner'
                    ? (ui.Paint()..blendMode = ui.BlendMode.clear)
                    : (ui.Paint()..color = fillPaint.color..shader = fillPaint.shader));
          }
          return;
        }
        // square / triangle ends, sharp joins, a changing width: the
        // stroke as its filled pieces (non-zero, so they make one shape).
        if (!outline && lineNeedsShapedStroke(c)) {
          final path = ui.Path()..fillType = ui.PathFillType.nonZero;
          for (final r in lineStrokeRings(c, frame: localFrameOp, t0: t0, t1: t1)) {
            path.addPolygon([for (final p in r) ui.Offset(p[0], p[1])], true);
          }
          contentCanvas.drawPath(path, ui.Paint()..color = color);
          return;
        }
        final shown = trimPolyline(pts, t0, t1);
        if (shown.length < 2) return;
        contentCanvas.drawPath(
            // a whole loop joins up without a seam.
            _pathFromPoints(shown, close: c.lineClosed && whole),
            ui.Paint()
              ..color = color
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = outline ? 1.5 : c.lineWidth
              ..strokeCap = ui.StrokeCap.round
              ..strokeJoin = ui.StrokeJoin.round);
        });
      }
    } else if (isTextured && !backTexture && _warpsAsVector(layer)) {
      // a vector shape under a deforming effect stays a vector: its outline
      // follows the effect grid point by point (sharp at any zoom, no
      // texture edge - a caved-in corner pin or a squeeze keeps the shape).
      final c = layer.content;
      List<List<double>> warp(List<List<double>> ring) =>
          warpRingThroughEffects(layer, c, ring, globalFrame, project: project, inherited: true);
      // origami: in pieces (its parts), so folded-over parts don't cancel.
      List<List<List<double>>> pieces(List<List<double>> ring) =>
          origamiRingPieces(layer, ring, globalFrame, project: project) ?? [warp(ring)];
      // text: its letters (and block) through the warp, still vectors.
      // (no early return: the layer is finished below, masks and all.)
      if (c.shape == 'text') {
        _withGlows(contentCanvas, project, layer, globalFrame, deviceScale, () {
          _textWarp = pieces;
          try {
            _drawVectorContent(contentCanvas, layer, color, outline, localFrameOp, project);
          } finally {
            _textWarp = null;
          }
        });
      } else {
      _withGlows(contentCanvas, project, layer, globalFrame, deviceScale, () {
        if (c.shape == 'compound') {
          final cc = c.contourColors;
          final join = c.contourJoin;
          final rings = layerContours(layer);
          for (var i = 0; i < rings.length; i++) {
            if (join != null && join.length == rings.length && join[i]) continue;
            final path = ui.Path();
            for (var j = i; j < rings.length && (j == i || (join != null && join.length == rings.length && join[j])); j++) {
              if (rings[j].length >= 3) {
                for (final piece in pieces(rings[j])) {
                  path.addPolygon([for (final q in piece) ui.Offset(q[0], q[1])], true);
                }
              }
            }
            final own = cc != null && cc.length == rings.length ? _parseColor(cc[i]) : null;
            final col = own == null ? color : own.withOpacity(own.opacity * color.opacity);
            contentCanvas.drawPath(
                path,
                ui.Paint()
                  ..color = col
                  ..style = outline ? ui.PaintingStyle.stroke : ui.PaintingStyle.fill
                  ..strokeWidth = 1.5);
          }
          return;
        }
        final ring = c.shape == 'circle'
            ? [
                for (var i = 0; i < 160; i++)
                  [
                    c.offset[0] + math.cos(i / 160 * math.pi * 2) * math.min(c.size[0], c.size[1]) / 2,
                    c.offset[1] + math.sin(i / 160 * math.pi * 2) * math.min(c.size[0], c.size[1]) / 2,
                  ]
              ]
            : layerShapePoints(layer);
        if (ring.length < 3) return;
        final path = ui.Path()..fillType = ui.PathFillType.nonZero;
        for (final piece in pieces(ring)) {
          path.addPolygon([for (final q in piece) ui.Offset(q[0], q[1])], true);
        }
        contentCanvas.drawPath(path, outline ? strokePaint : fillPaint);
      });
      }
    } else if (isTextured) {
      final sourceImage = isPrecompose
          ? _renderChildrenToImage(project, layer, globalFrame, depth)
          : isMediaShape(layer.content.shape)
              ? _rasterizeImageIntoStageSpace(
                  _layerImage(layer, globalFrame), layer.content, layer)
              : (layer.content.shape == 'text' || layer.content.shape == 'textGroup' || layer.content.shape == 'compound')
                  ? _rasterizeVectorIntoStageSpace(project, layer, globalFrame, color, outline)
                  : _rasterizeShapeSilhouette(
                      layer.content, color, outline, layer, project, globalFrame);
      if (sourceImage != null) {
        final n = needsSubdivision ? 10 : 2;
        Content srcContent;
        if (isPrecompose) {
          srcContent =
              Content(shape: 'rect', offset: [0, 0], size: [_width, _height]);
        } else {
          final bbox = shapeBoundingBox(layer.content);
          srcContent = Content(
            shape: 'rect',
            offset: [(bbox.minX + bbox.maxX) / 2, (bbox.minY + bbox.maxY) / 2],
            size: [bbox.maxX - bbox.minX, bbox.maxY - bbox.minY],
          );
        }
        // pristine, UNDEFORMED - defines the source sub-rects (adaptive
        // when an effect asks for rows, e.g. along a bend axis).
        final srcGrid = buildEffectGrid(layer, srcContent, globalFrame, project: project, n: n);
        final dstGrid = applyInheritedDeform(
            project,
            layer,
            applyEffectStack(
                layer,
                [
                  for (final row in srcGrid)
                    [
                      for (final p in row) [...p]
                    ]
                ],
                globalFrame,
                project: project),
            globalFrame);
        final back = backTexture
            ? _backImage(project, layer, backLayer, sourceImage, baseM, flipAbout, globalFrame, depth)
            : null;
        _drawWarpedGrid(contentCanvas, sourceImage, srcGrid, dstGrid, back: back, flipped: flipped);
      }
    } else if (layer.content.shape == 'rect' || layer.content.shape == 'line') {
      _withGlows(contentCanvas, project, layer, globalFrame, deviceScale, () {
        final needsSub = needsSubdivision;
        // a rect under origami: its own outline (rounded corners too), in
        // the paper's pieces - exact, not a grid.
        if (needsSub && layer.content.shape == 'rect') {
          final ring = layerFlatOutline(layer, globalFrame: globalFrame, project: project);
          final parts = origamiRingPieces(layer, ring, globalFrame, project: project);
          if (parts != null) {
            final path = ui.Path()..fillType = ui.PathFillType.nonZero;
            for (final piece in parts) {
              path.addPolygon([for (final q in piece) ui.Offset(q[0], q[1])], true);
            }
            contentCanvas.drawPath(path, outline ? strokePaint : fillPaint);
            return;
          }
        }
        var grid = needsSub
            ? buildEffectGrid(layer, layer.content, globalFrame, project: project)
            : buildGrid(layer.content, 2, 2);
        grid = applyInheritedDeform(project, layer, applyEffectStack(layer, grid, globalFrame, project: project), globalFrame);
        // smoothed / grown (Fill tab): its outline as it is then.
        if (!needsSub && layer.content.shape == 'rect' && shapeSmoothedOrGrown(layer)) {
          contentCanvas.drawPath(
              _pathFromPoints(layerFlatOutline(layer, globalFrame: globalFrame, project: project), close: true),
              outline ? strokePaint : fillPaint);
          return;
        }
        // rounded corners (Fill tab) on an undeformed rect.
        // (a link can round it too.)
        final rounded = layer.fill.cornerRadius > 0 || layer.links.any((k) => k.enabled && k.to.startsWith('round'));
        if (rounded && !needsSub && layer.content.shape == 'rect') {
          if ((layer.fill.cornerShape - circleRoundK).abs() > 1e-4 || layer.fill.cornersOn.any((c) => !c)) {
            final c = layer.content;
            final (rx, ry) = cornerRadii(layer, _radiiFrame, project: _radiiProject);
            contentCanvas.drawPath(
                _pathFromPoints(
                    roundedRectRing(c.offset[0], c.offset[1], c.size[0], c.size[1], rx, ry,
                        k: layer.fill.cornerShape,
                        corners: layer.fill.cornersOn,
                        each: cornerRadiiEach(layer, _radiiFrame, project: _radiiProject)),
                    close: true),
                outline ? strokePaint : fillPaint);
            return;
          }
          contentCanvas.drawRRect(_roundedRect(layer), outline ? strokePaint : fillPaint);
          return;
        }
        if (outline) {
          final rows = grid.length, cols = grid[0].length;
          final boundary = [
            ...grid[0],
            ...grid.sublist(1).map((row) => row[cols - 1]),
            ...grid[rows - 1].sublist(0, cols - 1).reversed,
            ...grid.sublist(0, rows - 1).reversed.map((row) => row[0]),
          ];
          contentCanvas.drawPath(
              _pathFromPoints(boundary, close: true), strokePaint);
        } else {
          // one path for all cells: filled cell by cell, anti-aliasing left
          // a faint seam along every shared edge (visible across a bend's
          // lines). Every cell is wound the same way so overlapping cells
          // (a fold) still fill under non-zero.
          final path = ui.Path()..fillType = ui.PathFillType.nonZero;
          if (perfInstrumentation) perfCounters.gridCells += (grid.length - 1) * (grid[0].length - 1);
          for (var r = 0; r < grid.length - 1; r++) {
            for (var c = 0; c < grid[0].length - 1; c++) {
              var quad = [
                grid[r][c],
                grid[r][c + 1],
                grid[r + 1][c + 1],
                grid[r + 1][c]
              ];
              var area = 0.0;
              for (var i = 0; i < 4; i++) {
                final a = quad[i], b = quad[(i + 1) % 4];
                area += a[0] * b[1] - b[0] * a[1];
              }
              if (area < 0) quad = quad.reversed.toList();
              path.addPath(_pathFromPoints(quad, close: true), ui.Offset.zero);
            }
          }
          contentCanvas.drawPath(path, fillPaint);
        }
      });
    } else if (layer.content.shape == 'circle') {
      final offset = layer.content.offset, size = layer.content.size;
      final r = math.min(size[0], size[1]) / 2;
      final rect = ui.Rect.fromCircle(
          center: ui.Offset(offset[0], offset[1]), radius: r);
      _withGlows(contentCanvas, project, layer, globalFrame, deviceScale, () {
        outline
            ? contentCanvas.drawOval(rect, strokePaint)
            : contentCanvas.drawOval(rect, fillPaint);
      });
    } else if (layer.content.shape == 'compound' && (layer.chromaKey.active || _edgeMatteOn(layer))) {
      // a keyed merged shape: its picture, keyed like an image.
      final keyed = _layerImage(layer, globalFrame);
      if (keyed != null) {
        final offset = layer.content.offset, size = layer.content.size;
        contentCanvas.drawImageRect(
            keyed,
            ui.Rect.fromLTWH(0, 0, keyed.width.toDouble(), keyed.height.toDouble()),
            ui.Rect.fromCenter(center: ui.Offset(offset[0], offset[1]), width: size[0], height: size[1]),
            ui.Paint()..filterQuality = ui.FilterQuality.medium);
      }
    } else if (layer.content.shape == 'text' || layer.content.shape == 'compound' || layer.content.shape == 'textGroup') {
      _withGlows(contentCanvas, project, layer, globalFrame, deviceScale,
          () => _drawVectorContent(contentCanvas, layer, color, outline, layerLocalFrame(layer, globalFrame), project));
    } else if (isMediaShape(layer.content.shape)) {
      // no active effect (isTextured is false here, or this branch
      // wouldn't be reached) - draw the decoded bitmap directly into
      // its content rect. Outline mode has no real meaning for a raster
      // image (there's no vector boundary to stroke instead of fill),
      // so it's left unaffected by globalOutlineMode/renderMode here,
      // same as a precompose group's rendered content already is.
      final decoded = _layerImage(layer, globalFrame);
      final placeholder = refPlaceholder(layer);
      if (placeholder != null) _paintRefPlaceholder(contentCanvas, layer, placeholder);
      if (decoded != null) {
        final offset = layer.content.offset, size = layer.content.size;
        final dst = ui.Rect.fromCenter(
            center: ui.Offset(offset[0], offset[1]),
            width: size[0],
            height: size[1]);
        final src = ui.Rect.fromLTWH(
            0, 0, decoded.width.toDouble(), decoded.height.toDouble());
        contentCanvas.drawImageRect(decoded, src, dst,
            ui.Paint()..filterQuality = ui.FilterQuality.medium);
      }
    } else {
      // a plain polygon (triangle, star, ...) with its corner rounding;
      // with an exact 3-point corner pin, its bare points (the pin warps
      // exactly those).
      var row = [hasExactPointPin ? shapePoints(layer.content) : layerShapePoints(layer)];
      row = applyEffectStack(layer, row, globalFrame, project: project);
      final pts = row[0];
      if (pts.isNotEmpty) {
        _withGlows(
            contentCanvas,
            project,
            layer,
            globalFrame,
            deviceScale,
            () => contentCanvas.drawPath(_pathFromPoints(pts, close: true),
                outline ? strokePaint : fillPaint));
      }
    }
    // an outlined shape cut by "Detach a piece": its contour runs along
    // the cut too, not only along what is left of the original outline.
    if (outline && layer.pieceClips.isNotEmpty) {
      _strokePieceCuts(contentCanvas, project, layer, globalFrame, strokePaint,
          canvasMirrored: !isTextured || isPrecompose);
    }
    contentCanvas.restore();
    // Outline strokes "center" / "inside" go over it.
    if (!isPrecompose) _outlinesAround(contentCanvas, project, layer, globalFrame, behind: false);
    if (!isPrecompose) _edgeBlur(contentCanvas, project, layer, globalFrame);
    contentCanvas.restore();

    // mask stack: painted into its own picture, then multiplied onto
    // the content via BlendMode.dstIn (destination-in) - modulates
    // alpha only, leaves the drawn color untouched.
    final maskPicture = _paintMaskStack(project, layer, mCanvas, globalFrame);
    if (maskPicture != null) {
      contentCanvas.saveLayer(null, ui.Paint()..blendMode = ui.BlendMode.dstIn);
      contentCanvas.drawPicture(maskPicture);
      contentCanvas.restore();
    }

    // stage only: holes cut out of this layer alone (a selected line's
    // point handles), never what's under it.
    final cuts = stageCuts?.call(project, layer, globalFrame);
    if (cuts != null) {
      for (final c in cuts) {
        contentCanvas.drawPath(c, ui.Paint()..blendMode = ui.BlendMode.clear);
      }
    }

    var contentPicture = contentRecorder.endRecording();
    // opacity AND blend composite together in one saveLayer, against
    // destCanvas's actual current contents - this matters for motion
    // blur (blend: BlendMode.plus): each sample has to accumulate
    // additively onto what's already been drawn to destCanvas, not
    // into a separate empty layer that then gets normal-composited on
    // top (which would silently turn "additive" into "opaque overwrite
    // at low alpha" - not what accumulate-then-normalize is meant to
    // do). Paint.color's alpha and Paint.blendMode both apply at the
    // same restore() step, so a single saveLayer is both correct and
    // sufficient - no inner layer needed.
    final layerPaint = ui.Paint()
      ..color = ui.Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0))
      // see-through text cuts its letters out of what is under it.
      // a digging layer cuts its shape out of everything under it.
      ..blendMode = blend ??
          (layer.content.text?.knockout == true || layer.dig ? ui.BlendMode.dstOut : ui.BlendMode.srcOver);
    // effect shading (3D Rotate turning away): a grey multiply on the
    // colour channels only - modulate by an opaque grey keeps alpha.
    final brightness = layerEffectBrightness(layer, globalFrame);
    if (brightness < 1) {
      final g = (brightness.clamp(0.0, 1.0) * 255).round();
      layerPaint.colorFilter =
          ui.ColorFilter.mode(ui.Color.fromARGB(255, g, g, g), ui.BlendMode.modulate);
    }
    // a lens: what is under it, seen with its angle of view.
    if (layer.lens.enabled) {
      _drawLens(destCanvas, project, layer, localFrameOp, globalFrame, mCanvas, opacity.clamp(0.0, 1.0));
      return;
    }
    final filters = layer.filters;
    // Filters as glass: what is under the layer, filtered, inside its
    // shape - the layer itself is only the glass.
    if (filters.scope == 'glass' && filters.any) {
      final rec = ui.PictureRecorder();
      _drawLayersBelow(ui.Canvas(rec), project, project.layers.indexOf(layer), globalFrame, 0, layer);
      final below = rec.endRecording();
      destCanvas.saveLayer(null, layerPaint);
      _drawFiltered(destCanvas, below, project, layer, localFrameOp, globalFrame);
      destCanvas.saveLayer(null, ui.Paint()..blendMode = ui.BlendMode.dstIn);
      destCanvas.drawPicture(contentPicture);
      destCanvas.restore();
      destCanvas.restore();
      return;
    }
    destCanvas.saveLayer(null, layerPaint);
    // Filters on the layer itself (the whole scene's are applied once
    // every layer is drawn - see renderFrame).
    if (filters.scope == 'self' && filters.any) {
      _drawFiltered(destCanvas, contentPicture, project, layer, localFrameOp, globalFrame);
    } else {
      destCanvas.drawPicture(contentPicture);
    }
    if (filters.scope == 'self' && filters.lightWrap > 0) {
      _lightWrap(destCanvas, project, layer, contentPicture, globalFrame);
    }
    destCanvas.restore();
  }

  // ============================================================
  // filters
  // ============================================================

  static ui.FragmentProgram? _filterProgram;
  static bool _filterProgramLoading = false;

  /// The filters' shader (fractal warp, gamma) - loaded once; until it is
  /// there those two are skipped, and a render follows when it lands.
  void _loadFilterProgram() {
    if (_filterProgram != null || _filterProgramLoading) return;
    _filterProgramLoading = true;
    ui.FragmentProgram.fromAsset('shaders/filter.frag').then((p) {
      _filterProgram = p;
      onImageDecoded?.call();
    }, onError: (Object _) {});
  }

  /// A trail point: the line it has left behind it so far, in the frame
  /// (not in its own space - the trail stays where it was drawn).
  void _drawTrail(ui.Canvas canvas, Project project, Layer layer, int globalFrame, double weight) {
    final lines = trailPolylines(project, layer, globalFrame);
    if (lines.isEmpty) return;
    final lf = layerLocalFrame(layer, globalFrame);
    final opacity =
        ((evaluateTrack(project, layer.transform.opacity, lf, layer) as num).toDouble().clamp(0.0, 1.0)) * weight;
    if (opacity <= 0) return;
    final k = _width / stageSize.width;
    final w = math.max(0.5, layer.content.lineWidth) * k;
    final color = (_parseColor(layer.color) ?? const ui.Color(0xFFFFFFFF));
    final paint = ui.Paint()
      ..color = color.withOpacity(color.opacity * opacity)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round;
    final path = ui.Path();
    for (final l in lines) {
      path.moveTo(l[0][0] * k, l[0][1] * k);
      // a point that hasn't moved: a dot.
      if (l.length == 1) path.lineTo(l[0][0] * k + 0.01, l[0][1] * k);
      for (var i = 1; i < l.length; i++) {
        path.lineTo(l[i][0] * k, l[i][1] * k);
      }
    }
    canvas.drawPath(path, paint);
  }

  static ui.FragmentProgram? _lensProgram;
  static bool _lensProgramLoading = false;

  /// Lens (Masks tab): the layers under it through the lens shader, in
  /// the circle inside the layer's box.
  void _drawLens(ui.Canvas canvas, Project project, Layer layer, num lf, int globalFrame, List<double> mCanvas,
      double opacity) {
    final prog = _lensProgram;
    if (prog == null) {
      if (!_lensProgramLoading) {
        _lensProgramLoading = true;
        ui.FragmentProgram.fromAsset('shaders/lens.frag').then((p) {
          _lensProgram = p;
          onImageDecoded?.call();
        }, onError: (Object _) {});
      }
      return;
    }
    final rec = ui.PictureRecorder();
    _drawLayersBelow(ui.Canvas(rec), project, project.layers.indexOf(layer), globalFrame, 0, layer);
    final w = math.max(1, _width.round()), h = math.max(1, _height.round());
    final below = rec.endRecording().toImageSync(w, h);
    final c = layer.content;
    final centre = applyAffine(mCanvas, c.offset);
    final k = math.sqrt((mCanvas[0] * mCanvas[3] - mCanvas[1] * mCanvas[2]).abs());
    final radius = math.min(c.size[0].abs(), c.size[1].abs()) / 2 * k;
    final lens = layer.lens;
    final fov = (evaluateTrack(project, lens.fov, lf.toDouble(), layer) as num).toDouble().clamp(1.0, 178.0);
    final shader = prog.fragmentShader()
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, centre[0])
      ..setFloat(3, centre[1])
      ..setFloat(4, radius)
      ..setFloat(5, fov / 2 * math.pi / 180)
      ..setFloat(6, lens.zoom)
      ..setFloat(7, lens.vignette.clamp(0.0, 1.0))
      ..setFloat(8, lens.softness.clamp(0.0, 1.0))
      ..setImageSampler(0, below);
    final out = ui.PictureRecorder();
    ui.Canvas(out).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..shader = shader);
    final img = out.endRecording().toImageSync(w, h);
    below.dispose();
    shader.dispose();
    canvas.drawImage(img, ui.Offset.zero, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, opacity));
  }

  /// `pic` (canvas-sized, canvas units) through the layer's filters onto
  /// `canvas`: warp and gamma (the shader), then the colour wheels' linear
  /// part and negative (one colour matrix), with the blur.
  void _drawFiltered(ui.Canvas canvas, ui.Picture pic, Project project, Layer layer, num lf, int globalFrame) {
    final f = layer.filters;
    double tv(Track t) => (evaluateTrack(project, t, lf.toDouble(), layer) as num).toDouble();
    final neg = tv(f.negative).clamp(0.0, 1.0);
    final blur = math.max(0.0, tv(f.blur));
    final warp = tv(f.warp);
    var p = pic;
    if (warp != 0 || f.gamma.any((v) => v != 0)) {
      p = _shaderPass(p, warp, f, globalFrame) ?? p;
    }
    final paint = ui.Paint();
    if (neg > 0 || f.graded) {
      final lin = liftGainLinear(f);
      final k = 1 - 2 * neg, o = 255 * neg;
      paint.colorFilter = ui.ColorFilter.matrix([
        k * lin.a[0], 0, 0, 0, k * lin.b[0] * 255 + o, //
        0, k * lin.a[1], 0, 0, k * lin.b[1] * 255 + o, //
        0, 0, k * lin.a[2], 0, k * lin.b[2] * 255 + o, //
        0, 0, 0, 1, 0,
      ]);
    }
    final sigma = blur / 2;
    if (sigma > 0.05 && f.blurKind == 'gaussian') {
      paint.imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: ui.TileMode.decal);
    } else if (sigma > 0.05 && f.blurKind == 'directional') {
      // along the angle: turned so it lies along x, blurred, turned back.
      final a = f.blurAngle * math.pi / 180;
      Float64List rot(double t) =>
          Float64List.fromList([math.cos(t), math.sin(t), 0, 0, -math.sin(t), math.cos(t), 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
      paint.imageFilter = ui.ImageFilter.compose(
          outer: ui.ImageFilter.matrix(rot(a)),
          inner: ui.ImageFilter.compose(
              outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: 0, tileMode: ui.TileMode.decal),
              inner: ui.ImageFilter.matrix(rot(-a))));
    }
    canvas.saveLayer(null, paint);
    if (blur > 0.1 && (f.blurKind == 'zoom' || f.blurKind == 'spin')) {
      // copies spread out from / around the layer's middle, averaged.
      final st = getLayerStateAt(project, layer.id, globalFrame);
      final c = layer.filters.scope == 'scene'
          ? ui.Offset(_width / 2, _height / 2)
          : ui.Offset(st.matrix[4] * _width, st.matrix[5] * _height);
      const n = 12;
      for (var i = 0; i < n; i++) {
        final t = i / (n - 1) - (f.blurKind == 'spin' ? 0.5 : 0.0);
        canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, 1 / (i + 1)));
        canvas.translate(c.dx, c.dy);
        if (f.blurKind == 'zoom') {
          final k = 1 + t * blur / 200;
          canvas.scale(k, k);
        } else {
          canvas.rotate(t * blur * math.pi / 180);
        }
        canvas.translate(-c.dx, -c.dy);
        canvas.drawPicture(p);
        canvas.restore();
      }
    } else {
      canvas.drawPicture(p);
    }
    _drawVignette(canvas, project, layer, tv(f.vignette).clamp(0.0, 1.0).toDouble(), globalFrame);
    canvas.restore();
  }

  /// The vignette over what was just drawn (only where it shows): darker
  /// toward the edges of the object's box - the frame's for the scene.
  void _drawVignette(ui.Canvas canvas, Project project, Layer layer, double amount, int globalFrame) {
    if (amount <= 0) return;
    final f = layer.filters;
    final k = _width / stageSize.width;
    ui.Rect box;
    if (f.scope == 'scene') {
      box = ui.Rect.fromLTWH(0, 0, _width, _height);
    } else {
      final b = computeLayerFrameGeometry(project, layer, globalFrame, includeVertices: false).bbox;
      box = ui.Rect.fromLTRB(b.minX * k, b.minY * k, b.maxX * k, b.maxY * k);
    }
    final r = math.max(1.0, math.sqrt(box.width * box.width + box.height * box.height) / 2);
    final start = f.vignetteSize.clamp(0.0, 1.0).toDouble();
    final end = math.min(1.0, start + math.max(0.01, f.vignetteSoft.clamp(0.0, 1.0)));
    final c = _parseColor(f.vignetteColor) ?? const ui.Color(0xFF000000);
    canvas.drawRect(
        box.inflate(2),
        ui.Paint()
          ..blendMode = ui.BlendMode.srcATop
          ..shader = ui.Gradient.radial(box.center, r, [c.withOpacity(0), c.withOpacity(c.opacity * amount)],
              [math.min(start, end - 0.001), end]));
  }

  /// Warp and gamma per pixel (the shader) - null until it is loaded.
  ui.Picture? _shaderPass(ui.Picture pic, double warp, LayerFilters f, int globalFrame) {
    final prog = _filterProgram;
    if (prog == null) {
      _loadFilterProgram();
      return null;
    }
    final w = math.max(1, _width.round()), h = math.max(1, _height.round());
    final img = pic.toImageSync(w, h);
    final shader = prog.fragmentShader()
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, warp)
      ..setFloat(3, f.warpScale)
      ..setFloat(4, globalFrame / fps * f.warpSpeed)
      ..setFloat(5, math.pow(2, -f.gamma[0]).toDouble())
      ..setFloat(6, math.pow(2, -f.gamma[1]).toDouble())
      ..setFloat(7, math.pow(2, -f.gamma[2]).toDouble())
      ..setImageSampler(0, img);
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..shader = shader);
    final out = rec.endRecording().toImageSync(w, h);
    img.dispose();
    shader.dispose();
    final rec2 = ui.PictureRecorder();
    ui.Canvas(rec2).drawImage(out, ui.Offset.zero, ui.Paint());
    return rec2.endRecording();
  }

  /// Light wrap: the blurred light of what is under the layer, kept in a
  /// rim just inside its edge, screened over it.
  void _lightWrap(ui.Canvas canvas, Project project, Layer layer, ui.Picture content, int globalFrame) {
    final f = layer.filters;
    final rec = ui.PictureRecorder();
    _drawLayersBelow(ui.Canvas(rec), project, project.layers.indexOf(layer), globalFrame, 0, layer);
    final below = rec.endRecording();
    final s = math.max(0.5, f.lightWrapWidth / 2);
    final blur = ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: ui.TileMode.decal);
    canvas.saveLayer(
        null,
        ui.Paint()
          ..blendMode = ui.BlendMode.screen
          ..color = ui.Color.fromRGBO(0, 0, 0, f.lightWrap.clamp(0.0, 1.0)));
    canvas.saveLayer(null, ui.Paint()..imageFilter = blur);
    canvas.drawPicture(below);
    canvas.restore();
    canvas.saveLayer(null, ui.Paint()..blendMode = ui.BlendMode.dstIn);
    canvas.drawPicture(content);
    canvas.restore();
    canvas.saveLayer(null, ui.Paint()
      ..blendMode = ui.BlendMode.dstOut
      ..imageFilter = blur);
    canvas.drawPicture(content);
    canvas.restore();
    canvas.restore();
  }

  /// Match Color: the colour statistics (mean, deviation per channel,
  /// 0..1) of the layer itself (no filters) and of what is under it,
  /// both weighed by the layer's own coverage. Null: nothing to compare.
  Future<({List<double> srcMean, List<double> srcDev, List<double> dstMean, List<double> dstDev})?> matchColorStats(
      Project project, Layer layer, int frame) async {
    final k = 256 / math.max(_width, _height);
    final w = math.max(1, (_width * k).round()), h = math.max(1, (_height * k).round());
    Future<ByteData?> grab(void Function(ui.Canvas c) draw) async {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec)..scale(k, k);
      draw(c);
      final img = await rec.endRecording().toImage(w, h);
      final b = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      img.dispose();
      return b;
    }

    final saved = layer.filters;
    layer.filters = LayerFilters();
    final own = await grab((c) => _drawLayer(c, project, layer.id, frame));
    layer.filters = saved;
    final below = await grab((c) => _drawLayersBelow(c, project, project.layers.indexOf(layer), frame, 0, layer));
    if (own == null || below == null) return null;
    ({List<double> mean, List<double> dev})? stats(ByteData b, {required bool weighOwn}) {
      final sum = [0.0, 0.0, 0.0], sq = [0.0, 0.0, 0.0];
      var total = 0.0;
      for (var i = 0; i < w * h; i++) {
        final a = own.getUint8(i * 4 + 3) / 255 * (weighOwn ? 1 : b.getUint8(i * 4 + 3) / 255);
        if (a <= 0) continue;
        total += a;
        for (var ch = 0; ch < 3; ch++) {
          final v = b.getUint8(i * 4 + ch) / 255;
          sum[ch] += v * a;
          sq[ch] += v * v * a;
        }
      }
      if (total < 1) return null;
      final mean = [for (var ch = 0; ch < 3; ch++) sum[ch] / total];
      return (
        mean: mean,
        dev: [for (var ch = 0; ch < 3; ch++) math.sqrt(math.max(0, sq[ch] / total - mean[ch] * mean[ch]))],
      );
    }

    final src = stats(own, weighOwn: true);
    // what is under the layer - or, if nothing is under it, the whole
    // scene below.
    var dst = stats(below, weighOwn: false);
    if (dst == null) {
      final sum = [0.0, 0.0, 0.0], sq = [0.0, 0.0, 0.0];
      var total = 0.0;
      for (var i = 0; i < w * h; i++) {
        final a = below.getUint8(i * 4 + 3) / 255;
        if (a <= 0) continue;
        total += a;
        for (var ch = 0; ch < 3; ch++) {
          final v = below.getUint8(i * 4 + ch) / 255;
          sum[ch] += v * a;
          sq[ch] += v * v * a;
        }
      }
      if (total >= 1) {
        final mean = [for (var ch = 0; ch < 3; ch++) sum[ch] / total];
        dst = (
          mean: mean,
          dev: [for (var ch = 0; ch < 3; ch++) math.sqrt(math.max(0, sq[ch] / total - mean[ch] * mean[ch]))],
        );
      }
    }
    if (src == null || dst == null) return null;
    return (srcMean: src.mean, srcDev: src.dev, dstMean: dst.mean, dstDev: dst.dev);
  }

  /// Filters on the whole scene: every such layer in range, in order,
  /// over the finished frame.
  ui.Picture _sceneFilters(Project project, ui.Picture frame, int globalFrame, ui.Rect cull) {
    var pic = frame;
    for (final l in project.layers) {
      if (l.hidden || l.filters.scope != 'scene' || !l.filters.any) continue;
      if (!getLayerStateAt(project, l.id, globalFrame).inRange) continue;
      final rec = ui.PictureRecorder();
      _drawFiltered(ui.Canvas(rec, cull), pic, project, l, layerLocalFrame(l, globalFrame), globalFrame);
      pic = rec.endRecording();
    }
    return pic;
  }

  // ============================================================
  // precomposition - render a group null's children into their own
  // image, one PictureRecorder per recursion depth (no pooling needed
  // the way JS pools canvas elements to dodge GC churn - Dart's
  // PictureRecorder/Image are cheap enough to just recreate per call).
  // ============================================================

  ui.Image? _renderChildrenToImage(
      Project project, Layer nullLayer, int globalFrame, int depth) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final nullState = getLayerStateAt(project, nullLayer.id, globalFrame);
    final nullMCanvas = [
      nullState.matrix[0],
      nullState.matrix[1],
      nullState.matrix[2],
      nullState.matrix[3],
      nullState.matrix[4] * _width,
      nullState.matrix[5] * _height,
    ];
    final invNull = invertAffine(nullMCanvas);

    for (final id in nullLayer.groupedChildren ?? const <String>[]) {
      final child = findLayer(project, id);
      if (child == null) continue;
      final childState = getLayerStateAt(project, id, globalFrame);
      if (!childState.inRange) continue;
      final childMCanvas = [
        childState.matrix[0],
        childState.matrix[1],
        childState.matrix[2],
        childState.matrix[3],
        childState.matrix[4] * _width,
        childState.matrix[5] * _height,
      ];
      final rel = matMul(invNull, childMCanvas);
      final bufMatrix = [
        rel[0],
        rel[1],
        rel[2],
        rel[3],
        rel[4] + _width / 2,
        rel[5] + _height / 2
      ];
      _drawLayerInto(
          canvas, project, child, globalFrame, bufMatrix, depth + 1, 1);
    }

    final picture = recorder.endRecording();
    return picture.toImageSync(_width.round(), _height.round());
  }

  /// mirrors _rasterizeShapeSilhouette's own stage-sized intermediate
  /// raster, but for an image layer: draws the already-DECODED bitmap
  /// into its content rect on a stage-sized canvas, so the exact same
  /// _drawWarpedGrid UV pipeline other shapes use for effect-warping
  /// works completely unchanged (it assumes its source image's own
  /// pixel space equals stage-pixel space, content-centered - true here
  /// because this intermediate raster is built the same way the
  /// silhouette one is, not because the SOURCE image's native
  /// resolution has anything to do with the stage).
  ui.Image? _rasterizeImageIntoStageSpace(ui.Image? decoded, Content content,
      [Layer? layer]) {
    if (decoded == null) return null;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.save();
    canvas.translate(_width / 2, _height / 2);
    if (layer != null) _applyCropAndMirror(canvas, layer);
    final dst = ui.Rect.fromCenter(
        center: ui.Offset(content.offset[0], content.offset[1]),
        width: content.size[0],
        height: content.size[1]);
    final src = ui.Rect.fromLTWH(
        0, 0, decoded.width.toDouble(), decoded.height.toDouble());
    canvas.drawImageRect(
        decoded, src, dst, ui.Paint()..filterQuality = ui.FilterQuality.medium);
    canvas.restore();
    final picture = recorder.endRecording();
    return picture.toImageSync(_width.round(), _height.round());
  }

  // ===== vector text / compound shapes =====

  final Expando<ui.Path> _textPaths = Expando();

  /// While a text under a deforming effect is drawn: each outline goes
  /// through the effect grid point by point (the letters stay vectors).
  List<List<List<double>>> Function(List<List<double>>)? _textWarp;

  ui.Path _pathFromCmds(List<PathCmd> cmds) {
    final warp = _textWarp;
    if (warp != null) {
      // curves flattened, then every point carried through the warp.
      final path = ui.Path()..fillType = ui.PathFillType.nonZero;
      for (final ring in flattenPath(cmds, segments: 10)) {
        if (ring.length < 2) continue;
        for (final piece in warp(ring)) {
          path.addPolygon([for (final q in piece) ui.Offset(q[0], q[1])], true);
        }
      }
      return path;
    }
    final path = ui.Path();
    for (final c in cmds) {
      final p = c.p;
      switch (c.op) {
        case 'M':
          path.moveTo(p[0], p[1]);
        case 'L':
          path.lineTo(p[0], p[1]);
        case 'Q':
          path.quadraticBezierTo(p[0], p[1], p[2], p[3]);
        case 'C':
          path.cubicTo(p[0], p[1], p[2], p[3], p[4], p[5]);
        case 'Z':
          path.close();
      }
    }
    return path;
  }

  /// Outline polylines of glyph commands: every command end point (the
  /// corners stay exact), curves split into short straight pieces.
  static List<List<ui.Offset>> _flattenCmds(List<PathCmd> cmds) {
    final out = <List<ui.Offset>>[];
    var cur = <ui.Offset>[];
    var at = ui.Offset.zero;
    int pieces(double len) => (len / 2).ceil().clamp(2, 32);
    for (final c in cmds) {
      final p = c.p;
      switch (c.op) {
        case 'M':
          if (cur.length > 1) out.add(cur);
          at = ui.Offset(p[0], p[1]);
          cur = [at];
        case 'L':
          at = ui.Offset(p[0], p[1]);
          cur.add(at);
        case 'Q':
          final c1 = ui.Offset(p[0], p[1]), e = ui.Offset(p[2], p[3]);
          final n = pieces((c1 - at).distance + (e - c1).distance);
          for (var i = 1; i <= n; i++) {
            final t = i / n, u = 1 - t;
            cur.add(at * (u * u) + c1 * (2 * u * t) + e * (t * t));
          }
          at = e;
        case 'C':
          final c1 = ui.Offset(p[0], p[1]), c2 = ui.Offset(p[2], p[3]), e = ui.Offset(p[4], p[5]);
          final n = pieces((c1 - at).distance + (c2 - c1).distance + (e - c2).distance);
          for (var i = 1; i <= n; i++) {
            final t = i / n, u = 1 - t;
            cur.add(at * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + e * (t * t * t));
          }
          at = e;
        case 'Z':
          if (cur.length > 1) out.add(cur);
          cur = [at];
      }
    }
    if (cur.length > 1) out.add(cur);
    return out;
  }

  /// Outline polylines of any path, sampled along its length (fine
  /// enough for a small shape blown up).
  static List<List<ui.Offset>> _flattenPath(ui.Path path) => [
        for (final m in path.computeMetrics())
          () {
            final step = (m.length / 2000).clamp(0.05, 1.0);
            return [
              for (var d = 0.0; d < m.length; d += step) m.getTangentForOffset(d)!.position,
              if (m.length > 0) m.getTangentForOffset(m.length)!.position,
            ];
          }()
      ];

  /// A shape's outline as exact rings (corners kept), or null to sample
  /// its path.
  List<List<ui.Offset>>? _shapeRings(Layer layer) {
    final c = layer.content;
    ui.Offset o(List<double> p) => ui.Offset(p[0], p[1]);
    if ((c.shape == 'rect' || (c.shape == 'line' && !isNodeLine(c))) && layer.fill.cornerRadius <= 0) {
      final r = ui.Rect.fromCenter(center: ui.Offset(c.offset[0], c.offset[1]), width: c.size[0], height: c.size[1]);
      return [
        [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]
      ];
    }
    if (c.shape == 'compound') return [for (final ct in layerContours(layer)) [for (final p in ct) o(p)]];
    if (isMediaShape(c.shape) || isNodeLine(c) || c.shape == 'rect') return null;
    final pts = layerShapePoints(layer);
    return pts.length < 3 ? null : [[for (final p in pts) o(p)]];
  }

  /// The outline of a stroke of `width` along `path` (round ends):
  /// each piece a rectangle, each joint a circle.
  static ui.Path _strokeOutline(ui.Path path, double width) {
    final out = ui.Path(), h = width / 2;
    for (final r in _flattenPath(path)) {
      for (var i = 0; i + 1 < r.length; i += 2) {
        final a = r[i], b = r[math.min(i + 2, r.length - 1)];
        final v = b - a;
        if (v.distance < 1e-6) continue;
        final n = ui.Offset(-v.dy, v.dx) / v.distance * h;
        out.addPolygon([a + n, b + n, b - n, a - n], true);
      }
      out.addOval(ui.Rect.fromCircle(center: r.first, radius: h));
      out.addOval(ui.Rect.fromCircle(center: r.last, radius: h));
    }
    return out;
  }

  /// Where the shadow's copies go (0..1 of the offset) and how opaque:
  /// one at the end, or with Echo `echoCount` copies along the way, the
  /// farthest the faintest (drawn first, the nearest on top).
  static List<(double, double)> _shadowCopies(TextShadowSpec sh, num localFrame) {
    if (!sh.echo || sh.long) return const [(1.0, 1.0)];
    final fade = (evaluateTrack(null, sh.echoFade, localFrame.toDouble()) as num).toDouble();
    final n = sh.echoCount.clamp(1, 100);
    return [
      for (var i = n; i >= 1; i--) (i / n, n == 1 ? 1.0 : (1 - fade * (i - 1) / (n - 1)).clamp(0.0, 1.0)),
    ];
  }

  /// A long shadow's sides: each outline edge joined to its copy at the far
  /// end (moved by d, scaled by `sc` about `c`) by a four-sided face - one
  /// solid body, no gaps between steps. All faces wound the same way so
  /// their overlaps never cancel.
  static ui.Path _extrusionSides(List<List<ui.Offset>> rings, ui.Offset d, double sc, ui.Offset c) {
    final out = ui.Path();
    ui.Offset far(ui.Offset p) => c + (p - c) * sc + d;
    for (final r in rings) {
      for (var i = 0; i < r.length; i++) {
        final a = r[i], b = r[(i + 1) % r.length];
        if (a == b) continue;
        final fa = far(a), fb = far(b);
        final area = (b.dx - a.dx) * (fb.dy - a.dy) - (b.dy - a.dy) * (fb.dx - a.dx);
        if (area.abs() < 1e-9) continue;
        out.addPolygon(area > 0 ? [a, b, fb, fa] : [fa, fb, b, a], true);
      }
    }
    return out;
  }

  /// Whether a deformed layer can be drawn as a warped vector outline
  /// instead of a warped picture: plain vector shapes (not text, pictures
  /// or groups; crop and mirror still go through the picture).
  bool _warpsAsVector(Layer layer) {
    final c = layer.content;
    if (layer.precompose ?? false) return false;
    if (!const {'circle', 'triangle', 'ngon', 'polygon', 'compound', 'text'}.contains(c.shape)) return false;
    if (c.shape == 'text' && c.text == null) return false;
    if (c.shape == 'compound' && (layer.chromaKey.active || _edgeMatteOn(layer))) return false;
    if (layerHasCrop(layer) || layer.mirrorX || layer.mirrorY) return false;
    return true;
  }

  ui.Color _withOpacity(String? hex, double opacity, ui.Color fallback) =>
      (_parseColor(hex) ?? fallback).withOpacity(opacity.clamp(0.0, 1.0));

  /// Draws a text layer (background block, shadow, letter outline, fill)
  /// or a compound shape, in content-local space.
  void _drawVectorContent(ui.Canvas canvas, Layer layer, ui.Color layerColor, bool outline,
      [num localFrame = 0, Project? project]) {
    final c = layer.content;
    final contours = layerContours(layer);
    if (c.shape == 'compound' && c.contourColors != null && c.contourColors!.length == contours.length) {
      // merged shapes: each contour in its own colour, in order.
      final join = c.contourJoin != null && c.contourJoin!.length == contours.length ? c.contourJoin! : null;
      for (var i = 0; i < contours.length; i++) {
        if (join != null && join[i]) continue; // drawn with the one before
        final ct = contours[i];
        final hex = c.contourColors![i];
        // a merged shape keeps its own colour and its own opacity (alpha).
        final own = _parseColor(hex);
        final col = own == null ? layerColor : own.withOpacity(own.opacity * layerColor.opacity);
        // its holes (the contours joined to it) go in the same path.
        final path = ui.Path();
        for (var j = i; j < contours.length && (j == i || (join != null && join[j])); j++) {
          if (contours[j].length < 3) continue;
          path.addPolygon([for (final p in contours[j]) ui.Offset(p[0], p[1])], true);
        }
        if (ct.length < 3 && path.getBounds().isEmpty) continue;
        canvas.drawPath(
            path,
            ui.Paint()
              ..color = col
              ..style = outline ? ui.PaintingStyle.stroke : ui.PaintingStyle.fill
              ..strokeWidth = 1.5);
      }
      return;
    }
    if (c.shape == 'compound') {
      final path = ui.Path();
      for (final ct in contours) {
        if (ct.length < 3) continue;
        path.addPolygon([for (final p in ct) ui.Offset(p[0], p[1])], true);
      }
      canvas.drawPath(
          path,
          ui.Paint()
            ..color = layerColor
            ..style = outline ? ui.PaintingStyle.stroke : ui.PaintingStyle.fill
            ..strokeWidth = 1.5);
      return;
    }
    if (c.shape == 'textGroup') {
      // a text group: its parent's letters of this group, at their place
      // in the parent's box, moved back by the pivot it sits on.
      final parent = project == null ? null : findLayer(project, layer.parentId);
      if (parent == null) return;
      final pf = layer.startFrame + localFrame - parent.startFrame;
      final spec = textGroupSpec(project!, layer, pf);
      if (spec == null) return;
      canvas.save();
      canvas.translate(-c.textGroupPivot[0], -c.textGroupPivot[1]);
      _drawText(canvas, layer, parent.content, spec, pf, null, outline);
      canvas.restore();
      return;
    }
    var t = c.text?.atFrame(localFrame); // text keys
    if (t == null) return;
    // letters drawn by their group layers are left out here.
    final hidden = project == null ? const <int>{} : textGroupHidden(project, layer, localFrame);
    if (hidden.isNotEmpty) t = t.copy()..hidden = hidden;
    _drawText(canvas, layer, c, t, localFrame, project, outline);
  }

  /// A text's letters (background, shadow, outline, fill) laid out in the
  /// box of `c`.
  void _drawText(ui.Canvas canvas, Layer layer, Content c, TextSpec t, num localFrame, Project? project, bool outline) {
    final layout = layoutText(t, c.offset, c.size);
    // text animators: each unit drawn on its own (see _drawTextUnits).
    final sw = Stopwatch()..start();
    final units = animatedTextUnits(t, c.offset, c.size, localFrame);
    // Lag: how far the shadow's spring(s) hang behind (content px).
    final lag = project == null || outline ? null : textShadowLag(project, layer, layer.startFrame + localFrame);
    if (units != null) {
      _drawTextUnits(canvas, t, c, layout, units, outline, lag, localFrame);
      textUnitsDrawn = units.length;
      textUnitsMs = sw.elapsedMicroseconds / 1000;
      return;
    }
    final path = _textWarp != null ? _pathFromCmds(layout.path) : (_textPaths[layout] ??= _pathFromCmds(layout.path));
    // letter styles: letters in their own colours.
    final plain = identical(layout.plain, layout.path) ? path : _pathFromCmds(layout.plain);
    const white = ui.Color(0xFFFFFFFF), black = ui.Color(0xFF000000);
    if (outline) {
      canvas.drawPath(
          path,
          ui.Paint()
            ..color = _withOpacity(t.color, 1, white)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 1.5);
      return;
    }
    if (t.background.enabled) {
      // around the text itself (not its box), the padding on every side.
      final pad = t.background.padding;
      final w = layout.width, h = layout.height;
      final x0 = switch (t.align) {
        'left' => c.offset[0] - c.size[0] / 2,
        'right' => c.offset[0] + c.size[0] / 2 - w,
        _ => c.offset[0] - w / 2,
      };
      final box = ui.Rect.fromLTWH(x0 - pad, c.offset[1] - h / 2 - pad, w + 2 * pad, h + 2 * pad);
      final paint = ui.Paint()..color = _withOpacity(t.background.color, t.background.opacity, black);
      // rounded corners (with their shape).
      final r = math.min(t.background.radius, math.min(box.width, box.height) / 2);
      if (_textWarp != null) {
        final ring = r > 0
            ? roundedRectRing(box.center.dx, box.center.dy, box.width, box.height, r, r, k: t.background.radiusShape)
            : [
                [box.left, box.top], [box.right, box.top], [box.right, box.bottom], [box.left, box.bottom]
              ];
        // densified so the warp bends its edges.
        final bg = ui.Path();
        for (final piece in _textWarp!(densifyRing(ring, math.max(box.width, box.height) / 24))) {
          bg.addPolygon([for (final q in piece) ui.Offset(q[0], q[1])], true);
        }
        canvas.drawPath(bg, paint);
      } else if (r <= 0) {
        canvas.drawRect(box, paint);
      } else if ((t.background.radiusShape - circleRoundK).abs() < 1e-4) {
        canvas.drawRRect(ui.RRect.fromRectXY(box, r, r), paint);
      } else {
        canvas.drawPath(
            _pathFromPoints(roundedRectRing(box.center.dx, box.center.dy, box.width, box.height, r, r, k: t.background.radiusShape),
                close: true),
            paint);
      }
    }
    // the outline sits outside the letters: a stroke twice as wide drawn
    // behind the fill, so the fill never gets thinner.
    ui.Paint strokePaint(ui.Color color) => ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = t.strokeWidth * 2
      ..strokeJoin = ui.StrokeJoin.round;
    if (t.shadow.enabled) {
      final shadowColor = _withOpacity(t.shadow.color, t.shadow.opacity, black);
      // the shadow is one flat shape: fill + outline merged in their own layer.
      canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, shadowColor.opacity));
      final solid = shadowColor.withOpacity(1);
      // long shadow: solid sides from the letters to the far copy; the lag
      // moves the far end, so the sides stretch.
      final lx = lag == null ? 0.0 : lag[0], ly = lag == null ? 0.0 : lag[1];
      final d = ui.Offset(t.shadow.dx + lx, t.shadow.dy + ly), mid = ui.Offset(c.offset[0], c.offset[1]);
      // the far copy (the whole shadow when it isn't long), or the echo's
      // copies along the way.
      for (final (k, al) in _shadowCopies(t.shadow, localFrame)) {
        canvas.save();
        canvas.translate(d.dx * k, d.dy * k);
        final sc = 1 + (t.shadow.scale - 1) * k;
        if (sc != 1) {
          canvas.translate(mid.dx, mid.dy);
          canvas.scale(sc);
          canvas.translate(-mid.dx, -mid.dy);
        }
        if (t.strokeWidth > 0) canvas.drawPath(path, strokePaint(solid.withOpacity(al)));
        canvas.drawPath(path, ui.Paint()..color = solid.withOpacity(al));
        canvas.restore();
      }
      if (t.shadow.long) {
        // joined to the letters by solid sides (no stacked copies).
        final sides = _extrusionSides(_flattenCmds(layout.path), d, t.shadow.scale, mid);
        if (t.strokeWidth > 0) canvas.drawPath(sides, strokePaint(solid));
        canvas.drawPath(sides, ui.Paint()..color = solid);
      }
      canvas.restore();
    }
    if (t.strokeWidth > 0) canvas.drawPath(path, strokePaint(_withOpacity(t.strokeColor, 1, black)));
    canvas.drawPath(plain, ui.Paint()..color = _withOpacity(t.color, 1, white));
    for (final e in layout.colored.entries) {
      canvas.drawPath(_pathFromCmds(e.value), ui.Paint()..color = _withOpacity(e.key, 1, white));
    }
  }

  // the frame being drawn, for the corners' radii (they may keep round
  // against the layer's scale at that frame).
  Project? _radiiProject;
  int _radiiFrame = 0;

  ui.RRect _roundedRect(Layer layer) {
    final c = layer.content;
    final r = ui.Rect.fromCenter(center: ui.Offset(c.offset[0], c.offset[1]), width: c.size[0], height: c.size[1]);
    final each = cornerRadiiEach(layer, _radiiFrame, project: _radiiProject);
    final on = layer.fill.cornersOn;
    ui.Radius rad(int i) => on[i] ? ui.Radius.elliptical(each[i].$1, each[i].$2) : ui.Radius.zero;
    return ui.RRect.fromRectAndCorners(r, topLeft: rad(0), topRight: rad(1), bottomRight: rad(2), bottomLeft: rad(3));
  }

  /// The outline a shape's shadow takes (content-local); null for content
  /// without one (pictures, text - text has its own).
  ui.Path? _shapeShadowPath(Layer layer) {
    final c = layer.content;
    if (isMediaShape(c.shape) || c.shape == 'text' || c.shape == 'textGroup' || isAudioShape(c.shape) || isCameraShape(c.shape) || c.shape == 'null') {
      return null;
    }
    if (c.shape == 'rect' && (layer.fill.cornerRadius > 0 || layer.links.any((k) => k.enabled && k.to.startsWith('round')))) {
      return ui.Path()..addRRect(_roundedRect(layer));
    }
    if (c.shape == 'rect' || (c.shape == 'line' && !isNodeLine(c))) {
      return ui.Path()
        ..addRect(ui.Rect.fromCenter(center: ui.Offset(c.offset[0], c.offset[1]), width: c.size[0], height: c.size[1]));
    }
    if (c.shape == 'compound') {
      final path = ui.Path();
      for (final ct in layerContours(layer)) {
        if (ct.length >= 3) path.addPolygon([for (final p in ct) ui.Offset(p[0], p[1])], true);
      }
      return path;
    }
    if (isNodeLine(c)) {
      return isFilledLine(c)
          ? _pathFromPoints(sampleLine(c.lineNodes!, closed: true), close: true)
          : (ui.Path()..addPath(_pathFromPoints(sampleLine(c.lineNodes!, closed: c.lineClosed)), ui.Offset.zero));
    }
    final pts = layerShapePoints(layer);
    return pts.length < 3 ? null : _pathFromPoints(pts, close: true);
  }

  /// A shape's shadow: offset, scaled about its middle; a long one joined
  /// to the shape all the way.
  void _drawShapeShadow(ui.Canvas canvas, Layer layer, ui.Path path, [Project? project, int globalFrame = 0]) {
    final sh = layer.fill.shadow;
    // Lag: the far end hangs behind the moving shape.
    final lag = project == null ? null : shapeShadowLag(project, layer, globalFrame);
    final ldx = sh.dx + (lag == null ? 0.0 : lag[0]), ldy = sh.dy + (lag == null ? 0.0 : lag[1]);
    final localFrame = layerLocalFrame(layer, globalFrame);
    final c = layer.content;
    final col = _withOpacity(sh.color, 1, const ui.Color(0xFF000000));
    final openLine = isNodeLine(c) && !isFilledLine(c);
    final paint = openLine
        ? (ui.Paint()
          ..color = col
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = c.lineWidth
          ..strokeCap = ui.StrokeCap.round
          ..strokeJoin = ui.StrokeJoin.round)
        : (ui.Paint()..color = col);
    canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, sh.opacity.clamp(0.0, 1.0)));
    final base = paint.color;
    for (final (k, al) in _shadowCopies(sh, localFrame)) {
      canvas.save();
      canvas.translate(ldx * k, ldy * k);
      final sc = 1 + (sh.scale - 1) * k;
      if (sc != 1) {
        canvas.translate(c.offset[0], c.offset[1]);
        canvas.scale(sc);
        canvas.translate(-c.offset[0], -c.offset[1]);
      }
      canvas.drawPath(path, paint..color = base.withOpacity(al));
      canvas.restore();
    }
    paint.color = base;
    if (sh.long) {
      // a line's shadow is its stroke band: the band's outline extrudes.
      final body = paint.style == ui.PaintingStyle.stroke ? _strokeOutline(path, paint.strokeWidth) : path;
      // exact corners where the shape has them (sampling along the path
      // clips each corner, which shows on a small shape scaled up).
      final rings = paint.style == ui.PaintingStyle.stroke ? null : _shapeRings(layer);
      final sides = _extrusionSides(
          rings ?? _flattenPath(body), ui.Offset(ldx, ldy), sh.scale, ui.Offset(c.offset[0], c.offset[1]));
      canvas.drawPath(sides, ui.Paint()..color = paint.color);
    }
    canvas.restore();
  }

  /// HUD: units the last animated text drew, and its time (ms).
  int textUnitsDrawn = 0;
  double textUnitsMs = 0;

  /// An animated text: background, shadow (of all units that show),
  /// then each unit with its own opacity, colour and blur.
  void _drawTextUnits(ui.Canvas canvas, TextSpec t, Content c, TextLayout layout, List<UnitState> units, bool outline,
      [Float64List? lag, num localFrame = 0]) {
    const white = ui.Color(0xFFFFFFFF), black = ui.Color(0xFF000000);
    final shown = [for (final u in units) if (u.opacity > 0.01) u];
    final all = _pathFromCmds([for (final u in shown) ...u.cmds]);
    if (outline) {
      canvas.drawPath(
          all,
          ui.Paint()
            ..color = _withOpacity(t.color, 1, white)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 1.5);
      return;
    }
    if (t.background.enabled) {
      final pad = t.background.padding;
      final w = layout.width, h = layout.height;
      final x0 = switch (t.align) {
        'left' => c.offset[0] - c.size[0] / 2,
        'right' => c.offset[0] + c.size[0] / 2 - w,
        _ => c.offset[0] - w / 2,
      };
      canvas.drawRect(ui.Rect.fromLTWH(x0 - pad, c.offset[1] - h / 2 - pad, w + 2 * pad, h + 2 * pad),
          ui.Paint()..color = _withOpacity(t.background.color, t.background.opacity, black));
    }
    ui.Paint strokePaint(ui.Color color) => ui.Paint()
      ..color = color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = t.strokeWidth * 2
      ..strokeJoin = ui.StrokeJoin.round;
    if (t.shadow.enabled) {
      final shadowColor = _withOpacity(t.shadow.color, t.shadow.opacity, black);
      canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, shadowColor.opacity));
      final solid = shadowColor.withOpacity(1);
      // Per letter: each unit's shadow on its own spring; else one lag.
      final perUnit = lag != null && lag.length == units.length * 2 && lag.length > 2;
      final groups = perUnit
          ? [
              for (var u = 0; u < units.length; u++)
                if (units[u].opacity > 0.01) (_pathFromCmds(units[u].cmds), units[u].cmds, lag[2 * u], lag[2 * u + 1])
            ]
          : [(all, [for (final u in shown) ...u.cmds], lag == null ? 0.0 : lag[0], lag == null ? 0.0 : lag[1])];
      final mid = ui.Offset(c.offset[0], c.offset[1]);
      for (final (p, cmds, lx, ly) in groups) {
        final d = ui.Offset(t.shadow.dx + lx, t.shadow.dy + ly);
        for (final (k, al) in _shadowCopies(t.shadow, localFrame)) {
          canvas.save();
          canvas.translate(d.dx * k, d.dy * k);
          final sc = 1 + (t.shadow.scale - 1) * k;
          if (sc != 1) {
            canvas.translate(mid.dx, mid.dy);
            canvas.scale(sc);
            canvas.translate(-mid.dx, -mid.dy);
          }
          if (t.strokeWidth > 0) canvas.drawPath(p, strokePaint(solid.withOpacity(al)));
          canvas.drawPath(p, ui.Paint()..color = solid.withOpacity(al));
          canvas.restore();
        }
        if (t.shadow.long) {
          final sides = _extrusionSides(_flattenCmds(cmds), d, t.shadow.scale, mid);
          if (t.strokeWidth > 0) canvas.drawPath(sides, strokePaint(solid));
          canvas.drawPath(sides, ui.Paint()..color = solid);
        }
      }
      canvas.restore();
    }
    for (final u in shown) {
      final p = _pathFromCmds(u.cmds);
      var col = _withOpacity(u.baseColor ?? t.color, 1, white);
      if (u.tint != null && u.tintAmount > 0) {
        col = ui.Color.lerp(col, _withOpacity(u.tint, 1, white), u.tintAmount.clamp(0.0, 1.0))!;
      }
      final blur = u.blur > 0.05 ? ui.MaskFilter.blur(ui.BlurStyle.normal, u.blur / 2) : null;
      if (t.strokeWidth > 0) {
        canvas.drawPath(
            p,
            strokePaint(_withOpacity(t.strokeColor, 1, black).withOpacity(u.opacity))..maskFilter = blur);
      }
      canvas.drawPath(p, ui.Paint()
        ..color = col.withOpacity(u.opacity)
        ..maskFilter = blur);
    }
  }

  /// Text / compound content drawn onto a stage-sized raster, centred like
  /// _rasterizeShapeSilhouette, for the effect-warp path.
  ui.Image _rasterizeVectorIntoStageSpace(
      Project project, Layer layer, int globalFrame, ui.Color color, bool outline) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.save();
    canvas.translate(_width / 2, _height / 2);
    _applyCropAndMirror(canvas, layer);
    _withGlows(canvas, project, layer, globalFrame, 1, () => _drawVectorContent(canvas, layer, color, outline, layerLocalFrame(layer, globalFrame), project));
    canvas.restore();
    return recorder.endRecording().toImageSync(_width.round(), _height.round());
  }



  /// The cut edges of an outlined vector shape: each cut's outline,
  /// drawn only where it crosses the shape (the canvas is already clipped
  /// to the kept part). The stroke is doubled because the cut clips half
  /// of it away, so it matches the shape's own outline.
  void _strokePieceCuts(ui.Canvas canvas, Project project, Layer layer, int globalFrame, ui.Paint strokePaint,
      {required bool canvasMirrored}) {
    final shape = layer.content.shape;
    if (isMediaShape(shape) || shape == 'text' || shape == 'textGroup' || shape == 'compound' || shape == 'audio') return;
    final outlinePts = getContentOutline(layer.content, layer, globalFrame, project: project);
    if (outlinePts.length < 3) return;
    canvas.save();
    // undo the mirror the crop/mirror step applied to this canvas: cuts
    // are drawn where the clip put them.
    if (canvasMirrored && (layer.mirrorX || layer.mirrorY)) {
      final b = shapeBoundingBox(layer.content);
      final cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
      canvas.translate(cx, cy);
      canvas.scale(layer.mirrorX ? -1 : 1, layer.mirrorY ? -1 : 1);
      canvas.translate(-cx, -cy);
    }
    // the shape itself is drawn mirrored: clip with its mirrored outline.
    final b = shapeBoundingBox(layer.content);
    final cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
    canvas.clipPath(_pathFromPoints([
      for (final p in outlinePts) [layer.mirrorX ? 2 * cx - p[0] : p[0], layer.mirrorY ? 2 * cy - p[1] : p[1]]
    ], close: true));
    // only on the kept part (a textured shape got its cuts inside its
    // raster, not on this canvas).
    for (final cut in layer.pieceClips) {
      if (cut.points.length < 3) continue;
      final poly = _pathFromPoints(cut.points, close: true);
      canvas.clipPath(cut.inside
          ? poly
          : (ui.Path()
            ..fillType = ui.PathFillType.evenOdd
            ..addRect(const ui.Rect.fromLTRB(-1e6, -1e6, 1e6, 1e6))
            ..addPath(poly, ui.Offset.zero)));
    }
    final paint = ui.Paint()
      ..color = strokePaint.color
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = strokePaint.strokeWidth * 2;
    for (final cut in layer.pieceClips) {
      if (cut.points.length < 3) continue;
      canvas.drawPath(_pathFromPoints(cut.points, close: true), paint);
    }
    canvas.restore();
  }

  /// Clips `canvas` (already in the layer's content-local space) to the
  /// layer's crop rect, then flips it about the content box's centre for
  /// mirror. The clip comes first, so crop insets always name the sides
  /// you see.
  void _applyCropAndMirror(ui.Canvas canvas, Layer layer) {
    if (layerHasCrop(layer)) {
      final c = croppedBox(layer);
      canvas.clipRect(ui.Rect.fromLTRB(c.minX, c.minY, c.maxX, c.maxY));
    }
    // detached pieces: the piece keeps the inside of its cut, the layer it
    // came from the outside.
    for (final cut in layer.pieceClips) {
      if (cut.points.length < 3) continue;
      final poly = ui.Path()..addPolygon([for (final p in cut.points) ui.Offset(p[0], p[1])], true);
      if (cut.inside) {
        canvas.clipPath(poly);
      } else {
        canvas.clipPath(ui.Path()
          ..fillType = ui.PathFillType.evenOdd
          ..addRect(const ui.Rect.fromLTRB(-1e6, -1e6, 1e6, 1e6))
          ..addPath(poly, ui.Offset.zero));
      }
    }
    if (layer.mirrorX || layer.mirrorY) {
      final b = shapeBoundingBox(layer.content);
      final cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
      canvas.translate(cx, cy);
      canvas.scale(layer.mirrorX ? -1 : 1, layer.mirrorY ? -1 : 1);
      canvas.translate(-cx, -cy);
    }
  }

  /// cache key for an image Content - the source data itself (the
  /// base64 string, or the file path) IS the identity, so two layers
  /// referencing the same embedded bytes or the same file share one
  /// decoded ui.Image rather than each decoding their own copy.
  String? _imageCacheKey(Content c) {
    if (c.imageSourceType == 'embedded' && c.imageData != null) {
      return 'embedded:${c.imageData}';
    }
    if (c.imageSourceType == 'file' && c.imagePath != null) {
      return 'file:${c.imagePath}';
    }
    return null;
  }

  /// returns the already-decoded bitmap for an image Content, or null
  /// if it hasn't finished decoding yet - kicking off the async decode
  /// on first request, exactly once per cache key. Necessarily
  /// synchronous: renderFrame() itself is synchronous (the Renderer
  /// interface's own pull-model contract), so the very first frame that
  /// requests a given image simply draws it blank; onImageDecoded fires
  /// once decode finishes so the caller (AppState) can trigger a
  /// re-render/rebuild that picks the now-cached bitmap up.
  ui.Image? _getDecodedImage(Content content) {
    final key = _imageCacheKey(content);
    if (key == null) return null;
    final cached = _imageCache[key];
    if (cached != null) return cached;
    if (_failedKeys.contains(key)) return null;
    if (_decodingKeys.add(key)) {
      decodeAttempts++;
      _decodeImageAsync(key, content);
    }
    return null;
  }

  // ===== video frames =====

  /// Decoded frames of video layers around the playhead (see
  /// video_frame_cache.dart). AppState points `framesRoot` at the frame
  /// cache; tests swap the decoder.
  late final VideoFrameCache videoFrames = VideoFrameCache()
    ..onDecoded = (() => onImageDecoded?.call())
    ..onEvict = _sourcePixels.remove;

  /// The source frame a video layer shows at `globalFrame` (its own time,
  /// with time quantize, held at its ends).
  int? videoFrameIndex(Layer layer, num globalFrame) {
    final local = math.min(layer.durationFrames, math.max(0, layerTimeFrame(layer, globalFrame) - layer.startFrame));
    // reversed: the same stretch of the clip, from its end.
    return videoSourceFrame(layer.content, layer.content.playReversed ? layer.durationFrames - local : local);
  }

  /// A media layer's source picture at `globalFrame` and its identity: the
  /// decoded image, or for video the frame (the nearest decoded one while
  /// the exact frame is still loading).
  ({String key, ui.Image image})? _sourceImageOf(Layer layer, int globalFrame) {
    final c = layer.content;
    // a merged shape keys as a picture of itself.
    if (c.shape == 'compound') return _vectorRaster(layer);
    if (c.shape == 'projectRef') return _projectRefImage(layer, globalFrame);
    if (c.shape == 'video') {
      final index = videoFrameIndex(layer, globalFrame);
      return index == null ? null : videoFrames.frameFor(c, index);
    }
    final decoded = _getDecodedImage(c);
    final key = _imageCacheKey(c);
    return decoded == null || key == null ? null : (key: key, image: decoded);
  }

  final Map<String, ({String key, ui.Image image})> _vectorRasters = {};

  /// A merged shape's content box as a picture (long side about 768 px),
  /// kept until its outlines or colours change.
  ({String key, ui.Image image}) _vectorRaster(Layer layer) {
    final c = layer.content;
    final key = 'vec:${layer.id}:${jsonEncode([c.contours, c.contourColors, c.contourJoin, c.size, c.offset, layer.color, layer.fill.cornerRadius, layer.fill.outerRadius, layer.fill.cornerShape])}'.hashCode.toString();
    final have = _vectorRasters[layer.id];
    if (have != null && have.key == key) return have;
    final w = math.max(1.0, c.size[0]), h = math.max(1.0, c.size[1]);
    final s = (768 / math.max(w, h)).clamp(1.0, 8.0);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(s);
    canvas.translate(w / 2 - c.offset[0], h / 2 - c.offset[1]);
    _drawVectorContent(canvas, layer, _parseColor(layer.color) ?? const ui.Color(0xFF8AB4D8), false);
    final image = recorder.endRecording().toImageSync((w * s).round(), (h * s).round());
    have?.image.dispose();
    return _vectorRasters[layer.id] = (key: key, image: image);
  }

  /// An image from straight (non-premultiplied) RGBA - premultiplied first,
  /// because decodeImageFromPixels' rgba8888 IS premultiplied. keyed-out areas
  /// came out white instead of transparent - their colour was kept at alpha 0
  /// and got added on top.
  static Future<ui.Image> imageFromStraightRgba(Uint8List rgba, int width, int height) {
    final pre = Uint8List.fromList(rgba);
    for (var i = 0; i < pre.length; i += 4) {
      final a = pre[i + 3];
      if (a == 255) continue;
      pre[i] = (pre[i] * a + 127) ~/ 255;
      pre[i + 1] = (pre[i + 1] * a + 127) ~/ 255;
      pre[i + 2] = (pre[i + 2] * a + 127) ~/ 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(pre, width, height, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  /// Makes sure every video frame that rendering `globalFrame` needs is
  /// decoded (motion-blur samples included) and chroma keying for them is
  /// done - export awaits this before each renderFrame, so it never gets
  /// the editor's "nearest frame" stand-in.
  Future<void> prepareFrame(Project project, int globalFrame) async {
    // export: the physics fully baked up to the frame.
    _bakePhysics(project, globalFrame, null);
    final needed = <String>{};
    final jobs = <Future<void>>[];
    for (final layer in project.layers) {
      if (layer.content.shape != 'video' || layer.hidden) continue;
      final frames = <int>{globalFrame};
      final mb = layer.motionBlur;
      if (mb.enabled && mb.samples > 1 && effectActiveAt(layer, 'motionBlur', globalFrame - layer.startFrame)) {
        for (var s = 0; s < mb.samples; s++) {
          frames.add((globalFrame + ((s / (mb.samples - 1)) - 0.5) * mb.shutterAngle / 360).round());
        }
      }
      for (final f in frames) {
        final index = videoFrameIndex(layer, f);
        final asset = VideoFrameCache.assetOf(layer.content);
        if (index == null || asset == null) continue;
        needed.add(VideoFrameCache.keyOf(asset, index));
        jobs.add(() async {
          final image = await videoFrames.load(layer.content, index);
          if (image != null && f == globalFrame && (layer.chromaKey.active || _edgeMatteOn(layer))) {
            await _ensureKeyed(layer, VideoFrameCache.keyOf(asset, index), image);
          }
        }());
      }
    }
    videoFrames.pinned = needed;
    // referenced projects: their own videos, at their own frames.
    for (final layer in project.layers) {
      if (layer.content.shape != 'projectRef' || layer.hidden) continue;
      final job = _prepareRef(layer, globalFrame);
      if (job != null) jobs.add(job);
    }
    await Future.wait(jobs);
  }

  // ===== project references (model/project_ref.dart) =====

  /// The referenced projects as loaded (AppState fills it); nested
  /// renderers share it.
  RefSources refSources = {};

  /// While true, references not loaded yet draw "Loading..." rather than
  /// "Project not found".
  bool refsLoading = false;

  /// This renderer's project and the ones around it, outermost first: a
  /// reference back into it is a cycle (drawn as a placeholder).
  List<String> refChain = const [];

  final Map<String, CanvasRenderer> _refRenderers = {};
  final LinkedHashMap<String, ui.Image> _refFrames = LinkedHashMap();
  static const _refFrameBudget = 32;
  final Expando<bool> _refStatic = Expando('static source');

  // HUD: nested renders and cache hits in the last second, the last
  // nested render's time.
  final List<int> _refRenderTimes = [], _refHitTimes = [];
  double refLastMs = 0;
  ({int loaded, int renders, int hits, double ms}) refStats() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _refRenderTimes.removeWhere((t) => now - t > 1000);
    _refHitTimes.removeWhere((t) => now - t > 1000);
    return (loaded: refSources.length, renders: _refRenderTimes.length, hits: _refHitTimes.length, ms: refLastMs);
  }

  /// Forgets rendered frames (a source was reloaded).
  void clearRefFrames() {
    _refFrames.clear();
    for (final r in _refRenderers.values) {
      r.clearRefFrames();
    }
  }

  void _dropRefFrames(String id) => _refFrames.removeWhere((k, _) => k.startsWith('ref:$id:'));

  CanvasRenderer _refRenderer(RefSource s) {
    final r = _refRenderers[s.id] ??= CanvasRenderer()
      ..onImageDecoded = () {
        // the source drew something new (an image decoded, physics
        // baked on): its frames are re-rendered.
        _dropRefFrames(s.id);
        onImageDecoded?.call();
      };
    r
      ..refSources = refSources
      ..refsLoading = refsLoading
      ..refChain = [...refChain, s.id]
      ..backgroundColor = s.backgroundRgb == null ? null : ui.Color(0xFF000000 | s.backgroundRgb!);
    return r;
  }

  /// Runs `f` under the source's own stage size and frame rate (every
  /// coordinate and time in it is relative to those).
  T _inSource<T>(RefSource s, T Function() f) {
    final hostW = stageSize.width, hostH = stageSize.height, hostFps = fps;
    try {
      fps = s.fps;
      setStageSize(s.width, s.height);
      return f();
    } finally {
      fps = hostFps;
      setStageSize(hostW, hostH);
      clearStateCaches();
    }
  }

  int? _refFrame(Layer layer, int globalFrame, RefSource s) =>
      (_refStatic[s] ??= projectIsStatic(s.project)) ? 0 : refSourceFrame(layer, globalFrame, s, fps);

  /// A reference's picture at `globalFrame`: the source rendered at its
  /// frame for that time (cached per source, revision, frame and size).
  /// Null while hidden (past the end) or a placeholder is drawn.
  ({String key, ui.Image image})? _projectRefImage(Layer layer, int globalFrame) {
    final c = layer.content;
    if (refStatus(c, refSources, refChain) != RefStatus.ok) return null;
    final s = refSourceOf(c, refSources)!;
    final sf = _refFrame(layer, globalFrame, s);
    if (sf == null) return null;
    // the size the layer's box needs, never above the source's own canvas
    // (in quarter steps, so small changes share frames).
    final need = math.max(c.size[0] / s.width, c.size[1] / s.height);
    final k = ((need * 4).ceil() / 4).clamp(0.25, 1.0);
    final w = math.max(1, (s.width * k).round()), h = math.max(1, (s.height * k).round());
    // a live source (Show in context: the open project, unsaved) has
    // no revision to key by - always rendered.
    final key = 'ref:${s.id}:${s.revision}:$sf:${w}x$h';
    if (s.revision >= 0) {
      final hit = _refFrames.remove(key);
      if (hit != null) {
        _refFrames[key] = hit;
        _refHitTimes.add(DateTime.now().millisecondsSinceEpoch);
        return (key: key, image: hit);
      }
    }
    final sw = Stopwatch()..start();
    final child = _refRenderer(s);
    final pic = _inSource(s, () {
      child.setSize(s.width, s.height);
      child.renderFrame(s.project, sf);
      return child.currentPicture;
    });
    if (pic == null) return null;
    final rec = ui.PictureRecorder();
    ui.Canvas(rec)
      ..scale(w / s.width, h / s.height)
      ..drawPicture(pic);
    final image = rec.endRecording().toImageSync(w, h);
    if (s.revision >= 0) {
      _refFrames[key] = image;
      while (_refFrames.length > _refFrameBudget) {
        _refFrames.remove(_refFrames.keys.first);
      }
    }
    refLastMs = sw.elapsedMicroseconds / 1000;
    _refRenderTimes.add(DateTime.now().millisecondsSinceEpoch);
    return (key: key, image: image);
  }

  /// Export: the source's own media for the frame, loaded.
  Future<void>? _prepareRef(Layer layer, int globalFrame) {
    if (refStatus(layer.content, refSources, refChain) != RefStatus.ok) return null;
    final s = refSourceOf(layer.content, refSources)!;
    final sf = _refFrame(layer, globalFrame, s);
    if (sf == null) return null;
    final child = _refRenderer(s);
    // the synchronous part (which frames) runs under the source's
    // settings; the loading itself needs none.
    final job = _inSource(s, () => child.prepareFrame(s.project, sf));
    return job.then((_) => _dropRefFrames(s.id));
  }

  /// What a reference draws instead of its source, or null.
  String? refPlaceholder(Layer layer) {
    if (layer.content.shape != 'projectRef') return null;
    return switch (refStatus(layer.content, refSources, refChain)) {
      RefStatus.ok => null,
      RefStatus.missing => refsLoading ? 'Loading…' : 'Project not found',
      RefStatus.cycle => 'Contains itself',
      RefStatus.tooDeep => 'Nested too deep',
    };
  }

  void _paintRefPlaceholder(ui.Canvas canvas, Layer layer, String label) {
    final c = layer.content;
    final r = ui.Rect.fromCenter(center: ui.Offset(c.offset[0], c.offset[1]), width: c.size[0], height: c.size[1]);
    canvas.drawRect(r, ui.Paint()..color = const ui.Color(0x33FFFFFF));
    canvas.drawRect(
        r,
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, r.shortestSide / 100)
          ..color = const ui.Color(0xAAFFFFFF));
    final fontSize = (r.shortestSide / 10).clamp(8.0, 48.0);
    final pb = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: ui.TextAlign.center, fontSize: fontSize, maxLines: 2))
      ..pushStyle(ui.TextStyle(color: const ui.Color(0xEEFFFFFF)))
      ..addText('${layer.name}\n$label');
    final para = pb.build()..layout(ui.ParagraphConstraints(width: r.width));
    canvas.drawParagraph(para, ui.Offset(r.left, r.center.dy - para.height / 2));
    if (refsLoading && label.startsWith('Loading')) {
      final sr = fontSize;
      canvas.drawArc(
          ui.Rect.fromCircle(center: ui.Offset(r.center.dx, r.center.dy - para.height / 2 - sr * 1.2), radius: sr / 2),
          0,
          4.5,
          false,
          ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = sr / 6
            ..color = const ui.Color(0xEEFFFFFF));
    }
  }

  // ===== chroma key =====

  /// Straight RGBA of each decoded image source (for keying and the
  /// eyedropper), read back once per source.
  final Map<String, ({Uint8List rgba, int width, int height})> _sourcePixels = {};
  final Map<String, Future<({Uint8List rgba, int width, int height})?>> _pixelsLoading = {};

  /// The last keyed image per layer, with the settings it was made with.
  final Map<String, ({String sig, ui.Image image})> _keyed = {};
  final Map<String, Future<void>> _keyingInFlight = {};

  String _keySig(String sourceKey, ChromaKey ck, {bool matte = false}) =>
      '$sourceKey|${jsonEncode(chromaKeyToJson(ck))}${matte ? '|matte' : ''}';

  /// Chroma tab, the contrast view: this layer shows what its keys keep,
  /// white, and what they remove, black.
  String? chromaMatteLayerId;

  /// The image a layer draws: its source (see _sourceImageOf), or its
  /// chroma-keyed version. Keying runs asynchronously; until the image for
  /// the current settings is ready, the previous keyed image (or the plain
  /// source) is drawn and onImageDecoded fires once the new one lands.
  ui.Image? _layerImage(Layer layer, int globalFrame) {
    final src = _sourceImageOf(layer, globalFrame);
    final ck = layer.chromaKey;
    if (src == null || !(ck.active || _edgeMatteOn(layer))) return src?.image;
    final matte = chromaMatteLayerId == layer.id;
    final sig = '${_keySig(src.key, ck, matte: matte)}|${_edgeMatteSig(layer)}';
    final have = _keyed[layer.id];
    if (have != null && have.sig == sig) return have.image;
    if (!_keyingInFlight.containsKey(layer.id)) {
      _keyingInFlight[layer.id] = _keyLayerAsync(layer.id, src.key, src.image, ck.copy(), sig,
          matte: matte, edge: _edgeMatteOn(layer) ? (parseRgbHex(layer.edgeMatteColor) ?? const [0, 0, 0], layer.edgeMatteStrength) : null);
    }
    return have?.image ?? src.image;
  }

  /// Keys `image` for `layer` now (export), waiting out a keying already
  /// running for it.
  Future<void> _ensureKeyed(Layer layer, String sourceKey, ui.Image image) async {
    // the same signature _layerImage looks for (export never shows the
    // contrast view).
    final sig = '${_keySig(sourceKey, layer.chromaKey)}|${_edgeMatteSig(layer)}';
    await _keyingInFlight[layer.id];
    if (_keyed[layer.id]?.sig == sig) return;
    final job = _keyLayerAsync(layer.id, sourceKey, image, layer.chromaKey.copy(), sig,
        edge: _edgeMatteOn(layer) ? (parseRgbHex(layer.edgeMatteColor) ?? const [0, 0, 0], layer.edgeMatteStrength) : null);
    _keyingInFlight[layer.id] = job;
    await job;
  }

  Future<({Uint8List rgba, int width, int height})?> _pixelsOf(String key, ui.Image image) {
    final cached = _sourcePixels[key];
    if (cached != null) return Future.value(cached);
    return _pixelsLoading.putIfAbsent(key, () async {
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        if (data == null) return null;
        final px = (rgba: data.buffer.asUint8List(), width: image.width, height: image.height);
        _sourcePixels[key] = px;
        return px;
      } catch (_) {
        return null; // e.g. a video frame that left the window meanwhile
      } finally {
        _pixelsLoading.remove(key);
      }
    });
  }

  /// Edge matte on a picture layer (image, video, merged shape).
  static bool _edgeMatteOn(Layer l) => l.edgeMatte && l.edgeMatteStrength > 0;
  static String _edgeMatteSig(Layer l) => _edgeMatteOn(l) ? 'edge:${l.edgeMatteColor}:${l.edgeMatteStrength}' : '';

  Future<void> _keyLayerAsync(String layerId, String key, ui.Image decoded, ChromaKey ck, String sig,
      {bool matte = false, (List<int>, double)? edge}) async {
    try {
      final px = await _pixelsOf(key, decoded);
      if (px == null) return;
      // off the UI thread: keying a big picture takes a while.
      final rgba = px.rgba, w = px.width, h = px.height;
      final keyed = await Isolate.run(() {
        if (matte) return chromaMatte(rgba, w, h, ck);
        final out = ck.active ? chromaKeyedCopy(rgba, w, h, ck) : Uint8List.fromList(rgba);
        if (edge != null) colorToAlpha(out, w, h, edge.$1, edge.$2);
        return out;
      });
      final image = await imageFromStraightRgba(keyed, px.width, px.height);
      _keyed[layerId]?.image.dispose();
      _keyed[layerId] = (sig: sig, image: image);
    } catch (_) {
      // keying failed - the plain image keeps being drawn.
    } finally {
      _keyingInFlight.remove(layerId);
      onImageDecoded?.call();
    }
  }

  /// The source picture a media layer shows at `globalFrame` (null until
  /// decoded) - the eyedropper loupe magnifies it.
  ui.Image? decodedImageOf(Layer layer, int globalFrame) => _sourceImageOf(layer, globalFrame)?.image;

  /// Like sampleImageRgb, but answers only from pixels already read back
  /// (for painting); starts the read-back otherwise and returns null.
  List<int>? sampleImageRgbSync(Layer layer, int globalFrame, double u, double v) {
    final src = _sourceImageOf(layer, globalFrame);
    if (src == null) return null;
    final px = _sourcePixels[src.key];
    if (px == null) {
      _pixelsOf(src.key, src.image).then((_) => onImageDecoded?.call());
      return null;
    }
    return sampleRgb(px.rgba, px.width, px.height, u, v);
  }

  /// The picture's alpha (0..255) at (u, v), fractions of the image; null
  /// while its pixels aren't read yet (they are being now).
  int? alphaAtSync(Layer layer, int globalFrame, double u, double v) {
    final src = _sourceImageOf(layer, globalFrame);
    if (src == null) return 0;
    final px = _sourcePixels[src.key];
    if (px == null) {
      _pixelsOf(src.key, src.image);
      return null;
    }
    final x = (u * px.width).floor().clamp(0, px.width - 1), y = (v * px.height).floor().clamp(0, px.height - 1);
    return px.rgba[(y * px.width + x) * 4 + 3];
  }

  /// The source colour around (u, v) (fractions of the image) - the Chroma
  /// tab's eyedropper. Null while the source isn't decoded.
  Future<List<int>?> sampleImageRgb(Layer layer, int globalFrame, double u, double v) async {
    final src = _sourceImageOf(layer, globalFrame);
    if (src == null) return null;
    final px = await _pixelsOf(src.key, src.image);
    if (px == null) return null;
    return sampleRgb(px.rgba, px.width, px.height, u, v);
  }

  Future<void> _decodeImageAsync(String key, Content content) async {
    try {
      final Uint8List bytes;
      if (content.imageSourceType == 'embedded') {
        bytes = base64Decode(content.imageData!);
      } else {
        bytes = await File(content.imagePath!).readAsBytes();
      }
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _imageCache[key] = frame.image;
    } catch (_) {
      _failedKeys.add(key);
      // a missing/unreadable file or corrupt bytes just leaves this
      // layer blank - no crash, matches every other "content not ready
      // yet" case in this renderer (e.g. a not-yet-decoded precompose).
    } finally {
      _decodingKeys.remove(key);
      onImageDecoded?.call();
    }
  }

  /// rasterizes a non-rect shape's own undeformed silhouette, centered
  /// on the stage, so a plain shape can be texture-warped through the
  /// same drawVertices pipeline precompose groups use - fixes warp
  /// quality on circles/ngons the same way the JS original notes
  /// (their vertex distribution doesn't line up with a bbox UV
  /// parametrization when warped as a sparse point list directly).
  ui.Image _rasterizeShapeSilhouette(
      Content content, ui.Color color, bool outline,
      [Layer? layer, Project? project, int globalFrame = 0]) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    // a rect only gets here with a gradient fill (see isTextured).
    final pts = content.shape == 'rect' || content.shape == 'line'
        ? () {
            final o = content.offset, hw = content.size[0] / 2, hh = content.size[1] / 2;
            return [
              [o[0] - hw, o[1] - hh],
              [o[0] + hw, o[1] - hh],
              [o[0] + hw, o[1] + hh],
              [o[0] - hw, o[1] + hh],
            ];
          }()
        : shapePoints(content);
    if (pts.isNotEmpty) {
      canvas.save();
      canvas.translate(_width / 2, _height / 2);
      if (layer != null) _applyCropAndMirror(canvas, layer);
      final paint = ui.Paint()..color = color;
      if (outline) {
        paint
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5;
      } else {
        paint.style = ui.PaintingStyle.fill;
      }
      if (layer != null && project != null) {
        _withGlows(canvas, project, layer, globalFrame, 1,
            () => canvas.drawPath(_pathFromPoints(pts, close: true), paint));
      } else {
        canvas.drawPath(_pathFromPoints(pts, close: true), paint);
      }
      canvas.restore();
    }
    final picture = recorder.endRecording();
    return picture.toImageSync(_width.round(), _height.round());
  }

  /// per-cell warp via Canvas.drawVertices - a single call mapping the
  /// UNDEFORMED source grid's cells (as texture UVs into sourceImage)
  /// onto the DEFORMED destination grid's positions, rather than the
  /// JS's many small per-cell drawImage(sx,sy,sw,sh -> dst) calls. Each
  /// grid cell becomes 2 triangles.
  /// Turning a layer over: a mirror about its content's vertical middle.
  List<double> _flipMatrix(Layer layer) {
    final b = shapeBoundingBox(layer.content);
    final cx = (b.minX + b.maxX) / 2;
    return [-1, 0, 0, 1, 2 * cx, 0];
  }

  /// The back side's picture, in the same buffer as the front's
  /// (`front`): the front the right way round (backSame), or the back
  /// layer drawn as it was placed within the turned-over layer.
  ui.Image? _backImage(Project project, Layer layer, Layer? backLayer, ui.Image front, List<double> baseM,
      List<double> flip, int globalFrame, int depth) {
    final w = front.width, h = front.height;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    if (backLayer != null && backLayer.id != layer.id && depth < 3) {
      final st = getLayerStateAt(project, backLayer.id, globalFrame);
      final bm = [st.matrix[0], st.matrix[1], st.matrix[2], st.matrix[3], st.matrix[4] * _width, st.matrix[5] * _height];
      final toBuffer = matMul([1, 0, 0, 1, w / 2, h / 2], invertAffine(matMul(baseM, flip)));
      // the paper itself (the front seen from behind), the back picture
      // printed on it - only within the layer's own shape.
      canvas.drawImage(front, ui.Offset.zero, ui.Paint());
      canvas.saveLayer(null, ui.Paint()..blendMode = ui.BlendMode.srcATop);
      _drawLayerInto(canvas, project, backLayer, globalFrame, matMul(toBuffer, bm), depth + 1, 1);
      canvas.restore();
    } else if (layer.backSame) {
      // buffer(p) = front(flip(p)): read the right way round once turned.
      canvas.translate(2 * (flip[4] / 2 + w / 2), 0);
      canvas.scale(-1, 1);
      canvas.drawImage(front, ui.Offset.zero, ui.Paint());
    } else {
      return null;
    }
    return rec.endRecording().toImageSync(w, h);
  }

  void _drawWarpedGrid(ui.Canvas canvas, ui.Image sourceImage, Grid srcGrid,
      Grid dstGrid, {ui.Image? back, bool flipped = false}) {
    final rows = math.min(srcGrid.length, dstGrid.length);
    final cols = rows == 0 ? 0 : math.min(srcGrid[0].length, dstGrid[0].length);
    if (perfInstrumentation && rows > 1 && cols > 1) perfCounters.gridCells += (rows - 1) * (cols - 1);
    final positions = <double>[];
    final uvs = <double>[];
    final indices = <int>[];
    // with a back side: the triangles seen from behind (their winding
    // turned against the source's) take it.
    final backIndices = <int>[];
    var vertexIndex = 0;
    double cross(List<double> a, List<double> b, List<double> c) =>
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    bool isBack(List<double> d0, List<double> d1, List<double> d2, List<double> s0, List<double> s1, List<double> s2) =>
        (cross(d0, d1, d2) * cross(s0, s1, s2) < 0) != flipped;
    final imgW = sourceImage.width.toDouble(),
        imgH = sourceImage.height.toDouble();

    for (var r = 0; r < rows - 1; r++) {
      for (var c = 0; c < cols - 1; c++) {
        final d00 = dstGrid[r][c],
            d10 = dstGrid[r][c + 1],
            d01 = dstGrid[r + 1][c],
            d11 = dstGrid[r + 1][c + 1];
        final s00 = srcGrid[r][c],
            s10 = srcGrid[r][c + 1],
            s01 = srcGrid[r + 1][c],
            s11 = srcGrid[r + 1][c + 1];
        // source coordinates are centered on the buffer (see
        // buildGrid's offset convention) - shift into image pixel space.
        final uv00 = [s00[0] + imgW / 2, s00[1] + imgH / 2];
        final uv10 = [s10[0] + imgW / 2, s10[1] + imgH / 2];
        final uv01 = [s01[0] + imgW / 2, s01[1] + imgH / 2];
        final uv11 = [s11[0] + imgW / 2, s11[1] + imgH / 2];

        void addVertex(List<double> pos, List<double> uv) {
          positions.addAll(pos);
          uvs.addAll(uv);
        }

        addVertex(d00, uv00); // vertexIndex + 0
        addVertex(d10, uv10); // vertexIndex + 1
        addVertex(d01, uv01); // vertexIndex + 2
        addVertex(d11, uv11); // vertexIndex + 3
        if (back == null) {
          indices.addAll([
            vertexIndex,
            vertexIndex + 1,
            vertexIndex + 2,
            vertexIndex + 1,
            vertexIndex + 3,
            vertexIndex + 2
          ]);
        } else {
          (isBack(d00, d10, d01, s00, s10, s01) ? backIndices : indices)
              .addAll([vertexIndex, vertexIndex + 1, vertexIndex + 2]);
          (isBack(d10, d11, d01, s10, s11, s01) ? backIndices : indices)
              .addAll([vertexIndex + 1, vertexIndex + 3, vertexIndex + 2]);
        }
        vertexIndex += 4;
      }
    }

    if (positions.isEmpty) return;
    if (back != null && backIndices.isNotEmpty) {
      canvas.drawVertices(
          ui.Vertices.raw(ui.VertexMode.triangles, Float32List.fromList(positions),
              textureCoordinates: Float32List.fromList(uvs), indices: Uint16List.fromList(backIndices)),
          ui.BlendMode.srcOver,
          ui.Paint()
            ..shader = ui.ImageShader(back, ui.TileMode.clamp, ui.TileMode.clamp, Matrix4Identity.value)
            ..filterQuality = ui.FilterQuality.medium);
    }
    if (indices.isEmpty) return;
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.fromList(positions),
      textureCoordinates: Float32List.fromList(uvs),
      indices: Uint16List.fromList(indices),
    );
    final paint = ui.Paint()
      ..shader = ui.ImageShader(sourceImage, ui.TileMode.clamp,
          ui.TileMode.clamp, Matrix4Identity.value)
      // a squeezed/warped/bent shape "turned into pixels" - visibly blocky
      // rather than staying vector-crisp. Root cause: Paint's default
      // filterQuality is FilterQuality.none (nearest-neighbor texture
      // sampling), and the source silhouette is rasterized at its own native
      // content-pixel size (e.g. a 46x46 rect) - whenever the warped
      // destination ends up larger than that on screen (any transform.scale
      // above 1, or simply zooming in), each source texel gets sampled as a
      // hard-edged block instead of blended. Bilinear filtering doesn't fix
      // the underlying resolution mismatch, but it turns the visible artifact
      // from sharp pixel blocks into a smooth gradient, which is what
      // "vector-like" softness the issue is asking for.
      ..filterQuality = ui.FilterQuality.medium;
    canvas.drawVertices(vertices, ui.BlendMode.srcOver, paint);
  }

  // ============================================================
  // gradient fill
  // ============================================================

  /// The shader of a paint gradient, content px.
  static ui.Shader fillGradientShader(FillGradient g) {
    final stops = [...g.stops]..sort((a, b) => a.offset.compareTo(b.offset));
    if (stops.isEmpty) stops.add(GradientStop(0, '#000000', 0));
    if (stops.length == 1) stops.add(stops.first.copy()..offset = 1);
    final colors = [
      for (final s in stops)
        ui.Color(0xFF000000 | (int.tryParse(s.color.replaceFirst('#', ''), radix: 16) ?? 0))
            .withOpacity(s.opacity.clamp(0.0, 1.0))
    ];
    final at = [for (final s in stops) s.offset.clamp(0.0, 1.0).toDouble()];
    final mode = switch (g.spread) {
      'reflect' => ui.TileMode.mirror,
      'repeat' => ui.TileMode.repeated,
      _ => ui.TileMode.clamp,
    };
    final m = g.matrix;
    final m4 = Float64List.fromList([m[0], m[1], 0, 0, m[2], m[3], 0, 0, 0, 0, 1, 0, m[4], m[5], 0, 1]);
    return g.type == 'radial'
        ? ui.Gradient.radial(ui.Offset(g.cx, g.cy), g.r, colors, at, mode, m4)
        : ui.Gradient.linear(ui.Offset(g.x1, g.y1), ui.Offset(g.x2, g.y2), colors, at, mode, m4);
  }

  /// Runs [draw] (the shape in its base colour) and, when the layer has a
  /// gradient fill, lights its glows over it - only where the shape is
  /// (srcATop inside an isolated layer, so fill and outline both work).
  void _withGlows(ui.Canvas canvas, Project project, Layer layer, int globalFrame, double deviceScale,
      void Function() draw) {
    final paintG = supportsShapeFill(layer) ? layer.fill.paint : null;
    final glows = layer.fill.active && supportsShapeFill(layer);
    if (!glows && paintG == null) {
      draw();
      return;
    }
    canvas.saveLayer(null, ui.Paint());
    draw();
    // a paint gradient takes the shape's colour (its alpha kept).
    if (paintG != null) {
      canvas.drawPaint(ui.Paint()
        ..blendMode = ui.BlendMode.srcIn
        ..shader = fillGradientShader(paintG));
    }
    for (final g in glows ? evaluateGlows(project, layer, globalFrame) : const <GlowSample>[]) {
      if (g.radius <= 0 || g.strength <= 0) continue;
      // a see-through glow fades the shape out instead of colouring it.
      final erase = g.glow.color == 'transparent';
      final color = erase ? const ui.Color(0xFF000000) : (_parseColor(g.glow.color) ?? const ui.Color(0xFFFFFFFF));
      final mode = erase ? ui.BlendMode.dstOut : ui.BlendMode.srcATop;
      if (g.glow.kind == 'point') {
        const n = 12;
        canvas.drawCircle(
            ui.Offset(g.a[0], g.a[1]),
            g.radius,
            ui.Paint()
              ..blendMode = mode
              ..shader = ui.Gradient.radial(
                ui.Offset(g.a[0], g.a[1]),
                g.radius,
                [for (var i = 0; i <= n; i++) color.withOpacity(g.strength * glowFalloff(i / n))],
                [for (var i = 0; i <= n; i++) i / n],
              ));
      } else {
        // distance to the segment, as three gradient fills (cheap at any
        // radius): a band along it, falloff across, and a round cap at
        // each end - each clipped to its own side, so none overlap.
        final dx = g.b[0] - g.a[0], dy = g.b[1] - g.a[1];
        final len = math.sqrt(dx * dx + dy * dy), r = g.radius;
        const n = 16;
        final radial = [for (var i = 0; i <= n; i++) color.withOpacity(g.strength * glowFalloff(i / n))];
        final rStops = [for (var i = 0; i <= n; i++) i / n];
        final across = [for (var i = 0; i <= 2 * n; i++) color.withOpacity(g.strength * glowFalloff((i - n).abs() / n))];
        final aStops = [for (var i = 0; i <= 2 * n; i++) i / (2 * n)];
        canvas.save();
        canvas.translate(g.a[0], g.a[1]);
        canvas.rotate(math.atan2(dy, dx));
        final paint = ui.Paint()..blendMode = mode;
        if (len > 0) {
          canvas.drawRect(ui.Rect.fromLTRB(0, -r, len, r),
              paint..shader = ui.Gradient.linear(ui.Offset(0, -r), ui.Offset(0, r), across, aStops));
        }
        for (final (cx, side) in [(0.0, -1.0), (len, 1.0)]) {
          canvas.save();
          canvas.clipRect(side < 0 ? ui.Rect.fromLTRB(-r, -r, 0, r) : ui.Rect.fromLTRB(len, -r, len + r, r));
          canvas.drawCircle(ui.Offset(cx, 0), r,
              paint..shader = ui.Gradient.radial(ui.Offset(cx, 0), r, radial, rStops));
          canvas.restore();
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  // ============================================================
  // mask stack
  // ============================================================

  ui.Picture? _paintMaskStack(Project project, Layer layer,
      List<double> mCanvasTarget, int globalFrame) {
    final mr = layer.maskRegions;
    if (mr != null && mr.enabled && mr.sources.isNotEmpty) {
      return _paintMaskRegions(project, layer, mCanvasTarget, globalFrame);
    }
    final local = globalFrame - layer.startFrame;
    final enabled = layer.masks.where((mk) => mk.enabled && mk.activeAt(local)).toList();
    if (enabled.isEmpty) return null;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    final all = ui.Rect.fromLTWH(0, 0, _width, _height);
    // "not R": white over the whole picture, xor'd (1 - R).
    void flip() => canvas.drawRect(all, ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF)
      ..blendMode = ui.BlendMode.xor);
    for (var i = 0; i < enabled.length; i++) {
      final mk = enabled[i];
      // the first one starts from everything or from nothing (see
      // maskStartsFull) - the same logic as the outline's.
      if (i == 0 && maskStartsFull(mk.mode)) {
        canvas.drawRect(all, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      }
      // implication: not R, then S over it.
      if (mk.mode == 'implication') flip();
      // a picture among the sources: masks by its own alpha, not by its
      // rectangle - the coverage is drawn per pixel into a layer, which
      // then lands with the mode's blend.
      final pictures = [
        for (final id in mk.sourceIds)
          if (findLayer(project, id) case final s?
              when isMediaShape(s.content.shape) && _layerImage(s, globalFrame) != null)
            s
      ];
      if (pictures.isNotEmpty) {
        _paintPictureMask(canvas, project, layer, mCanvasTarget, mk, pictures, globalFrame, all);
        if (mk.mode == 'equivalence') flip();
        continue;
      }
      canvas.save();
      canvas.transform(_toMatrix4(mCanvasTarget));
      var projected =
          _buildMaskPath(project, layer, mCanvasTarget, mk, globalFrame);
      // intersect: dstIn only touches what the path covers - so cut away
      // everything outside S instead (dstOut of not S).
      final invertPath = mk.mode == 'intersect' ? !mk.invert : mk.invert;
      if (projected != null && invertPath) {
        projected = ui.Path()
          ..fillType = ui.PathFillType.evenOdd
          ..addRect(const ui.Rect.fromLTRB(-1e6, -1e6, 1e6, 1e6))
          ..addPath(projected, ui.Offset.zero);
      }
      if (projected != null) {
        final blendMode = switch (mk.mode) {
          'subtract' => ui.BlendMode.dstOut,
          'intersect' => ui.BlendMode.dstOut,
          'exclude' || 'equivalence' => ui.BlendMode.xor,
          _ => ui.BlendMode.srcOver,
        };
        // feather: this mask's own edge falloff, in the target's local
        // units (so it grows with the layer - the canvas transform scales
        // it once; it used to be multiplied by the scale again on top,
        // which made it grow with scale squared).
        final localFrame = math
            .min(layer.durationFrames,
                math.max(0, globalFrame - layer.startFrame))
            .toDouble();
        final featherPx =
            evaluateTrack(project, mk.feather, localFrame) as double;
        final deviceScale = math.sqrt((mCanvasTarget[0] * mCanvasTarget[3] -
                mCanvasTarget[2] * mCanvasTarget[1])
            .abs());
        if (featherPx > 0) {
          drawFeatheredPath(canvas, projected, featherPx, deviceScale == 0 ? 1.0 : deviceScale, blendMode,
              outside: mk.featherOutside);
        } else {
          canvas.drawPath(
              projected,
              ui.Paint()
                ..color = const ui.Color(0xFFFFFFFF)
                ..blendMode = blendMode);
        }
      }
      canvas.restore();
      // equivalence: not (R xor S).
      if (mk.mode == 'equivalence') flip();
    }
    return recorder.endRecording();
  }

  /// Mask regions: each region at its own opacity (keys, then the
  /// commands that fired). Sharp vector sources: the regions' own shapes
  /// (they don't overlap, so they add up exactly; a piece a command aims
  /// at by number is drawn on its own). Soft edges, see-through or
  /// picture sources: per pixel, visibility = sum over regions of
  /// opacity x product of (a or 1 - a) of each source's coverage a.
  /// Export: mask regions' episodes are baked in full now (on the stage
  /// the app bakes them a step at a time and the last bake is drawn).
  bool bakeRegionsNow = false;

  RegionBake _regionBake(Project project, Layer layer) =>
      bakeRegionsNow ? regionEpisodes(project, layer) : regionEpisodesReady(project, layer);

  ui.Picture? _paintMaskRegions(Project project, Layer layer, List<double> mCanvasTarget, int globalFrame) {
    final mr = layer.maskRegions!;
    final many = mr.sources.length > 3 && !mr.commands.any((c) => c.targetNumber != null);
    final geo = many && mr.commands.isEmpty ? null : maskRegionGeometry(project, layer, globalFrame);
    final bake = mr.commands.isNotEmpty && (geo != null || many) ? _regionBake(project, layer) : RegionBake.empty;
    // a cell of another shape (not this layer's ground): as it is.
    double opOf(int sig, [int? number]) => regionShownOpacity(project, layer, bake, sig, number, globalFrame);
    final sources = [for (final id in mr.sources) findLayer(project, id)];
    if (sources.any((l) => l == null)) return null;
    double alphaOf(Layer l) {
      final lf = layerLocalFrame(l, globalFrame);
      return (evaluateTrack(project, l.transform.opacity, lf, l) as num).toDouble().clamp(0.0, 1.0);
    }

    // many sources: per pixel on the GPU (the booleans of 4+ overlapping
    // shapes cost more than a frame).
    final soft = geo == null ||
        (sources.length > 3 && !mr.commands.any((c) => c.targetNumber != null)) ||
        [for (var i = 0; i < sources.length; i++) mr.featherOf(i) > 0 || alphaOf(sources[i]!) < 1].any((x) => x);
    // frame px -> this canvas.
    final m = matMul(mCanvasTarget, invertAffine(toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix)));
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.transform(_toMatrix4(m));
    ui.Path pathOf(List<List<List<double>>> rings) {
      final path = ui.Path();
      for (final r in rings) {
        if (r.length >= 3) path.addPolygon([for (final q in r) ui.Offset(q[0], q[1])], true);
      }
      return path;
    }

    if (!soft) {
      for (final g in geo) {
        if (g.rings.isEmpty) continue;
        if (regionHasPieceCommands(mr, g.sig)) {
          for (final (ep, piece) in bake.piecesAt(globalFrame)) {
            if (ep.sig != g.sig) continue;
            final op = opOf(g.sig, ep.numberAt(globalFrame));
            if (op > 0) canvas.drawPath(pathOf(piece), ui.Paint()..color = ui.Color.fromRGBO(255, 255, 255, op));
          }
          continue;
        }
        final op = opOf(g.sig);
        if (op > 0) canvas.drawPath(pathOf(g.rings), ui.Paint()..color = ui.Color.fromRGBO(255, 255, 255, op));
      }
      return recorder.endRecording();
    }
    // per pixel: each region is white, kept where every source is (or is
    // not) as its signature says - dstIn / dstOut of the source's
    // coverage over the whole canvas - and they add up (plus).
    final deviceScale = math.sqrt((m[0] * m[3] - m[1] * m[2]).abs());
    const big = ui.Rect.fromLTRB(-1e5, -1e5, 1e5, 1e5);
    void coverage(int i) {
      final src = sources[i]!;
      final st = getLayerStateAt(project, src.id, globalFrame);
      final alpha = alphaOf(src);
      canvas.saveLayer(null, ui.Paint()..color = ui.Color.fromRGBO(0, 0, 0, alpha));
      final rings = layerVectorRings(project, src, globalFrame);
      if (rings == null) {
        // a picture: its own alpha.
        final img = _layerImage(src, globalFrame);
        if (img != null) {
          canvas.save();
          canvas.transform(_toMatrix4(toFrameMatrix(st.matrix)));
          final c = src.content;
          canvas.drawImageRect(img, ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
              ui.Rect.fromCenter(center: ui.Offset(c.offset[0], c.offset[1]), width: c.size[0], height: c.size[1]),
              ui.Paint()..filterQuality = ui.FilterQuality.medium);
          canvas.restore();
        }
      } else {
        final mm = toFrameMatrix(st.matrix);
        final path = pathOf([
          for (final r in rings) [for (final q in r) applyAffine(mm, q)]
        ]);
        final f = mr.featherOf(i);
        if (f > 0) {
          drawFeatheredPath(canvas, path, f, deviceScale == 0 ? 1.0 : deviceScale, ui.BlendMode.srcOver);
        } else {
          canvas.drawPath(path, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
        }
      }
      canvas.restore();
    }

    for (var sig = 0; sig < mr.signatureCount; sig++) {
      final op = opOf(sig);
      if (op <= 0) continue;
      canvas.saveLayer(null, ui.Paint()
        ..color = ui.Color.fromRGBO(0, 0, 0, op)
        ..blendMode = ui.BlendMode.plus);
      canvas.drawRect(big, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
      for (var i = 0; i < sources.length; i++) {
        canvas.saveLayer(null, ui.Paint()..blendMode = (sig >> i) & 1 == 1 ? ui.BlendMode.dstIn : ui.BlendMode.dstOut);
        coverage(i);
        canvas.restore();
      }
      canvas.restore();
    }
    return recorder.endRecording();
  }

  /// A mask's shape in the target's space: all its sources together.
  // a picture source drawn for a mask (it may be masked itself).
  int _maskSourceDepth = 0;

  /// One mask whose sources include pictures: coverage = the vector
  /// sources' union plus each picture's alpha, inverted if asked,
  /// feathered by a blur, then combined with the mode's blend.
  void _paintPictureMask(ui.Canvas canvas, Project project, Layer layer, List<double> mCanvasTarget, Mask mk,
      List<Layer> pictures, int globalFrame, ui.Rect all) {
    final blendMode = switch (mk.mode) {
      'subtract' || 'intersect' => ui.BlendMode.dstOut,
      'exclude' || 'equivalence' => ui.BlendMode.xor,
      _ => ui.BlendMode.srcOver,
    };
    final localFrame = math.min(layer.durationFrames, math.max(0, globalFrame - layer.startFrame)).toDouble();
    final featherPx = (evaluateTrack(project, mk.feather, localFrame) as num).toDouble();
    final deviceScale = math.sqrt((mCanvasTarget[0] * mCanvasTarget[3] - mCanvasTarget[2] * mCanvasTarget[1]).abs());
    final sigma = featherPx * (deviceScale == 0 ? 1.0 : deviceScale) / 2;
    final layerPaint = ui.Paint()..blendMode = blendMode;
    if (sigma > 0.01) layerPaint.imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    canvas.saveLayer(null, layerPaint);
    canvas.save();
    canvas.transform(_toMatrix4(mCanvasTarget));
    final white = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
    final pictureIds = {for (final p in pictures) p.id};
    for (final id in mk.sourceIds) {
      if (pictureIds.contains(id)) continue;
      final p = _buildSourcePath(project, layer, mCanvasTarget, id, globalFrame,
          part: id == mk.sourceLayerId ? mk.sourcePart : null);
      if (p != null) canvas.drawPath(p, white);
    }
    canvas.restore();
    // each picture as it is drawn - its effects' deformation, crop, flip -
    // turned white by its alpha (any alpha at all: in full, when asked).
    for (final src in pictures) {
      if (_maskSourceDepth > 2) continue;
      final st = getLayerStateAt(project, src.id, globalFrame);
      final m = [st.matrix[0], st.matrix[1], st.matrix[2], st.matrix[3], st.matrix[4] * _width, st.matrix[5] * _height];
      canvas.saveLayer(
          null,
          ui.Paint()
            ..colorFilter = ui.ColorFilter.matrix(mk.coverAlpha
                ? const [0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 0, 255, 0]
                : const [0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 0, 0, 255, 0, 0, 0, 1, 0]));
      _maskSourceDepth++;
      try {
        _drawLayerInto(canvas, project, src, globalFrame, m, 1, 1);
      } finally {
        _maskSourceDepth--;
      }
      canvas.restore();
    }
    // intersect cuts away everything outside S (dstOut of not S).
    final invert = mk.mode == 'intersect' ? !mk.invert : mk.invert;
    if (invert) {
      canvas.drawRect(all, ui.Paint()
        ..color = const ui.Color(0xFFFFFFFF)
        ..blendMode = ui.BlendMode.xor);
    }
    canvas.restore();
  }

  ui.Path? _buildMaskPath(Project project, Layer targetLayer,
      List<double> mCanvasTarget, Mask mk, int globalFrame) {
    ui.Path? out;
    for (final id in mk.sourceIds) {
      final p = _buildSourcePath(project, targetLayer, mCanvasTarget, id, globalFrame,
          part: id == mk.sourceLayerId ? mk.sourcePart : null);
      if (p == null) continue;
      out = out == null ? p : ui.Path.combine(ui.PathOperation.union, out, p);
    }
    return out;
  }

  ui.Path? _buildSourcePath(Project project, Layer targetLayer,
      List<double> mCanvasTarget, String sourceId, int globalFrame, {int? part}) {
    final source = findLayer(project, sourceId);
    if (source == null) return null;
    final sourceState = getLayerStateAt(project, source.id, globalFrame);
    final mCanvasSource = [
      sourceState.matrix[0],
      sourceState.matrix[1],
      sourceState.matrix[2],
      sourceState.matrix[3],
      sourceState.matrix[4] * _width,
      sourceState.matrix[5] * _height,
    ];
    final rel = matMul(invertAffine(mCanvasTarget), mCanvasSource);
    // text / compound shapes mask by their letters (outlines with holes),
    // not by their box.
    final c = source.content;
    if (c.shape == 'text' && c.text != null) {
      final lf = layerLocalFrame(source, globalFrame);
      final t = c.text!.atFrame(lf);
      // one part of it, as it moves.
      if (part != null) return _pathFromCmds(textPartCmds(t, c.offset, c.size, lf, part)).transform(_toMatrix4(rel));
      final layout = layoutText(t, c.offset, c.size);
      final glyphs = _textPaths[layout] ??= _pathFromCmds(layout.path);
      return glyphs.transform(_toMatrix4(rel));
    }
    if (c.shape == 'compound' && c.contours != null) {
      final path = ui.Path();
      for (final ct in layerContours(source)) {
        if (ct.length < 3) continue;
        path.addPolygon([for (final p in ct) ui.Offset(p[0], p[1])], true);
      }
      return path.transform(_toMatrix4(rel));
    }
    final projected = [
      for (final p in getContentOutline(source.content, source, globalFrame, project: project))
        applyAffine(rel, p)
    ];
    if (projected.isEmpty) return null;
    return _pathFromPoints(projected, close: true);
  }

  // ============================================================
  // small helpers
  // ============================================================

  ui.Path _pathFromPoints(List<List<double>> pts, {bool close = false}) {
    final path = ui.Path()..moveTo(pts[0][0], pts[0][1]);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i][0], pts[i][1]);
    }
    if (close) path.close();
    return path;
  }

  /// "#rrggbb", or "#rrggbbaa" with its own alpha.
  ui.Color? _parseColor(String? hex) {
    if (hex == null) return null;
    final h = hex.replaceFirst('#', '');
    final v = int.tryParse(h, radix: 16);
    if (v == null) return null;
    if (h.length == 8) return ui.Color(((v & 0xFF) << 24) | (v >> 8));
    return ui.Color(0xFF000000 | v);
  }
}

/// Fills [path] white with a soft edge whose profile is a Gaussian blur of
/// the shape (sigma in the canvas's current units), combined onto the
/// canvas with [blend].
///
/// Built from geometry instead of a blur filter: the device's GPU blur
/// (downsampled, snapped to its own pixel grid) made the softness pulse
/// as the mask moved or turned. Here the falloff is a stack of strokes
/// around the outline - a stroke of width 2d covers everything within d
/// of the edge - so the result is plain anti-aliased vector drawing that
/// moves, turns and scales smoothly:
/// - inside: fill, then dstOut strokes from widest to narrowest dim the
///   band near the edge;
/// - outside: srcOver strokes from widest to narrowest build the glow.
/// One step per device pixel (4..48 steps over 3 sigma); each step's
/// 8-bit alpha rounding is fed back into the next, so it doesn't add up.
/// `outside` (0..1) limits how far the soft edge reaches past the outline:
/// the profile slides inward by (1 - outside) * 3 sigma, so at 0 nothing
/// shows outside the shape and the fade happens within it.
void drawFeatheredPath(ui.Canvas canvas, ui.Path path, double sigma, double deviceScale, ui.BlendMode blend,
    {double outside = 1}) {
  final shift = (1 - outside.clamp(0.0, 1.0)) * 3 * sigma;
  final extent = 3 * sigma + shift; // the deepest the fade reaches inside
  final extentOut = math.max(0.0, 3 * sigma - shift);
  final n = (extent * deviceScale).ceil().clamp(4, 64);
  final step = extent / n;
  double erfcHalf(double x) => 0.5 * _erfc(x / (sigma * math.sqrt2));
  // alpha at distance x OUTSIDE the outline, and at depth x INSIDE it.
  double f(double x) => x >= extentOut ? 0 : erfcHalf(x + shift);
  double inside(double x) => erfcHalf(shift - x);
  ui.Paint stroke(double width, double alpha, ui.BlendMode mode) => ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = ui.StrokeJoin.round
    ..strokeCap = ui.StrokeCap.round
    ..blendMode = mode
    ..color = ui.Color.fromARGB((alpha.clamp(0.0, 1.0) * 255).round(), 255, 255, 255);
  double q(double a) => (a.clamp(0.0, 1.0) * 255).round() / 255;

  canvas.saveLayer(null, ui.Paint()..blendMode = blend);
  canvas.drawPath(path, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  // inside: alpha at depth x should end up inside(x) once the outside
  // strokes (which also cover it) are on top: A = (in - f) / (1 - f).
  var kept = 1.0;
  for (var m = n; m >= 1; m--) {
    final x = (m - 0.5) * step;
    final fx = f(x);
    final target = ((inside(x) - fx) / (1 - fx)).clamp(0.0, 1.0);
    final cut = q(1 - target / kept);
    if (cut > 0) canvas.drawPath(path, stroke(2 * m * step, cut, ui.BlendMode.dstOut));
    kept *= 1 - cut;
  }
  var built = 0.0;
  for (var m = n; m >= 1; m--) {
    final target = f((m - 0.5) * step);
    final add = q((target - built) / (1 - built));
    if (add > 0) canvas.drawPath(path, stroke(2 * m * step, add, ui.BlendMode.srcOver));
    built = add + built * (1 - add);
  }
  canvas.restore();
}

/// complementary error function (Abramowitz & Stegun 7.1.26, |error| < 1.5e-7).
double _erfc(double x) {
  final z = x.abs();
  final t = 1 / (1 + 0.3275911 * z);
  final y = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429)))) *
      math.exp(-z * z);
  return x >= 0 ? y : 2 - y;
}

/// 2x3 affine [a,b,c,d,tx,ty] -> the 4x4 column-major matrix
/// Canvas.transform() expects.
Float64List _toMatrix4(List<double> m) {
  return Float64List.fromList([
    m[0],
    m[1],
    0,
    0,
    m[2],
    m[3],
    0,
    0,
    0,
    0,
    1,
    0,
    m[4],
    m[5],
    0,
    1,
  ]);
}

/// identity 4x4, for ImageShader's matrix param when no extra transform
/// beyond drawVertices' own positions is needed.
class Matrix4Identity {
  static Float64List get value => Float64List.fromList([
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
      ]);
}

/// PictureRecorder's optional cull rect - named for clarity at the call
/// site above.
ui.Rect stageCullRect(double width, double height) =>
    ui.Rect.fromLTWH(0, 0, width, height);
