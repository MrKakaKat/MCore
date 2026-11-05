import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/hint.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';

void main() {
  tearDown(() {
    hideHandles = false;
    cropEditing = false;
    descriptionsVisible.value = true;
  });

  test('handles hidden: the Crop tab\'s handles still work on the selected layer', () {
    setStageSize(400, 400);
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    hideHandles = true;
    cropEditing = true;
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    final h = getCropHandles(app.project, layer, 0);
    final e = h.screen.entries.first;
    final at = camera.frameToScreen(Offset(e.value[0], e.value[1]));
    c.onPointerDown(PointerDownEvent(pointer: 1, position: at));
    expect(c.anyDragActive, isTrue, reason: 'the crop handle is grabbed');
    c.onPointerUp(PointerUpEvent(pointer: 1, position: at));
    cropEditing = false;
    final tb = getTransformBoxHandles(app.project, layer, 0);
    final grip = camera.frameToScreen(Offset(tb.screen['moveCorner']![0], tb.screen['moveCorner']![1]));
    c.onPointerDown(PointerDownEvent(pointer: 2, position: grip));
    expect(c.anyDragActive, isFalse, reason: 'the transform handles stay hidden');
  });

  testWidgets('descriptions can be switched off everywhere', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Hint('explained'))));
    expect(find.text('explained'), findsOneWidget);
    final app = AppState();
    app.setAppPreference('showDescriptions', false);
    await tester.pump();
    expect(find.text('explained'), findsNothing);
    expect(hint('x'), isNull, reason: 'a tile subtitle goes away entirely');
  });

  testWidgets('Keyframes tab: the selected keys can be deleted from their row', (tester) async {
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.transform.rotation.keyframes.addAll([Keyframe(frame: 10, value: 0.0), Keyframe(frame: 20, value: 9.0)]);
    kfSelectedFrames = {layer.startFrame + 10};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    await tester.tap(find.byKey(const ValueKey('delete-selected-keys')));
    await tester.pump();
    expect(layer.transform.rotation.keyframes.map((k) => k.frame), [20]);
    expect(kfSelectedFrames, isEmpty);
    app.performUndo();
    expect(findLayer(app.project, layer.id)!.transform.rotation.keyframes, hasLength(2));
  });
}
