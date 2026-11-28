import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(registerBuiltinEffects);

  test('Submit: the folded paper becomes the shape; the fold goes into the history', () {
    setStageSize(400, 400);
    final l = createLayer('rect')
      ..id = 'P'
      ..content.size = [200, 100]
      ..durationFrames = 300;
    final inst = createEffectInstance('origami_fold', 'o', l);
    (inst.params['angle'] as Track).defaultValue = 180.0;
    l.effectStack.add(inst);
    final p = Project(layers: [l]);
    final before = layerBaseRings(p, l, 0)!;
    double width(List<List<List<double>>> rs) {
      var lo = double.infinity, hi = -double.infinity;
      for (final r in rs) {
        for (final q in r) {
          if (q[0] < lo) lo = q[0];
          if (q[0] > hi) hi = q[0];
        }
      }
      return hi - lo;
    }

    expect(width(before), lessThan(199), reason: 'folded over: narrower than the flat paper');
    expect(submitOrigami(p, l, 'o', 0), isTrue);
    expect(l.content.shape, 'compound');
    expect(l.effectStack, isEmpty);
    expect(l.confirmHistory.last['label'], 'Origami');
    clearStateCaches();
    expect(width(layerBaseRings(p, l, 0)!), closeTo(width(before), 1), reason: 'looks as it did folded');
    expect(submitOrigami(p, l, 'o', 0), isFalse, reason: 'gone already');
  });
}
