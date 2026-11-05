import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  test('a child drawn on a squeezed parent is squeezed with it', () {
    final parent = createLayer('rect')
      ..id = 'p'
      ..content.size = [100, 100];
    final inst = createEffectInstance('squeeze_axis', 's', parent);
    (inst.params['axisX'] as Track).defaultValue = 0.5;
    parent.effectStack.add(inst);
    final child = createLayer('rect')
      ..id = 'c'
      ..parentId = 'p'
      ..content.size = [20, 20]
      ..transform.anchor.defaultValue = [0.2, 0.0]; // 40 px right of the parent's middle
    final p = Project(layers: [parent, child]);
    expect(deformingAncestors(p, child, 0).map((l) => l.id), ['p']);
    final grid = buildGrid(child.content, 2, 2);
    final bent = applyInheritedDeform(p, child, grid, 0);
    // the child's middle (40 px out) moves to 20 px out: 20 px left in its own space.
    final mid = [(bent[0][0][0] + bent[1][1][0]) / 2, (bent[0][0][1] + bent[1][1][1]) / 2];
    expect(mid[0], closeTo(-20, 1e-6));
    expect(bent[1][1][0] - bent[0][0][0], closeTo(10, 1e-6), reason: 'half as wide');
    expect(mid[1], closeTo(0, 1e-6));
  });

  test('no shape effects up the chain: unchanged', () {
    final parent = createLayer('rect')..id = 'p';
    final child = createLayer('rect')
      ..id = 'c'
      ..parentId = 'p';
    final p = Project(layers: [parent, child]);
    final grid = buildGrid(child.content, 2, 2);
    expect(identical(applyInheritedDeform(p, child, grid, 0), grid), isTrue);
  });
}
