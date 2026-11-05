import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';

void main() {
  test('tapping the same spot picks the top region, then the one under it, round and round', () {
    final app = AppState();
    setStageSize(400, 400);
    clearStateCaches();
    clearRegionBakes();
    Layer sq(String id, double x, List<String> srcs) => createLayer('rect')
      ..id = id
      ..name = id.toUpperCase()
      ..content.size = [160, 160]
      ..transform.anchor.defaultValue = [x, 0.5]
      ..maskRegions = MaskRegions(sources: srcs);
    app.project.layers
      ..clear()
      ..addAll([sq('b', 0.55, ['b', 'a']), sq('a', 0.45, ['a', 'b'])]);
    app.selection.selectedLayer = 'a';
    showRegionTints = true;
    addTearDown(() => showRegionTints = false);
    final c = StageGestureController(app: app, camera: StageCamera(), onNeedsRepaint: () {});
    void tap(double x, double y) {
      c.onPointerDown(PointerDownEvent(pointer: 1, position: Offset(x, y)));
      c.onPointerUp(PointerUpEvent(pointer: 1, position: Offset(x, y)));
    }

    tap(200, 200);
    expect((app.selection.selectedLayer, app.selectedRegionSig, stageSelectedRegionDepth), ('a', 3, 0));
    tap(201, 200);
    expect((app.selection.selectedLayer, app.selectedRegionSig, stageSelectedRegionDepth), ('b', 3, 1),
        reason: 'the overlap again - B\'s part, under A\'s');
    tap(200, 201);
    expect((app.selection.selectedLayer, app.selectedRegionSig, stageSelectedRegionDepth), ('a', 3, 0), reason: 'round');
    // elsewhere: the top one there.
    tap(120, 200);
    expect((app.selection.selectedLayer, app.selectedRegionSig), ('a', 1));
  });
}
