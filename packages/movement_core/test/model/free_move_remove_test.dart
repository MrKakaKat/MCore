import 'dart:math' as math;
import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 600);
    clearStateCaches();
  });

  Layer keyed() {
    final l = createLayer('rect')..id = 'A'..durationFrames = 100;
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.2, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 40, value: <double>[0.6, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 80, value: <double>[0.6, 0.9], temporal: const Easing(0, 0, 1, 1)),
    ];
    return l;
  }

  List<List<double>> wave(Project p, Layer l, int a, int b) {
    List<double> c(int f) => computeLayerFrameGeometry(p, l, f, includeVertices: false).center;
    final c0 = c(a), c1 = c(b);
    return [
      for (var i = 0; i <= 30; i++)
        [c0[0] + (c1[0] - c0[0]) * i / 30, c0[1] + (c1[1] - c0[1]) * i / 30 - 120 * math.sin(math.pi * i / 30)]
    ];
  }

  test('the drawn way between two keys can be taken away: straight between them again', () {
    final l = keyed();
    final p = Project(layers: [l]);
    final trk = l.transform.anchor;
    expect(replaceMoveBetweenKeys(p, l, trk, 0, 40, wave(p, l, 0, 40), smoothing: 0.3), isTrue);
    expect(drawnWayBetween(trk, 0, 40), isTrue);
    expect(removeMoveBetweenKeys(trk, 0, 40), isTrue);
    expect(trk.keyframes.map((k) => k.frame), [0, 40, 80]);
    clearStateCaches();
    final mid = computeLayerFrameGeometry(p, l, 20, includeVertices: false).center;
    expect(mid[1], closeTo(300, 1e-6));
  });

  test('a key taken away takes the drawn way next to it along', () {
    final l = keyed();
    final p = Project(layers: [l]);
    final trk = l.transform.anchor;
    replaceMoveBetweenKeys(p, l, trk, 40, 80, wave(p, l, 40, 80), smoothing: 0.3);
    bindFreeMoveKeys(l); // seen
    expect(trk.keyframes.any((k) => k.passive), isTrue);
    trk.keyframes.removeWhere((k) => k.frame == 80);
    bindFreeMoveKeys(l);
    expect(trk.keyframes.any((k) => k.passive), isFalse);
    expect(trk.keyframes.map((k) => k.frame), [0, 40]);
  });

  test('a free move whose two keys are taken away goes whole', () {
    final l = keyed();
    final p = Project(layers: [l]);
    final n = addFreeMoveLayer(p, l, wave(p, l, 10, 30), 10, 20, smoothing: 0);
    final t = l.transform.anchor.animLayers[n - 1].track;
    bindFreeMoveKeys(l);
    // a key of its own after it.
    t.keyframes.add(Keyframe(frame: 60, value: <double>[0.1, 0.1], temporal: const Easing(0, 0, 1, 1)));
    bindFreeMoveKeys(l);
    final ends = t.keyframes.where((k) => !k.passive).map((k) => k.frame).toList()..sort();
    t.keyframes.removeWhere((k) => !k.passive && (k.frame == ends.first || k.frame == ends[1]));
    bindFreeMoveKeys(l);
    expect(t.keyframes.map((k) => k.frame), [60]);
  });

  test('the whole way turned keeps its shape, a free move on it too', () {
    final l = keyed();
    final p = Project(layers: [l]);
    l.transform.anchor.constantSpeed = true;
    addFreeMoveLayer(p, l, wave(p, l, 10, 30), 10, 20, smoothing: 0);
    clearStateCaches();
    List<double> c(int f) => computeLayerFrameGeometry(p, l, f, includeVertices: false).center;
    final before = [for (var f = 0; f <= 80; f++) c(f)];
    turnWholePosition(p, l, degrees: 90, w: 1000, h: 600);
    clearStateCaches();
    final after = [for (var f = 0; f <= 80; f++) c(f)];
    // the same distances between any two frames.
    for (var i = 0; i < before.length; i += 7) {
      for (var j = i + 3; j < before.length; j += 11) {
        double d(List<List<double>> s) => math.sqrt(math.pow(s[i][0] - s[j][0], 2) + math.pow(s[i][1] - s[j][1], 2));
        expect(d(after), closeTo(d(before), 0.5), reason: 'frames $i and $j');
      }
    }
  });
}
