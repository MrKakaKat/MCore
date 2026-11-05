import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _sq(String id, double side, double x) => createLayer('rect')
  ..id = id
  ..content.size = [side, side]
  ..transform.anchor.defaultValue = [x, 0.5];

double _area(List<List<List<double>>> rings) {
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
  setUp(() {
    clearStateCaches();
    clearCutCaches();
  });

  // the layer: 100x100; the source: 40x40 inside it.
  ({Project p, Layer l}) scene(List<Mask> masks) {
    final l = _sq('l', 100, 0.5)..masks.addAll(masks);
    final s = _sq('s', 40, 0.5);
    return (p: Project(layers: [s, l]), l: l);
  }

  double shown(List<Mask> masks) {
    final sc = scene(masks);
    return _area(layerVectorRings(sc.p, sc.l, 0)!);
  }

  test('modes as logic on "shown" (one mask: starts full or empty)', () {
    expect(shown([Mask(mode: 'add', sourceLayerId: 's')]), closeTo(1600, 1));
    expect(shown([Mask(mode: 'subtract', sourceLayerId: 's')]), closeTo(10000 - 1600, 1));
    expect(shown([Mask(mode: 'intersect', sourceLayerId: 's')]), closeTo(1600, 1));
    expect(shown([Mask(mode: 'implication', sourceLayerId: 's')]), closeTo(1600, 1), reason: 'all -> S = S');
    expect(shown([Mask(mode: 'equivalence', sourceLayerId: 's')]), closeTo(1600, 1), reason: 'all <=> S = S');
  });

  test('invert turns the source inside out', () {
    expect(shown([Mask(mode: 'add', sourceLayerId: 's', invert: true)]), closeTo(10000 - 1600, 1));
  });

  test('implication and equivalence after an add', () {
    // R = S; S -> S = everything; S <=> S = everything.
    expect(shown([Mask(sourceLayerId: 's'), Mask(mode: 'implication', sourceLayerId: 's')]), closeTo(10000, 1));
    expect(shown([Mask(sourceLayerId: 's'), Mask(mode: 'equivalence', sourceLayerId: 's')]), closeTo(10000, 1));
    // S xor S = nothing.
    final sc = scene([Mask(sourceLayerId: 's'), Mask(mode: 'exclude', sourceLayerId: 's')]);
    expect(_area(layerVectorRings(sc.p, sc.l, 0)!), lessThan(1));
  });

  test('mask steps: an add shows its part; a second add on top changes nothing', () {
    final sc = scene([Mask(sourceLayerId: 's'), Mask(sourceLayerId: 's')]);
    final steps = maskSteps(sc.p, sc.l, 0);
    expect(steps, hasLength(2));
    expect(_area(steps[0].gained), closeTo(1600, 1));
    expect(steps[0].unchanged, isFalse);
    expect(steps[1].unchanged, isTrue);
  });

  test('invert survives a save', () {
    final m = maskFromJson(maskToJson(Mask(mode: 'equivalence', invert: true)));
    expect(m.invert, isTrue);
    expect(m.mode, 'equivalence');
  });

  test('equivalence as the first mask: its effect shows on every frame (no flicker)', () {
    for (var f = 0; f < 5; f++) {
      clearStateCaches();
      final sc = scene([Mask(mode: 'equivalence', sourceLayerId: 's')]);
      sc.l.transform.anchor.defaultValue = [0.5 + f * 0.001, 0.5];
      final st = maskSteps(sc.p, sc.l, 0).single;
      expect(_area(st.lost), closeTo(10000 - 1600, 2), reason: 'frame $f: it hides all but the source');
      expect(st.unchanged, isFalse);
    }
  });

  test('a picture source is reported, not dropped', () {
    final l = _sq('l', 100, 0.5)..masks.add(Mask(sourceLayerId: 'img'));
    final img = createLayer('image')..id = 'img';
    final st = maskSteps(Project(layers: [img, l]), l, 0).single;
    expect(st.raster, isTrue);
    expect(st.at, isNotNull);
  });
}
