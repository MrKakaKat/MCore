import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer() => Layer(
      id: 'L_a',
      name: 'a',
      startFrame: 0,
      durationFrames: 120,
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [40, 20]),
    );

void main() {
  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
  });
  for (final cut in [20, 39, 40, 41, 60]) {
    test('a border key: cut at $cut, the two parts move exactly as before', () {
      const h = Easing(0, 0, 1, 1, hold: true);
      final a = _layer();
      a.transform.rotation.keyframes.addAll([
        Keyframe(frame: 0, value: 0.0),
        Keyframe(frame: 40, value: 100.0, temporal: h),
        Keyframe(frame: 80, value: 200.0)
      ]);
      final orig = _layer()
        ..transform.rotation.keyframes.addAll([
          for (final k in a.transform.rotation.keyframes) Keyframe(frame: k.frame, value: k.value, temporal: k.temporal)
        ]);
      final po = Project(layers: [orig]);
      final want = [
        for (var f = 0; f < 120; f++) evaluateTrackOwn(po, orig.transform.rotation, f.toDouble(), orig) as double
      ];
      final p = Project(layers: [a]);
      final b = splitLayer(p, a, cut, 'L_b')!;
      final got = [
        for (var f = 0; f < cut; f++) evaluateTrackOwn(p, a.transform.rotation, f.toDouble(), a) as double,
        for (var f = 0; f < 120 - cut; f++) evaluateTrackOwn(p, b.transform.rotation, f.toDouble(), b) as double,
      ];
      final bad = [
        for (var f = 0; f < 120; f++)
          if ((got[f] - want[f]).abs() > 1e-6) '$f:${want[f].toStringAsFixed(1)}->${got[f].toStringAsFixed(1)}'
      ];
      expect(bad, isEmpty);
    });
  }

  for (final cut in [20, 40, 41, 60, 100]) {
    test('cut at $cut and joined again: moves exactly as before, one layer, ties kept', () {
      const h = Easing(0, 0, 1, 1, hold: true);
      final a = _layer();
      a.transform.rotation.keyframes.addAll([
        Keyframe(frame: 0, value: 0.0),
        Keyframe(frame: 40, value: 100.0, temporal: h),
        Keyframe(frame: 80, value: 200.0)
      ]);
      a.transform.scale.keyframes.addAll([
        Keyframe(frame: 10, value: [1.0, 1.0]),
        Keyframe(frame: 90, value: [2.0, 3.0])
      ]);
      final child = _layer()
        ..id = 'kid'
        ..startFrame = 70
        ..durationFrames = 30
        ..parentId = 'L_a';
      final p = Project(layers: [a, child]);
      List<Object?> look() => [
            for (var f = 0; f < 120; f++)
              jsonEncode([
                evaluateTrackOwn(p, a.transform.rotation, f.toDouble(), a),
                ...evaluateTrackOwn(p, a.transform.scale, f.toDouble(), a) as List
              ].map((v) => ((v as num) * 1e6).round()).toList())
          ];
      final want = look();
      final b = splitLayer(p, a, cut, 'L_b')!;
      expect(nextJoinable(p, a), same(b));
      expect(joinLayers(p, a, b), isTrue);
      expect(p.layers.map((l) => l.id), ['L_a', 'kid']);
      expect([a.startFrame, a.durationFrames], [0, 120]);
      expect(child.parentId, 'L_a');
      final got = look();
      expect([for (var f = 0; f < 120; f++) if (got[f] != want[f]) '$f: ${want[f]} -> ${got[f]}'], isEmpty);
    });
  }

  test('different things are not joined', () {
    final a = _layer();
    final b = _layer()
      ..id = 'b'
      ..startFrame = 120
      ..content.size = [10, 10];
    final p = Project(layers: [a, b]);
    expect(joinBlocker(a, b), isNotNull);
    expect(joinLayers(p, a, b), isFalse);
  });
}
