import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double area(List<List<List<double>>> rings) {
  var a = 0.0;
  for (final r in rings) {
    var s = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      s += p[0] * q[1] - q[0] * p[1];
    }
    a += s / 2;
  }
  return a.abs();
}

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    setStageSize(400, 200);
    clearStateCaches();
  });

  Layer sq(String id, double x, double y, double s) => createLayer('rect')
    ..id = id
    ..content.offset = [0, 0]
    ..content.size = [s, s]
    ..transform.anchor.defaultValue = [x / 400, y / 200];

  test('a tap on a square fills exactly the square', () {
    final p = Project(layers: [sq('a', 100, 100, 80)]);
    final r = fillRegionAt(p, 0, [100, 100]);
    expect(area(r), closeTo(6400, 1));
  });

  test('two overlapping squares: their overlap; ignoring one, the whole other', () {
    final p = Project(layers: [sq('a', 100, 100, 80), sq('b', 140, 100, 80)]);
    // a: 60..140, b: 100..180 -> overlap 100..140 (40 x 80).
    expect(area(fillRegionAt(p, 0, [120, 100])), closeTo(3200, 1));
    // only a counts: all of a.
    expect(area(fillRegionAt(p, 0, [120, 100], only: {'a'})), closeTo(6400, 1));
    // in a but not b: a less the overlap.
    expect(area(fillRegionAt(p, 0, [80, 100])), closeTo(3200, 1));
  });

  test('outside everything: the frame less the layers; a new Fill layer on top', () {
    final p = Project(layers: [sq('a', 100, 100, 80)]);
    expect(area(fillRegionAt(p, 0, [300, 20])), closeTo(400 * 200 - 6400, 2));
    final l = addFillLayer(p, 0, [100, 100], 'f', color: '#00ff00')!;
    expect(p.layers.last, same(l));
    expect(l.content.shape, 'compound');
    expect(l.color, '#00ff00');
  });
}
