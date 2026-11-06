import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Keyframe _k(int f, List<double> v) => Keyframe(frame: f, value: v);

/// A: a 100 px square in the middle (450..550); B: a 40 px circle moved by
/// `bx` (its centre, px) keys; T: the masked layer, numbering on.
({Project p, Layer t, Layer a, Layer b}) scene(List<(int, double, double)> bKeys, {int duration = 120}) {
  setStageSize(1000, 1000);
  clearStateCaches();
  clearRegionBakes();
  final a = createLayer('rect')
    ..id = 'a'
    ..name = 'Square'
    ..durationFrames = duration
    ..content.size = [100, 100]
    ..transform.anchor.defaultValue = [0.5, 0.5];
  final b = createLayer('circle')
    ..id = 'b'
    ..name = 'Circle'
    ..durationFrames = duration
    ..content.size = [40, 40];
  b.transform.anchor.keyframes = [for (final (f, x, y) in bKeys) _k(f, [x / 1000, y / 1000])];
  final t = createLayer('rect')
    ..id = 't'
    ..durationFrames = duration
    ..content.size = [900, 900]
    ..transform.anchor.defaultValue = [0.5, 0.5]
    ..maskRegions = MaskRegions(sources: ['a', 'b'], numbered: true, opacity: {3: track(1.0)});
  return (p: Project(layers: [a, b, t]), t: t, a: a, b: b);
}

List<RegionEpisode> overlaps(RegionBake b) => [for (final e in b.episodes) if (e.sig == 3) e];

void main() {
  test('B passes through A: one episode, #1, footprint at the deepest frame, open then final', () {
    final s = scene([(0, 380, 500), (60, 620, 500)]);
    final bake = regionEpisodes(s.p, s.t);
    final eps = overlaps(bake);
    expect(eps, hasLength(1));
    expect(eps.single.number, 1);
    expect(eps.single.end, isNotNull, reason: 'B left A');
    final fp = bake.footprints.single;
    expect(fp.area, closeTo(eps.single.peakArea, 1e-6));
    expect(fp.area, greaterThan(1100), reason: 'the whole circle inside the square');
    expect(fp.openAt(eps.single.start + 2), isTrue, reason: 'dashed while it runs');
    expect(fp.openAt(eps.single.end! + 1), isFalse, reason: 'solid once B is out');
  });

  test('touching again inside footprint #1 without going deeper: no new number', () {
    // depth 30, out, then depth 20.
    final s = scene([(0, 400, 500), (20, 460, 500), (40, 400, 500), (60, 400, 500), (80, 450, 500), (100, 400, 500)]);
    final eps = overlaps(regionEpisodes(s.p, s.t));
    expect(eps, hasLength(2));
    expect(eps[0].number, 1);
    expect(eps[1].number, isNull);
    expect(eps[1].pendingAs, 1, reason: 'a repeat of #1');
    expect(eps[1].numberAt(80), 1);
  });

  test('touching again inside #1 and going deeper: #2 at the breakthrough frame', () {
    final s = scene([(0, 400, 500), (20, 460, 500), (40, 400, 500), (60, 400, 500), (80, 475, 500), (100, 400, 500)]);
    final eps = overlaps(regionEpisodes(s.p, s.t));
    expect(eps, hasLength(2));
    expect(eps[1].number, 2);
    final bt = eps[1].breakthrough!;
    expect(bt, greaterThan(eps[1].start), reason: 'pending first');
    expect(eps[1].numberAt(bt - 1), 1);
    expect(eps[1].numberAt(bt), 2);
  });

  test('touching somewhere outside #1: #2 at once', () {
    final s = scene([(0, 400, 500), (20, 460, 500), (40, 400, 500), (45, 300, 300), (55, 500, 300), (60, 500, 400), (80, 500, 460), (100, 500, 400)]);
    final eps = overlaps(regionEpisodes(s.p, s.t));
    expect(eps, hasLength(2));
    expect(eps[1].number, 2);
    expect(eps[1].breakthrough, isNull);
  });

  test('the pair moves across the stage and repeats the contact: the same number', () {
    final s = scene([(0, 400, 500), (20, 460, 500), (40, 400, 500), (45, 400, 300), (55, 600, 300), (60, 600, 500), (80, 660, 500), (100, 600, 500)]);
    // A jumps 200 px right between the two contacts.
    s.a.transform.anchor.keyframes = [_k(50, [0.5, 0.5]), _k(55, [0.7, 0.5])];
    final eps = overlaps(regionEpisodes(s.p, s.t));
    expect(eps, hasLength(2));
    expect(eps[1].numberAt(80), 1, reason: 'footprints are kept relative to the sources');
  });

  test('a U-shaped A and a bar: two pieces on one frame are #1 (left) and #2 (right); merging keeps #1', () {
    setStageSize(1000, 1000);
    clearStateCaches();
    clearRegionBakes();
    final u = createLayer('polygon')
      ..id = 'u'
      ..durationFrames = 80
      ..content.points = [
        [-60, -60], [-30, -60], [-30, 30], [30, 30], [30, -60], [60, -60], [60, 60], [-60, 60]
      ]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final bar = createLayer('rect')
      ..id = 'bar'
      ..durationFrames = 80
      ..content.size = [200, 20];
    bar.transform.anchor.keyframes = [_k(0, [0.5, 0.4]), _k(60, [0.5, 0.56])];
    final t = createLayer('rect')
      ..id = 't'
      ..durationFrames = 80
      ..content.size = [900, 900]
      ..transform.anchor.defaultValue = [0.5, 0.5]
      ..maskRegions = MaskRegions(sources: ['u', 'bar'], numbered: true);
    final eps = overlaps(regionEpisodes(Project(layers: [u, bar, t]), t));
    final first = eps.where((e) => e.start == eps.first.start).toList();
    expect(first, hasLength(2), reason: 'both arms on the same frame');
    final left = first.firstWhere((e) => e.number == 1), right = first.firstWhere((e) => e.number == 2);
    final f = left.start;
    double cx(RegionEpisode e) => e.pieces[f]!.first.map((p) => p[0]).reduce((a, b) => a + b) / e.pieces[f]!.first.length;
    expect(cx(left), lessThan(cx(right)));
    // the bar reaches the U's base: one piece, #1 goes on, #2 ends.
    expect(right.end, isNotNull);
    expect(left.end == null || left.end! > right.end!, isTrue);
  });

  test('a grazing touch that flickers stays one episode', () {
    final s = scene([for (var f = 0; f <= 20; f++) (f, f.isEven ? 430.6 : 429.4, 500.0)], duration: 20);
    final eps = overlaps(regionEpisodes(s.p, s.t));
    expect(eps.length, lessThanOrEqualTo(1));
  });

  test('determinism: two bakes are identical; an edit at frame 50 keeps what came before', () {
    final keys = [(0, 400.0, 500.0), (20, 460.0, 500.0), (40, 400.0, 500.0), (60, 400.0, 500.0), (80, 470.0, 500.0), (100, 400.0, 500.0)];
    final s1 = scene(keys);
    final a = regionBakeFingerprint(regionEpisodes(s1.p, s1.t));
    clearRegionBakes();
    clearStateCaches();
    expect(regionBakeFingerprint(regionEpisodes(s1.p, s1.t)), a);
    // edit after frame 50.
    s1.b.transform.anchor.keyframes[4].value = [0.48, 0.5];
    clearStateCaches();
    final after = regionEpisodes(s1.p, s1.t);
    final e0 = overlaps(after).first;
    expect(e0.start, lessThan(50));
    expect(e0.number, 1);
    expect(e0.end, lessThan(50));
  });

  test('a renumbering edit is flagged', () {
    final s = scene([(0, 400, 500), (20, 460, 500), (40, 400, 500), (45, 300, 300), (55, 500, 300), (60, 500, 400), (80, 500, 460), (100, 500, 400)]);
    regionEpisodes(s.p, s.t);
    // the first contact goes: the top one becomes #1.
    s.b.transform.anchor.keyframes[1].value = [0.4, 0.5];
    clearStateCaches();
    final b = regionEpisodes(s.p, s.t);
    expect(b.renumbered, isNotEmpty);
  });

  test('command: when A·B appears, a region fades to 0 over 10 frames', () {
    final s = scene([(0, 380, 500), (60, 620, 500)]);
    s.t.maskRegions!.opacity[1] = track(1.0);
    s.t.maskRegions!.commands.add(RegionCommand(when: 'appears', whenSig: 3, targetSig: 1, opacity: 0, frames: 10, ease: 'linear', timed: true));
    final bake = regionEpisodes(s.p, s.t);
    final e = overlaps(bake).single.start;
    expect(regionOpacityAt(s.p, s.t, bake, 1, null, e - 1), 1.0);
    expect(regionOpacityAt(s.p, s.t, bake, 1, null, e + 5), closeTo(0.5, 0.01));
    expect(regionOpacityAt(s.p, s.t, bake, 1, null, e + 10), 0.0);
    expect(regionInWords(s.p, s.t.maskRegions!, 1), 'inside Square, outside Circle');
  });

  test('baking a step at a time gives the same bake as at once', () {
    final keys = [(0, 400.0, 500.0), (20, 460.0, 500.0), (40, 400.0, 500.0), (60, 400.0, 500.0), (80, 470.0, 500.0), (100, 400.0, 500.0)];
    final s = scene(keys);
    final whole = regionBakeFingerprint(regionEpisodes(s.p, s.t));
    clearRegionBakes();
    clearStateCaches();
    var steps = 0;
    while (!regionBakeStep(s.p, s.t, budgetMs: 0)) {
      steps++;
    }
    expect(steps, greaterThan(1));
    expect(regionBakeCurrent(s.p, s.t), isTrue);
    expect(regionBakeFingerprint(regionEpisodesReady(s.p, s.t)), whole);
  });
}
