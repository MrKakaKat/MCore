import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';

/// the same project, viewed once in portrait and once in landscape, showed the
/// same layer (anchor -0.136/-0.309) at two DIFFERENT physical positions - the
/// frame's own coordinate system was drifting with device rotation instead of
/// staying fixed. Root cause: stage_view.dart used to call
/// CanvasRenderer.setSize from the widget's OWN layout size (see its and
/// stage_camera.dart's doc comments for the full history - this went through
/// two rounds: first locking onto a degenerate size and never updating, then
/// still re-locking on any rotation that swapped which branch of a responsive
/// layout was picked). The fix: the render frame is now a FIXED constant
/// (AppState.frameWidth/frameHeight, 640x400) never touched by any widget, and
/// StageCamera letterboxes that fixed frame into whatever viewport is current
/// via a BoxFit.contain fit layer, recomputed fresh every paint.
///
/// stage_camera_test.dart already proves this at the pure-math level;
/// this test proves it with REAL rendered pixels, the same
/// CanvasRenderer + paintStage + toImage technique already used by
/// stage_painter_test.dart/off_canvas_export_test.dart - a real object,
/// actually painted twice at two very differently-shaped viewport
/// sizes (simulating portrait vs landscape), same underlying
/// CanvasRenderer picture both times (produced once, at the FIXED
/// frame size, completely independent of either viewport - exactly
/// mirroring how the real render pipeline works).
void main() {
  const frameWidth = 640.0, frameHeight = 400.0; // AppState.frameWidth/frameHeight

  test('the same anchor lands at the same proportional position of the letterboxed frame in both a portrait-shaped and a landscape-shaped viewport', () async {
    registerBuiltinEffects();
    final project = Project();
    final layer = createLayer('rect');
    layer.color = '#ff4488';
    layer.transform.anchor.defaultValue = [0.7, 0.3]; // arbitrary, off-center
    layer.content = Content(shape: 'rect', offset: [0, 0], size: [16, 16]); // small, precise probe target
    project.layers.add(layer);

    final renderer = CanvasRenderer();
    renderer.setSize(frameWidth, frameHeight); // the FIXED frame - set once, same for every viewport below
    renderer.renderFrame(project, 0);
    final contentPicture = renderer.currentPicture;
    expect(contentPicture, isNotNull);

    Future<ByteData> renderAt(ui.Size viewport) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, ui.Offset.zero & viewport);
      paintStage(
        canvas: canvas,
        size: viewport,
        contentPicture: contentPicture,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        project: project,
        selectedLayer: null, // no handles/path visuals - isolates this test to the rendered CONTENT's own position
        globalFrame: 0,
        camera: StageCamera(),
        activeDrag: null,
      );
      final image = await recorder.endRecording().toImage(viewport.width.round(), viewport.height.round());
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }

    const portrait = ui.Size(360, 800);
    const landscape = ui.Size(800, 360);
    final portraitBytes = await renderAt(portrait);
    final landscapeBytes = await renderAt(landscape);

    // independently computed expected screen position for each
    // viewport - a SEPARATE StageCamera from the one paintStage used
    // internally, so this isn't just checking the code agrees with
    // itself.
    ui.Offset expectedScreenPos(ui.Size viewport) {
      final cam = StageCamera()..updateLayout(frame: const ui.Size(frameWidth, frameHeight), viewport: viewport);
      return cam.frameToScreen(const ui.Offset(0.7 * frameWidth, 0.3 * frameHeight));
    }

    bool colorPresentNear(ByteData bytes, ui.Size viewport, ui.Offset pos, {int radius = 3}) {
      final cx = pos.dx.round(), cy = pos.dy.round();
      for (var dy = -radius; dy <= radius; dy++) {
        for (var dx = -radius; dx <= radius; dx++) {
          final px = cx + dx, py = cy + dy;
          if (px < 0 || py < 0 || px >= viewport.width || py >= viewport.height) continue;
          final i = (py * viewport.width.round() + px) * 4;
          // #ff4488 = (255, 68, 136)
          if ((bytes.getUint8(i) - 0xff).abs() <= 4 && (bytes.getUint8(i + 1) - 0x44).abs() <= 4 && (bytes.getUint8(i + 2) - 0x88).abs() <= 4) {
            return true;
          }
        }
      }
      return false;
    }

    expect(colorPresentNear(portraitBytes, portrait, expectedScreenPos(portrait)), isTrue,
        reason: 'the layer\'s own color should appear at its expected letterboxed position in the PORTRAIT-shaped viewport');
    expect(colorPresentNear(landscapeBytes, landscape, expectedScreenPos(landscape)), isTrue,
        reason: 'the layer\'s own color should appear at its expected letterboxed position in the LANDSCAPE-shaped viewport - '
            'same anchor, same underlying picture, only the viewport SHAPE differs. A regression of the orientation-drift bug '
            'would make this fail while the portrait case above still passes (or vice versa), since the two viewports use '
            'very different fitScale/fitOffset values - a coincidental identity match wouldn\'t hide a real bug here.');
  });
}
