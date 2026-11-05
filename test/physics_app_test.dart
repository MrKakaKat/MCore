import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('rendering bakes the push: B is moved at the frame shown; bake to keys keeps it', () {
    final app = AppState()..setFrameSize(1000, 1000);
    app.project.layers.clear();
    Layer box(String id, double x) => createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = 60
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [x, 0.5]
      ..physics.collide = true;
    final a = box('A', 0.1), b = box('B', 0.4);
    a.transform.anchor.keyframes
      ..add(Keyframe(frame: 0, value: [0.1, 0.5], temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 40, value: [0.7, 0.5], temporal: const Easing(0, 0, 1, 1)));
    app.project.layers.addAll([a, b]);
    app.setFrame(50);
    // a little per render: render until the bake reaches the frame.
    for (var i = 0; i < 100 && app.renderer.physicsBaking; i++) {
      app.setFrame(50);
    }
    expect(app.renderer.physicsBaking, isFalse);
    final bx = getLayerStateAt(app.project, 'B', 50).matrix[4];
    expect(bx, greaterThan(0.4), reason: 'pushed');
    app.bakePhysicsToKeys('B');
    expect(b.physics.collide, isFalse);
    clearStateCaches();
    expect(getLayerStateAt(app.project, 'B', 50).matrix[4], closeTo(bx, 0.0005));
    app.performUndo();
    expect(findLayer(app.project, 'B')!.physics.collide, isTrue, reason: 'one undo step');
  });

  test('chroma submit keeps the settings for the next colour; invert and the contrast view reset', () {
    final app = AppState();
    final l = createImageLayer(imageSourceType: 'embedded', imageData: 'AAAA', naturalWidth: 4, naturalHeight: 4);
    app.project.layers.add(l);
    l.chromaKey
      ..enabled = true
      ..strength = 0.7
      ..invert = true;
    app.renderer.chromaMatteLayerId = l.id;
    app.submitChromaKeyOf(l.id);
    expect(l.chromaKey.strength, 0.7);
    expect(l.chromaKey.invert, isFalse);
    expect(app.renderer.chromaMatteLayerId, isNull);
  });
}
