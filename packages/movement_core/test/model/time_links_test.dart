import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Timeline links: linked layers move together in time.
void main() {
  setUp(() => fps = 60);

  Layer layer(String id, int start, int dur) => createLayer('rect')
    ..id = id
    ..name = id
    ..startFrame = start
    ..durationFrames = dur;

  test('link, link a third (groups merge), unlink; a group of one dissolves', () {
    final a = layer('a', 0, 10), b = layer('b', 0, 10), c = layer('c', 0, 10);
    final p = Project(layers: [a, b, c]);
    linkInTime(p, a, b);
    expect(areTimeLinked(a, b), isTrue);
    expect(timeLinkGroup(p, a), [a, b]);
    linkInTime(p, c, b);
    expect(timeLinkGroup(p, a).toSet(), {a, b, c});
    unlinkInTime(p, a);
    expect(a.linkId, isNull);
    expect(areTimeLinked(b, c), isTrue);
    unlinkInTime(p, b);
    expect(c.linkId, isNull, reason: 'nothing left to be linked with');
  });

  test('dragging one moves the linked layers the same way; trimming does not', () {
    final a = layer('a', 10, 20), b = layer('b', 40, 5);
    final p = Project(layers: [a, b]);
    linkInTime(p, a, b);
    final lim = timeLinkShiftLimits(p, [a, b]);
    final op = LayerTrackDragOp.grab(a, LayerDragMode.move, partners: [a, b], minDelta: lim.minDelta, maxDelta: lim.maxDelta);
    op.apply(15);
    expect([a.startFrame, b.startFrame], [25, 55]);
    op.apply(-50); // a could only go to 0: the group stops together
    expect([a.startFrame, b.startFrame], [0, 30]);
    op.apply(0);
    expect([a.startFrame, b.startFrame], [10, 40], reason: 'cancel puts both back');

    final trim = LayerTrackDragOp.grab(a, LayerDragMode.trimLeft);
    trim.apply(5);
    expect(b.startFrame, 40);
  });

  test('a row neighbour stops the whole group; members in one row do not block each other', () {
    // a and b share a row (like the halves of a split), w sits after b.
    final a = layer('a', 0, 10), b = layer('b', 10, 10), w = layer('w', 30, 10);
    a.rowId = b.rowId = w.rowId = 'r';
    final p = Project(layers: [a, b, w]);
    linkInTime(p, a, b);
    expect(shiftTimeLinked(p, a, 50), 10, reason: 'b reaches w');
    expect([a.startFrame, b.startFrame], [10, 20]);
    expect(shiftTimeLinked(p, b, 0), -10, reason: 'a reaches frame 0 first');
    expect([a.startFrame, b.startFrame], [0, 10]);
  });

  test('saved, loaded, cloned; a split piece stays in the group', () {
    final a = layer('a', 0, 20), b = layer('b', 0, 20);
    final p = Project(layers: [a, b]);
    linkInTime(p, a, b);
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(a))) as Map<String, dynamic>);
    expect(back.linkId, a.linkId);
    expect(layerToJson(layer('x', 0, 1)).containsKey('link'), isFalse);
    final right = splitLayer(p, a, 10, 'a2')!;
    expect(areTimeLinked(right, b), isTrue);
  });

  test('deleting one of two linked layers leaves the other unlinked (no lone link icon)', () {
    final a = createLayer('rect')..id = 'va';
    final b = createLayer('rect')..id = 'sa';
    final c = createLayer('rect')..id = 'c';
    final p = Project(layers: [a, b, c]);
    linkInTime(p, a, b);
    deleteLayer(p, Selection(), 'sa', 0);
    expect(a.linkId, isNull);
    // a group of three keeps its link when one goes.
    final d = createLayer('rect')..id = 'd';
    p.layers.add(d);
    linkInTime(p, a, c);
    linkInTime(p, a, d);
    deleteLayer(p, Selection(), 'd', 0);
    expect(a.linkId, isNotNull);
    expect(a.linkId, c.linkId);
  });
}
