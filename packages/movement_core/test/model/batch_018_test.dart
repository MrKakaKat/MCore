import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    registerBuiltinEffects();
  });

  Layer paper() => createLayer('rect')
    ..id = 'P'
    ..content.size = [200, 100]
    ..durationFrames = 300;

  EffectInstance bend(Layer l, {double width = 40, double turn = 0}) {
    final inst = createEffectInstance('origami_fold', 'o', l);
    (inst.params['angle'] as Track).defaultValue = 90.0;
    inst.params['kind'] = 'bend';
    inst.params['twoLineWidth'] = Track(width, false);
    inst.params['twoLineTurn'] = Track(turn, false);
    l.effectStack.add(inst);
    return inst;
  }

  List<List<double>> map(Layer l, List<List<double>> pts) => applyEffectStack(l, [pts], 0).first;

  group('bend between two lines', () {
    test('before the first line nothing moves; between them it bends; past the second it is folded', () {
      final l = paper();
      bend(l);
      final out = map(l, [
        [-10.0, 0.0],
        [20.0, 0.0],
        [39.9, 0.0],
        [40.1, 0.0],
        [90.0, 0.0],
      ]);
      expect(out[0], [-10.0, 0.0], reason: 'before the first line');
      expect(out[1][0], lessThan(20), reason: 'bending');
      expect((out[2][0] - out[3][0]).abs(), lessThan(1), reason: 'no break at the second line');
      // folded by 90 deg: the part past the second line stands up (toward
      // the viewer) - seen from the front it barely reaches on.
      expect(out[4][0], lessThan(out[3][0] + 20));
    });

    test('lines not parallel: the bend is wider on one side', () {
      final l = paper();
      bend(l, turn: 20);
      final out = map(l, [
        [45.0, -40.0],
        [45.0, 40.0],
      ]);
      expect((out[0][0] - out[1][0]).abs(), greaterThan(1), reason: 'the two sides bend differently');
      for (final q in out) {
        expect(q[0].isFinite && q[1].isFinite, isTrue);
      }
    });
  });

  test('elasticity: the angle overshoots its key and settles', () {
    final l = paper();
    final inst = createEffectInstance('origami_fold', 'o', l);
    inst.params['angle'] = Track(0.0, false)
      ..keyframes = [
        Keyframe(frame: 0, value: 0.0, temporal: easingPresets['linear']),
        Keyframe(frame: 5, value: 90.0, temporal: easingPresets['linear']),
      ];
    inst.params['elastic'] = Track(0.8, false);
    final peak = [for (var f = 5; f < 40; f++) resolveEffectParams(inst, f.toDouble())['angle'] as double].reduce(math.max);
    expect(peak, greaterThan(95));
    expect(resolveEffectParams(inst, 290)['angle'] as double, closeTo(90, 0.5));
    (inst.params['elastic'] as Track).defaultValue = 0.0;
    expect(resolveEffectParams(inst, 7)['angle'] as double, 90.0, reason: 'off: the keys as they are');
  });

  group('free move', () {
    List<List<double>> wave() => [
          for (var i = 0; i <= 60; i++) [100.0 + 5 * i, 300 + 60 * math.sin(i / 8)]
        ];

    test('as drawn: its time and pace from the hand', () {
      final l = paper();
      final p = Project(layers: [l]);
      // a slow first half, a quick second half - 2 s in all.
      final times = [for (var i = 0; i <= 60; i++) i <= 30 ? i / 30 * 1.5 : 1.5 + (i - 30) / 30 * 0.5];
      addFreeMoveLayer(p, l, wave(), 0, 10, smoothing: 0, times: times);
      final trk = l.transform.anchor.animLayers.single.track;
      expect(trk.keyframes.last.frame, (2 * fps).round(), reason: 'as long as the hand took');
      expect(trk.constantSpeed, isFalse);
      // half the way at 1.5 s, not at 1 s.
      final mid = evaluateTrack(p, trk, 1.5 * fps) as List<double>;
      // (at one pace it would be ~225 by then)
      expect(mid[0] * 1000, closeTo(150, 20));
    });

    test('the way\'s points follow its end keys: moved, and gone with one', () {
      final l = paper();
      final p = Project(layers: [l]);
      addFreeMoveLayer(p, l, wave(), 0, 40, smoothing: 0);
      final trk = latestFreeMove(l)!;
      expect(trk.freeMove, isTrue);
      expect(trk.globalEasing, isNotNull, reason: 'one ease from its first key to its last');
      final shares = [for (final k in trk.keyframes.where((k) => k.passive)) k.frame / 40];
      trk.keyframes.last.frame = 80;
      expect(bindFreeMoveKeys(l), isTrue);
      final now = [for (final k in trk.keyframes.where((k) => k.passive)) k.frame / 80];
      for (var i = 0; i < shares.length; i++) {
        expect(now[i], closeTo(shares[i], 0.03));
      }
      expect(bindFreeMoveKeys(l), isFalse, reason: 'nothing more to do');
      trk.keyframes.removeAt(0);
      bindFreeMoveKeys(l);
      expect(trk.keyframes, hasLength(1), reason: 'the way went with its first key');
    });
  });
}
