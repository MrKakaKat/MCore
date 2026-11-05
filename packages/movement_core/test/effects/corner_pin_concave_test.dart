import 'package:movement_core/movement_core.dart';
import 'package:movement_core/effects/builtins/corner_pin.dart' show quadIsConvex, bilinearQuad, quadMap;
import 'package:test/test.dart';

void main() {
  test('a caved-in corner pin keeps the shape in one finite piece', () {
    registerBuiltinEffects();
    final l = createLayer('circle')..content.size = [200, 200];
    final inst = createEffectInstance('corner_pin', 'cp', l);
    // pull the bottom-right corner far up-left, past the middle: a dart.
    (inst.params['br'] as Track).defaultValue = [-150.0, -150.0];
    l.effectStack.add(inst);
    final ring = getContentOutline(l.content, l, 0);
    expect(ring.length, greaterThan(40), reason: 'densified vector outline');
    for (final p in ring) {
      expect(p[0].isFinite && p[1].isFinite, isTrue);
      expect(p[0].abs(), lessThan(400));
      expect(p[1].abs(), lessThan(400));
    }
  });

  test('quadIsConvex / bilinearQuad', () {
    expect(quadIsConvex([0, 0], [1, 0], [1, 1], [0, 1]), isTrue);
    expect(quadIsConvex([0, 0], [1, 0], [0.2, 0.2], [0, 1]), isFalse);
    expect(bilinearQuad([0, 0], [2, 0], [2, 2], [0, 2], 0.5, 0.5), [1.0, 1.0]);
  });

  test('a caved-in quad maps the square exactly onto itself, nothing past its inner corner', () {
    final p0 = [0.0, 0.0], p1 = [100.0, 0.0], p2 = [30.0, 30.0], p3 = [0.0, 100.0]; // inner corner p2
    expect(quadMap(p0, p1, p2, p3, 1, 1), [30.0, 30.0]);
    // the square's edges land on the quad's edges.
    final mid = quadMap(p0, p1, p2, p3, 1, 0.5); // on edge p1-p2
    expect(mid[0], closeTo(65, 1e-9));
    expect(mid[1], closeTo(15, 1e-9));
    // inside the square: inside the quad (never beyond p2 outward).
    for (final (u, v) in [(0.9, 0.9), (0.7, 0.95), (0.95, 0.7)]) {
      final q = quadMap(p0, p1, p2, p3, u, v);
      expect(q[0] + q[1], lessThanOrEqualTo(100 + 1e-9));
      expect(!(q[0] > 30 && q[1] > 30), isTrue, reason: '($u, $v) -> $q');
    }
  });
}
