import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    fps = 60;
    clearFollowCaches();
    clearStateCaches();
  });

  Layer box(String id, double x, double y, {int frames = 600}) => createLayer('rect')
    ..id = id
    ..startFrame = 0
    ..durationFrames = frames
    ..transform.anchor.defaultValue = [x / 1000, y / 1000];

  List<double> pos(Project p, String id, int f) {
    clearStateCaches();
    final m = getLayerStateAt(p, id, f).matrix;
    return [m[4] * 1000, m[5] * 1000];
  }

  // A jumps from 100 to 500 (x) at frame 10; F follows from 100,300.
  Project step({double bounciness = 0, double speed = 60}) {
    final a = box('A', 100, 500);
    a.transform.anchor.keyframes = [
      Keyframe(frame: 9, value: [0.1, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 10, value: [0.5, 0.5], temporal: const Easing(0, 0, 1, 1)),
    ];
    final f = box('F', 100, 300);
    f.follow
      ..enabled = true
      ..targetId = 'A'
      ..bounciness = Track(bounciness, false)
      ..speed = Track(speed, false);
    return Project(layers: [a, f]);
  }

  test('a target at rest: the follower stays at rest, no drift over 600 frames', () {
    final a = box('A', 300, 300), f = box('F', 600, 600);
    f.follow
      ..enabled = true
      ..targetId = 'A';
    final p = Project(layers: [a, f]);
    expect(pos(p, 'F', 600), [600.0, 600.0]);
    expect(pos(p, 'F', 0), [600.0, 600.0]);
  });

  test('a step: it converges; no overshoot at bounciness 0, decaying overshoot above; faster with speed', () {
    final calm = step();
    var maxX = 0.0;
    for (var f = 0; f <= 300; f += 3) {
      maxX = math.max(maxX, pos(calm, 'F', f)[0]);
    }
    expect(maxX, lessThanOrEqualTo(500 + 1e-6), reason: 'no overshoot');
    expect(pos(calm, 'F', 300)[0], closeTo(500, 0.5), reason: 'it gets there');
    final bouncy = step(bounciness: 80);
    var over = 0.0;
    for (var f = 10; f <= 120; f++) {
      over = math.max(over, pos(bouncy, 'F', f)[0] - 500);
    }
    expect(over, greaterThan(5), reason: 'overshoots');
    expect((pos(bouncy, 'F', 590)[0] - 500).abs(), lessThan(0.5), reason: 'and settles');
    int settle(Project p) {
      for (var f = 10; f < 600; f++) {
        if ((pos(p, 'F', f)[0] - 500).abs() < 1) return f;
      }
      return 600;
    }

    clearFollowCaches();
    final slow = settle(step(speed: 20));
    clearFollowCaches();
    final fast = settle(step(speed: 200));
    expect(fast, lessThan(slow));
  });

  test('deterministic; editing the target from frame 50 keeps earlier frames identical', () {
    final p = step(bounciness: 50);
    final before = [for (var f = 0; f < 50; f++) pos(p, 'F', f)];
    final again = [for (var f = 0; f < 50; f++) pos(p, 'F', f)];
    expect(again, before);
    final a = findLayer(p, 'A')!;
    a.transform.anchor.keyframes.addAll([
      Keyframe(frame: 50, value: [0.5, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 51, value: [0.9, 0.9]),
    ]);
    pos(p, 'F', 80);
    expect([for (var f = 0; f < 50; f++) pos(p, 'F', f)], before);
  });

  test('rotation follows the shortest way (350 -> 10 through 360)', () {
    final a = box('A', 500, 500)..transform.rotation.defaultValue = 350.0;
    a.transform.rotation.keyframes = [
      Keyframe(frame: 10, value: 350.0),
      Keyframe(frame: 11, value: 370.0),
    ];
    final f = box('F', 500, 500);
    f.follow
      ..enabled = true
      ..targetId = 'A'
      ..position = false
      ..rotation = true;
    final p = Project(layers: [a, f]);
    double rotAt(int fr) {
      clearStateCaches();
      final m = getLayerStateAt(p, 'F', fr).matrix;
      return math.atan2(m[1], m[0]) * 180 / math.pi;
    }

    // starts at its own 0, turns +20 (not -340).
    expect(rotAt(200), closeTo(20, 0.5));
  });

  test('a 3-layer chain runs in order; a circle is refused', () {
    final a = box('A', 100, 100), b = box('B', 200, 200), c = box('C', 300, 300);
    a.transform.anchor.keyframes = [Keyframe(frame: 0, value: [0.1, 0.1]), Keyframe(frame: 10, value: [0.4, 0.1])];
    b.follow
      ..enabled = true
      ..targetId = 'A';
    c.follow
      ..enabled = true
      ..targetId = 'B';
    final p = Project(layers: [a, b, c]);
    expect(pos(p, 'C', 400)[0], closeTo(600, 1), reason: 'C goes as far as A did, through B');
    expect(followWouldCycle(p, a, 'C'), isTrue);
    expect(followWouldCycle(p, a, 'B'), isTrue);
    expect(followWouldCycle(p, c, 'A'), isFalse);
  });

  test('amount 0 is the own pose exactly; own keys add on top', () {
    final p = step();
    final f = findLayer(p, 'F')!;
    f.follow.amount = Track(0.0, false);
    expect(pos(p, 'F', 100), [100.0, 300.0]);
    f.follow.amount = Track(1.0, false);
    clearFollowCaches();
    f.transform.anchor.keyframes = [Keyframe(frame: 0, value: [0.1, 0.3]), Keyframe(frame: 100, value: [0.1, 0.4])];
    final at = pos(p, 'F', 300);
    expect(at[1], closeTo(400, 0.5), reason: 'its own move down by 100');
    expect(at[0], closeTo(500, 0.5), reason: 'and the followed move right');
  });

  test('bake to keys: within 0.5 px, the effect off', () {
    final p = step(bounciness: 40);
    final want = [for (var f = 0; f <= 200; f += 5) pos(p, 'F', f)];
    final f = findLayer(p, 'F')!;
    expect(bakeFollowToKeys(p, f), isTrue);
    expect(f.follow.enabled, isFalse);
    var i = 0;
    for (var fr = 0; fr <= 200; fr += 5) {
      final got = pos(p, 'F', fr);
      expect(math.sqrt(math.pow(got[0] - want[i][0], 2) + math.pow(got[1] - want[i][1], 2)), lessThan(0.5), reason: 'frame $fr');
      i++;
    }
  });

  test('JSON: follow and shape corners / shadow round-trip; old layers load without them', () {
    final l = box('F', 1, 1);
    l.follow
      ..enabled = true
      ..targetId = 'A'
      ..rotation = true
      ..speed = Track(120.0, false);
    l.fill
      ..cornerRadius = 12
      ..shadow = (TextShadowSpec(enabled: true, dx: 5, dy: 6, long: true, scale: 1.5));
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.follow.enabled, isTrue);
    expect(back.follow.targetId, 'A');
    expect(back.follow.rotation, isTrue);
    expect(back.follow.speed.defaultValue, 120.0);
    expect(back.fill.cornerRadius, 12);
    expect(back.fill.shadow.long, isTrue);
    expect(back.fill.shadow.scale, 1.5);
    final plain = layerToJson(box('P', 1, 1));
    expect(plain.containsKey('follow'), isFalse, reason: 'nothing written when unused');
    final old = layerFromJson(plain);
    expect(old.follow.enabled, isFalse);
    expect(old.fill.cornerRadius, 0);
    expect(old.fill.shadow.enabled, isFalse);
  });
}
