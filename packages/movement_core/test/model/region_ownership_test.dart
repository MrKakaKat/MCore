import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _sq(String id, double side, double x) => createLayer('rect')
  ..id = id
  ..name = id.toUpperCase()
  ..content.size = [side, side]
  ..transform.anchor.defaultValue = [x, 0.5];

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    clearRegionBakes();
  });

  test('a layer lists its own regions: 3, 5 and 9 for 2, 3 and 4 shapes', () {
    for (final (n, count) in [(2, 3), (3, 5), (4, 9)]) {
      final l = _sq('a', 100, 0.5)..maskRegions = MaskRegions(sources: ['a', for (var i = 1; i < n; i++) 's$i']);
      expect(ownedRegionSigs(l), hasLength(count), reason: '$n shapes');
      expect(ownedRegionSigs(l).last, 0, reason: 'Outer last');
      expect(regionOuterEmpty(l), isTrue, reason: 'a plain shape has nothing outside itself');
    }
  });

  test('regions on A only: B still splits A; B lists nothing; labels name the owner', () {
    final a = _sq('a', 200, 0.45)..maskRegions = MaskRegions(sources: ['a', 'b']);
    final b = _sq('b', 200, 0.55);
    final p = Project(layers: [b, a]);
    final geo = maskRegionGeometry(p, a, 0)!;
    expect(geo[3].exists && geo[1].exists, isTrue, reason: 'A + B and A − B');
    expect(ownedRegionSigs(a), [3, 1, 0]);
    expect(ownedRegionSigs(b), isEmpty);
    expect(regionLabel(p, a, 3), 'A + B · A');
    expect(regionLabel(p, a, 1), 'A − B');
    expect(regionLabel(p, a, 0), 'Outer');
  });

  test('numbering is shared: A and B see the same overlap with the same number', () {
    final a = _sq('a', 100, 0.5)
      ..durationFrames = 60
      ..maskRegions = MaskRegions(sources: ['a', 'b'], numbered: true);
    final b = createLayer('circle')
      ..id = 'b'
      ..durationFrames = 60
      ..content.size = [40, 40]
      ..maskRegions = MaskRegions(sources: ['b', 'a'], numbered: true);
    b.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [0.35, 0.5]),
      Keyframe(frame: 60, value: [0.65, 0.5]),
    ];
    final p = Project(layers: [a, b]);
    final ea = regionEpisodes(p, a).episodes.where((e) => e.sig == 3).toList();
    final eb = regionEpisodes(p, b).episodes.where((e) => e.sig == 3).toList();
    expect(ea, hasLength(1));
    expect(eb, hasLength(1));
    expect(ea.single.number, eb.single.number);
    expect(ea.single.start, eb.single.start);
    // B − A in B's own order is sig 1 (B is B's first shape).
    expect(regionEpisodes(p, b).episodes.any((e) => e.sig == 1), isTrue);
    // a command on A's part doesn't touch B's.
    a.maskRegions!.opacity[3] = track(1.0);
    b.maskRegions!.opacity[3] = track(1.0);
    a.maskRegions!.commands.add(RegionCommand(whenSig: 3, targetSig: 3, opacity: 0, timed: false));
    final f = ea.single.start + 1;
    expect(regionOpacityAt(p, a, regionEpisodes(p, a), 3, null, f), 0.0);
    expect(regionOpacityAt(p, b, regionEpisodes(p, b), 3, null, f), 1.0);
  });

  test('old projects (content masked by other shapes) list every cell and keep rendering as they were', () {
    final t = _sq('t', 900, 0.5)..maskRegions = MaskRegions(sources: ['a'], opacity: {0: track(1.0)});
    expect(regionSelfIndex(t), isNull);
    expect(ownedRegionSigs(t).toSet(), {0, 1});
    expect(regionOuterEmpty(t), isFalse);
  });

  test('older regions on a shape take the shape itself in when loaded, showing the same', () {
    final b = _sq('b', 200, 0.55)
      ..maskRegions = MaskRegions(
          sources: ['a'], opacity: {1: track(0.0), 0: track(1.0)}, commands: [RegionCommand(whenSig: 1, targetSig: 1, timed: true)]);
    final json = layerToJson(b);
    final back = layerFromJson(json);
    final mr = back.maskRegions!;
    expect(mr.sources, ['a', 'b']);
    expect(ownedRegionSigs(back), [3, 2, 0]);
    expect(mr.opacity[3]!.defaultValue, 0.0, reason: 'inside A (and B) stays hidden');
    expect(mr.opacity[2]!.defaultValue, 1.0, reason: 'B outside A stays shown');
    expect(mr.commands.single.targetSig, 3);
    expect(mr.commands.single.whenSig, 1);
    // a picture stays content masked by the others.
    final v = createLayer('image')
      ..id = 'v'
      ..maskRegions = MaskRegions(sources: ['a']);
    expect(layerFromJson(layerToJson(v)).maskRegions!.sources, ['a']);
  });
}
