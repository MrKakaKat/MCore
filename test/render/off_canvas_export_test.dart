import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Real, run verification of the gesture spec addendum's "required
/// test, not a visual check" for off-canvas interaction: an object (or
/// a handle-driven deformation) positioned via the stage's own new
/// off-canvas capability must still export strictly bounded to the true
/// frame - not larger, and not corrupted for in-frame content drawn
/// alongside it. Previously this session only asserted the underlying
/// MATRIX math stays finite (drag_ops_test.dart, pure Dart) - these
/// tests go one level further and actually render + capture a frame via
/// CanvasRenderer, the real code path canvas_renderer.dart's own
/// buildGrid/applyEffectStack/drawVertices calls run through, which the
/// matrix-only test never exercised.
///
/// Made possible by this session's own flutter test feasibility spike
/// (smoke_test.dart) - `flutter test` runs real dart:ui headlessly, no
/// device/emulator needed, contrary to this whole port's earlier
/// assumption that render/ui code was categorically unverifiable here.
void main() {
  Project buildProject() {
    final p = createDefaultProject();
    // drop the stock layers' preset content in favor of controlled ones
    p.layers.clear();
    return p;
  }

  test('an anchor dragged far off-canvas exports a fully transparent frame, at exactly the requested size', () async {
    registerBuiltinEffects();
    final project = buildProject();
    final renderer = CanvasRenderer();
    renderer.setSize(64, 40); // small on purpose - cheap to sample every pixel

    final layer = createLayer('rect');
    layer.color = '#ff0000';
    project.layers.add(layer);

    // drag it via the SAME AnchorDragOp this session already tested at
    // the data level (drag_ops_test.dart), not a hand-set value -
    // landing it 50 frame-widths away, deep off-canvas.
    final grab = AnchorDragOp.grab(project, layer, 0, [32.0, 20.0]); // grab exactly on the default anchor (center)
    grab.apply(project, 0, [32.0 + 50 * 64, 20.0]);
    expect(layer.transform.anchor.defaultValue[0], greaterThan(10)); // sanity: actually moved off-canvas

    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    expect(image.width, equals(64));
    expect(image.height, equals(40));

    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    // nothing on-screen should be visible anywhere in the frame - the
    // only layer that exists is entirely off-canvas, so every pixel
    // must be fully transparent (alpha=0). A NaN-poisoned paint state
    // or a leaked off-canvas raster would show up here as SOME non-
    // zero alpha pixel somewhere in the frame.
    var anyOpaque = false;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      if (bytes.getUint8(i) != 0) {
        anyOpaque = true;
        break;
      }
    }
    expect(anyOpaque, isFalse, reason: 'an entirely off-canvas layer must not paint anything into the exported frame');
  });

  test('a moderately off-canvas mesh-warp pin on a non-rect shape (the drawVertices path) renders cleanly and doesn\'t blank an unrelated in-frame sibling', () async {
    registerBuiltinEffects();
    final project = buildProject();
    final renderer = CanvasRenderer();
    renderer.setSize(64, 40);

    // layer A: a small control rect tucked in a corner FAR from where
    // layer B (below) sits or could plausibly stretch to - the point
    // of sampling it is "did something elsewhere in the pipeline go
    // wrong and blank/corrupt the whole frame," not "predict B's exact
    // deformed footprint," which isn't practical to hand-derive for a
    // warped quad.
    final layerA = createLayer('rect');
    layerA.name = 'control';
    layerA.color = '#00ff00';
    layerA.transform.anchor.defaultValue = [0.05, 0.05];
    layerA.content = Content(shape: 'rect', offset: [0, 0], size: [6, 6]);
    project.layers.add(layerA);

    // layer B: a CIRCLE (non-rect) with mesh-warp active - unlike a
    // rect (which always fills its deformed grid directly, see
    // _drawLayerInto's own isTextured condition), a non-rect shape
    // under an active effect routes through the textured path:
    // _rasterizeShapeSilhouette -> buildGrid -> applyEffectStack ->
    // _drawWarpedGrid's Canvas.drawVertices with UV coordinates derived
    // from the pin offset - the actual riskiest numeric path for
    // extreme/off-canvas pin values, and the one this test means to
    // exercise for real. Offset is moderate (well outside the shape's
    // own ~46px silhouette, but not so extreme the deformed quad could
    // plausibly sweep all the way to layer A's corner) so the test
    // stays meaningful without requiring exact footprint prediction.
    final layerB = createLayer('circle');
    layerB.name = 'warped';
    layerB.color = '#0000ff';
    layerB.transform.anchor.defaultValue = [0.7, 0.7];
    project.layers.add(layerB);
    final inst = createEffectInstance('mesh_warp', 'fx1', layerB);
    layerB.effectStack.add(inst);
    final mesh = getMeshWarpHandles(project, layerB, inst, 0);
    final r0c0 = mesh.handles.firstWhere((h) => h.key == 'r0c0');
    final dragOp = MeshDragOp(layer: layerB, inst: inst, pinKey: 'r0c0', natural: r0c0.natural);
    dragOp.apply(project, 0, [r0c0.screen[0] + 200, r0c0.screen[1] - 200]);

    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    expect(image.width, equals(64));
    expect(image.height, equals(40));

    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    // layer A's own corner must still show its exact opaque green -
    // proof the off-canvas-pinned sibling didn't corrupt or blank
    // unrelated, spatially-separate parts of the same captured frame.
    final ax = (0.05 * 64).round(), ay = (0.05 * 40).round();
    final aIndex = (ay * 64 + ax) * 4;
    expect(bytes.getUint8(aIndex), equals(0x00)); // R
    expect(bytes.getUint8(aIndex + 1), equals(0xFF)); // G
    expect(bytes.getUint8(aIndex + 2), equals(0x00)); // B
    expect(bytes.getUint8(aIndex + 3), equals(0xFF)); // A

    // and the capture as a whole isn't degenerately blank (i.e. the
    // warp didn't silently fail to draw anything at all) - some pixel
    // beyond layer A's own footprint should be non-transparent too.
    var anyOtherOpaque = false;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      final pixel = i ~/ 4;
      final px = pixel % 64, py = pixel ~/ 64;
      if ((px - ax).abs() < 5 && (py - ay).abs() < 5) continue; // skip layer A's own known footprint
      if (bytes.getUint8(i) != 0) {
        anyOtherOpaque = true;
        break;
      }
    }
    expect(anyOtherOpaque, isTrue, reason: 'the warped layer should still paint SOMETHING - a fully blank result beyond layer A would mean the warp silently failed');
  });
}
