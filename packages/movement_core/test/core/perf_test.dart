import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Engine instrumentation for the performance HUD: it counts, and changes
/// nothing it counts.
void main() {
  setUp(() {
    fps = 60;
    setStageSize(480, 480);
    clearStateCaches();
  });
  tearDown(() => perfInstrumentation = false);

  test('reference scenes: what each one stresses', () {
    final scenes = perfReferenceScenes();
    expect(scenes.map((s) => s.name).take(4), ['Perf: static shapes', 'Perf: pendulum chain', 'Perf: motion blur', 'Perf: mesh warp']);
    // the mask demos: four modes each, every target masked twice.
    final masks = scenes.where((s) => s.name.startsWith('Masks')).toList();
    expect(masks, hasLength(2));
    for (final m in masks) {
      final targets = m.project.layers.where((l) => l.masks.isNotEmpty).toList();
      expect(targets, hasLength(4));
      for (final t in targets) {
        expect(t.masks.every((k) => findLayer(m.project, k.sourceLayerId) != null), isTrue);
        expect(layerVectorRings(m.project, t, 60), isNotNull);
      }
    }
    expect(masks[1].project.layers.map((l) => l.name), containsAll(['Implication', 'Equivalence', 'Exclude + Invert', 'Subtract + Invert']));
    expect(scenes[0].project.layers.every((l) => collectLayerKeyframeFrames(l).isEmpty), isTrue);
    expect(scenes[1].project.layers.where((l) => l.pendulum.enabled).length, 5);
    expect(scenes[1].maxFrame, 1800);
    expect(scenes[2].project.layers.any((l) => l.motionBlur.enabled && l.motionBlur.samples == 8), isTrue);
    expect(scenes[3].project.layers.single.effectStack.single.effectId, 'mesh_warp');
  });

  test('layer states are the same with the counters on; hits, misses, pendulum and time are counted', () {
    final p = perfReferenceScenes()[1].project;
    List<List<double>> states() => [
          for (final f in [0, 37, 400, 1799])
            for (final l in p.layers) getLayerStateAt(p, l.id, f).matrix
        ];
    final plain = states();
    clearStateCaches();
    perfInstrumentation = true;
    perfCounters.reset();
    final counted = states();
    expect(counted, plain);
    expect(perfCounters.stateMisses, greaterThan(0));
    expect(perfCounters.stateHits, greaterThan(0), reason: 'parents come from the cache');
    expect(perfCounters.pendulumEvals, greaterThan(0));
    expect(perfCounters.stateMicros, greaterThan(0));
  });

  test('off: nothing is counted', () {
    final p = perfReferenceScenes()[1].project;
    perfCounters.reset();
    getLayerStateAt(p, 'chain_5', 100);
    expect(perfCounters.stateHits + perfCounters.stateMisses + perfCounters.pendulumEvals, 0);
  });
}
