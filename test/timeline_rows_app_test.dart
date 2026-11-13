import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/stage/stage_view.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';
import 'package:movement_mobile/ui/timeline/timeline_rows_view.dart';

/// Several layers per timeline row, the Timeline tab (rows + fill the
/// gaps), plus this round's two fixes: chroma-keyed pixels are really
/// transparent, and the stage no longer shows through the timeline.
void main() {
  late AppState app;
  late Layer a, b, c;

  Layer make(String id, int start, int dur) => createLayer('rect')
    ..id = id
    ..name = id
    ..startFrame = start
    ..durationFrames = dur;

  setUp(() {
    fps = 60;
    app = AppState();
    a = make('a', 0, 30);
    b = make('b', 60, 30);
    c = make('c', 0, 200);
    app.project.layers
      ..clear()
      ..addAll([a, b, c]);
    app.selectLayer('b');
  });

  List<List<String>> rows() => [
        for (final r in timelineRows(app.project)) [for (final l in r) l.id]
      ];

  group('AppState', () {
    test('joining a row is one undo step; a layer that does not fit is refused', () {
      expect(app.placeLayerInRow('b', 0, join: true), isTrue);
      expect(rows(), [['a', 'b'], ['c']]);
      expect(app.placeLayerInRow('c', 0, join: true), isFalse, reason: 'c overlaps both');
      expect(rows(), [['a', 'b'], ['c']]);
      app.performUndo();
      expect(rows(), [['a'], ['b'], ['c']]);
    });

    test('in a shared row a dragged layer stops at its neighbour', () {
      app.placeLayerInRow('b', 0, join: true);
      app.beginLayerDrag('b', LayerDragMode.move);
      app.updateLayerDrag(-100);
      app.endLayerDrag();
      expect(findLayer(app.project, 'b')!.startFrame, 30);
      app.moveSelectedLayerToFrame(5);
      expect(findLayer(app.project, 'b')!.startFrame, 30, reason: 'the move-to-frame field respects it too');
    });

    test('a duplicate gets its own row (same time as the original)', () {
      app.placeLayerInRow('b', 0, join: true);
      app.duplicateLayer('a');
      expect(rows().first, ['a', 'b']);
      expect(rows().length, 3);
    });

    test('fill the gaps, undoable', () {
      app.placeLayerInRow('b', 0, join: true); // row: a [0,30) b [60,90), gap [30,60)
      expect(app.fillRowGapsWith('c', 0), isTrue);
      expect(timelineRows(app.project).length, 1);
      final piece = app.project.layers.firstWhere((l) => l.startFrame == 30);
      expect(piece.durationFrames, 30);
      expect(app.selection.selectedLayer, piece.id);
      app.performUndo();
      expect(findLayer(app.project, 'c')!.durationFrames, 200);
      expect(rows(), [['a', 'b'], ['c']]);
    });
  });

  group('timeline', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SizedBox(width: 600, height: 200, child: LayersTimelineView(app: app)))));
      await tester.pumpAndSettle();
    }

    Finder moveAreas() => find.byWidgetPredicate((w) => w is GestureDetector && w.onLongPressStart != null);

    testWidgets('two layers in one row share the line and each can still be tapped', (tester) async {
      app.placeLayerInRow('b', 0, join: true);
      await pump(tester);
      final areas = moveAreas();
      expect(areas, findsNWidgets(3));
      final ra = tester.getRect(areas.at(0)), rb = tester.getRect(areas.at(1));
      expect(ra.center.dy, rb.center.dy, reason: 'same row');
      await tester.tap(areas.at(0));
      await tester.pump();
      expect(app.selection.selectedLayer, 'a', reason: "b's lane on top doesn't swallow the tap");
    });

    testWidgets('the reorder handle dropped on the middle of another row puts the layer into it', (tester) async {
      await pump(tester);
      await tester.tap(moveAreas().at(1)); // focus b (row 1)
      await tester.pump();
      final handle = find.byIcon(Icons.drag_handle);
      final rowZeroY = tester.getCenter(handle).dy - 12; // rows are 12 px
      final g = await tester.startGesture(tester.getCenter(handle));
      await g.moveBy(const Offset(0, -20)); // past the touch slop
      await tester.pump();
      // steer the handle onto the middle of row 0 (a's line).
      await g.moveBy(Offset(0, rowZeroY - tester.getCenter(handle).dy));
      await tester.pump();
      expect(find.byKey(const ValueKey('reorder-join-target')), findsOneWidget);
      await g.up();
      await tester.pumpAndSettle();
      expect(rows(), [['a', 'b'], ['c']]);
    });
  });

  group('Timeline tab', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SizedBox(width: 420, height: 1100, child: TimelineRowsView(app: app)))));
      await tester.pumpAndSettle();
    }

    testWidgets('into the row above, then back to its own row', (tester) async {
      await pump(tester);
      expect(find.text('Row 2 of 3'), findsOneWidget);
      await tester.tap(find.text('Into row above'));
      await tester.pump();
      expect(rows(), [['a', 'b'], ['c']]);
      expect(find.textContaining('shared with a'), findsOneWidget);
      await tester.tap(find.text('Own row'));
      await tester.pump();
      expect(rows(), [['a'], ['b'], ['c']]);
    });

    testWidgets('fill the gaps with the selected layer', (tester) async {
      app.placeLayerInRow('b', 0, join: true);
      app.selectLayer('c');
      await pump(tester);
      // (the Path section is above it)
      await tester.scrollUntilVisible(find.text('Fill gaps with this layer'), 100,
          scrollable: find.descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable)).first);
      expect(find.textContaining('Row 1: a, b'), findsOneWidget);
      await tester.tap(find.text('Fill gaps with this layer'));
      await tester.pump();
      expect(timelineRows(app.project).single.map((l) => (l.startFrame, l.durationFrames)), [(0, 30), (30, 30), (60, 30)]);
    });
  });

  test('chroma: keyed pixels are transparent, not added on top (they came out white)', () async {
    // straight RGBA: a fully keyed green pixel and a half-transparent red one.
    final px = Uint8List.fromList([0, 255, 0, 0, 255, 0, 0, 128]);
    final image = await CanvasRenderer.imageFromStraightRgba(px, 2, 1);
    final rec = ui.PictureRecorder();
    ui.Canvas(rec)
      ..drawRect(const ui.Rect.fromLTWH(0, 0, 2, 1), ui.Paint()..color = const ui.Color(0xFF0000FF))
      ..drawImage(image, ui.Offset.zero, ui.Paint());
    final out = await rec.endRecording().toImage(2, 1);
    final data = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    expect([data.getUint8(0), data.getUint8(1), data.getUint8(2)], [0, 0, 255], reason: 'only the background');
    expect(data.getUint8(4), closeTo(128, 2));
    expect(data.getUint8(6), closeTo(127, 2));
  });

  testWidgets('the stage is clipped to its area and the timeline panel is opaque', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(StageView), matching: find.byType(ClipRect)), findsWidgets);
    final section = tester.widget<ColoredBox>(find.byKey(const ValueKey('timeline-section')));
    expect(section.color.alpha, 255);
  });
}
