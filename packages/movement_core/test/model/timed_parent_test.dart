import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  test('a link for a time: the child follows inside it, keeps its place at the edges', () {
    final parent = createLayer('rect')
      ..id = 'p'
      ..durationFrames = 100
      ..transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.0, 0.5]),
        Keyframe(frame: 100, value: [1.0, 0.5]),
      ]);
    final child = createLayer('rect')
      ..id = 'c'
      ..durationFrames = 100
      ..parentId = 'p'
      ..transform.anchor.defaultValue = [0.1, 0.0];
    final p = Project(layers: [parent, child]);
    double x(int f) => getLayerStateAt(p, 'c', f).matrix[4];
    expect(x(50), closeTo(0.6, 1e-9));
    child
      ..parentFrom = 20
      ..parentUntil = 60;
    clearStateCaches();
    expect(x(10), closeTo(x(20), 1e-9), reason: 'before: as at the start of the link');
    expect(x(40), closeTo(0.5, 1e-9));
    expect(x(90), closeTo(x(60), 1e-9), reason: 'after: stays where the link ended');
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(child))) as Map<String, dynamic>);
    expect([back.parentFrom, back.parentUntil], [20, 60]);
    reparentPreservingWorldPosition(p, child, null, 40);
    expect([child.parentFrom, child.parentUntil], [null, null]);
  });
}
