import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_view.dart';

void main() {
  testWidgets('one finger anywhere off the handles moves the view', (tester) async {
    final app = AppState()..selectLayer(null);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 400, height: 400, child: StageView(app: app)))));
    await tester.pump();
    StageCamera cam() => (tester.state(find.byType(StageView)) as dynamic).debugCamera as StageCamera;
    final before = cam().pan;
    await tester.dragFrom(const Offset(30, 30), const Offset(60, 40));
    await tester.pump();
    expect(cam().pan.dx, greaterThan(before.dx + 30));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  test('zoom lock: the canvas keeps filling the width; off by default', () {
    expect(AppState().stageZoomLock, isFalse);
    final cam = StageCamera()
      ..updateLayout(frame: const Size(100, 100), viewport: const Size(200, 400))
      ..lockSides = true;
    cam.applyScaleUpdate(scaleDelta: 0.5, focalPointDelta: Offset.zero, focalPoint: const Offset(100, 200));
    expect(cam.scale, closeTo(1, 1e-9), reason: 'not narrower than the screen');
    cam.panBy(const Offset(50, 30));
    expect(cam.frameToScreen(Offset.zero).dx, closeTo(0, 1e-9), reason: 'the left edge stays on the left side');
    cam.applyScaleUpdate(scaleDelta: 2, focalPointDelta: Offset.zero, focalPoint: const Offset(100, 200));
    cam.panBy(const Offset(0, 50));
    expect(cam.scale, 2, reason: 'zooming in is free');
  });
}
