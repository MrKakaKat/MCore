import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Stage 1 contour physics: collision push without inertia.
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });

  // a square of `size` px at (x, y) px, colliding.
  Layer box(String id, double x, double y, {double size = 100, int frames = 100}) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = frames
      ..content.offset = [0, 0]
      ..content.size = [size, size]
      ..transform.anchor.defaultValue = [x / 1000, y / 1000];
    l.physics.collide = true;
    return l;
  }

  void move(Layer l, int f0, List<double> from, int f1, List<double> to) {
    l.transform.anchor.keyframes
      ..clear()
      ..add(Keyframe(frame: f0, value: [from[0] / 1000, from[1] / 1000], temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: f1, value: [to[0] / 1000, to[1] / 1000], temporal: const Easing(0, 0, 1, 1)));
  }

  List<double> pos(Project p, String id, int f) {
    final m = getLayerStateAt(p, id, f).matrix;
    return [m[4] * 1000, m[5] * 1000];
  }

  // overlap of two axis-aligned 100 px squares (their centres).
  double overlapX(List<double> a, List<double> b, [double size = 100]) => size - (a[0] - b[0]).abs();

  PhysicsWorld bake(Project p, int to) {
    clearStateCaches();
    final w = physicsWorldOf(p)..bakeTo(to);
    clearStateCaches();
    return w;
  }

  test('push: A into resting B - B moves with A while touching, stops when A stops', () {
    final a = box('A', 100, 500), b = box('B', 400, 500);
    move(a, 0, [100, 500], 60, [700, 500]);
    final p = Project(layers: [a, b]);
    bake(p, 99);
    // contact once A's right edge reaches B's left: A at 300.
    final aEnd = pos(p, 'A', 99), bEnd = pos(p, 'B', 99);
    expect(overlapX(aEnd, bEnd), lessThanOrEqualTo(1e-6), reason: 'never overlapping');
    final aTravelAfterContact = aEnd[0] - 300;
    expect(bEnd[0] - 400, closeTo(aTravelAfterContact, 1e-6), reason: 'B displaced as much as A travelled after contact');
    expect(pos(p, 'B', 80)[0], closeTo(bEnd[0], 1e-9), reason: 'no inertia: stops when A stops');
  });

  test('weights: equal both yield; 1 vs 3 splits 3:1; Immovable takes none', () {
    double lagOf(double wA, double wB, {bool immovable = false}) {
      final a = box('A', 100, 500)..physics.weight = wA, b = box('B', 400, 500)..physics.weight = wB;
      if (immovable) b.physics.role = 'immovable';
      move(a, 0, [100, 500], 60, [700, 500]);
      final p = Project(layers: [a, b]);
      bake(p, 60);
      // how far A is behind its keys, against how far B moved.
      final lag = 700 - pos(p, 'A', 60)[0], push = pos(p, 'B', 60)[0] - 400;
      return push == 0 ? double.infinity : lag / push;
    }

    expect(lagOf(1, 1), closeTo(1, 1e-6));
    expect(lagOf(1, 3), closeTo(3, 1e-6), reason: 'the heavier B yields a third as much');
    expect(lagOf(1, 1, immovable: true), double.infinity, reason: 'Immovable never moves');
  });

  test('A against Immovable stops at the contact', () {
    final a = box('A', 100, 500), b = box('B', 400, 500)..physics.role = 'immovable';
    move(a, 0, [100, 500], 60, [700, 500]);
    final p = Project(layers: [a, b]);
    bake(p, 60);
    expect(pos(p, 'A', 60)[0], closeTo(300, 1e-6));
    expect(pos(p, 'B', 60)[0], 400);
  });

  test('moving diagonally toward each other at equal speed: the pushes cancel, they slide along, never overlapping', () {
    final a = box('A', 300, 200), b = box('B', 700, 200);
    move(a, 0, [300, 200], 60, [700, 800]);
    move(b, 0, [700, 200], 60, [300, 800]);
    final p = Project(layers: [a, b]);
    bake(p, 60);
    for (var f = 0; f <= 60; f++) {
      final pa = pos(p, 'A', f), pb = pos(p, 'B', f);
      final ox = 100 - (pa[0] - pb[0]).abs(), oy = 100 - (pa[1] - pb[1]).abs();
      expect(ox <= 1e-6 || oy <= 1e-6, isTrue, reason: 'frame $f overlaps');
    }
    expect(pos(p, 'A', 60)[1], closeTo(800, 1e-6), reason: 'the motion along the contact goes on');
    expect(pos(p, 'B', 60)[1], closeTo(800, 1e-6));
    expect(pos(p, 'A', 60)[0], closeTo(450, 1e-6), reason: 'across it, the equal pushes cancel: side by side');
    expect(pos(p, 'B', 60)[0], closeTo(550, 1e-6));
  });

  test('chain: A pushes B pushes C; nothing overlaps', () {
    final a = box('A', 100, 500), b = box('B', 300, 500), c = box('C', 500, 500);
    move(a, 0, [100, 500], 40, [700, 500]);
    final p = Project(layers: [a, b, c]);
    bake(p, 40);
    final pa = pos(p, 'A', 40), pb = pos(p, 'B', 40), pc = pos(p, 'C', 40);
    expect(pc[0], greaterThan(500), reason: 'C was pushed');
    // 8 iterations settle a chain to well under a pixel.
    expect(overlapX(pa, pb), lessThanOrEqualTo(0.01));
    expect(overlapX(pb, pc), lessThanOrEqualTo(0.01));
  });

  test('initial overlap: no push until they part, then armed', () {
    final a = box('A', 500, 500), b = box('B', 550, 500);
    move(a, 0, [500, 500], 20, [300, 500]); // out of B, then back in
    a.transform.anchor.keyframes.add(Keyframe(frame: 40, value: [0.6, 0.5], temporal: const Easing(0, 0, 1, 1)));
    final p = Project(layers: [a, b]);
    bake(p, 40);
    expect(pos(p, 'B', 5)[0], 550, reason: 'overlapping at the start: not armed, B untouched');
    expect(pos(p, 'B', 40)[0], greaterThan(550), reason: 'armed after parting: now A pushes B');
    expect(overlapX(pos(p, 'A', 40), pos(p, 'B', 40)), lessThanOrEqualTo(1e-6));
  });

  test('a fast pusher crossing a thin target pushes it (substeps), no pass-through', () {
    final a = box('A', 100, 500, size: 40), b = box('B', 300, 500, size: 10);
    move(a, 0, [100, 500], 2, [700, 500]); // 300 px per frame, much more than its size
    final p = Project(layers: [a, b]);
    bake(p, 2);
    expect(pos(p, 'B', 2)[0], greaterThan(pos(p, 'A', 2)[0]), reason: 'B stays ahead of A');
  });

  test('an edit from frame 50 on keeps every frame before it bit-identical', () {
    final a = box('A', 100, 500), b = box('B', 400, 500);
    move(a, 0, [100, 500], 50, [450, 500]);
    a.transform.anchor.keyframes.add(Keyframe(frame: 90, value: [0.8, 0.5], temporal: const Easing(0, 0, 1, 1)));
    final p = Project(layers: [a, b]);
    final w = bake(p, 99);
    final before = [for (var f = 0; f < 50; f++) w.offsetAt('B', f)!.toList()];
    final changedLater = w.offsetAt('B', 90)!.toList();
    a.transform.anchor.keyframes.last.value = [0.5, 0.7]; // the key at 90
    bake(p, 99);
    expect(w.offsetAt('B', 90), isNot(changedLater), reason: 'the edit did change what follows');
    for (var f = 0; f < 50; f++) {
      expect(w.offsetAt('B', f), before[f], reason: 'frame $f');
    }
  });

  test('deterministic: two bakes are bit-identical', () {
    List<List<double>> run() {
      final a = box('A', 100, 500), b = box('B', 400, 520), c = box('C', 520, 470);
      move(a, 0, [100, 500], 60, [700, 520]);
      final p = Project(layers: [a, b, c]);
      final w = bake(p, 60);
      return [for (var f = 0; f <= 60; f++) ...[w.offsetAt('B', f)!, w.offsetAt('C', f)!]];
    }

    expect(run(), run());
  });

  test('contact gap: they rest that far apart', () {
    final a = box('A', 100, 500)..physics.gap = 12, b = box('B', 400, 500);
    move(a, 0, [100, 500], 30, [350, 500]);
    final p = Project(layers: [a, b]);
    bake(p, 30);
    final gapNow = (pos(p, 'B', 30)[0] - pos(p, 'A', 30)[0]) - 100;
    expect(gapNow, closeTo(12, 0.5));
  });

  test('a pendulum bar with Collide pushes a resting cube; its swing is bit-identical with Collide off', () {
    Project scene(bool collide) {
      final bar = box('bar', 500, 300, size: 40)
        ..content.size = [20, 300]
        ..content.offset = [0, 150];
      bar.pendulum = Pendulum(enabled: true);
      bar.pendulum.pivotOffset.defaultValue = [0.0, 0.0];
      // keyed motion drives the swing.
      move(bar, 0, [300, 300], 15, [700, 300]);
      bar.physics.collide = collide;
      final cube = box('cube', 760, 480, size: 60)..physics.collide = collide;
      return Project(layers: [bar, cube]);
    }

    final on = scene(true), off = scene(false);
    bake(on, 60);
    for (var f = 0; f <= 60; f++) {
      expect(evaluatePendulumOffset(on, on.layers[0], f), evaluatePendulumOffset(off, off.layers[0], f), reason: 'frame $f');
    }
    final moved = [for (var f = 0; f <= 60; f++) pos(on, 'cube', f)[0]].any((x) => x != 760);
    expect(moved, isTrue, reason: 'the swinging bar pushes the cube');
  });

  test('bake push to keys: the whole group, the same paths within 0.5 px, Collide off, no walking into each other', () {
    final a = box('A', 100, 500), b = box('B', 400, 500);
    move(a, 0, [100, 500], 60, [700, 500]);
    final p = Project(layers: [a, b]);
    final w = bake(p, 99);
    final pushedA = [for (var f = 0; f <= 99; f++) pos(p, 'A', f)];
    final pushedB = [for (var f = 0; f <= 99; f++) pos(p, 'B', f)];
    expect(bakePushToKeys(p, w, b), [a, b]);
    clearStateCaches();
    expect(a.physics.collide || b.physics.collide, isFalse);
    double dist(List<double> u, List<double> v) => math.sqrt(math.pow(u[0] - v[0], 2) + math.pow(u[1] - v[1], 2));
    for (var f = 0; f <= 99; f++) {
      expect(dist(pos(p, 'A', f), pushedA[f]), lessThanOrEqualTo(0.5), reason: 'A, frame $f');
      expect(dist(pos(p, 'B', f), pushedB[f]), lessThanOrEqualTo(0.5), reason: 'B, frame $f');
      expect(overlapX(pos(p, 'A', f), pos(p, 'B', f)), lessThanOrEqualTo(0.6), reason: 'frame $f');
    }
  });

  test('a corner hit: B is pushed along x only, the direction never flips while they touch', () {
    // A comes diagonally at B's top-left corner: both faces close on the
    // same frame (an exact corner tie) - x is taken and kept.
    final a = box('A', 300, 300), b = box('B', 500, 500);
    move(a, 0, [300, 300], 30, [600, 600]);
    final p = Project(layers: [a, b]);
    final w = bake(p, 40);
    var touched = false;
    for (var f = 0; f <= 40; f++) {
      expect(pos(p, 'B', f)[1], 500, reason: 'frame $f: never pushed along y');
      for (final c in w.contactsAt(f)) {
        touched = true;
        expect(c.normal[0].abs(), closeTo(1, 1e-9), reason: 'frame $f: the push is along x');
        expect(c.normal[0], c.a == 'A' ? 1.0 : -1.0, reason: 'frame $f: always from A to B');
      }
    }
    expect(touched, isTrue);
    expect(pos(p, 'B', 40)[0], greaterThan(500), reason: 'pushed along x');
  });

  test('timeline markers stay inside the layer and only where contact starts / ends', () {
    final a = box('A', 100, 500, frames: 60), b = box('B', 400, 500, frames: 60);
    move(a, 0, [100, 500], 40, [500, 500]);
    final p = Project(layers: [a, b]);
    final w = physicsWorldOf(p);
    // half baked: no end marker at the baked edge.
    w.bakeTo(25);
    expect(w.contactMarkers('B').length, 1, reason: 'contact started; its end is not known yet');
    w.bakeTo(60);
    final m = w.contactMarkers('B');
    expect(m.length, 2);
    expect(m.every((f) => f >= 0 && f <= 60), isTrue);
  });

  test('markers come from a whole bake: the same however the bake was split', () {
    Project scene() {
      final a = box('A', 100, 500, frames: 80), b = box('B', 400, 500, frames: 80);
      move(a, 0, [100, 500], 50, [600, 500]);
      return Project(layers: [a, b]);
    }

    final one = physicsWorldOf(scene())..bakeTo(80);
    final p2 = scene();
    final split = physicsWorldOf(p2);
    final whole = one.contactMarkers('B');
    for (var f = 0; f <= 80; f += 7) {
      split.bakeTo(f);
      // part-way: only markers the whole bake has too (no phantoms).
      expect(whole, containsAll(split.contactMarkers('B')), reason: 'baked to $f');
    }
    split.bakeTo(80);
    expect(split.contactMarkers('B'), one.contactMarkers('B'));
    expect(split.contactMarkers('B'), isNotEmpty);
  });

  test('a touch going on past the last key ends with the animation, not the layer', () {
    final a = box('A', 100, 500, frames: 120), b = box('B', 400, 500, frames: 120);
    move(a, 0, [100, 500], 50, [600, 500]);
    final w = physicsWorldOf(Project(layers: [a, b]))..bakeTo(120);
    final m = w.contactMarkers('B');
    expect(m, isNotEmpty);
    expect(m.last, 50);
  });

  test('inertia: a pushed object slides on after the push ends, slowing down', () {
    Project scene(double inertia) {
      final a = box('A', 100, 500), b = box('B', 400, 500);
      move(a, 0, [100, 500], 30, [400, 500]);
      b.physics.inertia = inertia;
      return Project(layers: [a, b]);
    }

    final still = scene(0);
    physicsWorldOf(still).bakeTo(80);
    final slide = scene(0.9);
    physicsWorldOf(slide).bakeTo(80);
    expect(pos(still, 'B', 60)[0], closeTo(pos(still, 'B', 31)[0], 0.5), reason: 'no inertia: stops with the pusher');
    expect(pos(slide, 'B', 60)[0], greaterThan(pos(slide, 'B', 31)[0] + 20), reason: 'inertia: slides on');
    final step1 = pos(slide, 'B', 41)[0] - pos(slide, 'B', 40)[0], step2 = pos(slide, 'B', 61)[0] - pos(slide, 'B', 60)[0];
    expect(step2, lessThan(step1), reason: 'slowing down');
    // the timeline's inertia mark: from where contact ended to the rest.
    final spans = physicsWorldOf(slide).inertiaSpans('B');
    expect(spans, isNotEmpty);
    expect(spans.first.$1, inInclusiveRange(29, 33));
    expect(spans.first.$2, greaterThan(spans.first.$1 + 10));
    expect(physicsWorldOf(still).inertiaSpans('B'), isEmpty);
  });

  test('frame edges collide: a pushed object stays inside the frame', () {
    final a = box('A', 600, 500), b = box('B', 850, 500);
    move(a, 0, [600, 500], 40, [990, 500]);
    final p = Project(layers: [a, b], stageWalls: true);
    physicsWorldOf(p).bakeTo(40);
    expect(pos(p, 'B', 40)[0], lessThanOrEqualTo(950.5), reason: 'its right edge at the frame\'s');
  });

  test('negative gap: they may sink in that far before pushing', () {
    final a = box('A', 100, 500), b = box('B', 400, 500);
    move(a, 0, [100, 500], 60, [700, 500]);
    b.physics.gap = -20;
    a.physics.gap = -20;
    final p = Project(layers: [a, b]);
    bake(p, 99);
    expect(overlapX(pos(p, 'A', 99), pos(p, 'B', 99)), closeTo(20, 1e-6));
  });

  test('soft: overlapping objects part over several frames, the deeper the harder', () {
    // B appears right inside A (unarmed pairs pass through), so drive A
    // into B instead, then stop: soft keeps some overlap while settling.
    final a = box('A', 100, 500), b = box('B', 400, 500);
    move(a, 0, [100, 500], 10, [700, 500]);
    b.physics.softness = 0.8;
    final p = Project(layers: [a, b]);
    bake(p, 99);
    final hard = Project(layers: [box('A', 100, 500), box('B', 400, 500)]);
    move(hard.layers[0], 0, [100, 500], 10, [700, 500]);
    bake(hard, 99);
    expect(overlapX(pos(p, 'A', 10), pos(p, 'B', 10)), greaterThan(overlapX(pos(hard, 'A', 10), pos(hard, 'B', 10)) + 1),
        reason: 'soft: still in each other right after the hit');
    expect(overlapX(pos(p, 'A', 99), pos(p, 'B', 99)), lessThan(1), reason: 'apart in the end');
  });

  test('leash: pulled back toward its point once past the length', () {
    final a = box('A', 100, 500), b = box('B', 400, 500);
    move(a, 0, [100, 500], 30, [700, 500]);
    b.physics
      ..leash = true
      ..leashPoint = [400, 500]
      ..leashLength = 0
      ..leashStrength = 0.3;
    final p = Project(layers: [a, b]);
    // A goes away again: B comes back to its point.
    a.transform.anchor.keyframes.add(Keyframe(frame: 50, value: [100 / 1000, 500 / 1000], temporal: const Easing(0, 0, 1, 1)));
    bake(p, 99);
    expect(pos(p, 'B', 30)[0], greaterThan(420), reason: 'pushed away (the leash holds back)');
    expect(pos(p, 'B', 99)[0], closeTo(400, 2), reason: 'pulled back home');
    expect(PhysicsSettings.fromJson(b.physics.toJson()).leashStrength, 0.3);
  });

  test('bend + physics: a push bends the free end instead of moving the layer, then it springs back', () {
    registerBuiltinEffects();
    final a = box('A', 100, 300, size: 80), b = box('B', 400, 500, size: 100);
    // B is tall: a stalk from y 300 to 700, bending from its lower quarter.
    b.content.size = [60, 400];
    final bend = createEffectInstance('bend_arc', 'bend1', b);
    (bend.params['react'] as Track).defaultValue = 100.0;
    (bend.params['damping'] as Track).defaultValue = 40.0;
    b.effectStack.add(bend);
    // A sweeps across B's top and away.
    move(a, 0, [100, 340], 40, [700, 340]);
    final p = Project(layers: [a, b]);
    final w = bake(p, 199);
    final mid = [for (var f = 0; f <= 60; f++) w.bendAt('B', f).abs()].reduce(math.max);
    expect(mid, greaterThan(5), reason: 'the push bent it');
    expect((pos(p, 'B', 60)[0] - 400).abs(), lessThan(1), reason: 'the layer itself stayed');
    expect(w.bendAt('B', 199).abs(), lessThan(mid / 4), reason: 'springing back');
  });
}
