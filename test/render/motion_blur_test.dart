import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Real, run pixel-level verification of motion blur's isolated
/// accumulation buffer - the last "reasoned about, never rasterized"
/// spot in the whole project. `canvas_renderer.dart`'s `_drawLayer`
/// opens a private `canvas.saveLayer` BEFORE the sample loop, blends
/// every motion-blur sample into THAT via `BlendMode.plus`, and only
/// flattens the finished accumulation onto the real destination once,
/// via plain `srcOver` (see the file's own doc comment + the inline
/// comment at that saveLayer call). The claim has stood since this
/// session brought JS's own `renderLayer.js` into line with the same
/// isolated-buffer approach - but nothing before this test actually
/// RAN it: a bug that let a sample's additive blend touch the real
/// canvas directly (skipping the isolation) would look identical on
/// casual code reading, since the accumulation buffer and the direct
/// canvas are both `ui.Canvas` objects passed around the same call
/// chain. Same technique as stage_painter_test.dart/
/// off_canvas_export_test.dart: real CanvasRenderer, real toImage(),
/// real pixel bytes - no widget pump, no device.
///
/// Expected values below are hand-derived from Skia's premultiplied
/// BlendMode.plus + srcOver math, not guessed:
///   - accumulation buffer starts transparent; a single opaque white
///     sample drawn at weight 0.5 (1/validSamples) via BlendMode.plus
///     leaves that buffer at premultiplied (0.5,0.5,0.5,0.5) wherever
///     only that one sample's footprint lands.
///   - flattening that onto an opaque (160,160,160) background via
///     normal srcOver: 0.5 + 0.6275*(1-0.5) = 0.81375 -> ~207.5/255.
///   - the LEAKY alternative (each sample additively blended straight
///     onto the real canvas, skipping isolation) would instead clamp
///     to min(0.5+0.6275, 1) = opaque WHITE (255) at that same pixel -
///     a large, easy-to-distinguish gap from the correct ~207.5.
void main() {
  const width = 200.0, height = 150.0;

  test('motion blur\'s additive accumulation stays isolated - it never bleeds into the background or a neighboring layer', () async {
    registerBuiltinEffects();
    final project = Project();
    final renderer = CanvasRenderer();
    renderer.setSize(width, height);

    // background: opaque, non-black, uniform-channel gray covering the
    // whole frame - any additive leak at a probed pixel shows up as a
    // clean per-channel deviation from this known value, not swallowed
    // by a coincidental channel overlap the way a saturated color could.
    final background = createLayer('rect');
    background.color = '#a0a0a0';
    background.transform.anchor.defaultValue = [0.5, 0.5];
    background.content = Content(shape: 'rect', offset: [0, 0], size: [width, height]);
    project.layers.add(background);

    // foreground: small opaque-white rect, motion blur enabled with
    // just 2 samples and a wide (720 deg = 2 full frames) shutter, so
    // the two samples land far enough apart (frames 9 and 11, around
    // the rendered frame 10) that their 10x10 footprints don't overlap
    // at all - each probed pixel is then covered by EXACTLY one sample,
    // which is what makes the hand-derived expected value above exact
    // rather than a sum of multiple overlapping contributions.
    final foreground = createLayer('rect');
    foreground.color = '#ffffff';
    foreground.content = Content(shape: 'rect', offset: [0, 0], size: [10, 10]);
    foreground.motionBlur = MotionBlur(enabled: true, shutterAngle: 720, samples: 2);
    foreground.transform.anchor.spatial = true;
    foreground.transform.anchor.keyframes.addAll([
      Keyframe(frame: 9, value: [0.2, 0.5]),
      Keyframe(frame: 11, value: [0.8, 0.5]),
    ]);
    project.layers.add(foreground);

    renderer.renderFrame(project, 10);
    final image = await renderer.captureFrame();
    expect(image.width, equals(width.round()));
    expect(image.height, equals(height.round()));

    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int idx(int x, int y) => (y * width.round() + x) * 4;

    // sample 0's own footprint center: anchor (0.2*200, 0.5*150) = (40,75)
    // sample 1's own footprint center: anchor (0.8*200, 0.5*150) = (160,75)
    // each is covered by exactly one sample - see the header comment for
    // the exact expected value's derivation.
    for (final probe in [(40, 75), (160, 75)]) {
      final i = idx(probe.$1, probe.$2);
      expect(bytes.getUint8(i), closeTo(207.5, 15), reason: 'R at ${probe.$1},${probe.$2} - isolated blend, not a leaky additive one');
      expect(bytes.getUint8(i + 1), closeTo(207.5, 15), reason: 'G at ${probe.$1},${probe.$2}');
      expect(bytes.getUint8(i + 2), closeTo(207.5, 15), reason: 'B at ${probe.$1},${probe.$2}');
      expect(bytes.getUint8(i + 3), equals(0xFF), reason: 'A at ${probe.$1},${probe.$2} - fully opaque once flattened onto an opaque background');
    }

    // untouched background pixel, well clear of either sample's 10x10
    // footprint (spans x:35-45 and x:155-165) - must be exactly the
    // background color, proving the blur didn't spill sideways either.
    final untouched = idx(100, 75);
    expect(bytes.getUint8(untouched), equals(0xa0));
    expect(bytes.getUint8(untouched + 1), equals(0xa0));
    expect(bytes.getUint8(untouched + 2), equals(0xa0));
    expect(bytes.getUint8(untouched + 3), equals(0xFF));
  });
}
