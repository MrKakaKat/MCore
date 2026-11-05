import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kLongPressTimeout, kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';

/// Real, run widget-level coverage of the multi-layer timeline (port of
/// movement-core/src/ui/timeline/timelinePanel.js) - one row per layer,
/// drag-to-move (long-press first) and drag-to-trim (the two edge dots,
/// immediate, shown only once that layer's line is tapped/"focused"),
/// 2-finger pinch-zoom, and a draggable playhead. See
/// layers_timeline_view.dart's own doc comment for the disclosed
/// departures from JS this file's tests are written against.
void main() {
  late AppState app;
  late Layer parent;
  late Layer child;

  setUp(() {
    app = AppState()..timelineCenterPlayheadEnabled = false;
    parent = app.project.layers.firstWhere((l) => l.id == 'L_parent');
    child = app.project.layers.firstWhere((l) => l.id == 'L_child');
  });

  Future<void> pump(WidgetTester tester,
      {double width = 600, double height = 200}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: width,
                height: height,
                child: LayersTimelineView(app: app))),
      ),
    );
    await tester.pumpAndSettle();
  }

  // move-area GestureDetectors (onLongPressStart wired) exist for every
  // NON-dimmed lane - both, whenever nothing is focused. Tree order
  // matches project.layers = [L_parent, L_child].
  Finder moveAreas() => find.byWidgetPredicate(
      (w) => w is GestureDetector && w.onLongPressStart != null);

  // trim dots and the playhead are both raw Listener-based drag
  // targets (not GestureDetector/Pan-based - see layers_timeline_view.
  // dart's own doc comment on why: the horizontal SingleChildScrollView
  // always has scrollable range now, so an arena-based Pan recognizer
  // here would genuinely compete with - and could lose to - the scroll
  // view's own). Plain `onPointerDown!=null` is too broad - it also
  // matches this view's own outer pinch-zoom Listener plus several
  // framework-internal ones (Scrollable's own pan-zoom/mouse-wheel
  // Listeners) - translucent behavior + a wired onPointerMove is the
  // combination unique to _trimDot/_Playhead specifically (the outer
  // pinch listener defaults to deferToChild; the framework's own have
  // no onPointerMove callback at all).
  Finder dragCandidates() => find.byWidgetPredicate((w) =>
      w is Listener &&
      w.behavior == HitTestBehavior.translucent &&
      w.onPointerMove != null);

  testWidgets(
      'no per-layer label column - layer names are not shown as text anywhere',
      (tester) async {
    await pump(tester);
    expect(find.text(parent.name), findsNothing);
    expect(find.text(child.name), findsNothing);
  });

  testWidgets(
      'nothing focused by default: both layers have a working move area, and NO trim dots are shown at all',
      (tester) async {
    await pump(tester);
    expect(moveAreas(), findsNWidgets(2));

    expect(dragCandidates(), findsNWidgets(1),
        reason:
            'only the playhead\'s own drag listener - no layer is focused, so no trim dots exist yet');
  });

  testWidgets(
      'tapping a layer\'s line selects it and focuses it (its own trim dots appear)',
      (tester) async {
    await pump(tester);
    final childMoveArea = moveAreas().at(1);

    await tester.tap(childMoveArea);
    await tester.pump();

    expect(app.selection.selectedLayer, equals(child.id));
    expect(dragCandidates(), findsNWidgets(3),
        reason: 'child\'s own left+right trim dots, plus the playhead');
  });

  testWidgets(
      'tapping the FOCUSED layer\'s line again returns everything to normal (dots disappear)',
      (tester) async {
    await pump(tester);
    final childMoveArea = moveAreas().at(1);

    await tester.tap(childMoveArea);
    await tester.pump();
    // re-find: with child now focused, parent is dimmed/gone from
    // moveAreas() entirely, so child's own move area is the only (and
    // therefore first) one left.
    await tester.tap(moveAreas().at(0));
    await tester.pump();

    expect(dragCandidates(), findsNWidgets(1),
        reason: 'back to no trim dots at all, just the playhead');
    expect(moveAreas(), findsNWidgets(2),
        reason: 'both lanes interactive again, nothing dimmed');
  });

  testWidgets(
      'while one layer is focused, the OTHER layer\'s line is dimmed and fully non-interactive',
      (tester) async {
    await pump(tester);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    expect(moveAreas(), findsNWidgets(1),
        reason:
            'parent\'s own move area must be gone entirely while dimmed - not just visually dimmed');
  });

  Finder reorderHandle() => find.byIcon(Icons.drag_handle);

  testWidgets(
      'the reorder handle only appears (at 24x24, centered on the focused row) once a layer is focused',
      (tester) async {
    await pump(tester);
    expect(reorderHandle(), findsNothing,
        reason: 'no layer focused - the reorder handle must be fully hidden, same convention as trim handles');

    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    expect(reorderHandle(), findsOneWidget);
    final handleRect = tester.getRect(reorderHandle());
    expect(handleRect.size, equals(const Size(24, 24)));
    final childRowCenterY = tester.getRect(moveAreas().at(0)).center.dy;
    expect(handleRect.center.dy, closeTo(childRowCenterY, 0.5),
        reason: 'centered on the focused row, not hanging below it');
  });

  testWidgets(
      'the reorder handle sits in its own right-edge strip, never over the layer content, and ignores horizontal scroll',
      (tester) async {
    app.maxFrame = 6000;
    await pump(tester);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    final viewRight = tester.getTopRight(find.byType(LayersTimelineView)).dx;
    final before = tester.getRect(reorderHandle());
    expect(before.left, greaterThanOrEqualTo(viewRight - 28),
        reason: 'inside the reserved 28px strip at the right edge');

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    scrollable.position.jumpTo(500);
    await tester.pump();

    expect(tester.getRect(reorderHandle()), equals(before));
  });

  testWidgets(
      'dragging the reorder handle vertically reorders project.layers (one move, one undo step)',
      (tester) async {
    app.addLayer('rect');
    final third = app.project.layers.last;
    await pump(tester);
    await tester.tap(moveAreas().at(0)); // focus parent (row 0)
    await tester.pump();
    expect(app.project.layers.map((l) => l.id).toList(),
        equals([parent.id, child.id, third.id]));

    // two rows down (rows are 12px), plus sideways motion that must be ignored.
    await tester.drag(reorderHandle(), const Offset(-40, 24));
    await tester.pumpAndSettle();

    expect(app.project.layers.map((l) => l.id).toList(),
        equals([child.id, third.id, parent.id]));

    app.performUndo();
    expect(app.project.layers.map((l) => l.id).toList(),
        equals([parent.id, child.id, third.id]));
  });

  testWidgets(
      'dragging the reorder handle past the last row clamps to the last row',
      (tester) async {
    await pump(tester);
    await tester.tap(moveAreas().at(0)); // focus parent (row 0)
    await tester.pump();

    await tester.drag(reorderHandle(), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(app.project.layers.map((l) => l.id).toList(),
        equals([child.id, parent.id]));
  });

  Finder trimColumn(String side) => find.byKey(ValueKey('trim-$side'));

  testWidgets(
      'a focused layer gets full-height edge lines spanning the whole timeline, not just its own row',
      (tester) async {
    await pump(tester, height: 200);
    expect(trimColumn('left'), findsNothing, reason: 'nothing focused - no edge lines');
    expect(trimColumn('right'), findsNothing);

    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    for (final side in ['left', 'right']) {
      expect(tester.getSize(trimColumn(side)).height, closeTo(200, 1),
          reason: 'the whole timeline height, like the playhead - not the 12px row');
    }
  });

  testWidgets(
      'the whole edge line is a trim handle - grabbing it far below the layer\'s own row still trims',
      (tester) async {
    child.startFrame = 20;
    child.durationFrames = 60;
    await pump(tester, height: 200);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    final rightLine = tester.getRect(trimColumn('right'));
    // near the bottom of the timeline, nowhere near child's own row.
    final grab = Offset(rightLine.center.dx, rightLine.bottom - 10);
    final gesture = await tester.startGesture(grab);
    await gesture.moveBy(const Offset(-20, 0)); // 10 frames at 2px/frame
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(child.startFrame, equals(20), reason: 'trimRight keeps the start fixed');
    expect(child.durationFrames, equals(50));
  });

  testWidgets(
      'a short timeline ends at its own end: ruler stops there and the end scrolls exactly to the center',
      (tester) async {
    app.maxFrame = 90; // 180px at zoom 1 - shorter than the 572px scroll area
    await pump(tester, width: 600, height: 200);

    final rulerBox = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .firstWhere((w) => w.height == 18);
    expect(rulerBox.width, equals(180), reason: 'no viewport-wide floor any more');

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    expect(scrollable.position.maxScrollExtent, equals(180),
        reason: 'fully scrolled, the last frame sits at the viewport center - not right of it');
  });

  testWidgets(
      'a layer ending at the timeline end: its edge line is not clipped and its outer half still trims',
      (tester) async {
    app.maxFrame = 180;
    child.startFrame = 120;
    child.durationFrames = 60; // ends exactly at maxFrame
    await pump(tester, width: 600, height: 200);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    await tester.tap(moveAreas().at(1));
    await tester.pump();

    final line = tester.getRect(trimColumn('right'));
    // grab PAST the end (the half that used to be clipped away).
    final gesture = await tester.startGesture(Offset(line.center.dx + 12, line.center.dy));
    await gesture.moveBy(const Offset(-20, 0)); // -10 frames
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(child.durationFrames, equals(50));
  });

  testWidgets(
      'on the focused layer, tapping a keyframe selects it and dragging the selected key moves it in time',
      (tester) async {
    child.startFrame = 20;
    child.durationFrames = 60;
    child.transform.rotation.keyframes
      ..clear()
      ..addAll([Keyframe(frame: 10, value: 0.0), Keyframe(frame: 30, value: 90.0)]);
    await pump(tester, width: 600, height: 200);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('kf-30'))); // global 20 + 10
    await tester.pump();
    expect(kfSelectedFrames, equals({30}));
    expect(app.currentFrame, equals(30), reason: 'selecting a key jumps the playhead to it');

    final sel = tester.getRect(find.byKey(const ValueKey('kf-selected-0')));
    final gesture = await tester.startGesture(sel.center);
    await gesture.moveBy(const Offset(10, 0));
    await gesture.moveBy(const Offset(10, 0)); // +20px = +10 frames total
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(child.transform.rotation.keyframes.map((k) => k.frame).toList(), equals([20, 30]),
        reason: 'the key at local 10 moved to local 20 (the other stays put)');
    expect(kfSelectedFrames, equals({40}));
  });

  testWidgets(
      'long-pressing and dragging a layer\'s lane moves it (shifts startFrame, duration untouched)',
      (tester) async {
    child.startFrame = 20;
    child.durationFrames = 30;
    await pump(tester);

    final start = tester.getRect(moveAreas().at(1)).center;
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(child.durationFrames, equals(30),
        reason: 'moving must never change duration');
    expect(child.startFrame, greaterThan(20),
        reason:
            'dragged rightward (positive dx) - must move to a LATER start frame');
  });

  testWidgets(
      'a plain (non-long-press) drag on the lane does NOT move the layer - only long-press-then-drag does',
      (tester) async {
    child.startFrame = 20;
    child.durationFrames = 30;
    await pump(tester);

    final start = tester.getRect(moveAreas().at(1)).center;
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(40, 0)); // no long-press wait
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(child.startFrame, equals(20),
        reason:
            'an immediate drag without holding first must not move the layer');
  });

  testWidgets(
      'dragging the LEFT trim dot (once focused) shortens/moves start while keeping the end fixed',
      (tester) async {
    child.startFrame = 20;
    child.durationFrames = 30; // end = 50
    await pump(tester);

    await tester.tap(moveAreas().at(1)); // focus child - reveals its trim dots
    await tester.pump();

    // trim-dot drag listeners, tree order: child's [left, right], then
    // the playhead's own - parent stays unfocused so it has none.
    final trimDots = dragCandidates();
    expect(trimDots, findsNWidgets(3));
    final leftDotCenter = tester.getRect(trimDots.at(0)).center;

    final gesture = await tester.startGesture(leftDotCenter);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(child.startFrame, greaterThan(20));
    expect(child.startFrame + child.durationFrames, equals(50),
        reason: 'trimming the left edge must keep the END fixed');
  });

  testWidgets(
      'a 2-finger pinch actually zooms (lane content width grows once zoomed in far enough to exceed the viewport)',
      (tester) async {
    await pump(
        tester); // app.maxFrame defaults to 180; at zoom 1 (2px/frame) that's 360px, under the 600px viewport

    expect(
        find.byWidgetPredicate(
            (w) => w is SizedBox && w.width != null && w.width! > 600),
        findsNothing,
        reason:
            'sanity: not already zoomed in enough to exceed the viewport width');

    final gesture1 =
        await tester.startGesture(const Offset(250, 50), pointer: 1);
    final gesture2 =
        await tester.startGesture(const Offset(350, 50), pointer: 2);
    await tester.pump();
    await gesture1
        .moveTo(const Offset(150, 50)); // distance 100 -> 300, a 3x pinch-out
    await gesture2.moveTo(const Offset(450, 50));
    await tester.pump();
    await gesture1.up();
    await gesture2.up();
    await tester.pump();

    expect(
        find.byWidgetPredicate(
            (w) => w is SizedBox && w.width != null && w.width! > 600),
        findsWidgets);
  });

  testWidgets(
      'with quick-switch enabled, tapping a different (dimmed) layer\'s line switches focus directly - no need to unfocus first',
      (tester) async {
    app.toggleLayerQuickSwitch();
    await pump(tester);

    await tester
        .tap(moveAreas().at(1)); // focus child (nothing dimmed yet, normal path)
    await tester.pump();
    expect(app.selection.selectedLayer, equals(child.id));

    // parent is now dimmed but quick-switch is on, so it must still
    // expose SOME tappable area - a quick-switch dimmed tap area has
    // onTap but NOT onLongPressStart, unlike a normal (non-dimmed)
    // lane's move area which has both, so this predicate finds exactly
    // that new area without also matching child's own (still-present)
    // move area.
    final quickSwitchAreas = find.byWidgetPredicate((w) =>
        w is GestureDetector && w.onTap != null && w.onLongPressStart == null);
    expect(quickSwitchAreas, findsWidgets,
        reason:
            'parent\'s dimmed line must still expose a tap area when quick-switch is on');
    await tester.tap(quickSwitchAreas.first);
    await tester.pump();

    expect(app.selection.selectedLayer, equals(parent.id),
        reason: 'tapping the dimmed parent line should switch focus straight to it');
  });

  testWidgets(
      'without quick-switch, a dimmed layer\'s line has no tap area at all',
      (tester) async {
    await pump(tester); // quick-switch off by default
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    // (lane tap areas are translucent - the action row's buttons aren't)
    final quickSwitchAreas = find.byWidgetPredicate((w) =>
        w is GestureDetector &&
        w.onTap != null &&
        w.onLongPressStart == null &&
        w.behavior == HitTestBehavior.translucent);
    expect(quickSwitchAreas, findsNothing,
        reason: 'parent\'s dimmed line must be fully inert with quick-switch off');
  });

  testWidgets(
      'frame 0 sits at the viewport\'s horizontal center by default, not pinned to the scroll area\'s own left edge',
      (tester) async {
    app.setFrame(0);
    await pump(tester, width: 600, height: 200);

    final candidates = dragCandidates();
    expect(candidates, findsNWidgets(1), reason: 'the playhead is the only drag candidate with nothing focused');
    final playheadCenterX = tester.getRect(candidates.first).center.dx;
    final viewportLeft = tester.getTopLeft(find.byType(LayersTimelineView)).dx;

    // half of the whole 600px width (the reorder strip lies over the
    // right edge, it takes no width) - not flush left.
    expect(playheadCenterX - viewportLeft, closeTo(300, 2),
        reason: 'half the viewport\'s own width - frame 0 must be centered there, not flush left');
  });

  testWidgets(
      'pinch-in can zoom out far below the old fixed floor, shrinking a long timeline\'s content width substantially',
      (tester) async {
    app.maxFrame = 6000; // 200s at 30fps - long enough that zoom actually matters
    await pump(tester, width: 600, height: 200);

    double maxSizedBoxWidth() => tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .map((w) => w.width ?? 0)
        .reduce((a, b) => a > b ? a : b);
    // + 2 * 30: the content box's edge slack on both sides (keeps the
    // edge lines at frame 0 and at the end from being clipped in half).
    expect(maxSizedBoxWidth(), equals(12000 + 60),
        reason: 'zoom 1 (default): maxFrame(6000) * 2px/frame');

    final gesture1 = await tester.startGesture(const Offset(100, 50), pointer: 1);
    final gesture2 = await tester.startGesture(const Offset(500, 50), pointer: 2);
    await tester.pump();
    await gesture1.moveTo(const Offset(295, 50)); // distance 400 -> 10, a huge pinch-in
    await gesture2.moveTo(const Offset(305, 50));
    await tester.pump();
    await gesture1.up();
    await gesture2.up();
    await tester.pump();

    expect(maxSizedBoxWidth(), equals(1200 + 60),
        reason: 'clamped at the new, much lower _minZoom (0.1) floor - 6000 * 2 * 0.1, previously impossible since _minZoom used to be 1.0');
  });

  testWidgets(
      'dragging the playhead scrubs app.currentFrame within the lane\'s own coordinate space',
      (tester) async {
    app.maxFrame = 180;
    app.setFrame(90);
    await pump(tester, width: 600);

    // the playhead and any focused layer's trim dots are both drag
    // candidates - disambiguate by WIDTH instead of position (playhead
    // is 16 wide, trim dots are 24 - see _Playhead/_LayerLane's own
    // Positioned sizes). Nothing is focused here, so the playhead is
    // the ONLY candidate anyway.
    final candidates = dragCandidates();
    expect(candidates, findsNWidgets(1));
    final playhead = tester.getRect(candidates.first).center;

    final gesture = await tester.startGesture(playhead);
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // exact, not just "greater than": at zoom 1 (2px/frame), 100px must
    // move exactly 50 frames (90 -> 140) - see the runaway-drag
    // regression test below for why "somewhere further along" isn't
    // enough on its own.
    expect(app.currentFrame, equals(140));
  });

  testWidgets(
      'dragging the playhead across several incremental pointer-move steps never runs away disproportionately',
      (tester) async {
    // (moving the red indicator just flies off the edge of visibility) - root
    // cause was the horizontal SingleChildScrollView independently ALSO
    // scrolling in response to the very same finger movement, since the
    // playhead's own raw Listener never claims the gesture arena. Each
    // pointer-move event then compounded TWO shifts (the genuine frame change
    // AND the view sliding underneath the same finger), a issue loop that
    // grows with every step - a single big `moveBy` could mask this if
    // TestGesture happens to dispatch it as one event, so this drives several
    // SMALL incremental moves explicitly, the shape most likely to expose real
    // per-step compounding.
    app.maxFrame = 6000; // long enough that a runaway wouldn't just clamp at maxFrame and hide the bug
    // frame 0 (the default) sits at the viewport's own horizontal
    // center - a large starting frame would place the playhead outside
    // the actual visible/hit-testable scrolled viewport, which a
    // synthetic gesture can't reach at all (not what this test means
    // to exercise).
    await pump(tester, width: 600, height: 200);

    final playhead = tester.getRect(dragCandidates().first).center;
    final gesture = await tester.startGesture(playhead);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(10, 0)); // 10 steps x 10px = 100px total
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    // at zoom 1 (2px/frame), 100px total must move exactly 50 frames
    // (0 -> 50) - a runaway/compounding bug would land far beyond this,
    // not just "further along".
    expect(app.currentFrame, equals(50));
  });

  testWidgets(
      'holding a move-drag stationary in the auto-scroll edge zone keeps advancing the layer (it used to lag behind and get lost)',
      (tester) async {
    app.toggleTimelineEdgeAutoScroll(); // on
    app.maxFrame = 6000; // plenty of scrollable content on both sides
    child.startFrame = 0;
    child.durationFrames = 10;
    await pump(tester, width: 300, height: 100);

    final viewportRect = tester.getRect(find.byType(LayersTimelineView));
    final start = tester.getRect(moveAreas().at(1)).center;
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout + kPressTimeout);

    // move into the right-edge auto-scroll zone (the last 48px of the
    // viewport) and hold there.
    final edgeX = viewportRect.right - 20;
    await gesture.moveTo(Offset(edgeX, start.dy));
    await tester.pump();
    final startFrameAfterMove = child.startFrame;
    expect(startFrameAfterMove, greaterThan(0), reason: 'the initial move itself must already shift startFrame');

    // hold the finger perfectly still and let several 16ms auto-scroll
    // Timer ticks fire - a stationary finger produces NO
    // onLongPressMoveUpdate events at all, so any further movement here
    // can only come from the Timer re-applying the drag itself (the
    // actual fix, not just "scroll the view").
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(child.startFrame, greaterThan(startFrameAfterMove),
        reason:
            'the layer must keep advancing while the finger holds still in the edge zone - a stationary finger used to desync/lose the drag entirely once auto-scroll started');

    await gesture.up();
    await tester.pump();
  });

  testWidgets(
      'holding a playhead drag stationary in the auto-scroll edge zone keeps advancing currentFrame (the playhead never had auto-scroll wiring at all)',
      (tester) async {
    app.toggleTimelineEdgeAutoScroll(); // on
    app.maxFrame = 6000;
    app.setFrame(0);
    await pump(tester, width: 300, height: 100);

    final viewportRect = tester.getRect(find.byType(LayersTimelineView));
    final playhead = tester.getRect(dragCandidates().first).center;
    final gesture = await tester.startGesture(playhead);

    final edgeX = viewportRect.right - 20;
    await gesture.moveTo(Offset(edgeX, playhead.dy));
    await tester.pump();
    final frameAfterMove = app.currentFrame;
    expect(frameAfterMove, greaterThan(0));

    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(app.currentFrame, greaterThan(frameAfterMove),
        reason: 'the playhead must keep advancing while the finger holds still in the edge zone, same as a layer move-drag');

    await gesture.up();
    await tester.pump();
  });

  testWidgets(
      'pinch-zoom keeps the frame under the viewport\'s own center fixed (content used to slide out from under both fingers)',
      (tester) async {
    app.maxFrame = 6000;
    await pump(tester, width: 600, height: 200);

    // scroll so a known, non-zero frame sits at the viewport's own
    // center BEFORE zooming - at zoom 1 (2px/frame), scrolling to pixel
    // 400 puts frame 200 there (see this file's own doc comment on why
    // no halfViewport term is needed in this formula).
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    scrollable.position.jumpTo(400);
    await tester.pump();

    final gesture1 = await tester.startGesture(const Offset(250, 50), pointer: 1);
    final gesture2 = await tester.startGesture(const Offset(350, 50), pointer: 2);
    await tester.pump();
    await gesture1.moveTo(const Offset(150, 50)); // distance 100 -> 300, a 3x pinch-out
    await gesture2.moveTo(const Offset(450, 50));
    await tester.pump();
    await gesture1.up();
    await gesture2.up();
    await tester.pump();

    // zoom went from 1 to 3 (clamped under _maxZoom=8), so pixelsPerFrame
    // went from 2 to 6 - frame 200 must now sit at exactly 200*6=1200,
    // NOT still at the old 400 (which would mean the anchor did nothing
    // at all) and not at some other arbitrary offset (proving it's
    // frame 200 specifically that stayed centered, not a coincidence).
    expect(scrollable.position.pixels, closeTo(1200, 1));
  });

  testWidgets(
      'center-pin: turning it on and setting the frame scrolls that frame to the viewport\'s own center',
      (tester) async {
    app.toggleTimelineCenterPlayhead(); // on
    app.maxFrame = 6000;
    await pump(tester, width: 600, height: 200);

    app.setFrame(300);
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    // at zoom 1 (2px/frame), frame 300 -> scroll pixels 300*2=600.
    expect(scrollable.position.pixels, closeTo(600, 1));
  });

  testWidgets(
      'center-pin: scrolling the timeline (not dragging the playhead) moves app.currentFrame to match',
      (tester) async {
    app.toggleTimelineCenterPlayhead(); // on
    app.maxFrame = 6000;
    await pump(tester, width: 600, height: 200);

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    scrollable.position.jumpTo(500); // at 2px/frame -> frame 250
    await tester.pumpAndSettle();

    expect(app.currentFrame, equals(250));
  });

  testWidgets(
      'center-pin OFF: scrolling the timeline never touches app.currentFrame',
      (tester) async {
    app.maxFrame = 6000;
    app.setFrame(42);
    await pump(tester, width: 600, height: 200);

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    scrollable.position.jumpTo(500);
    await tester.pumpAndSettle();

    expect(app.currentFrame, equals(42));
  });

  testWidgets(
      'center-pin: the filmstrip moves only in whole-frame steps, never by a sub-frame amount',
      (tester) async {
    app.toggleTimelineCenterPlayhead(); // on
    app.maxFrame = 6000;
    await pump(tester, width: 600, height: 200);

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).last);
    double laneX() => tester.getTopLeft(moveAreas().at(0)).dx;

    scrollable.position.jumpTo(500); // frame 250 at 2px/frame
    await tester.pump();
    final atFrame250 = laneX();

    scrollable.position.jumpTo(500.8); // still frame 250
    await tester.pump();
    expect(laneX(), equals(atFrame250),
        reason: 'a sub-frame scroll must not move the filmstrip at all');

    scrollable.position.jumpTo(502); // frame 251
    await tester.pump();
    expect(laneX(), closeTo(atFrame250 - 2, 0.001),
        reason: 'exactly one frame (2px at zoom 1) step');
  });

  testWidgets(
      'center-pin: the playhead\'s own screen position is a hardcoded constant, never derived from currentFrame',
      (tester) async {
    app.toggleTimelineCenterPlayhead(); // on
    app.maxFrame = 6000;
    await pump(tester, width: 600, height: 200);

    // the pinned playhead is IgnorePointer(ignoring: true) unconditionally
    // - the ONLY such widget in this tree while center-pin is on, since
    // the draggable _Playhead (whose own IgnorePointer wraps a real
    // Listener) is not built at all in this mode - see
    // layers_timeline_view.dart's own doc comment.
    Finder fixedPlayhead() => find.descendant(
        of: find.byKey(const ValueKey('pinned-playhead')),
        matching: find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring));

    expect(dragCandidates(), findsNothing,
        reason: 'the pinned playhead has no drag/pointer logic at all - it is purely visual');
    expect(fixedPlayhead(), findsOneWidget);

    final viewportLeft = tester.getTopLeft(find.byType(LayersTimelineView)).dx;
    final xAtFrame300 = tester.getTopLeft(fixedPlayhead()).dx - viewportLeft;

    app.setFrame(3000); // a very different frame
    await tester.pumpAndSettle();

    final xAtFrame3000 = tester.getTopLeft(fixedPlayhead()).dx - viewportLeft;
    expect(xAtFrame3000, equals(xAtFrame300),
        reason: 'must be a literal constant (halfViewport - 8) - structurally incapable of moving with currentFrame, unlike the draggable playhead it replaces');
  });

  test(
      'ruler shows frame-level ticks at the default zoom (they used to require pinching in first)',
      () async {
    // a plain test(), not testWidgets() - paintTimelineRuler is a plain
    // top-level function (see layers_timeline_view.dart's own doc
    // comment on why: calling .paint() on a CustomPainter instance
    // pulled live out of an already-mounted widget tree hung the test
    // runner during teardown, for reasons not worth chasing further
    // once this simpler, already-proven-elsewhere alternative
    // (matches stage_painter.dart's own paintStage()) was available -
    // no widget pump needed at all to test this pure drawing function.
    const size = ui.Size(600, 18);

    Future<bool> hasTickNear(double x, {required double pixelsPerFrame, required int maxFrame}) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      paintTimelineRuler(canvas, size, pixelsPerFrame: pixelsPerFrame, maxFrame: maxFrame);
      final image = await recorder.endRecording().toImage(size.width.round(), size.height.round());
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final w = size.width.round();
      for (var dx = -2; dx <= 2; dx++) {
        final px = x.round() + dx;
        if (px < 0 || px >= w) continue;
        for (var py = (size.height - 4).round(); py < size.height.round(); py++) {
          final i = (py * w + px) * 4;
          // alpha channel, not red - a low-opacity tick (e.g. right at
          // the fade-in threshold) can have a near-zero premultiplied
          // red byte while still carrying a clearly nonzero alpha;
          // background is fully transparent (alpha 0) either way.
          if (bytes.getUint8(i + 3) > 0) return true;
        }
      }
      return false;
    }

    // frame 10 is never a whole-second boundary (fps=60) - below the
    // fade-in threshold (now 1.0px/frame), still nothing should be
    // drawn there.
    expect(await hasTickNear(10 * 0.5, pixelsPerFrame: 0.5, maxFrame: 180), isFalse,
        reason: 'no frame ticks below the fade-in threshold');

    // 2px/frame IS this app's own default zoom (_pixelsPerFrameAtZoom1
    // * initial _zoom=1.0) - was that ticks never appeared without pinching in
    //   first; this is the direct proof that they now show up at the default
    //   view, no zoom gesture required.
    expect(await hasTickNear(10 * 2.0, pixelsPerFrame: 2.0, maxFrame: 180), isTrue,
        reason: 'a frame tick must be visible at frame 10 at this app\'s own default zoom, unzoomed');

    // 16px/frame (zoom 8x, matching LayersTimelineView's own _maxZoom) -
    // full opacity (well past _frameTicksFullyVisibleAt=6.0).
    expect(await hasTickNear(10 * 16.0, pixelsPerFrame: 16.0, maxFrame: 180), isTrue,
        reason: 'a frame tick must still be visible at max zoom');
  });

  testWidgets('the start edge line at frame 0 is not cut in half - its left half can be grabbed too',
      (tester) async {
    child.startFrame = 0;
    child.durationFrames = 60;
    await pump(tester, height: 200);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();

    final leftLine = tester.getRect(trimColumn('left'));
    expect(leftLine.width, closeTo(60, 0.5), reason: '30px on each side of the line');
    // left of frame 0 - outside the old content box, so it used to miss.
    final gesture = await tester.startGesture(Offset(leftLine.left + 5, leftLine.center.dy));
    await gesture.moveBy(const Offset(20, 0)); // +10 frames at 2px/frame
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(child.startFrame, equals(10));
    expect(child.durationFrames, equals(50));
  });

  testWidgets('a focused layer\'s row is tinted across the whole width (third selection cue)',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('focus-band')), findsNothing);

    await tester.tap(moveAreas().at(1)); // focus child (row 1)
    await tester.pump();
    final band = tester.getRect(find.byKey(const ValueKey('focus-band')));
    expect(band.height, closeTo(12, 0.5));
    expect(band.width, greaterThan(500), reason: 'the whole visible timeline width');
  });

  double laneTop(WidgetTester tester, Layer l) =>
      tester.widget<AnimatedPositioned>(find.byKey(ValueKey(l.id))).top!;

  testWidgets('while the reorder handle is dragged, the other lanes slide into their new rows live',
      (tester) async {
    await pump(tester);
    await tester.tap(moveAreas().at(0)); // focus parent (row 0)
    await tester.pump();
    expect(laneTop(tester, child), closeTo(18 + 12 + 50, 0.01),
        reason: 'the action row under the focused lane pushes the next lane down');

    final gesture = await tester.startGesture(tester.getCenter(reorderHandle()));
    await gesture.moveBy(const Offset(0, 20)); // past the touch slop, into row 1
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // let the slide finish
    await tester.pump(const Duration(milliseconds: 50)); // and the action row fade out

    expect(app.project.layers.first.id, parent.id, reason: 'nothing moves until the drop');
    expect(laneTop(tester, child), closeTo(18, 0.01), reason: 'child slid up into row 0');
    expect(find.byKey(const ValueKey('layer-action-row')), findsNothing,
        reason: 'the action row steps aside while reordering');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(app.project.layers.map((l) => l.id).toList(), [child.id, parent.id]);
    expect(laneTop(tester, parent), closeTo(18 + 12, 0.01));
  });

  testWidgets('the action row appears under the focused lane and splits it at the playhead',
      (tester) async {
    child.startFrame = 20;
    child.durationFrames = 60;
    await pump(tester);
    expect(find.byKey(const ValueKey('layer-action-row')), findsNothing);

    await tester.tap(moveAreas().at(1)); // focus child (row 1)
    await tester.pump();
    app.setFrame(50); // after focusing - the playhead would sit on the tap point
    await tester.pump();
    final row = tester.getRect(find.byKey(const ValueKey('layer-action-row')));
    final lane = tester.getRect(find.byKey(ValueKey(child.id)));
    // centred in the 50 px under the lane: 11 above, 28 row, 11 below.
    expect(row.top - lane.bottom, closeTo(11, 0.01), reason: 'the same gap above and below it');

    final before = app.project.layers.length;
    await tester.tap(find.byTooltip('split at playhead'));
    await tester.pump();
    expect(app.project.layers.length, before + 1);
    expect([child.startFrame, child.durationFrames], [20, 30]);
  });

  testWidgets('a cancelled move (another gesture took over) puts the layer back and leaves nothing to undo',
      (tester) async {
    child.startFrame = 20;
    child.durationFrames = 30;
    await pump(tester);
    expect(app.undo.canUndo, isFalse);

    final gesture = await tester.startGesture(tester.getRect(moveAreas().at(1)).center);
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(child.startFrame, greaterThan(20), reason: 'the move is live');

    await gesture.cancel();
    await tester.pump();
    expect(child.startFrame, 20);
    expect(app.layerDragActive, isFalse);
    expect(app.undo.canUndo, isFalse);
  });

  testWidgets('effect time ranges: a line per effect, tap to edit, drag its end handle', (tester) async {
    child.startFrame = 0;
    child.durationFrames = 100;
    child.wiggle = Wiggle(enabled: true);
    child.swing = Swing(enabled: true);
    await pump(tester);
    await tester.tap(moveAreas().at(1));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('detail-effects')));
    await tester.pump();
    expect(find.byKey(const ValueKey('effect-span-wiggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('effect-span-swing')), findsOneWidget, reason: 'each effect its own row');
    expect(tester.getRect(find.byKey(const ValueKey('effect-span-swing'))).top,
        greaterThan(tester.getRect(find.byKey(const ValueKey('effect-span-wiggle'))).top));

    await tester.tap(find.byKey(const ValueKey('effect-span-wiggle')));
    await tester.pump();
    expect(app.editingEffectId, 'wiggle');
    final handle = find.byKey(const ValueKey('effect-end-line'));
    expect(find.byKey(const ValueKey('effect-start-line')), findsOneWidget, reason: 'both edges marked');
    await tester.dragFrom(tester.getCenter(handle), const Offset(-80, 0));
    await tester.pump();
    final r = child.effectRanges['wiggle']!;
    expect(r[0], 0);
    expect(r[1], lessThan(100));
    expect(app.undo.canUndo, isTrue);
  });

  testWidgets('expanded keys: a row per tab; tapping a line moves the playhead to its middle, delete removes both keys',
      (tester) async {
    child.startFrame = 0;
    child.durationFrames = 100;
    child.transform.rotation.keyframes.addAll([Keyframe(frame: 10, value: 0.0), Keyframe(frame: 50, value: 90.0)]);
    await pump(tester);
    await tester.tap(moveAreas().at(1));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('detail-keys')));
    await tester.pump();
    final row = find.byKey(const ValueKey('key-detail-Movement'));
    expect(row, findsOneWidget);
    final rect = tester.getRect(row);
    final ppf = (tester.getRect(find.byKey(ValueKey(child.id))).width) / (app.maxFrame);
    await tester.tapAt(Offset(rect.left + 30 * ppf, rect.center.dy));
    await tester.pump();
    expect(app.currentFrame, 30);
    expect(app.requestedTab, 'Movement');
    expect(find.byKey(const ValueKey('key-detail-delete')), findsNothing, reason: 'no separate bin');
    expect(find.byKey(const ValueKey('keyspan-start-line')), findsOneWidget, reason: 'its edge indicators');
    // the action row's delete acts on the selected line.
    final del = find.byTooltip('delete both keys of the line');
    await tester.tap(del);
    await tester.pump();
    expect(child.transform.rotation.keyframes, isEmpty);
  });

  testWidgets('select several on the timeline: tap other lanes, they light up and move together', (tester) async {
    parent.startFrame = 0;
    parent.durationFrames = 40;
    child.startFrame = 50;
    child.durationFrames = 40;
    await pump(tester);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-pick')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('group-pick-${parent.id}')));
    await tester.pump();
    expect(app.selectedGroup, {child.id, parent.id});
    expect(find.byKey(ValueKey('group-band-${parent.id}')), findsOneWidget);
    expect(app.selection.selectedLayer, child.id, reason: 'the main one stays');
    app.beginLayerDrag(parent.id, LayerDragMode.move);
    app.updateLayerDrag(5);
    app.endLayerDrag();
    expect([parent.startFrame, child.startFrame], [5, 55]);
  });

  testWidgets('range: two indicators, dragging one moves that edge; outside dims, inside lights up', (tester) async {
    app.setFrame(60);
    app.setTimeRangeEnabled(true);
    await pump(tester);
    expect(app.timeRange, (a: 30, b: 90));
    expect(find.byKey(const ValueKey('range-band')), findsOneWidget);
    expect(find.byKey(const ValueKey('range-dim-0')), findsOneWidget);
    final line = find.byKey(const ValueKey('range-end-line'));
    const ppf = 2.0; // zoom 1
    await tester.dragFrom(tester.getCenter(line), const Offset(-20 * ppf, 0));
    await tester.pump();
    expect(app.timeRange!.b, closeTo(70, 1));
    app.setTimeRangeEnabled(false);
    await tester.pump();
    expect(find.byKey(const ValueKey('range-band')), findsNothing);
  });

  testWidgets('effect lines and key rows show together', (tester) async {
    child.startFrame = 0;
    child.durationFrames = 100;
    child.wiggle = Wiggle(enabled: true);
    child.transform.rotation.keyframes.addAll([Keyframe(frame: 10, value: 0.0), Keyframe(frame: 50, value: 90.0)]);
    await pump(tester);
    await tester.tap(moveAreas().at(1));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('detail-keys')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('detail-effects')));
    await tester.pump();
    expect(find.byKey(const ValueKey('effect-span-wiggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-detail-Movement')), findsOneWidget, reason: 'keys stay visible');
    expect(tester.getRect(find.byKey(const ValueKey('key-detail-Movement'))).top,
        greaterThan(tester.getRect(find.byKey(const ValueKey('effect-span-wiggle'))).top));
  });

  testWidgets('layers selected together all stay above the action row; it fades out when let go', (tester) async {
    await pump(tester, height: 400);
    await tester.tap(moveAreas().at(0)); // focus parent (row 0)
    await tester.pumpAndSettle();
    app.toggleMultiSelect(child.id); // child (row 1) selected with it
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('layer-action-row'));
    expect(tester.getTopLeft(row).dy, greaterThan(laneTop(tester, child) + 12),
        reason: 'the action row sits under the lower selected layer');

    await tester.tap(moveAreas().at(0)); // unfocus
    await tester.pump();
    expect(row, findsOneWidget, reason: 'still there, fading');
    await tester.pumpAndSettle();
    expect(row, findsNothing);
  });

  testWidgets('mask time: a line per mask; tap to edit, its edge lines appear', (tester) async {
    child.masks.add(Mask(sourceLayerId: parent.id));
    await pump(tester, height: 400);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detail-masks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mask-span-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mask-span-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mask-start-line')), findsOneWidget);
    expect(find.byKey(const ValueKey('mask-end-line')), findsOneWidget);
  });

  testWidgets('a hold that goes nowhere picks a layer, and lets the picked one go', (tester) async {
    app.selectLayer(null);
    await pump(tester);
    await tester.longPress(moveAreas().at(0));
    await tester.pumpAndSettle();
    expect(app.selection.selectedLayer, parent.id);
    await tester.longPress(moveAreas().at(0));
    await tester.pumpAndSettle();
    expect(app.selection.selectedLayer, isNull);
  });

  testWidgets('pinch-zoom never drags an indicator: a second finger lets go of the edge the first one held', (tester) async {
    child.startFrame = 20;
    child.durationFrames = 60;
    await pump(tester, height: 200);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();
    final rightLine = tester.getRect(trimColumn('right'));
    final g1 = await tester.startGesture(Offset(rightLine.center.dx, rightLine.bottom - 10), pointer: 7);
    final g2 = await tester.startGesture(const Offset(100, 150), pointer: 8);
    await tester.pump();
    await g1.moveBy(const Offset(-40, 0));
    await g2.moveBy(const Offset(40, 0));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pump();
    expect(child.durationFrames, 60, reason: 'the pinch moved no edge');
  });

  testWidgets('a copied layer takes the timeline focus (the old one is not left focused, nothing dimmed wrongly)',
      (tester) async {
    await pump(tester, height: 300);
    await tester.tap(moveAreas().at(1)); // focus child
    await tester.pump();
    expect(app.selection.selectedLayer, child.id);
    app.duplicateLayer(child.id);
    await tester.pump(const Duration(milliseconds: 300));
    final copy = app.project.layers.firstWhere((l) => l.name.endsWith('_copy'));
    expect(app.selection.selectedLayer, copy.id);
    expect(app.multiSelection, isEmpty);
    // the focused lane (the only non-dimmed one) is the copy's.
    final lanes = tester.widgetList(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_LayerLane'));
    final focused = [for (final w in lanes) if (!(w as dynamic).dimmed) (w as dynamic).layer.id];
    expect(focused, [copy.id]);
  });

  testWidgets('a folder shows as a fold row; tapping it hides its layers\' rows', (tester) async {
    parent.folder = 'Group';
    child.folder = 'Group';
    await pump(tester, height: 300);
    final fold = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('timeline-folder-Group'));
    expect(fold, findsOneWidget);
    expect(find.byKey(ValueKey(child.id)), findsOneWidget);
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(app.collapsedTimelineFolders, {'Group'});
    expect(find.byKey(ValueKey(child.id)), findsNothing);
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(child.id)), findsOneWidget);
  });
}
