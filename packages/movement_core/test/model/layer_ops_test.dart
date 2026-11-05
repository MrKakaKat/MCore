import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  late Project project;
  setUp(() {
    registerBuiltinEffects();
    project = Project();
  });

  group('reparenting preserves world position and visual size', () {
    test('keeps a layer visually in place when moved under a scaled, offset parent', () {
      final parent = createLayer('rect');
      project.layers.add(parent);
      parent.transform.scale.defaultValue = [2.5, 2.5];
      parent.transform.anchor.defaultValue = [0.3, 0.4];

      final child = createLayer('circle');
      project.layers.add(child);
      child.transform.anchor.defaultValue = [0.5, 0.5];
      child.transform.scale.defaultValue = [1.0, 1.0];

      final before = getLayerStateAt(project, child.id, 0).matrix;
      final beforeScale = [_hypot(before[0], before[1]), _hypot(before[2], before[3])];
      final beforePos = [before[4], before[5]];

      reparentPreservingWorldPosition(project, child, parent.id, 0);

      final after = getLayerStateAt(project, child.id, 0).matrix;
      final afterScale = [_hypot(after[0], after[1]), _hypot(after[2], after[3])];
      final afterPos = [after[4], after[5]];

      // position unchanged
      expect(afterPos[0], closeTo(beforePos[0], 1e-4));
      expect(afterPos[1], closeTo(beforePos[1], 1e-4));

      // visual size unchanged, even though the new parent scales 2.5x
      expect(afterScale[0], closeTo(beforeScale[0], 1e-3));
      expect(afterScale[1], closeTo(beforeScale[1], 1e-3));

      // the mechanism: child's own scale got compensated to ~0.4 (1/2.5)
      final scaleDefault = child.transform.scale.defaultValue as List<double>;
      expect(scaleDefault[0], closeTo(0.4, 1e-3));
      expect(scaleDefault[1], closeTo(0.4, 1e-3));
    });
  });

  group('reparenting keeps the whole world matrix (rotation too)', () {
    void expectSameMatrix(List<double> a, List<double> b) {
      for (var i = 0; i < 6; i++) {
        expect(b[i], closeTo(a[i], 1e-6), reason: 'matrix entry $i');
      }
    }

    Layer parentLayer({int start = 0, int duration = 300}) {
      final parent = createLayer('rect')
        ..startFrame = start
        ..durationFrames = duration;
      project.layers.add(parent);
      parent.transform.scale.defaultValue = [2.0, 2.0];
      parent.transform.anchor.defaultValue = [0.3, 0.4];
      parent.transform.rotation.defaultValue = 35.0;
      return parent;
    }

    Layer childLayer() {
      final child = createLayer('rect');
      project.layers.add(child);
      child.transform.anchor.defaultValue = [0.6, 0.55];
      child.transform.rotation.defaultValue = 10.0;
      return child;
    }

    test('under a rotated, scaled parent the child neither turns nor moves nor resizes', () {
      final parent = parentLayer();
      final child = childLayer();
      final before = getLayerStateAt(project, child.id, 0).matrix;
      reparentPreservingWorldPosition(project, child, parent.id, 0);
      expectSameMatrix(before, getLayerStateAt(project, child.id, 0).matrix);
      expect(child.transform.rotation.defaultValue, closeTo(-25, 1e-9), reason: '10 world = 35 parent + -25 own');
    });

    test('rotation keyframes shift by the same angle, so the animation keeps its turn', () {
      final parent = parentLayer();
      final child = childLayer();
      addKeyframe(project, child.id, 'rotation', 0, 0.0, 'linear');
      addKeyframe(project, child.id, 'rotation', 60, 90.0, 'linear');
      final before30 = getLayerStateAt(project, child.id, 30).matrix;
      final before0 = getLayerStateAt(project, child.id, 0).matrix;
      reparentPreservingWorldPosition(project, child, parent.id, 0);
      expectSameMatrix(before0, getLayerStateAt(project, child.id, 0).matrix);
      final after30 = getLayerStateAt(project, child.id, 30).matrix;
      expect(math.atan2(after30[1], after30[0]), closeTo(math.atan2(before30[1], before30[0]), 1e-9),
          reason: 'still turns the same way later');
    });

    test('child outside the parent\'s time range at the reparent frame', () {
      final parent = parentLayer(start: 100, duration: 50); // frames 100..150
      final child = childLayer();
      final before = getLayerStateAt(project, child.id, 20).matrix;
      reparentPreservingWorldPosition(project, child, parent.id, 20);
      expectSameMatrix(before, getLayerStateAt(project, child.id, 20).matrix);
    });

    test('moving back out to no parent restores the world matrix too', () {
      final parent = parentLayer();
      final child = childLayer();
      reparentPreservingWorldPosition(project, child, parent.id, 0);
      final under = getLayerStateAt(project, child.id, 0).matrix;
      reparentPreservingWorldPosition(project, child, null, 0);
      expectSameMatrix(under, getLayerStateAt(project, child.id, 0).matrix);
    });
  });

  group('deleteLayer clears its stale state-cache entry', () {
    test("a leaf layer's cache entry doesn't outlive its removal (no children -> no reparent call to clear it as a side effect)", () {
      final leaf = createLayer('rect');
      project.layers.add(leaf);

      // populate a cache entry for this exact (id, frame) BEFORE deletion -
      // this is what a stale read would return if nothing cleared it.
      getLayerStateAt(project, leaf.id, 0);

      deleteLayer(project, Selection(), leaf.id, 0);

      final after = getLayerStateAt(project, leaf.id, 0);
      expect(after.inRange, isFalse); // "not found" fallback, not a stale cached matrix
      expect(after.matrix, equals([1.0, 0, 0, 1, 0, 0])); // identity, the defensive default
    });
  });

  group('ungroupLayer clears its stale state-cache entry', () {
    test("a childless group null's cache entry doesn't outlive its removal", () {
      final nullLayer = createLayer('null');
      nullLayer.groupedChildren = []; // degenerate case: nothing in the loop to trigger a clear as a side effect
      project.layers.add(nullLayer);

      getLayerStateAt(project, nullLayer.id, 0);

      ungroupLayer(project, nullLayer.id, 0);

      final after = getLayerStateAt(project, nullLayer.id, 0);
      expect(after.inRange, isFalse);
      expect(after.matrix, equals([1.0, 0, 0, 1, 0, 0]));
    });
  });

  group('rescaleProjectContent', () {
    test('scales content offset/size/points, leaving anchor untouched', () {
      final layer = createLayer('rect');
      layer.content.offset = [10, 20];
      layer.content.size = [46, 46];
      layer.content.points = [
        [1, 2],
        [3, 4],
      ];
      layer.transform.anchor.defaultValue = [0.5, 0.5];
      project.layers.add(layer);

      rescaleProjectContent(project, 2.0, 3.0);

      expect(layer.content.offset, equals([20.0, 60.0]));
      expect(layer.content.size, equals([92.0, 138.0]));
      expect(layer.content.points, equals([[2.0, 6.0], [6.0, 12.0]]));
      expect(layer.transform.anchor.defaultValue, equals([0.5, 0.5])); // fraction - already scale-free
    });

    test('covers image content too, via the same offset/size fields', () {
      final layer = createImageLayer(imageSourceType: 'embedded', imageData: 'AAAA', naturalWidth: 10, naturalHeight: 10);
      layer.content.offset = [5, 5];
      layer.content.size = [10, 10];
      project.layers.add(layer);

      rescaleProjectContent(project, 2.0, 2.0);

      expect(layer.content.offset, equals([10.0, 10.0]));
      expect(layer.content.size, equals([20.0, 20.0]));
    });

    test('scales mask feather by the geometric mean of scaleX/scaleY', () {
      final layer = createLayer('rect');
      layer.masks.add(Mask(feather: track(10.0)));
      project.layers.add(layer);

      rescaleProjectContent(project, 4.0, 9.0); // sqrt(4*9) = 6

      expect(layer.masks.single.feather.defaultValue, closeTo(60.0, 1e-9));
    });

    test('scales corner_pin tl/tr/br/bl tracks, including keyframe values', () {
      final layer = createLayer('rect'); // NOT triangle/polygon - keeps createEffectInstance in bbox mode (tl/tr/br/bl), not exact-N-point mode (p0..pN)
      final inst = createEffectInstance('corner_pin', 'e1', layer);
      (inst.params['tl'] as Track).defaultValue = [1.0, 2.0];
      (inst.params['tl'] as Track).keyframes.add(Keyframe(frame: 5, value: [3.0, 4.0]));
      layer.effectStack.add(inst);
      project.layers.add(layer);

      rescaleProjectContent(project, 2.0, 3.0);

      final tl = inst.params['tl'] as Track;
      expect(tl.defaultValue, equals([2.0, 6.0]));
      expect(tl.keyframes.single.value, equals([6.0, 12.0]));
    });

    test('scales mesh_warp per-pin tracks (r{r}c{c})', () {
      final layer = createLayer('rect');
      final inst = createEffectInstance('mesh_warp', 'e1', layer);
      (inst.params['r0c0'] as Track).defaultValue = [1.0, 1.0];
      layer.effectStack.add(inst);
      project.layers.add(layer);

      rescaleProjectContent(project, 2.0, 5.0);

      expect((inst.params['r0c0'] as Track).defaultValue, equals([2.0, 5.0]));
      // structural, non-spatial params are untouched
      expect(inst.params['rows'], equals(4));
    });

    test('scales pendulum pivotOffset (layer-local pixels, divided by stage size at eval time)', () {
      final layer = createLayer('rect');
      layer.pendulum.pivotOffset.defaultValue = [10.0, -10.0];
      project.layers.add(layer);

      rescaleProjectContent(project, 2.0, 2.0);

      expect(layer.pendulum.pivotOffset.defaultValue, equals([20.0, -20.0]));
    });

    test('scaleX == scaleY == 1 is a true no-op', () {
      final layer = createLayer('rect');
      final originalOffset = [...layer.content.offset];
      final originalSize = [...layer.content.size];
      project.layers.add(layer);

      rescaleProjectContent(project, 1.0, 1.0);

      expect(layer.content.offset, equals(originalOffset));
      expect(layer.content.size, equals(originalSize));
    });
  });
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);
