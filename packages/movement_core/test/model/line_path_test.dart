import 'dart:convert';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('a new line is two points; its box follows them', () {
    final l = createLayer('line');
    final c = l.content;
    expect(isOpenNodeLine(c), isTrue);
    expect(c.lineNodes, hasLength(2));
    expect(c.size[0], closeTo(46 * 3 + c.lineWidth, 1e-9));
    moveLineHandle(c, 'n1', [200, 50]);
    expect(c.offset[0], closeTo((-69 + 200) / 2, 1e-9));
    expect(c.size[1], closeTo(50 + c.lineWidth, 1e-9));
  });

  test('segments: straight, bezier through its handles, sine across the line', () {
    final c = createLayer('line').content..lineNodes = [LineNode(0, 0), LineNode(100, 0)];
    expect(sampleLine(c.lineNodes!), [
      [0.0, 0.0],
      [100.0, 0.0]
    ]);
    setLineSegmentKind(c, 1, 'bezier');
    final bez = sampleLine(c.lineNodes!);
    expect(bez.length, 33);
    expect(bez.any((p) => p[1].abs() > 1), isTrue, reason: 'new handles bend it');
    expect(bez.last, [100.0, 0.0]);
    setLineSegmentKind(c, 1, 'sine');
    c.lineNodes![1]
      ..amp = 10
      ..waves = 1;
    final sine = sampleLine(c.lineNodes!);
    final top = sine.map((p) => p[1]).reduce(math.max);
    expect(top, closeTo(10, 0.5));
  });

  test('points: insert in the middle, remove (two stay), close & fill', () {
    final c = createLayer('line').content..lineNodes = [LineNode(0, 0), LineNode(100, 0)];
    final i = insertLinePoint(c, 1);
    expect(i, 1);
    expect([c.lineNodes![1].x, c.lineNodes![1].y], [50, 0]);
    c.lineNodes!.add(LineNode(50, 80));
    closeLine(c);
    expect(c.lineClosed, isTrue);
    expect(isFilledLine(c), isTrue);
    expect(isOpenNodeLine(c), isTrue, reason: 'filling keeps the point handles');
    c.lineShowBox = true;
    expect(isOpenNodeLine(c), isFalse);
    expect(lineHandleKeys(c, editing: true), isEmpty);
    c.lineShowBox = false;
    expect(sampleLine(c.lineNodes!, closed: true).last, [0.0, 0.0]);
    removeLinePoint(c, 0);
    removeLinePoint(c, 0);
    expect(c.lineNodes, hasLength(2));
    removeLinePoint(c, 0);
    expect(c.lineNodes, hasLength(2));
  });

  test('reveal: the drawn part between start and end of the length, animated', () {
    final pts = [
      [0.0, 0.0],
      [100.0, 0.0],
      [100.0, 100.0]
    ];
    expect(trimPolyline(pts, 0, 0.25), [
      [0.0, 0.0],
      [50.0, 0.0]
    ]);
    expect(trimPolyline(pts, 0.75, 1), [
      [100.0, 50.0],
      [100.0, 100.0]
    ]);
    expect(trimPolyline(pts, 0.6, 0.4), isEmpty);
    final c = createLayer('line').content
      ..lineTrimEnd = (track(1.0)
        ..keyframes = [
          Keyframe(frame: 0, value: 0.0),
          Keyframe(frame: 10, value: 1.0),
        ]);
    final p = Project();
    expect(lineReveal(p, c, 0), (0.0, 0.0));
    expect(lineReveal(p, c, 10), (0.0, 1.0));
  });

  test('json round trip', () {
    final l = createLayer('line');
    setLineSegmentKind(l.content, 1, 'bezier');
    l.content.lineTrimStart = track(0.2);
    final back = projectLayersFromJson(jsonDecode(jsonEncode(projectLayersToJson(Project(layers: [l])))) as List).single;
    expect(back.content.lineNodes!.map((n) => n.toJson()).toList(), l.content.lineNodes!.map((n) => n.toJson()).toList());
    expect(back.content.lineWidth, l.content.lineWidth);
    expect(evaluateTrack(Project(), back.content.lineTrimStart!, 0), 0.2);
    final svg = exportProjectToSvg(Project(layers: [l]), 0, 100, 100);
    expect(svg, contains('stroke-linecap="round"'));
  });

  test('loop without fill; a point gets bezier handles on both sides', () {
    final c = createLayer('line').content
      ..lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(100, 100)];
    loopLine(c, true);
    expect(c.lineClosed, isTrue);
    expect(isFilledLine(c), isFalse);
    setLineSegmentKind(c, 1, 'bezier'); // before point 1
    setLineSegmentKind(c, 2, 'bezier'); // after point 1
    expect(lineHandleKeys(c, editing: true, selected: 1), containsAll(['i1', 'o1']));
    // the first point of an open line: only its after-segment.
    loopLine(c, false);
    setLineSegmentKind(c, 1, 'bezier');
    expect(lineHandleKeys(c, editing: true, selected: 0), contains('o0'));
    expect(lineHandleKeys(c, editing: true, selected: 0), isNot(contains('i0')));
  });

  test('a bezier on one side of a point bends only by that point\'s handle', () {
    final c = createLayer('line').content
      ..lineNodes = [LineNode(0, 0), LineNode(100, 0), LineNode(200, 0)];
    setLineSideKind(c, 1, 'before', 'bezier');
    expect(lineSideKind(c, 1, 'before'), 'bezier');
    expect(c.lineNodes![0].hOut, [0, 0], reason: 'the other end untouched');
    expect(lineSideKind(c, 0, 'after'), 'line', reason: 'point 1 has no handle of its own there');
    expect(lineHandleKeys(c, editing: true, selected: 1), contains('i1'));
    setLineSideKind(c, 1, 'before', 'line');
    expect(c.lineNodes![1].kind, 'line');
  });

  test('circle segment passes through its bulge; fill closes with a straight segment; amplitude animates', () {
    final c = createLayer('line').content
      ..lineNodes = [LineNode(0, 0), LineNode(100, 0)];
    setLineSideKind(c, 0, 'after', 'arc');
    c.lineNodes![1].amp = 50; // a half circle
    final pts = sampleLine(c.lineNodes!);
    final top = pts.map((p) => p[1]).reduce(math.max);
    expect(top, closeTo(50, 0.5));
    expect(pts.last[0], closeTo(100, 1e-6));
    c.lineNodes!.add(LineNode(50, -80)..kind = 'sine');
    c.lineNodes!.first.kind = 'sine';
    closeLine(c);
    expect(c.lineNodes!.first.kind, 'line');
    final n = c.lineNodes![1];
    n.kind = 'sine';
    n.ampT.keyframes = [Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 20.0)];
    expect(n.ampAt(0), 0);
    expect(n.ampAt(10), 20);
    final back = LineNode.fromJson(n.toJson());
    expect(back.ampAt(10), 20);
  });
}
