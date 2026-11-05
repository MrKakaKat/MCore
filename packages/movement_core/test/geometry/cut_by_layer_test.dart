import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// A square rotated 45 deg (a diamond) with half-diagonal `r`, centred at
/// (x, y) of a 1000 x 1000 frame.
Layer diamondLayer(String id, double x, double y, double r) => createLayer('rect')
  ..id = id
  ..startFrame = 0
  ..durationFrames = 120
  ..content.size = [r * math.sqrt2, r * math.sqrt2]
  ..transform.rotation.defaultValue = 45.0
  ..transform.anchor.defaultValue = [x / 1000, y / 1000];

List<List<List<double>>> world(Project p, Layer l, int f) {
  clearStateCaches();
  final m = toFrameMatrix(getLayerStateAt(p, l.id, f).matrix);
  return [
    for (final r in layerVectorRings(p, l, f)!) [for (final q in r) applyAffine(m, q)]
  ];
}

double area(List<List<List<double>>> rings) => rings.fold(0.0, (s, r) => s + ringArea(r));

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearCutCaches();
  });

  test('the notched diamond from layers: the big one minus the small one grown by 20', () {
    final big = diamondLayer('big', 500, 500, 200), small = diamondLayer('small', 500, 700, 70);
    big.cuts.add(CutByLayer(cutterId: 'small', gap: Track(20.0, false)));
    final p = Project(layers: [big, small]);
    final r = world(p, big, 0);
    expect(r, hasLength(1));
    const notch = (70 + 20 * math.sqrt2);
    // the grown diamond sits on the big one's bottom vertex: the quarter
    // of it in the vertex's wedge (notch^2 / 2) is cut away.
    const bigArea = 2 * 200.0 * 200;
    expect(area(r), closeTo(bigArea - notch * notch / 2, 0.05));
    // apex on the axis.
    expect(r.single.any((q) => (q[0] - 500).abs() < 0.01 && (q[1] - (700 - notch)).abs() < 0.01), isTrue);
  });

  test('animated: the notch follows the cutter every frame', () {
    final big = diamondLayer('big', 500, 500, 200), small = diamondLayer('small', 500, 700, 70);
    small.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [0.5, 0.7], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 60, value: [0.65, 0.55]),
    ];
    big.cuts.add(CutByLayer(cutterId: 'small', gap: Track(20.0, false)));
    final p = Project(layers: [big, small]);
    double? last;
    for (var f = 0; f <= 60; f += 2) {
      final a = area(world(p, big, f));
      if (last != null) expect((a - last).abs(), lessThan(4000), reason: 'frame $f');
      last = a;
    }
    final at0 = world(p, big, 0), at60 = world(p, big, 60);
    expect(jsonEncode(at0) == jsonEncode(at60), isFalse);
  });

  test('a circle of cutters is refused; hide cutter lists the cutter', () {
    final a = diamondLayer('a', 500, 500, 200), b = diamondLayer('b', 500, 700, 70);
    a.cuts.add(CutByLayer(cutterId: 'b', hideCutter: true));
    final p = Project(layers: [a, b]);
    expect(cutWouldCycle(p, b, 'a'), isTrue);
    expect(cutWouldCycle(p, a, 'a'), isTrue);
    expect(cutWouldCycle(p, a, 'b'), isFalse);
    expect(hiddenCutters(p), {'b'});
    b.cuts.add(CutByLayer(cutterId: 'a')); // a restored circle: no hang
    expect(layerVectorRings(p, a, 0), isNotNull);
  });

  test('a vector mask now shapes the outline (contour after masks)', () {
    final big = diamondLayer('big', 500, 500, 200), small = diamondLayer('small', 500, 700, 70);
    big.masks.add(Mask(mode: 'subtract', sourceLayerId: 'small'));
    final p = Project(layers: [big, small]);
    expect(area(world(p, big, 0)), closeTo(2 * 200.0 * 200 - 70.0 * 70 / 2, 0.05));
  });

  test('cuts survive JSON; old layers load without them', () {
    final l = diamondLayer('big', 500, 500, 200)
      ..cuts.add(CutByLayer(cutterId: 'x', mode: 'intersect', gap: Track(-5.0, false), join: 'round', hideCutter: true));
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.cuts.single.mode, 'intersect');
    expect(back.cuts.single.gap.defaultValue, -5.0);
    expect(back.cuts.single.join, 'round');
    expect(back.cuts.single.hideCutter, isTrue);
    expect(layerFromJson(layerToJson(diamondLayer('o', 1, 1, 1))).cuts, isEmpty);
  });

  test('only when touching: a cutter near but apart cuts nothing; touching, it cuts with its gap', () {
    final big = diamondLayer('big', 500, 500, 200), small = diamondLayer('small', 500, 780, 70);
    final cut = CutByLayer(cutterId: 'small', gap: Track(20.0, false));
    big.cuts.add(cut);
    final p = Project(layers: [big, small]);
    expect(area(world(p, big, 0)), lessThan(80000 - 1), reason: 'the gap reaches: cut');
    cut.onlyWhenTouching = true;
    clearCutCaches();
    expect(area(world(p, big, 0)), closeTo(80000, 0.05), reason: 'apart: nothing cut');
    small.transform.anchor.defaultValue = [0.5, 0.7];
    clearCutCaches();
    expect(area(world(p, big, 0)), lessThan(80000 - 1), reason: 'touching: cut');
  });
}
