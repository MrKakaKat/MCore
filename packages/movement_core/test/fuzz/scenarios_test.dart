// Randomized scenarios (fixed seeds): many combinations of the features at
// once, each checked against what must always hold.
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

const runs = 60;

double rnd(math.Random r, double a, double b) => a + r.nextDouble() * (b - a);

Layer randomLayer(math.Random r, String id, {int frames = 120, bool turn = true}) {
  final l = createLayer('rect')
    ..id = id
    ..durationFrames = frames;
  l.content.size = [rnd(r, 20, 200), rnd(r, 20, 200)];
  final n = 2 + r.nextInt(4);
  final fs = <int>{0, frames};
  while (fs.length < n) {
    fs.add(1 + r.nextInt(frames - 1));
  }
  final sorted = fs.toList()..sort();
  l.transform.anchor.keyframes = [
    for (final f in sorted)
      Keyframe(
          frame: f,
          value: <double>[rnd(r, 0.1, 0.9), rnd(r, 0.1, 0.9)],
          temporal: r.nextBool() ? const Easing(0, 0, 1, 1) : const Easing(0.42, 0, 0.58, 1))
  ];
  if (r.nextBool()) l.transform.anchor.tension = rnd(r, 0, 1);
  autoComputeTangents(l.transform.anchor);
  if (turn && r.nextBool()) {
    l.transform.rotation.keyframes = [
      Keyframe(frame: 0, value: rnd(r, -90, 90)),
      Keyframe(frame: frames, value: rnd(r, -360, 360)),
    ];
  }
  return l;
}

List<double> centre(Project p, Layer l, num f) => computeLayerFrameGeometry(p, l, f.round(), includeVertices: false).center;
List<double> pos(Project p, Layer l, num f) {
  final m = getLayerStateAt(p, l.id, f).matrix;
  return [m[4] * stageSize.width, m[5] * stageSize.height];
}

double dist(List<double> a, List<double> b) => math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));
bool finite(List<double> v) => v.every((x) => x.isFinite);

List<List<double>> randomWalk(math.Random r, List<double> from, int n) {
  final out = [from];
  var a = rnd(r, 0, 2 * math.pi);
  for (var i = 1; i < n; i++) {
    a += rnd(r, -0.6, 0.6);
    final s = rnd(r, 2, 15);
    out.add([out.last[0] + math.cos(a) * s, out.last[1] + math.sin(a) * s]);
  }
  return out;
}

void stage(math.Random r) {
  setStageSize([640.0, 1000.0, 1080.0, 1920.0][r.nextInt(4)], [400.0, 1000.0, 1920.0, 1080.0][r.nextInt(4)]);
  clearStateCaches();
}

void main() {
  test('frames worked out in any order give the same poses (no state leaks between frames)', () {
    final r = math.Random(1);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final a = randomLayer(r, 'A'), b = randomLayer(r, 'B');
      if (r.nextBool()) {
        b.parentId = 'A';
        b
          ..inheritPosition = r.nextBool()
          ..inheritRotation = r.nextBool()
          ..inheritScale = r.nextBool();
        if (r.nextBool()) a.rotateOrigin = [rnd(r, -50, 50), rnd(r, -50, 50)];
      }
      final p = Project(layers: [a, b]);
      final frames = [for (var f = 0; f <= 120; f += 3) f];
      final fwd = {for (final f in frames) f: getLayerStateAt(p, 'B', f).matrix};
      clearStateCaches();
      final back = {for (final f in frames.reversed) f: getLayerStateAt(p, 'B', f).matrix};
      clearStateCaches();
      final shuffled = [...frames]..shuffle(r);
      final mixed = {for (final f in shuffled) f: getLayerStateAt(p, 'B', f).matrix};
      for (final f in frames) {
        for (var i = 0; i < 6; i++) {
          expect(back[f]![i], closeTo(fwd[f]![i], 1e-9), reason: 'run $run frame $f');
          expect(mixed[f]![i], closeTo(fwd[f]![i], 1e-9), reason: 'run $run frame $f');
        }
      }
    }
  });

  test('saved and opened again: the same poses at every frame', () {
    final r = math.Random(2);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final a = randomLayer(r, 'A');
      if (r.nextBool()) a.transform.anchor.constantSpeed = true;
      if (r.nextBool()) a.transform.anchor.globalEasing = easingPresets['easeInOut'];
      if (r.nextBool()) startHandTangents(a.transform.anchor);
      if (r.nextBool()) addFreeMoveLayer(Project(layers: [a]), a, randomWalk(r, [300, 300], 30), r.nextInt(60), 10 + r.nextInt(40), smoothing: rnd(r, 0, 1));
      final p = Project(layers: [a]);
      final p2 = Project(layers: projectLayersFromJson(projectLayersToJson(p)));
      for (var f = 0; f <= 120; f += 5) {
        final m1 = getLayerStateAt(p, 'A', f).matrix, m2 = getLayerStateAt(p2, 'A', f).matrix;
        for (var i = 0; i < 6; i++) {
          expect(m2[i], closeTo(m1[i], 1e-9), reason: 'run $run frame $f');
        }
      }
    }
  });

  test('drawn anew between two keys: the keys stay, the way runs from one to the other; removed: straight again', () {
    final r = math.Random(3);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final l = randomLayer(r, 'A', turn: false);
      final p = Project(layers: [l]);
      if (r.nextBool()) addFreeMoveLayer(p, l, randomWalk(r, centre(p, l, 0), 20), r.nextInt(60), 20, smoothing: 0.5);
      clearStateCaches();
      final trk = l.transform.anchor;
      final ks = trk.keyframes.where((k) => !k.passive).toList();
      final pairs = [for (var i = 0; i + 1 < ks.length; i++) if (ks[i + 1].frame - ks[i].frame >= 2) (ks[i].frame, ks[i + 1].frame)];
      if (pairs.isEmpty) continue;
      final (a, b) = pairs[r.nextInt(pairs.length)];
      final before = {for (final k in ks) k.frame: [...k.value as List<double>]};
      final ca = centre(p, l, a), cb = centre(p, l, b);
      final ok = replaceMoveBetweenKeys(p, l, trk, a, b, randomWalk(r, ca, 5 + r.nextInt(80)), smoothing: rnd(r, 0, 1));
      expect(ok, isTrue);
      clearStateCaches();
      for (final k in trk.keyframes.where((k) => !k.passive)) {
        expect(k.value, before[k.frame], reason: 'run $run: key ${k.frame} kept');
      }
      expect(trk.keyframes.where((k) => !k.passive).length, ks.length);
      expect(dist(centre(p, l, a), ca), lessThan(1e-6), reason: 'run $run: starts at its key');
      expect(dist(centre(p, l, b), cb), lessThan(1e-6), reason: 'run $run: ends at its key');
      for (var f = 0; f <= 120; f++) {
        expect(finite(centre(p, l, f)), isTrue, reason: 'run $run frame $f');
      }
      expect(trk.keyframes.every((k) => !k.passive || (k.frame > a && k.frame < b)), isTrue, reason: "run $run ($a, $b): ${[for (final k in trk.keyframes) "${k.frame}${k.passive ? "p" : ""}"]}");
      expect(removeMoveBetweenKeys(trk, a, b), isTrue);
      expect(trk.keyframes.any((k) => k.passive && k.frame > a && k.frame < b), isFalse);
      for (final k in trk.keyframes.where((k) => !k.passive)) {
        expect(k.value, before[k.frame]);
      }
    }
  });

  test('a key taken away takes the drawn ways next to it, and only those', () {
    final r = math.Random(4);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final l = createLayer('rect')
        ..id = 'A'
        ..durationFrames = 200;
      l.transform.anchor.keyframes = [
        for (var i = 0; i <= 4; i++) Keyframe(frame: i * 40, value: <double>[rnd(r, 0.1, 0.9), rnd(r, 0.1, 0.9)])
      ];
      final p = Project(layers: [l]);
      final trk = l.transform.anchor;
      // a drawn way in some stretches.
      final drawn = [for (var i = 0; i < 4; i++) if (r.nextBool()) i];
      for (final i in drawn) {
        replaceMoveBetweenKeys(p, l, trk, i * 40, i * 40 + 40, randomWalk(r, centre(p, l, i * 40), 30), smoothing: 0.3);
      }
      bindFreeMoveKeys(l);
      final gone = r.nextInt(5);
      trk.keyframes.removeWhere((k) => !k.passive && k.frame == gone * 40);
      bindFreeMoveKeys(l);
      for (var i = 0; i < 4; i++) {
        final has = trk.keyframes.any((k) => k.passive && k.frame > i * 40 && k.frame < i * 40 + 40);
        final next = i == gone || i + 1 == gone;
        expect(has, drawn.contains(i) && !next, reason: 'run $run stretch $i, key ${gone * 40} gone');
      }
    }
  });

  test('the whole way turned and sized keeps its shape, and turning back puts it back', () {
    final r = math.Random(5);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final l = randomLayer(r, 'A', turn: false);
      final p = Project(layers: [l]);
      if (r.nextBool()) l.transform.anchor.constantSpeed = true;
      for (var i = r.nextInt(3); i > 0; i--) {
        addFreeMoveLayer(p, l, randomWalk(r, centre(p, l, 0), 25), r.nextInt(100), 5 + r.nextInt(30), smoothing: rnd(r, 0, 1));
      }
      clearStateCaches();
      final before = [for (var f = 0; f <= 120; f += 4) pos(p, l, f)];
      final deg = rnd(r, -180, 180), k = rnd(r, 0.5, 2);
      turnWholePosition(p, l, degrees: deg, k: k, w: stageSize.width, h: stageSize.height);
      clearStateCaches();
      final after = [for (var f = 0; f <= 120; f += 4) pos(p, l, f)];
      for (var i = 0; i < before.length; i += 3) {
        for (var j = i + 1; j < before.length; j += 5) {
          expect(dist(after[i], after[j]), closeTo(dist(before[i], before[j]) * k, 0.01 + 1e-6 * k * dist(before[i], before[j])),
              reason: 'run $run frames ${i * 4}, ${j * 4}');
        }
      }
      turnWholePosition(p, l, k: 1 / k, w: stageSize.width, h: stageSize.height);
      turnWholePosition(p, l, degrees: -deg, w: stageSize.width, h: stageSize.height);
      clearStateCaches();
      for (var i = 0; i < before.length; i++) {
        expect(dist(pos(p, l, i * 4), before[i]), lessThan(0.01), reason: 'run $run frame ${i * 4}: back');
      }
    }
  });

  test('a child following only its parent\'s place moves as the parent\'s turning point does', () {
    final r = math.Random(6);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final parent = randomLayer(r, 'P');
      parent.transform.rotation.keyframes = [
        Keyframe(frame: 0, value: rnd(r, -180, 180)),
        Keyframe(frame: 120, value: rnd(r, -720, 720)),
      ];
      if (r.nextBool()) parent.rotateOrigin = [rnd(r, -100, 100), rnd(r, -100, 100)];
      final child = randomLayer(r, 'C', turn: false);
      child.transform.anchor.keyframes = [Keyframe(frame: 0, value: <double>[rnd(r, 0.1, 0.9), rnd(r, 0.1, 0.9)])];
      child
        ..parentId = 'P'
        ..inheritPosition = true
        ..inheritRotation = false
        ..inheritScale = false;
      final p = Project(layers: [parent, child]);
      // the parent's own anchor with no turn: where its turning point goes.
      List<double> anchorPx(int f) {
        final v = evaluateTrack(p, parent.transform.anchor, f.toDouble(), parent) as List<double>;
        return [v[0] * stageSize.width, v[1] * stageSize.height];
      }

      final c0 = pos(p, child, 0), a0 = anchorPx(0);
      for (var f = 0; f <= 120; f += 6) {
        final c = pos(p, child, f), a = anchorPx(f);
        expect(c[0] - c0[0], closeTo(a[0] - a0[0], 1e-6), reason: 'run $run frame $f');
        expect(c[1] - c0[1], closeTo(a[1] - a0[1], 1e-6), reason: 'run $run frame $f');
      }
    }
  });

  test('constant speed: the same distance every frame on any stage', () {
    final r = math.Random(7);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final l = randomLayer(r, 'A', turn: false);
      l.transform.anchor.constantSpeed = true;
      final p = Project(layers: [l]);
      // the way gone along in each frame (a sharp turn back inside a
      // frame is still the same way gone).
      double way(int f) {
        var s = 0.0;
        for (var i = 1; i <= 20; i++) {
          s += dist(pos(p, l, f - 1 + i / 20), pos(p, l, f - 1 + (i - 1) / 20));
        }
        return s;
      }

      final steps = [for (var f = 1; f <= 120; f++) way(f)];
      final mean = steps.reduce((a, b) => a + b) / steps.length;
      if (mean < 0.5) continue;
      for (var i = 0; i < steps.length; i++) {
        expect(steps[i], closeTo(mean, mean * 0.06 + 0.05), reason: 'run $run step $i (mean $mean)');
      }
    }
  });

  test('motion blur: the shutter never closes below its angle nor stays open over 8 frames', () {
    final r = math.Random(8);
    for (var run = 0; run < runs; run++) {
      stage(r);
      final l = randomLayer(r, 'A');
      l.motionBlur = MotionBlur(enabled: true, shutterAngle: rnd(r, 0, 360), sensitivity: r.nextBool() ? 0 : rnd(r, 0, 1));
      final p = Project(layers: [l]);
      final s = l.motionBlur.shutterAngle / 360;
      for (var f = 0; f <= 120; f += 7) {
        final w = motionBlurWindow(p, l, f);
        expect(w, greaterThanOrEqualTo(s - 1e-12));
        expect(w, lessThanOrEqualTo(math.max(s, 8.0) + 1e-12));
        if (l.motionBlur.sensitivity == 0) expect(w, s);
      }
    }
  });

  test('where layers meet on a frame: the one ending there always shows, never neither', () {
    final r = math.Random(9);
    for (var run = 0; run < runs * 3; run++) {
      final ls = <Layer>[];
      for (var i = 0; i < 2 + r.nextInt(5); i++) {
        ls.add(createLayer('rect')
          ..id = 'L$i'
          ..startFrame = 10 * r.nextInt(6)
          ..durationFrames = 10 * (1 + r.nextInt(4))
          ..hidden = r.nextInt(6) == 0);
      }
      final p = Project(layers: ls..shuffle(r));
      for (var f = 0; f <= 100; f += 10) {
        final hide = junctionHidden(p, f);
        for (final id in hide) {
          final l = ls.firstWhere((l) => l.id == id);
          expect(l.startFrame, f, reason: 'only a layer starting there is left out');
          expect(l.startFrame + l.durationFrames == f, isFalse);
        }
        final there = ls.where((l) => !l.hidden && l.startFrame <= f && l.startFrame + l.durationFrames >= f);
        if (there.isNotEmpty) expect(there.any((l) => !hide.contains(l.id)), isTrue, reason: 'run $run frame $f');
      }
    }
  });

  test('a folder packed: no two of its layers in one row at the same time', () {
    final r = math.Random(10);
    for (var run = 0; run < runs; run++) {
      final ls = <Layer>[
        for (var i = 0; i < 2 + r.nextInt(7); i++)
          createLayer('rect')
            ..id = 'L$i'
            ..startFrame = r.nextInt(100)
            ..durationFrames = 5 + r.nextInt(40)
            ..folder = 'F'
      ];
      final p = Project(layers: ls);
      packFolderRows(p, 'F');
      for (final row in timelineRows(p)) {
        for (var i = 0; i < row.length; i++) {
          for (var j = i + 1; j < row.length; j++) {
            final a = row[i], b = row[j];
            final overlap = a.startFrame < b.startFrame + b.durationFrames && b.startFrame < a.startFrame + a.durationFrames;
            expect(overlap, isFalse, reason: 'run $run: ${a.id} [${a.startFrame}+${a.durationFrames}] / ${b.id} [${b.startFrame}+${b.durationFrames}]');
          }
        }
      }
      expect(timelineRows(p).expand((r) => r).length, ls.length, reason: 'none lost');
    }
  });
}
