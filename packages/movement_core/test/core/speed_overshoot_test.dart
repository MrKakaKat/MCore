import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  Track path(List<List<double>> pts, List<int> frames) {
    final t = Track([0.0, 0.0], true);
    t.keyframes = [for (var i = 0; i < pts.length; i++) Keyframe(frame: frames[i], value: pts[i])];
    return t;
  }

  double dist(List<double> a, List<double> b) => math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));

  group('constant speed', () {
    test('equal distance per frame whatever the key times', () {
      // 100 px then 300 px, but the first stretch gets 90 of 100 frames.
      final t = path([[0, 0], [100, 0], [100, 300]], [0, 90, 100]);
      t.constantSpeed = true;
      // 400 px in 100 frames: 4 px a frame, the corner at frame 25.
      List<double> at(double f) => evaluateTrack(null, t, f) as List<double>;
      expect(at(10), [closeTo(40, 0.5), closeTo(0, 0.5)]);
      expect(at(25), [closeTo(100, 0.5), closeTo(0, 0.5)]);
      expect(at(50), [closeTo(100, 0.5), closeTo(100, 0.5)]);
      expect(dist(at(60), at(70)), closeTo(40, 0.5));
      expect(t.keyframes.map((k) => k.frame), [0, 90, 100], reason: 'the keys keep their times');
      t.constantSpeed = false;
      expect((evaluateTrack(null, t, 90) as List<double>)[0], 100, reason: 'off: their own times again');
    });

    test('follows the curved path, and the whole-path curve shapes the pace', () {
      final t = path([[0, 0], [100, 100], [200, 0]], [0, 10, 100]);
      t.tension = 0;
      autoComputeTangents(t);
      t.constantSpeed = true;
      final mid = evaluateTrack(null, t, 50) as List<double>;
      expect(mid[0], closeTo(100, 1), reason: 'half the length is the symmetric middle');
      t.globalEasing = easingPresets['easeIn'];
      final slow = evaluateTrack(null, t, 50) as List<double>;
      expect(slow[0], lessThan(mid[0]), reason: 'ease-in: behind at half time');
    });

    test('saved and cloned', () {
      final t = path([[0, 0], [1, 1]], [0, 10])..constantSpeed = true;
      final back = trackFromJson(jsonDecode(jsonEncode(trackToJson(t))) as Map<String, dynamic>);
      expect(back.constantSpeed, isTrue);
    });
  });

  group('overshoot ease', () {
    test('curve starts at 0, passes 1 by about the amount, ends on 1', () {
      const e = Easing(0, 0, 1, 1, kind: 'overshoot', amount: 0.2);
      expect(easeProgress(e, 0), 0);
      expect(easeProgress(e, 1), 1);
      final peak = [for (var i = 0; i <= 100; i++) easeProgress(e, i / 100)].reduce(math.max);
      expect(peak, closeTo(1.2, 0.05));
      const a = Easing(0, 0, 1, 1, kind: 'anticipate', amount: 0.2);
      final low = [for (var i = 0; i <= 100; i++) easeProgress(a, i / 100)].reduce(math.min);
      expect(low, closeTo(-0.2, 0.05));
    });

    test('a value overshoots its key', () {
      final t = Track(0.0);
      t.keyframes = [
        Keyframe(frame: 0, value: 0.0),
        Keyframe(frame: 100, value: 100.0, temporal: const Easing(0, 0, 1, 1, kind: 'overshoot', amount: 0.3)),
      ];
      final peak = [for (var f = 0; f <= 100; f++) evaluateTrack(null, t, f.toDouble()) as double].reduce(math.max);
      expect(peak, greaterThan(120));
      expect(evaluateTrack(null, t, 100), 100);
    });

    test('a path carries on past the last key along its direction, then returns', () {
      final t = path([[0, 0], [100, 0]], [0, 100]);
      t.keyframes.last.temporal = const Easing(0, 0, 1, 1, kind: 'overshoot', amount: 0.3);
      final pts = [for (var f = 0; f <= 100; f++) evaluateTrack(null, t, f.toDouble()) as List<double>];
      expect(pts.map((p) => p[0]).reduce(math.max), greaterThan(120));
      expect(pts.every((p) => p[1].abs() < 1e-9), isTrue, reason: 'stays on the line');
      // whole path too (not clamped for an overshoot).
      t.keyframes.last.temporal = easingPresets['linear']!;
      t.globalEasing = const Easing(0, 0, 1, 1, kind: 'overshoot', amount: 0.3);
      final whole = [for (var f = 0; f <= 100; f++) (evaluateTrack(null, t, f.toDouble()) as List<double>)[0]];
      expect(whole.reduce(math.max), greaterThan(120));
      expect(whole.last, 100);
    });

    test('saved, and reversing a key swaps overshoot for anticipation', () {
      const e = Easing(0.1, 0.2, 0.3, 0.4, kind: 'overshoot', amount: 0.35, bounces: 2);
      final back = easingFromJson(jsonDecode(jsonEncode(easingToJson(e))) as Map<String, dynamic>);
      expect([back.kind, back.amount, back.bounces, back.x1], ['overshoot', 0.35, 2, 0.1]);
      expect(easingFromJson(easingToJson(easingPresets['linear']!)).kind, 'bezier');
      expect(reversedEasing(e).kind, 'anticipate');
    });
  });

  test('speed graph: the speed peaks where asked, sharper when less smooth', () {
    int peakAt(Easing e) {
      final v = easeSpeedSamples(e);
      return v.indexOf(v.reduce(math.max));
    }

    expect(peakAt(speedPeakEasing(0.3, 0.2)), closeTo(18, 4));
    expect(peakAt(speedPeakEasing(0.7, 0.2)), closeTo(42, 4));
    final sharp = easeSpeedSamples(speedPeakEasing(0.5, 0.1)).reduce(math.max);
    final soft = easeSpeedSamples(speedPeakEasing(0.5, 0.9)).reduce(math.max);
    expect(sharp, greaterThan(soft));
    expect(easeSpeedSamples(easingPresets['linear']!).every((v) => (v - 1).abs() < 1e-6), isTrue);
  });
}
