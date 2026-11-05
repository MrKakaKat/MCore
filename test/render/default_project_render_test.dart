import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// the object on the stage is fully transparent / doesn't render at all -
/// blocking verification of everything else, so this is fixed first. No
/// existing pixel test ever checked the single most basic case: does
/// createDefaultProject's own default layer (default color, default opacity,
/// no effects, no motion blur) actually paint non-transparent pixels at all?
/// off_canvas_export_test.dart and motion_blur_test.dart both build custom
/// projects with deliberately unusual layers; neither establishes that the
/// BASELINE case ever worked.
///
/// This calls CanvasRenderer directly at an explicit, known-good size
/// (not through StageView's widget layout), to isolate whether the bug
/// is in canvas_renderer.dart's own paint logic or somewhere in the
/// widget/layout wiring around it (a real, separate suspect: stage_view.
/// dart's `_framedSized` locks CanvasRenderer's internal frame size to
/// whatever the FIRST LayoutBuilder pass measured, and never calls
/// setSize again for the life of that State - if that first layout pass
/// ever measures a degenerate size, this test's clean, explicit-size
/// call path wouldn't reproduce it, which would itself be informative).
void main() {
  test('createDefaultProject()\'s own default layer paints real, non-transparent pixels', () async {
    registerBuiltinEffects();
    final project = createDefaultProject();
    final renderer = CanvasRenderer();
    renderer.setSize(640, 400);

    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    expect(image.width, equals(640));
    expect(image.height, equals(400));

    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    var anyOpaque = false;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      if (bytes.getUint8(i) != 0) {
        anyOpaque = true;
        break;
      }
    }
    expect(anyOpaque, isTrue,
        reason: 'the default project ships one visible layer (object_a, color #d8d8d8, opacity 1.0, no effects) - '
            'if NOTHING in the whole frame is non-transparent, the render pipeline itself is broken, not just this one project');

    // object_a's own content is a 46x46 rect centered on its own anchor,
    // which (via its parent rig L_parent's anchor [0.5, 0.55], child
    // anchor [0,0] i.e. exactly at the parent's own position) should
    // land at world (0.5*640, 0.55*400) = (320, 220) - probe there
    // directly rather than only checking "something, somewhere" painted.
    final cx = (0.5 * 640).round(), cy = (0.55 * 400).round();
    final i = (cy * 640 + cx) * 4;
    expect(bytes.getUint8(i + 3), equals(0xFF), reason: 'object_a\'s own footprint, at its expected world position, should be fully opaque');
    expect(bytes.getUint8(i), equals(0xd8), reason: 'R channel should match object_a\'s own color #d8d8d8');
    expect(bytes.getUint8(i + 1), equals(0xd8), reason: 'G channel should match object_a\'s own color #d8d8d8');
    expect(bytes.getUint8(i + 2), equals(0xd8), reason: 'B channel should match object_a\'s own color #d8d8d8');
  });
}
