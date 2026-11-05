import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _shape(String shape, String id, double side, double x, [double y = 0.5]) => createLayer(shape)
  ..id = id
  ..content.size = [side, side]
  ..transform.anchor.defaultValue = [x, y];

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

  test('two overlapping circles: four signatures, all there; apart, A·B is gone', () {
    final a = _shape('circle', 'a', 100, 0.45), b = _shape('circle', 'b', 100, 0.55);
    final t = _shape('rect', 't', 400, 0.5)..maskRegions = MaskRegions(sources: ['a', 'b']);
    final p = Project(layers: [a, b, t]);
    final g = maskRegionGeometry(p, t, 0)!;
    expect(g.map((r) => r.sig), [0, 1, 2, 3]);
    expect(g.every((r) => r.exists), isTrue);
    expect(regionSignatureLabel(1, 2), 'A·¬B');
    expect(regionSignatureLabel(0, 2), '¬A·¬B');
    // A = A·¬B + A·B.
    expect(_area(g[1].rings) + _area(g[3].rings), closeTo(_area(maskRegionGeometry(p, t, 0)![1].rings) + _area(g[3].rings), 1e-6));
    b.transform.anchor.defaultValue = [0.9, 0.5];
    clearStateCaches();
    final apart = maskRegionGeometry(p, t, 0)!;
    expect(apart[3].exists, isFalse, reason: 'no overlap');
    expect(apart[1].exists && apart[2].exists, isTrue);
  });

  test('three circles: eight signatures; the triple overlap exists', () {
    final p = Project(layers: [
      _shape('circle', 'a', 100, 0.47, 0.48),
      _shape('circle', 'b', 100, 0.53, 0.48),
      _shape('circle', 'c', 100, 0.5, 0.53),
      _shape('rect', 't', 400, 0.5)..maskRegions = MaskRegions(sources: ['a', 'b', 'c']),
    ]);
    final g = maskRegionGeometry(p, p.layers.last, 0)!;
    expect(g, hasLength(8));
    expect(g[7].exists, isTrue);
  });

  for (final mode in ['add', 'subtract', 'intersect', 'exclude', 'implication', 'equivalence', 'invert']) {
    test('preset "$mode" shows exactly what the old mask stack shows', () {
      final a = _shape('circle', 'a', 120, 0.45), b = _shape('circle', 'b', 120, 0.55);
      final stack = _shape('rect', 's', 300, 0.5)
        ..masks.addAll(mode == 'invert'
            ? [Mask(sourceLayerId: 'a', invert: true)]
            : [Mask(sourceLayerId: 'a'), Mask(mode: mode, sourceLayerId: 'b')]);
      final regions = _shape('rect', 'r', 300, 0.5)
        ..maskRegions = MaskRegions(
            sources: mode == 'invert' ? ['a'] : ['a', 'b'],
            opacity: {for (final e in regionPreset(mode).entries) e.key: track(e.value)});
      final p = Project(layers: [a, b, stack, regions]);
      final viaStack = layerVectorRings(p, stack, 0)!;
      final viaRegions = layerVectorRings(p, regions, 0)!;
      expect(_area(viaRegions), closeTo(_area(viaStack), 2));
      // the same place too: their XOR is empty.
      final List<List<List<double>>> diff = viaStack.isEmpty && viaRegions.isEmpty ? const [] : polygonBoolean(viaStack, viaRegions, BoolOp.exclude);
      expect(_area(diff), lessThan(2));
    });
  }

  test('regions survive a save; a picture source has no vector regions', () {
    final t = _shape('rect', 't', 100, 0.5)..maskRegions = MaskRegions(sources: ['a'], opacity: {1: track(0.5)});
    final back = layerFromJson(layerToJson(t));
    // a shape takes itself in (see ensureRegionSelf): inside A is now
    // "A and this layer".
    expect(back.maskRegions!.sources, ['a', 't']);
    expect(back.maskRegions!.opacity[3]!.defaultValue, 0.5);
    final img = createLayer('image')..id = 'a';
    expect(maskRegionGeometry(Project(layers: [img, t]), t, 0), isNull);
  });

  test('area opacity keys show on the timeline (Masks row); areas are named by their layers', () {
    final t = _shape('rect', 't', 100, 0.5)
      ..maskRegions = MaskRegions(sources: ['a', 'b'], opacity: {
        3: Track(1.0, false)..keyframes = [Keyframe(frame: 5, value: 1.0), Keyframe(frame: 20, value: 0.0)]
      });
    expect(keyDetailRows(t)['Masks'], [5, 20]);
    final p = Project(layers: [_shape('circle', 'a', 10, 0.4)..name = 'Rect 1', _shape('circle', 'b', 10, 0.6)..name = 'Circle', t]);
    expect(regionName(p, t.maskRegions!, 3), 'Rect 1 + Circle');
    expect(regionName(p, t.maskRegions!, 1), 'Rect 1 − Circle');
    expect(regionName(p, t.maskRegions!, 2), 'Circle − Rect 1');
    expect(regionName(p, t.maskRegions!, 0), 'Stage − Rect 1 − Circle');
  });
}
