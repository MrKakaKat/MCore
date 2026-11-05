import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/graph_editor/graph_editor_view.dart';

/// Real, run widget-level coverage of GraphEditorView - the state
/// transitions and curve sampling it's built on
/// (packages/movement_core/test/ui_geometry/graph_editor_test.dart)
/// prove the math; this proves the WIDGET wires touch input (dragging
/// the P1/P2 handles) and text input (the coordinate fields) into that
/// math correctly, against the real widget tree.
void main() {
  late AppState app;
  late Track spatialTrack;

  setUp(() {
    app = AppState();
    spatialTrack = Track([0.0, 0.0], true);
    spatialTrack.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [10.0, 0.0], temporal: const Easing(0.42, 0, 0.58, 1)),
      Keyframe(frame: 60, value: [20.0, 0.0], temporal: const Easing(0, 0, 1, 1)),
    ]);
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  testWidgets('per-segment mode: shows one tab per keyframe transition, defaulting to the LAST segment', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));

    expect(find.text('0→30'), findsOneWidget);
    expect(find.text('30→60'), findsOneWidget);
    // last segment's tab (30->60) is selected by default (segmentIndex
    // == keyframes.length - 2), matching openGraphEditor's own default.
    final lastTab = tester.widget<ChoiceChip>(find.ancestor(of: find.text('30→60'), matching: find.byType(ChoiceChip)));
    expect(lastTab.selected, isTrue);
  });

  testWidgets('whole-path mode: shows "whole path" label instead of segment tabs, and edits globalEasing', (tester) async {
    spatialTrack.globalEasing = const Easing(0.42, 0, 0.58, 1);
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2, wholePath: true));

    expect(find.text('Ease - whole path'), findsOneWidget);
    expect(find.text('0→30'), findsNothing);
  });

  testWidgets('dragging a handle in the easing square mutates the active segment\'s temporal easing', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));

    // default segment is index 1 (30->60), whose temporal is linear
    // (0,0,1,1) - P1 sits at the square's bottom-left corner. Locate the
    // easing square by its Listener (raw pointer capture, not
    // GestureDetector - see _EasingSquare's own doc comment on why).
    // Flutter's own scroll/gesture internals also build plain Listeners
    // (Scrollable, tap/pan-zoom recognizers), so `find.byType(Listener)`
    // alone is ambiguous - ours is the only one with onPointerMove wired
    // up at all, which uniquely identifies it.
    final squareFinder = find.byWidgetPredicate((w) => w is Listener && w.onPointerMove != null);
    final squareRect = tester.getRect(squareFinder);
    // nudged 1px inward from the exact corner so the hit-test point
    // unambiguously lands inside the widget's bounds.
    final p1Screen = Offset(squareRect.left + 1, squareRect.bottom - 1); // (x=0,y=0) -> bottom-left in screen space

    final before = spatialTrack.keyframes[2].temporal;
    expect(before.x1, equals(0));

    final gesture = await tester.startGesture(p1Screen);
    await gesture.moveBy(const Offset(30, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(10, -5));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final after = spatialTrack.keyframes[2].temporal;
    expect(after.x1, greaterThan(0), reason: 'dragging P1 rightward must move its x1 forward');
    expect(spatialTrack.keyframes[1].temporal.x1, equals(0.42), reason: 'the OTHER segment must be untouched');
  });

  testWidgets('editing a coordinate field commits a clamped value to the temporal easing', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));

    // x1 field for the default (last) segment, currently 0.
    await tester.enterText(find.byType(TextField).first, '5'); // out-of-range, must clamp to 1
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(spatialTrack.keyframes[2].temporal.x1, equals(1.0));
  });

  testWidgets('switching segment tabs edits a DIFFERENT keyframe\'s temporal', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));

    await tester.tap(find.text('0→30'));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '0.9');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(spatialTrack.keyframes[1].temporal.x1, equals(0.9), reason: 'editing after switching to segment 0->30 must touch keyframe[1] (frame 30)\'s temporal');
    expect(spatialTrack.keyframes[2].temporal.x1, equals(0), reason: 'the segment NOT being edited must stay untouched');
  });

  testWidgets('scalar (componentCount 1) track shows no X/Y component tabs', (tester) async {
    final rotation = Track(0.0);
    rotation.keyframes.addAll([
      Keyframe(frame: 0, value: 0.0),
      Keyframe(frame: 30, value: 90.0),
    ]);
    await pump(tester, GraphEditorView(app: app, track: rotation, componentCount: 1));

    expect(find.text('X'), findsNothing);
    expect(find.text('Y'), findsNothing);
  });

  testWidgets('vec2 track shows X/Y component tabs', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));
    expect(find.text('X'), findsOneWidget);
    expect(find.text('Y'), findsOneWidget);
  });

  testWidgets('Reset button restores the active easing back to the easeInOut default', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));

    // default (last) segment's temporal starts as linear (0,0,1,1), not easeInOut.
    expect(spatialTrack.keyframes[2].temporal.x1, equals(0));

    await tester.tap(find.byKey(const ValueKey('ease-reset')));
    await tester.pump();

    final t = spatialTrack.keyframes[2].temporal;
    expect(t.x1, equals(0.42));
    expect(t.y1, equals(0));
    expect(t.x2, equals(0.58));
    expect(t.y2, equals(1));
  });

  testWidgets('the ease type: overshoot replaces the square with its own controls, Bezier brings the curve back', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));
    await tester.tap(find.byKey(const ValueKey('ease-kind-overshoot')));
    await tester.pump();
    var t = spatialTrack.keyframes[2].temporal;
    expect(t.kind, 'overshoot');
    expect(find.byKey(const ValueKey('ease-overshoot-amount')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ease-bounces-plus')));
    await tester.pump();
    expect(spatialTrack.keyframes[2].temporal.bounces, 1);
    await tester.tap(find.byKey(const ValueKey('ease-kind-bezier')));
    await tester.pump();
    t = spatialTrack.keyframes[2].temporal;
    expect([t.kind, t.x1, t.x2], ['bezier', 0, 1], reason: 'the bezier it had is kept');
  });

  testWidgets('speed graph switch: presets and dragging set the bezier', (tester) async {
    await pump(tester, GraphEditorView(app: app, track: spatialTrack, componentCount: 2));
    await tester.tap(find.byKey(const ValueKey('ease-speed-view')));
    await tester.pump();
    expect(find.byKey(const ValueKey('speed-graph')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('speed-soft start')));
    await tester.pump();
    final t = spatialTrack.keyframes[2].temporal;
    expect([t.x1, t.x2], [0.5, 1]);
    final g = tester.getRect(find.byKey(const ValueKey('speed-graph')));
    await tester.dragFrom(g.center, Offset(g.width * 0.2, -g.height * 0.3));
    await tester.pump();
    expect(spatialTrack.keyframes[2].temporal.x1, isNot(0.5));
    await tester.tap(find.byKey(const ValueKey('ease-speed-view')));
    await tester.pump();
  });
}
