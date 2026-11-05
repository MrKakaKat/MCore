import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  test('two still shapes become one contour in the same place, each in its own colour', () {
    final a = createLayer('rect')
      ..id = 'a'
      ..color = '#ff0000'
      ..content.size = [40, 40]
      ..transform.anchor.defaultValue = [0.25, 0.5];
    final b = createLayer('rect')
      ..id = 'b'
      ..color = '#00ff00'
      ..content.size = [40, 40]
      ..transform.anchor.defaultValue = [0.75, 0.5]
      ..transform.rotation.defaultValue = 45.0;
    final p = Project(layers: [a, b]);
    final m = mergeLayers(p, [b, a], 'm', 0)!;
    expect(p.layers.map((l) => l.id), ['m']);
    expect(m.content.contourColors, ['#ff0000', '#00ff00'], reason: 'each keeps its colour');
    expect(m.content.shape, 'compound');
    expect(m.content.contours, hasLength(2));
    // a's corners land where they were: frame (30, 80) .. (70, 120).
    final mm = toFrameMatrix(getLayerStateAt(p, 'm', 0).matrix);
    final xs = [for (final pt in m.content.contours!.expand((c) => c)) applyAffine(mm, pt)[0]];
    expect(xs.reduce((x, y) => x < y ? x : y), closeTo(30, 1e-6));
  });

  test('layers with keys or effects merge as they look now (a warning); pictures and mirrors are refused', () {
    final a = createLayer('rect');
    final b = createLayer('rect')..transform.rotation.keyframes.add(Keyframe(frame: 0, value: 0.0));
    expect(mergeBlocker(a), isNull);
    expect(mergeBlocker(b), isNull);
    expect(mergeWarning(b), contains('keys'));
    expect(mergeWarning(createLayer('rect')..wiggle.enabled = true), contains('motion'));
    expect(mergeBlocker(createLayer('rect')..mirrorProbe = true), 'is a mirror');
    final p = Project(layers: [a, b]);
    expect(mergeLayers(p, [a, b], 'm', 0), isNotNull);
  });

  test('a hole cut by another layer stays a hole in the merged shape', () {
    final a = createLayer('rect')
      ..id = 'a'
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final hole = createLayer('rect')
      ..id = 'h'
      ..content.size = [20, 20]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    a.cuts.add(CutByLayer(cutterId: 'h', gap: Track(0.0, false)));
    final b = createLayer('rect')
      ..id = 'b'
      ..content.size = [20, 20]
      ..transform.anchor.defaultValue = [0.1, 0.1];
    final p = Project(layers: [hole, a, b]);
    clearCutCaches();
    final m = mergeLayers(p, [a, b], 'm', 0)!;
    final c = m.content;
    expect(c.contours, hasLength(3), reason: 'outer, its hole, the other square');
    expect(c.contourJoin, [false, true, false]);
    double area(List<List<double>> r) {
      var s = 0.0;
      for (var i = 0; i < r.length; i++) {
        final p = r[i], q = r[(i + 1) % r.length];
        s += p[0] * q[1] - q[0] * p[1];
      }
      return s / 2;
    }
    expect(area(c.contours![0]).sign, -area(c.contours![1]).sign, reason: 'the hole winds the other way');
    expect(layerFromJson(layerToJson(m)).content.contourJoin, [false, true, false]);
  });
}
