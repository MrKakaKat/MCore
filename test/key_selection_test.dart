import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// The key selection (and so its markers) never names a key that no
/// longer exists: after deleting a key, or after undoing a key move.
void main() {
  late AppState app;
  late Layer l;
  setUp(() {
    kfSelectedFrames = {};
    kfMultiselectMode = false;
    app = AppState();
    l = app.project.layers.first;
    app.selectLayer(l.id);
    addKeyframe(app.project, l.id, 'rotation', 10, 0.0, 'linear');
    addKeyframe(app.project, l.id, 'rotation', 30, 90.0, 'linear');
    app.commitEdit();
  });
  tearDown(() => kfSelectedFrames = {});

  test('deleting the selected key clears its marker', () {
    final key = l.startFrame + 30;
    app.selectKeyframeFrame(key);
    expect(kfSelectedFrames, {key});
    app.pushUndo();
    l.transform.rotation.keyframes.removeWhere((k) => k.frame == 30);
    app.commitEdit();
    expect(kfSelectedFrames, isEmpty);
  });

  test('moving a selected key, then undo: the marker does not stay at the moved place', () {
    final key = l.startFrame + 30;
    app.selectKeyframeFrame(key);
    app.beginKeyframeDrag(key);
    app.updateKeyframeDrag(key + 15);
    app.endKeyframeDrag();
    expect(kfSelectedFrames, {key + 15});
    app.performUndo();
    expect(findLayer(app.project, l.id)!.transform.rotation.keyframes.map((k) => k.frame), [10, 30]);
    expect(kfSelectedFrames, isNot(contains(key + 15)));
    app.performRedo();
    expect(kfSelectedFrames.every((f) => [10, 45].contains(f - l.startFrame)), isTrue);
  });
}
