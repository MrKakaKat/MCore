import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('keys stay selected on a layer you leave, and move with the active layer\'s keys', () {
    final app = AppState();
    app.addLayer('rect');
    app.addLayer('circle');
    final a = app.project.layers[0], b = app.project.layers[1];
    a.transform.rotation.keyframes.add(Keyframe(frame: 10, value: 0.0));
    b.transform.rotation.keyframes.add(Keyframe(frame: 20, value: 0.0));
    app.selectLayer(a.id);
    kfSelectedFrames = {a.startFrame + 10};
    app.selectLayer(b.id);
    expect(app.heldKeys[a.id], {a.startFrame + 10});
    expect(kfSelectedFrames, isEmpty);
    kfSelectedFrames = {b.startFrame + 20};

    app.beginKeyframeDrag(b.startFrame + 20);
    app.updateKeyframeDrag(b.startFrame + 25);
    app.endKeyframeDrag();
    expect(b.transform.rotation.keyframes.single.frame, 25);
    expect(a.transform.rotation.keyframes.single.frame, 15, reason: 'the kept key moved too');
    expect(app.heldKeys[a.id], {a.startFrame + 15});

    app.selectLayer(a.id);
    expect(kfSelectedFrames, {a.startFrame + 15}, reason: 'picked up again');

    app.keepKeysAcrossLayers = false;
    app.selectLayer(b.id);
    expect(app.heldKeys, isEmpty);
    expect(kfSelectedFrames, isEmpty);
  });
}
