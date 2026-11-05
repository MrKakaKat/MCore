import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

/// Real, run coverage of the pointer state machine - previously flagged
/// as unverifiable (no device/emulator here), which turned out to be
/// wrong: `flutter test` drives this directly with synthetic
/// PointerDownEvent/PointerMoveEvent/PointerUpEvent (constructible with
/// a plain `pointer` id + `position`, no widget pump or real display
/// needed - `localPosition` defaults to `position` with no transform
/// applied, confirmed against the Flutter SDK's own PointerEvent
/// source). This is exactly the class of stateful, order-dependent code
/// this session already found real bugs in twice (motion-blur
/// compositing, the reparent cache) - worth actually running rather
/// than leaving as reviewed-but-never-executed.
void main() {
  late AppState app;
  late StageCamera camera;
  late StageGestureController controller;
  late Layer layer;
  int repaintCount = 0;

  setUp(() {
    setStageSize(640, 400);
    hideHandles = false;
    hideVisualLayer = false;
    registerBuiltinEffects();
    repaintCount = 0;

    app = AppState();
    setStageSize(640, 400); // AppState()'s own constructor re-applies its default frame size (480x480) via renderer.setSize - reassert this file's own 640x400 pixel math after construction, not before.
    app.project.layers.clear();
    layer = createLayer('rect');
    app.project.layers.add(layer);
    app.selection.selectedLayer = layer.id;

    camera = StageCamera();
    controller = StageGestureController(app: app, camera: camera, onNeedsRepaint: () => repaintCount++);
  });

  PointerDownEvent down(int pointer, double x, double y) => PointerDownEvent(pointer: pointer, position: Offset(x, y));
  PointerMoveEvent move(int pointer, double x, double y) => PointerMoveEvent(pointer: pointer, position: Offset(x, y));
  PointerUpEvent up(int pointer, double x, double y) => PointerUpEvent(pointer: pointer, position: Offset(x, y));

  group('magnet-capture priority', () {
    test('corner-pin beats transform-box when both are within range, matching JS\'s own tier order', () {
      final inst = createEffectInstance('corner_pin', 'fx1', layer);
      layer.effectStack.add(inst);
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final cp = getCornerPinHandles(app.project, layer, inst, 0);
      // corner-pin's own tl handle and the transform box's moveCorner
      // both exist on this layer at once - tap near corner-pin's tl,
      // well within both handles' hit radius, corner-pin must win.
      final p = cp.screen['tl']!;
      expect((Offset(p[0], p[1]) - Offset(tb.screen['moveCorner']![0], tb.screen['moveCorner']![1])).distance, lessThan(32),
          reason: 'test setup sanity: the two handles need to be close enough that priority, not distance alone, decides it');

      controller.onPointerDown(down(1, p[0], p[1]));
      expect(controller.activeDrag, isNotNull);
      expect(controller.activeDrag!.family, equals('cornerPin'));
    });

    test('transform-box move handle is captured when no corner-pin/mesh-warp is active', () {
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final p = tb.screen['moveCorner']!;
      controller.onPointerDown(down(1, p[0], p[1]));
      expect(controller.activeDrag, isNotNull);
      expect(controller.activeDrag!.family, equals('transformBox'));
      expect(controller.activeDrag!.activeKey, equals('moveCorner'));
    });

    test('hideHandles=true skips the entire magnet-capture tier - nothing is ever captured', () {
      hideHandles = true;
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final p = tb.screen['moveCorner']!;
      controller.onPointerDown(down(1, p[0], p[1]));
      expect(controller.activeDrag, isNull);
    });

    test('nothing within radius of any handle falls through to a tap-select candidate, not a capture', () {
      controller.onPointerDown(down(1, 5.0, 5.0)); // far corner, nowhere near any handle
      expect(controller.activeDrag, isNull);
    });
  });

  group('handle capture under a non-identity camera (pan/zoom applied)', () {
    // on a physical phone in landscape, the scale handle captured correctly
    // but the move/anchor handle didn't - every test above only ever used the
    // DEFAULT StageCamera, i.e. pan=(0,0), scale=1 - a real,
    // previously-unexamined gap, since pan/zoom is exactly the new feature
    // this bug report is about. A touch happens in SCREEN space;
    // tb.screen[key] (despite its name) is FRAME space - camera.frameToScreen
    // is the one correct way to get the real on-screen point a finger would
    // actually land on, the same conversion _tryCaptureHandle's own
    // camera.screenToFrame is meant to invert. Using tb.screen[key] directly
    // here (screen == frame only by coincidence at pan=0/scale=1) would
    // silently make this test worthless the moment it stopped being identity.
    test('moveCorner still captures at its real on-screen position after pan+zoom', () {
      camera.scale = 2.4;
      camera.pan = const Offset(137, 58);
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final framePt = tb.screen['moveCorner']!;
      final onScreen = camera.frameToScreen(Offset(framePt[0], framePt[1]));

      controller.onPointerDown(down(1, onScreen.dx, onScreen.dy));
      expect(controller.activeDrag, isNotNull, reason: 'moveCorner should be reachable at the same touch radius under zoom/pan as at identity');
      expect(controller.activeDrag!.family, equals('transformBox'));
      expect(controller.activeDrag!.activeKey, equals('moveCorner'));
    });

    test('scaleCorner still captures at its real on-screen position after pan+zoom - same camera as the moveCorner case above', () {
      camera.scale = 2.4;
      camera.pan = const Offset(137, 58);
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final framePt = tb.screen['scaleCorner']!;
      final onScreen = camera.frameToScreen(Offset(framePt[0], framePt[1]));

      controller.onPointerDown(down(1, onScreen.dx, onScreen.dy));
      expect(controller.activeDrag, isNotNull);
      expect(controller.activeDrag!.family, equals('transformBox'));
      expect(controller.activeDrag!.activeKey, equals('scaleCorner'));
    });

    test('a touch at the FRAME-space coordinate (not converted through the camera) misses once pan/zoom is non-trivial - guards against silently reintroducing the identity-only blind spot', () {
      camera.scale = 2.4;
      camera.pan = const Offset(137, 58);
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final framePt = tb.screen['moveCorner']!;

      // touching the RAW frame-space number, as if the camera didn't
      // exist - should now land far from the handle's actual on-screen
      // spot and miss entirely.
      controller.onPointerDown(down(1, framePt[0], framePt[1]));
      expect(controller.activeDrag, isNull);
    });
  });

  group('captured drag actually mutates the underlying data', () {
    test('dragging the move handle moves the layer\'s anchor by the pointer\'s own delta', () {
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final p = tb.screen['moveCorner']!;
      final before = List<double>.from(layer.transform.anchor.defaultValue as List<double>);

      controller.onPointerDown(down(1, p[0], p[1]));
      controller.onPointerMove(move(1, p[0] + 64, p[1] + 40)); // +0.1,+0.1 in frame-fraction terms

      final after = layer.transform.anchor.defaultValue as List<double>;
      expect(after[0], closeTo(before[0] + 0.1, 1e-9));
      expect(after[1], closeTo(before[1] + 0.1, 1e-9));
      expect(repaintCount, greaterThan(0));
    });

    test('releasing the pointer ends the drag and clears activeDrag', () {
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final p = tb.screen['moveCorner']!;
      controller.onPointerDown(down(1, p[0], p[1]));
      expect(controller.activeDrag, isNotNull);
      controller.onPointerUp(up(1, p[0], p[1]));
      expect(controller.activeDrag, isNull);
    });
  });

  group('sibling-hide bookkeeping (via activeDrag.family/activeKey - stage_painter.dart reads these directly)', () {
    test('capturing one mesh-warp pin reports that exact pin as the active key', () {
      final inst = createEffectInstance('mesh_warp', 'fx1', layer);
      layer.effectStack.add(inst);
      final mesh = getMeshWarpHandles(app.project, layer, inst, 0);
      final target = mesh.handles.firstWhere((h) => h.key == 'r2c1');

      controller.onPointerDown(down(1, target.screen[0], target.screen[1]));
      expect(controller.activeDrag!.family, equals('meshWarp'));
      expect(controller.activeDrag!.activeKey, equals('r2c1'));
    });
  });

  group('tap-to-select', () {
    test('a short tap directly on the layer selects it, unaffected by hideHandles', () {
      hideHandles = true; // tap-to-select must work regardless - it is not a "handle"
      app.selection.selectedLayer = null;
      final state = getLayerStateAt(app.project, layer.id, 0);
      final cx = state.matrix[4] * 640, cy = state.matrix[5] * 400; // layer's own center, well within its 46x46 body

      controller.onPointerDown(down(1, cx, cy));
      controller.onPointerUp(up(1, cx, cy));
      expect(app.selection.selectedLayer, equals(layer.id));
    });

    test('a tap that moves past the movement threshold before release is NOT treated as a tap', () {
      app.selection.selectedLayer = null;
      final state = getLayerStateAt(app.project, layer.id, 0);
      final cx = state.matrix[4] * 640, cy = state.matrix[5] * 400;

      controller.onPointerDown(down(1, cx, cy));
      controller.onPointerMove(move(1, cx + 50, cy + 50)); // well past the 8px threshold, and off the layer entirely
      controller.onPointerUp(up(1, cx + 50, cy + 50));
      expect(app.selection.selectedLayer, isNull);
    });
  });

  group('combined pinch + pan (two-finger, addendum-specified)', () {
    test('pinching apart zooms in and pinch/pan starts only once a 2nd finger joins with nothing captured', () {
      controller.onPointerDown(down(1, 100.0, 100.0));
      expect(controller.activeDrag, isNull); // nothing there to capture - pending tap candidate only

      controller.onPointerDown(down(2, 200.0, 100.0)); // 2nd finger joins - cancels the tap, starts pinch tracking
      final scaleBefore = camera.scale;

      // spread the two fingers apart (pinch out / zoom in), same midpoint.
      controller.onPointerMove(move(1, 80.0, 100.0));
      controller.onPointerMove(move(2, 220.0, 100.0));

      expect(camera.scale, greaterThan(scaleBefore));
    });

    test('a second touch during an ACTIVE drag is ignored outright, never starts a pinch', () {
      final tb = getTransformBoxHandles(app.project, layer, 0);
      final p = tb.screen['moveCorner']!;
      controller.onPointerDown(down(1, p[0], p[1]));
      expect(controller.activeDrag, isNotNull);

      final scaleBefore = camera.scale;
      controller.onPointerDown(down(2, 300.0, 300.0));
      controller.onPointerMove(move(2, 350.0, 350.0));
      expect(camera.scale, equals(scaleBefore)); // untouched - pointer 2 was never tracked at all
      expect(controller.activeDrag, isNotNull); // pointer 1's drag is still the only thing active
    });
  });

  test('crop editing: the crop handles are captured instead of the transform box, and dragging crops', () {
    cropEditing = true;
    addTearDown(() => cropEditing = false);
    final h = getCropHandles(app.project, layer, 0);
    final p = h.screen['right']!;
    controller.onPointerDown(down(1, p[0], p[1]));
    expect(controller.activeDrag?.family, equals('crop'));
    expect(controller.activeDrag?.activeKey, equals('right'));

    final box = shapeBoundingBox(layer.content);
    final halfWidth = (box.maxX - box.minX) / 2;
    controller.onPointerMove(move(1, p[0] - halfWidth, p[1]));
    controller.onPointerUp(up(1, p[0] - halfWidth, p[1]));
    expect(layer.crop[2], closeTo(0.5, 0.02));
  });

  test('3D Rotate: its pivot handle is captured and dragging moves the pivot', () {
    final inst = createEffectInstance('rotate_3d', 'fx3d', layer);
    layer.effectStack.add(inst);
    final h = getRotate3dPivotHandle(app.project, layer, inst, 0);
    final p = camera.frameToScreen(Offset(h.screen[0], h.screen[1]));
    controller.onPointerDown(down(1, p.dx, p.dy));
    expect(controller.activeDrag?.family, 'rotate3dPivot');

    final box = shapeBoundingBox(layer.content);
    final corner = camera.frameToScreen(Offset(h.screen[0] + (box.maxX - box.minX) / 2, h.screen[1]));
    controller.onPointerMove(move(1, corner.dx, corner.dy));
    controller.onPointerUp(up(1, corner.dx, corner.dy));
    final pivot = (inst.params['pivot'] as Track).defaultValue as List<double>;
    expect(pivot[0], closeTo(1.0, 0.02));
    expect(pivot[1], closeTo(0.5, 0.02));
  });
}
