import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/grid_settings_dialog.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

void main() {
  test('a hidden cutter is not picked on the stage; the layer under it is', () {
    final app = AppState();
    app.project.layers.clear();
    Layer box(String id) => createLayer('rect')
      ..id = id
      ..content.size = [200, 200]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final a = box('a'), cutter = box('cutter')..content.size = [80, 80];
    a.cuts.add(CutByLayer(cutterId: 'cutter', hideCutter: true));
    app.project.layers.addAll([a, cutter]);
    clearStateCaches();
    app.selectLayer(null);
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final mid = camera.frameToScreen(Offset(app.frameWidth / 2 + 60, app.frameHeight / 2));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: mid));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: mid));
    expect(app.selection.selectedLayer, 'a', reason: 'the invisible cutter on top is skipped');
  });

  testWidgets('grid: colour and opacity, saved with the project view', (tester) async {
    final app = AppState();
    gridOverlayEnabled = true;
    addTearDown(() {
      gridOverlayEnabled = false;
      gridColorRgb = 0xFFFFFF;
      gridOpacity = 0.2;
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: GridSettingsView(app: app)))));
    await tester.tap(find.byKey(const ValueKey('grid-color-f44336')));
    await tester.pump();
    expect(gridColorRgb, 0xF44336);
    await tester.drag(find.byKey(const ValueKey('grid-opacity')), const Offset(300, 0));
    await tester.pump();
    expect(gridOpacity, greaterThan(0.9));
  });

  testWidgets('gravity keys show as squares on the falling layer', (tester) async {
    final app = AppState()..timelineCenterPlayheadEnabled = false;
    app.project.layers.clear();
    final l = createLayer('rect')
      ..id = 'f'
      ..startFrame = 0
      ..durationFrames = 120;
    l.physics
      ..collide = true
      ..falls = true
      ..fallsKeys = (Track(0.0, false)..keyframes = [Keyframe(frame: 10, value: 1.0)]);
    app.project.layers.add(l);
    app.project.gravityWays = [(50, 0.0)];
    app.maxFrame = 120;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 600, height: 200, child: LayersTimelineView(app: app)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gravity-key-f-10')), findsOneWidget);
    expect(find.byKey(const ValueKey('gravity-key-f-50')), findsOneWidget);
  });
}
