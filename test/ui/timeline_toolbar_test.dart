import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/timeline/timeline_toolbar.dart';

/// Real, run widget-level coverage of TimelineToolbar - the transport/ action
/// controls split out of TimelineView (play, frame counter, undo/redo, the
/// drawer caret). The keyframe copy/paste/multiselect buttons that used to
/// live here moved to keyframes_editor_view_test.dart - see
/// timeline_toolbar.dart's own doc comment. Delete-selected-layer moved OFF
/// this toolbar entirely, into each layer's own row in layer_panel_view.dart
/// (see app_state_layer_actions_test.dart for deleteLayerById's own coverage)
/// -. The layer quick-switch/drag-to-edge auto-scroll/center-pin toggles that
/// used to sit here, right of the Spacer, moved to
/// timeline_drawer_row_test.dart - see TimelineToolbar's own doc comment for
/// behind that move.
void main() {
  late AppState app;
  late Layer layer;

  setUp(() {
    app = AppState();
    layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.transform.rotation.keyframes.addAll([
      Keyframe(frame: 20, value: 10.0),
      Keyframe(frame: 60, value: 30.0),
    ]);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelineToolbar(app: app))));
    await tester.pumpAndSettle();
  }

  testWidgets('play button toggles playback and its own icon', (tester) async {
    await pump(tester);
    expect(app.playing, isFalse);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();

    expect(app.playing, isTrue);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // stop the periodic playback Timer before the test ends - a pending
    // Timer at teardown fails the test framework's own invariant check.
    app.togglePlay();
  });

  testWidgets('the frame counter is editable (go to frame); the length is shown (set in Layers)', (tester) async {
    app.setFrame(42);
    app.maxFrame = 180;
    await pump(tester);
    final frame = find.descendant(of: find.byKey(const ValueKey('toolbar-frame')), matching: find.byType(TextField));
    expect(tester.widget<TextField>(frame).controller!.text, '42');
    expect(find.text(' / 180'), findsNothing);
    await tester.enterText(frame, '99');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(app.currentFrame, 99);
  });

  testWidgets('undo/redo buttons actually undo/redo an edit', (tester) async {
    await pump(tester);
    app.pushUndo();
    layer.transform.rotation.defaultValue = 99.0;
    app.commitEdit();

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    // undo restores the project via a deep-cloned snapshot, so the
    // layer object identity changes - re-fetch rather than reuse the
    // now-stale `layer` reference from before the undo.
    var current = findLayer(app.project, app.selection.selectedLayer)!;
    expect(current.transform.rotation.defaultValue, isNot(equals(99.0)));

    await tester.tap(find.byIcon(Icons.redo));
    await tester.pump();
    current = findLayer(app.project, app.selection.selectedLayer)!;
    expect(current.transform.rotation.defaultValue, equals(99.0));
  });

  testWidgets('drawer caret toggles AppState.timelineDrawerExpanded and flips 180 degrees', (tester) async {
    await pump(tester);
    expect(app.timelineDrawerExpanded, isFalse);
    expect(tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns, equals(0.0));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    expect(app.timelineDrawerExpanded, isTrue);
    expect(tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns, equals(0.5));

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pump();
    expect(app.timelineDrawerExpanded, isFalse);
    expect(tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns, equals(0.0));
  });
}
