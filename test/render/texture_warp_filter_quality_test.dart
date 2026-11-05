import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// a shape with an active vertex-deformation effect (squeeze/bend/mesh_warp -
/// anything routing through canvas_renderer. dart's `_drawWarpedGrid`
/// texture-warp path) "turned into pixels" - visibly blocky instead of staying
/// vector-crisp, especially once scaled up. Root cause confirmed by reading
/// `_drawWarpedGrid`: its `Paint` never sets `filterQuality`, defaulting to
/// `FilterQuality. none` (nearest-neighbor texture sampling) - fixed by
/// setting it to `.medium` (bilinear).
///
/// This proves the fix at the pixel level: nearest-neighbor sampling of
/// a magnified texture produces contiguous RUNS of identical alpha
/// values (a "staircase" - each source texel repeats across several
/// destination pixels before jumping to the next), while bilinear
/// sampling interpolates continuously, so the alpha value changes at
/// (almost) every destination pixel instead. Probes a scanline crossing
/// a heavily-scaled circle's soft edge and asserts no long run of
/// identical alpha values survives - a real regression check, not a
/// visual eyeball comparison.
void main() {
  test('a heavily-scaled, effect-deformed shape\'s edge is smoothly bilinear-filtered, not a nearest-neighbor staircase', () async {
    registerBuiltinEffects();
    final layer = Layer(
      id: 'L1',
      name: 'circle',
      transform: Transform(
        anchor: track([0.5, 0.5]),
        scale: track([8.0, 8.0]), // heavy magnification - blows up any per-source-texel sampling artifact
        rotation: track(0.0),
        opacity: track(1.0),
      ),
      // non-rect shape: rect content skips the texture-warp path
      // entirely (canvas_renderer.dart draws it as plain vector quads
      // regardless of any active effect) - circle always routes through
      // _drawWarpedGrid once an effect is enabled, which is what this
      // test needs to exercise.
      content: Content(shape: 'circle', offset: [0, 0], size: [46, 46]),
      color: '#ffffff',
    );
    // squeeze_axis's default params (axisX=axisY=1) are a geometric
    // no-op - deliberately so, since this test is about texture
    // FILTERING, not about the deformation itself; merely having an
    // enabled effect instance is what routes rendering through the
    // texture-warp path at all.
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));

    final project = Project(layers: [layer]);
    final renderer = CanvasRenderer();
    renderer.setSize(640, 400);
    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    // circle center lands at (0.5*640, 0.5*400) = (320, 200); radius
    // 23*8 = 184 -> right edge around x=504. Scan a window straddling it.
    const centerX = 320, centerY = 200;
    final alphas = <int>[];
    for (var x = centerX + 160; x <= centerX + 210; x++) {
      final i = (centerY * 640 + x) * 4;
      alphas.add(bytes.getUint8(i + 3));
    }

    // must actually cross the edge (both fully-opaque and fully-
    // transparent samples present), otherwise the scan window missed it.
    expect(alphas.first, equals(0xFF), reason: 'scan window must start inside the opaque circle');
    expect(alphas.last, equals(0), reason: 'scan window must end outside the circle, in the transparent background');

    // longest run of consecutive IDENTICAL alpha values strictly between
    // the fully-opaque and fully-transparent plateaus - nearest-neighbor
    // sampling of an ~8x-magnified texture would produce runs around 8px
    // wide at each intermediate alpha level; bilinear changes almost
    // every pixel, so the longest such run should be short.
    var longestMidRun = 0, currentRun = 0;
    for (var i = 1; i < alphas.length; i++) {
      final a = alphas[i];
      if (a == 0 || a == 0xFF) {
        currentRun = 0;
        continue;
      }
      currentRun = (alphas[i - 1] == a) ? currentRun + 1 : 1;
      if (currentRun > longestMidRun) longestMidRun = currentRun;
    }
    expect(longestMidRun, lessThan(4),
        reason: 'a run of $longestMidRun consecutive identical intermediate-alpha pixels looks like nearest-neighbor '
            'staircasing, not bilinear filtering - filterQuality regressed back to FilterQuality.none');
  });
}
