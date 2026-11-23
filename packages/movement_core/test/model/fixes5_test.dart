import 'dart:math' as math;
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    clearStateCaches();
  });

  test('a placed project is never drawn once for the whole export', () {
    final l = createLayer('rect')..content.shape = 'projectRef';
    expect(layerIsStill(Project(layers: [l]), l), isFalse);
  });

  test('a placed project\'s sound: its mix laid over the layer, looping or silent after the end', () {
    // a source of 1 s (at 30 fps) with a 1 s clip of a steady value.
    const sr = 100;
    final clip = createLayer('audio')
      ..startFrame = 0
      ..durationFrames = 30
      ..content.audioAssetId = 'a';
    final src = Project(fps: 30, layers: [clip]);
    final pcm = {'a': Int16List.fromList(List.filled(sr * 2, 1000))};
    final ref = createLayer('rect')
      ..id = 'R'
      ..startFrame = 0
      ..durationFrames = 150; // 2.5 s at 60
    RefSound r(String end) => (layer: ref, source: src, sourceFps: 30, sourceFrames: 30, endBehavior: end);
    final looped = refSoundPcm(r('loop'), pcm, 60, sampleRate: sr);
    expect(looped.length, 250 * 2);
    expect(looped[2 * 2 * sr - 2], 1000, reason: 'second run');
    final once = refSoundPcm(r('hide'), pcm, 60, sampleRate: sr);
    expect(once[10], 1000);
    expect(once[2 * (sr + 10)], 0, reason: 'past the source: silent');
    expect(fps, 60, reason: 'the host rate is back');
  });

  test('an empty source shows its first frame (no division by zero)', () {
    final p = Project(layers: []);
    final s = RefSource(id: 'x', name: 'x', project: p, width: 10, height: 10, fps: 30, durationFrames: 0, revision: 0);
    expect(refSourceFrameAt(100, s, 60, 'loop'), 0);
  });

  test('copied keys paste onto another layer, into its tracks of the same name', () {
    final a = createLayer('rect')..id = 'A'..startFrame = 0..durationFrames = 100;
    a.transform.rotation.keyframes = [Keyframe(frame: 10, value: 0.0), Keyframe(frame: 20, value: 90.0)];
    final b = createLayer('rect')..id = 'B'..startFrame = 50..durationFrames = 100;
    copySelectedKeyframes(a, {10, 20});
    final sel = pasteKeyframes(b, 60);
    expect(sel, {60, 70});
    expect(b.transform.rotation.keyframes.map((k) => k.frame), [10, 20]);
    expect(b.transform.rotation.keyframes.last.value, 90.0);
    expect(a.transform.rotation.keyframes.length, 2, reason: 'the source is left as it was');
  });

  test('anticipation and overshoot together: first a swing back, then past the end; damping fades the swings', () {
    const e = Easing(0, 0, 1, 1, over: true, ant: true, amount: 0.2, antAmount: 0.2, bounces: 1, antBounces: 1);
    expect(easeProgress(e, 0), 0);
    expect(easeProgress(e, 1), 1);
    final ys = [for (var i = 0; i <= 200; i++) easeProgress(e, i / 200)];
    expect(ys.reduce((a, b) => a < b ? a : b), lessThan(-0.05));
    expect(ys.reduce((a, b) => a > b ? a : b), greaterThan(1.05));
    // only one on: the other's settings make no difference.
    const o = Easing(0, 0, 1, 1, over: true, amount: 0.3, bounces: 2);
    const o2 = Easing(0, 0, 1, 1, over: true, amount: 0.3, bounces: 2, antAmount: 0.6);
    expect(easeProgress(o, 0.4), easeProgress(o2, 0.4));
    // damping: later swings smaller, the first one about the same, ends on 1.
    double lastSwing(double d) {
      var m = 0.0;
      for (var i = 120; i <= 200; i++) {
        m = m > (overshootCurve(0.3, 3, i / 200, damping: d) - 1).abs() ? m : (overshootCurve(0.3, 3, i / 200, damping: d) - 1).abs();
      }
      return m;
    }
    expect(lastSwing(3), lessThan(lastSwing(1)));
    expect(overshootCurve(0.3, 3, 1, damping: 3), 1);
    expect(overshootCurve(0.3, 3, 0.999999, damping: 3), closeTo(1, 1e-3));
    // old files: one kind keeps meaning what it did.
    final back = easingFromJson(easingToJson(const Easing(0, 0, 1, 1, kind: 'anticipate', amount: 0.3)));
    expect(back.ant, isTrue);
    expect(back.over, isFalse);
    expect(back.antAmount, 0.3);
    final both = easingFromJson(easingToJson(e));
    expect(both.over && both.ant, isTrue);
  });

  test('curve handles: one movement at a time; a hold between two movements stays straight', () {
    // movement 1: 0 -> 20, hold, movement 2: 30 -> 50 (as order keys merge them).
    final t = Track(<double>[0, 0], true)
      ..keyframes = [
        Keyframe(frame: 0, value: <double>[0, 0]),
        Keyframe(frame: 10, value: <double>[0.2, 0.1]),
        Keyframe(frame: 20, value: <double>[0.4, 0]),
        Keyframe(frame: 30, value: <double>[0.4, 0]),
        Keyframe(frame: 40, value: <double>[0.6, 0.2]),
        Keyframe(frame: 50, value: <double>[0.8, 0]),
      ];
    autoComputeTangents(t);
    expect(t.keyframes[2].spatialTangent.outTan, [0, 0], reason: 'no going out and back while it holds');
    expect(t.keyframes[3].spatialTangent.inTan, [0, 0]);
    expect(pathRuns(t), [(0, 2), (3, 5)]);
    expect(pathRunAt(t, 45), (3, 5));
    startHandTangents(t, from: 30, to: 50);
    expect([for (final k in t.keyframes) k.hand], [false, false, false, true, true, true]);
    // its ends have a handle to drag (the last key's way in, the first's way out).
    expect(t.keyframes[5].spatialTangent.inTan.any((v) => v.abs() > 1e-6), isTrue);
    expect(t.keyframes[3].spatialTangent.outTan.any((v) => v.abs() > 1e-6), isTrue);
    // the other movement still follows the tension.
    t.tension = 0;
    final before = [...t.keyframes[4].spatialTangent.outTan];
    autoComputeTangents(t);
    expect(t.keyframes[4].spatialTangent.outTan, before, reason: 'set by hand: kept');
    expect(t.keyframes[1].spatialTangent.outTan.any((v) => v.abs() > 1e-6), isTrue);
    stopHandTangents(t, from: 30, to: 50);
    expect(t.handTangents, isFalse);
  });

  test('scale wiggle: the size wobbles (together or each side); an offset makes another wander', () {
    setStageSize(1000, 1000);
    final l = createLayer('rect')..id = 'A'..durationFrames = 300;
    final p = Project(layers: [l]);
    addMotionPanelEntry(l, 'scaleWiggle');
    l.scaleWiggle.amplitude = 30;
    final sizes = [for (var f = 0; f < 120; f += 7) getLayerStateAt(p, 'A', f).scale];
    expect(sizes.any((s) => (s[0] - 1).abs() > 0.02), isTrue);
    expect(sizes.every((s) => (s[0] - s[1]).abs() < 1e-9), isTrue, reason: 'together');
    l.scaleWiggle.axes = true;
    clearStateCaches();
    expect([for (var f = 0; f < 120; f += 7) getLayerStateAt(p, 'A', f).scale].any((s) => (s[0] - s[1]).abs() > 0.01), isTrue);
    // offset: another wander for the place wiggle too.
    l.wiggle = Wiggle(enabled: true);
    final a = evaluateWiggleOffset(l, 40);
    l.wiggle.wiggleSeed = 37;
    expect(evaluateWiggleOffset(l, 40), isNot(a));
    final back = layerFromJson(layerToJson(l));
    expect(back.wiggle.wiggleSeed, 37);
    expect(back.scaleWiggle.enabled && back.scaleWiggle.axes, isTrue);
    expect(cloneLayer(l).scaleWiggle.amplitude, 30);
  });

  test('swing with damping: still before it first moves, full while moving, dying out after', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 400;
    l.transform.anchor.keyframes = [
      Keyframe(frame: 30, value: <double>[0.2, 0.5]),
      Keyframe(frame: 60, value: <double>[0.8, 0.5]),
    ];
    l.swing = Swing(enabled: true, minAngle: -20, maxAngle: 20, frequency: 1, damping: 2);
    final p = Project(layers: [l]);
    double peak(int a, int b) {
      var m = 0.0;
      for (var f = a; f <= b; f++) {
        m = math.max(m, swingAngleAt(p, l, f).abs());
      }
      return m;
    }
    expect(peak(0, 29), 0, reason: 'no swinging before it moves');
    expect(peak(35, 60), greaterThan(15));
    expect(peak(300, 399), lessThan(1));
    // no damping: as before, from the start.
    l.swing.damping = 0;
    expect(peak(0, 29), greaterThan(15));
  });

  test('parented: it stays where it is, also with a side kept by its size handles', () {
    setStageSize(1000, 600);
    final parent = createLayer('rect')..id = 'P';
    parent.transform.anchor.defaultValue = <double>[0.3, 0.4];
    parent.transform.scale.defaultValue = <double>[2, 2];
    parent.transform.rotation.defaultValue = 30.0;
    final child = createLayer('rect')..id = 'C'..content.size = [100, 60];
    child.transform.anchor.defaultValue = <double>[0.7, 0.6];
    child.transform.scale.defaultValue = <double>[1.5, 1];
    child.scaleOrigin = [-50, 0]; // its left side kept
    child.rotateOrigin = [20, 10];
    child.transform.rotation.defaultValue = 10.0;
    final p = Project(layers: [parent, child]);
    List<List<double>> corners() {
      final m = toFrameMatrix(getLayerStateAt(p, 'C', 0).matrix);
      return [for (final q in [[-50.0, -30.0], [50.0, 30.0]]) applyAffine(m, q)];
    }
    final before = corners();
    reparentPreservingWorldPosition(p, child, 'P', 0);
    clearStateCaches();
    final after = corners();
    for (var i = 0; i < 2; i++) {
      expect(after[i][0], closeTo(before[i][0], 1e-3));
      expect(after[i][1], closeTo(before[i][1], 1e-3));
    }
  });

  test('a border key: the value stays, then jumps on its frame; saved', () {
    final t = Track(0.0)
      ..keyframes = [Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 100.0, temporal: const Easing(0, 0, 1, 1, hold: true))];
    expect(evaluateTrack(null, t, 5.0), 0.0);
    expect(evaluateTrack(null, t, 9.9), 0.0);
    expect(evaluateTrack(null, t, 10.0), 100.0);
    final back = easingFromJson(easingToJson(t.keyframes[1].temporal));
    expect(back.hold, isTrue);
    expect(back.withHold(false).hold, isFalse);
  });
}
