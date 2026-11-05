import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer(String id, int start, int dur) => createLayer('rect')
  ..id = id
  ..name = id
  ..startFrame = start
  ..durationFrames = dur;

void main() {
  setUp(() => fps = 60);

  List<List<String>> rowsOf(Project p) => [
        for (final r in timelineRows(p)) [for (final l in r) l.id]
      ];

  test('layers without a row id each get a row; a shared id is one row', () {
    final p = Project(layers: [_layer('a', 0, 10), _layer('b', 20, 10), _layer('c', 0, 50)]);
    expect(rowsOf(p), [['a'], ['b'], ['c']]);
    p.layers[0].rowId = 'r';
    p.layers[1].rowId = 'r';
    expect(rowsOf(p), [['a', 'b'], ['c']]);
    expect(timelineRowOf(p, 'c'), 1);
  });

  test('joining a row needs free time there; the row keeps its place in paint order', () {
    final p = Project(layers: [_layer('a', 0, 10), _layer('mid', 0, 100), _layer('b', 20, 10)]);
    // b into a's row (row 0 once b is taken out).
    expect(placeLayerInTimelineRows(p, 'b', 0, join: true), isTrue);
    expect(rowsOf(p), [['a', 'b'], ['mid']]);
    expect(p.layers.map((l) => l.id), ['a', 'b', 'mid']);
    // mid overlaps both - refused, nothing changes.
    expect(placeLayerInTimelineRows(p, 'mid', 0, join: true), isFalse);
    expect(rowsOf(p), [['a', 'b'], ['mid']]);
  });

  test('own row / join the neighbour row', () {
    final p = Project(layers: [_layer('a', 0, 10), _layer('b', 20, 10), _layer('c', 40, 10)]);
    expect(joinNeighbourTimelineRow(p, 'b', up: true), isTrue);
    expect(joinNeighbourTimelineRow(p, 'c', up: true), isTrue);
    expect(rowsOf(p), [['a', 'b', 'c']]);
    expect(takeOwnTimelineRow(p, 'b'), isTrue);
    expect(rowsOf(p), [['a', 'c'], ['b']]);
    expect(p.layers.firstWhere((l) => l.id == 'b').rowId, isNull, reason: 'a one-layer row has no id');
    expect(joinNeighbourTimelineRow(p, 'a', up: false), isTrue);
    expect(rowsOf(p), [['c'], ['a', 'b']]);
  });

  test('moving and trimming stop at the neighbours in the row', () {
    final a = _layer('a', 0, 10), b = _layer('b', 30, 10), c = _layer('c', 60, 10);
    for (final l in [a, b, c]) {
      l.rowId = 'r';
    }
    final p = Project(layers: [a, b, c]);
    final limits = timelineRowLimits(p, b);
    expect(limits.minStart, 10);
    expect(limits.maxEnd, 60);

    var op = LayerTrackDragOp.grab(b, LayerDragMode.move, minStart: limits.minStart, maxEnd: limits.maxEnd);
    op.apply(-100);
    expect(b.startFrame, 10);
    op.apply(100);
    expect(b.startFrame, 50, reason: 'end stops at c');
    op.apply(0);

    op = LayerTrackDragOp.grab(b, LayerDragMode.trimLeft, minStart: limits.minStart, maxEnd: limits.maxEnd);
    op.apply(-100);
    expect([b.startFrame, b.durationFrames], [10, 30]);
    op.apply(0);
    op = LayerTrackDragOp.grab(b, LayerDragMode.trimRight, minStart: limits.minStart, maxEnd: limits.maxEnd);
    op.apply(100);
    expect(b.startFrame + b.durationFrames, 60);
  });

  test('split keeps both halves in one row', () {
    final a = _layer('a', 0, 100);
    final p = Project(layers: [a, _layer('z', 0, 10)]);
    splitLayer(p, a, 40, 'a2');
    expect(rowsOf(p), [['a', 'a2'], ['z']]);
  });

  test('gaps of a row', () {
    expect(timelineRowGaps([_layer('a', 0, 10), _layer('b', 30, 10), _layer('c', 50, 10)]), [(10, 30), (40, 50)]);
    expect(timelineRowGaps([_layer('a', 0, 10), _layer('b', 10, 10)]), isEmpty);
  });

  test('fill gaps: "–..–..–" - the other layer keeps only its parts inside the dots, in that row', () {
    // row: a [0,10) b [30,40) c [60,70) -> gaps [10,30) [40,60).
    final a = _layer('a', 0, 10), b = _layer('b', 30, 10), c = _layer('c', 60, 10);
    for (final l in [a, b, c]) {
      l.rowId = 'r';
    }
    // x spans [5, 65) and animates its rotation 0 -> 60 over that span.
    final x = _layer('x', 5, 60);
    x.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 60, value: 60.0)]);
    final p = Project(layers: [a, b, c, x]);
    var n = 0;
    final kept = fillTimelineRowGaps(p, Selection(), 'x', 0, newLayerId: () => 'x${++n}')!;
    expect([for (final k in kept) (k.startFrame, k.startFrame + k.durationFrames)], [(10, 30), (40, 60)]);
    expect(timelineRows(p).length, 1, reason: 'the parts joined the row; nothing else is left of x');
    expect(rowsOf(p).single.length, 5);
    // a cut, not a move: the part at [40,60) shows what x showed at frame 40.
    final second = kept[1];
    final rot = evaluateTrack(p, second.transform.rotation, 0, second) as double;
    expect(rot, closeTo(35, 1e-6));
  });

  test('fill gaps does nothing when no gap overlaps the layer', () {
    final a = _layer('a', 0, 10), b = _layer('b', 30, 10);
    a.rowId = b.rowId = 'r';
    final x = _layer('x', 100, 10);
    final p = Project(layers: [a, b, x]);
    expect(fillTimelineRowGaps(p, Selection(), 'x', 0, newLayerId: () => 'n'), isNull);
    expect(p.layers.length, 3);
  });

  test('row id survives save/load', () {
    final a = _layer('a', 0, 10)..rowId = 'r';
    final back = layerFromJson(layerToJson(a));
    expect(back.rowId, 'r');
    expect(layerToJson(_layer('b', 0, 1)).containsKey('row'), isFalse);
  });

  group('loop', () {
    test('repeats the first pass until the limit, then stops', () {
      final l = _layer('l', 10, 20)..loopEnabled = true;
      l.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 20, value: 20.0)]);
      final p = Project(layers: [l]);
      double rot(int f) => getLayerStateAt(p, 'l', f).rot;
      expect(rot(15), closeTo(5, 1e-9));
      expect(rot(35), closeTo(5, 1e-9), reason: 'second pass');
      expect(rot(1015), closeTo(5, 1e-9), reason: 'no limit: keeps going');
      expect(getLayerStateAt(p, 'l', 1015).inRange, isTrue);
      l.loopUntil = 50;
      clearStateCaches();
      expect(getLayerStateAt(p, 'l', 45).inRange, isTrue);
      expect(getLayerStateAt(p, 'l', 55).inRange, isFalse);
      expect(layerVisibleEnd(l), 50);
      expect(recomputeMaxFrameToFit([l], 1), 50);
      expect(localFrameOf(l, 35), 5, reason: 'edits on a repeat go to the first pass');
    });

    test('a looping layer occupies its row up to the limit; split leaves the loop on the right part', () {
      final a = _layer('a', 0, 10)..loopEnabled = true..loopUntil = 40;
      final b = _layer('b', 50, 10);
      final p = Project(layers: [a, b]);
      expect(placeLayerInTimelineRows(p, 'b', 0, join: true), isTrue);
      b.startFrame = 30;
      expect(fitsInTimelineRow([a], b), isFalse, reason: 'inside the repeats');
      final c = _layer('c', 0, 100)..loopEnabled = true;
      final p2 = Project(layers: [c]);
      final right = splitLayer(p2, c, 40, 'c2')!;
      expect([c.loopEnabled, right.loopEnabled], [false, true]);
    });

    test('loop survives save/load', () {
      final l = _layer('l', 0, 10)..loopEnabled = true..loopUntil = 90;
      final back = layerFromJson(layerToJson(l));
      expect([back.loopEnabled, back.loopUntil], [true, 90]);
      expect(layerFromJson(layerToJson(_layer('m', 0, 1))).loopEnabled, isFalse);
    });
  });

  test('lay over a row: the layer exists only where the row has layers, in a new row drawn over it', () {
    // row: a [0,10) b [30,40); x [5,35) -> parts [5,10) and [30,35).
    final a = _layer('a', 0, 10), b = _layer('b', 30, 10);
    a.rowId = b.rowId = 'r';
    final other = _layer('o', 0, 5);
    final x = _layer('x', 5, 30);
    final p = Project(layers: [a, b, other, x]);
    var n = 0;
    final kept = overlayTimelineRow(p, Selection(), 'x', 0, newLayerId: () => 'x${++n}')!;
    expect([for (final k in kept) (k.startFrame, k.startFrame + k.durationFrames)], [(5, 10), (30, 35)]);
    expect(rowsOf(p), [
      ['a', 'b'],
      [for (final k in kept) k.id],
      ['o']
    ]);
    expect(overlayTimelineRow(p, Selection(), 'o', 0, newLayerId: () => 'z'), isNotNull);
  });
}
