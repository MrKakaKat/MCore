import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer(String id, {String? parent, int start = 0}) => createLayer('rect')
  ..id = id
  ..name = id
  ..parentId = parent
  ..startFrame = start
  ..durationFrames = 100;

void main() {
  setUp(() {
    fps = 60;
    setStageSize(640, 400);
    clearStateCaches();
  });

  group('selective parenting', () {
    late Layer parent, child;
    late Project p;
    setUp(() {
      parent = _layer('p');
      parent.transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.5, 0.5]),
        Keyframe(frame: 60, value: [0.8, 0.5]),
      ]);
      parent.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 60, value: 90.0)]);
      parent.transform.scale.keyframes.addAll([
        Keyframe(frame: 0, value: [1.0, 1.0]),
        Keyframe(frame: 60, value: [2.0, 2.0]),
      ]);
      child = _layer('c', parent: 'p');
      child.transform.anchor.defaultValue = [0.0, 0.0];
      p = Project(layers: [parent, child]);
    });

    List<double> m(int f) {
      clearStateCaches();
      return getLayerStateAt(p, 'c', f).matrix;
    }

    test('all on: the parent is followed fully', () {
      final full = m(60);
      expect(full[4], closeTo(0.8, 1e-9));
      expect(math.atan2(full[1], full[0]) * 180 / math.pi, closeTo(90, 1e-6));
    });

    test('position only: the child moves with the parent but keeps the first-frame rotation and scale', () {
      child.inheritRotation = false;
      child.inheritScale = false;
      final a = m(60);
      expect(a[4], closeTo(0.8, 1e-9), reason: 'follows the move');
      expect(math.atan2(a[1], a[0]), closeTo(0, 1e-9), reason: 'rotation stays as on frame 0');
      expect(math.sqrt(a[0] * a[0] + a[1] * a[1]), closeTo(1, 1e-9), reason: 'scale stays as on frame 0');
    });

    test('rotation off only: nothing jumps on the first frame', () {
      final before = m(0);
      child.inheritRotation = false;
      final after = m(0);
      for (var i = 0; i < 6; i++) {
        expect(after[i], closeTo(before[i], 1e-9));
      }
      child.inheritPosition = false;
      expect(m(60)[4], closeTo(0.5, 1e-9), reason: 'position stays at the parent\'s first-frame place');
    });

    test('a child starting later freezes the parent as it was at its own start', () {
      child.startFrame = 60;
      child.inheritPosition = false;
      expect(m(80)[4], closeTo(0.8, 1e-9));
    });

    test('saved and loaded', () {
      child.inheritScale = false;
      final back = layerFromJson(layerToJson(child));
      expect([back.inheritPosition, back.inheritRotation, back.inheritScale], [true, true, false]);
      expect(layerToJson(parent).containsKey('inherit'), isFalse);
    });
  });

  group('swing', () {
    test('a sine between the two angles, starting at the phase, decaying toward the middle', () {
      final s = Swing(enabled: true, minAngle: 0, maxAngle: 40, frequency: 1, phase: 90);
      expect(evaluateSwing(s, 0), closeTo(40, 1e-9), reason: 'phase 90: starts at the top');
      expect(evaluateSwing(s, 30), closeTo(0, 1e-9), reason: 'half a period later: the bottom');
      s.damping = 2;
      expect((evaluateSwing(s, 120) - 20).abs(), lessThan(20 * math.exp(-4) + 1e-9));
      expect(evaluateSwing(Swing(), 10), 0, reason: 'off');
    });

    test('adds to the layer rotation and reaches children', () {
      final l = _layer('l')..swing = Swing(enabled: true, minAngle: 10, maxAngle: 10);
      final c = _layer('c', parent: 'l');
      final p = Project(layers: [l, c]);
      expect(getLayerStateAt(p, 'l', 5).rot, closeTo(10, 1e-9));
      final cm = getLayerStateAt(p, 'c', 5).matrix;
      expect(math.atan2(cm[1], cm[0]) * 180 / math.pi, closeTo(10, 1e-6));
      final back = layerFromJson(layerToJson(l));
      expect([back.swing.enabled, back.swing.maxAngle], [true, 10.0]);
    });
  });
}
