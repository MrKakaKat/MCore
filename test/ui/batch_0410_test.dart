import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

Layer _rect(String id) => createLayer('rect')
  ..id = id
  ..name = id
  ..content.offset = [0, 0]
  ..content.size = [100, 100]
  ..transform.anchor.defaultValue = [0.5, 0.5];

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    chromaTool = 'none';
  });
  tearDown(() => chromaTool = 'none');

  test('an eyedropper that is on takes the finger before the brush', () {
    setStageSize(480, 480);
    final app = AppState()..setFrameSize(480, 480);
    app.project.layers.clear();
    app.setDrawTool('brush');
    chromaTool = 'stagePick';
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final a = camera.frameToScreen(const Offset(100, 100)), b = camera.frameToScreen(const Offset(200, 120));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: a));
    c.onPointerMove(PointerMoveEvent(pointer: 1, position: b));
    c.onPointerUp(PointerUpEvent(pointer: 1, position: b));
    expect(app.project.layers, isEmpty, reason: 'no stroke drawn while picking a colour');
    expect(app.drawTool, 'brush', reason: 'the brush stays on for after the pick');
    // turning a drawing tool on puts the eyedroppers away.
    chromaTool = 'pick';
    app.setDrawTool('fill');
    expect(chromaTool, 'none');
  });

  test('parent field: keep its place off - its own numbers stay, it moves with the parent', () {
    setStageSize(200, 200);
    final app = AppState()..setFrameSize(200, 200);
    app.project.layers
      ..clear()
      ..addAll([_rect('p')..transform.anchor.defaultValue = [0.2, 0.3], _rect('c')..transform.anchor.defaultValue = [0.1, 0.1]]);
    final c = findLayer(app.project, 'c')!;
    app.parentKeepsPlace = false;
    app.linkParent(c, 'p');
    expect(c.parentId, 'p');
    expect(c.transform.anchor.defaultValue, [0.1, 0.1]);
    app.linkParent(c, null);
    app.parentKeepsPlace = true;
    final before = getLayerStateAt(app.project, 'c', 0).matrix;
    app.linkParent(c, 'p');
    clearStateCaches();
    final after = getLayerStateAt(app.project, 'c', 0).matrix;
    expect(after[4], closeTo(before[4], 1e-9));
    expect(after[5], closeTo(before[5], 1e-9));
  });

  test('each layer keeps its picked keys while another is picked', () {
    final app = AppState();
    app.project.layers
      ..clear()
      ..addAll([_rect('a'), _rect('b')]);
    final a = findLayer(app.project, 'a')!;
    for (final f in [3, 4, 7]) {
      a.transform.rotation.keyframes.add(Keyframe(frame: f, value: f.toDouble()));
    }
    app.keepKeysAcrossLayers = false;
    app.selectLayer('a');
    kfSelectedFrames = {3, 7};
    app.selectLayer('b');
    expect(kfSelectedFrames, isEmpty);
    app.selectLayer('a');
    expect(kfSelectedFrames, {3, 7});
    // picked from the timeline: the layer picked, then its lane focused
    // (two reports of one switch) - its keys come back all the same.
    app.selectLayer('b');
    app.selectLayer('a');
    app.switchKeySelection('b', 'a');
    expect(kfSelectedFrames, {3, 7});
    for (final keep in [true, false]) {
      app.keepKeysAcrossLayers = keep;
      kfSelectedFrames = {4};
      app.selectLayer('b');
      app.switchKeySelection('a', 'b');
      app.selectLayer('a');
      app.switchKeySelection('b', 'a');
      expect(kfSelectedFrames, {4}, reason: 'keep across layers $keep');
    }
  });
}
