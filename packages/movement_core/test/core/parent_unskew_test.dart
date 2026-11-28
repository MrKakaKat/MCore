import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('a turned child under a wide parent keeps right angles (no parallelogram)', () {
    setStageSize(400, 400);
    final parent = createLayer('rect')..id = 'p';
    parent.transform.scale.defaultValue = [2.0, 1.0];
    final child = createLayer('rect')
      ..id = 'c'
      ..parentId = 'p';
    child.transform.rotation.defaultValue = 45.0;
    final p = Project(layers: [parent, child]);
    clearStateCaches();
    final m = getLayerStateAt(p, 'c', 0).matrix;
    expect(m[0] * m[2] + m[1] * m[3], closeTo(0, 1e-9), reason: 'its sides at right angles');
    // as large as it was (area).
    expect((m[0] * m[3] - m[1] * m[2]).abs(), closeTo(2, 1e-9));
    // with an even parent nothing changes.
    parent.transform.scale.defaultValue = [2.0, 2.0];
    clearStateCaches();
    final e = getLayerStateAt(p, 'c', 0).matrix;
    expect(e[0], closeTo(2 * 0.7071067811865476, 1e-9));
  });
}
