import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer(String id, int start, int dur) => createLayer('rect')
  ..id = id
  ..name = id
  ..startFrame = start
  ..durationFrames = dur;

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  test('a border (hold) key is edited anywhere in its range', () {
    final t = Track(0.0);
    t.keyframes.addAll([
      Keyframe(frame: 0, value: 1.0, temporal: easingPresets['linear']!.withHold(true)),
      Keyframe(frame: 10, value: 5.0),
      Keyframe(frame: 20, value: 9.0),
    ]);
    setTrackValueAt(t, 6, 3.0);
    expect(t.keyframes.length, 3, reason: 'no new key');
    expect(t.keyframes.first.value, 3.0, reason: 'the border key owning frames 0..9');
    // between two ordinary keys: no key owns it (as before).
    expect(keyframeToEdit(t, 15), isNull);
  });

  test('a piece cut out of a grouped layer joins its group', () {
    final a = _layer('a', 0, 30)..parentId = 'g';
    final g = _layer('g', 0, 30)..groupedChildren = ['a'];
    final p = Project(layers: [g, a]);
    final right = splitLayer(p, a, 10, 'a2')!;
    expect(g.groupedChildren, ['a', 'a2']);
    expect(right.parentId, 'g');
    final piece = detachPiece(p, a, [
      [-10, -10],
      [10, -10],
      [10, 10],
      [-10, 10]
    ], 'a3')!;
    expect(piece.parentId, 'g');
    expect(g.groupedChildren, ['a', 'a3', 'a2']);
  });

  test('cut to a row: what was tied to a cut-away part goes to a kept part', () {
    final a = _layer('a', 0, 10), b = _layer('b', 30, 10);
    a.rowId = b.rowId = 'r';
    final x = _layer('x', 5, 30);
    final child = _layer('c', 0, 40)..parentId = 'x';
    final p = Project(layers: [a, b, x, child]);
    var n = 0;
    final sel = Selection()..selectedLayer = 'x';
    final kept = fillTimelineRowGaps(p, sel, 'x', 0, newLayerId: () => 'x${++n}')!;
    expect(kept.length, 1);
    expect(child.parentId, kept.single.id, reason: 'still linked to what is left of x');
    expect(sel.selectedLayer, kept.single.id);
  });

  test('a line outline is kept until the line changes', () {
    final pts = [for (var i = 0; i < 60; i++) [i * 3.0, (i % 7) * 4.0]];
    final b = brushStrokeLayer(pts, id: 'B', color: '#ffffff', width: 6, smooth: 0.5, soft: 0, opacity: 1, startFrame: 0, durationFrames: 10);
    final r1 = lineOutlineRings(b.content, frame: 0);
    final r2 = lineOutlineRings(b.content, frame: 3);
    expect(r2, r1);
    r2.first.first[0] = 1e9; // a copy: changing it changes nothing kept
    expect(lineOutlineRings(b.content, frame: 0), r1);
    b.content.lineWidth = 20;
    expect(lineOutlineRings(b.content, frame: 0), isNot(r1));
  });
}
