import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';

/// Real, run widget-level coverage of the new Keyframes tab - asked for a
/// dedicated place to review/move/delete keyframes and toggle looping, beyond
/// the compact merged strip.
void main() {
  late AppState app;
  late Layer layer;

  setUp(() {
    kfSelectedFrames = {};
    kfMultiselectMode = false;
    app = AppState();
    layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.transform.rotation.keyframes.addAll([
      Keyframe(frame: 10, value: 5.0),
      Keyframe(frame: 40, value: 15.0),
    ]);
  });

  Future<void> pumpView(WidgetTester tester) async {
    app.showKeyParams = true; // the parameters with keys, opened
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: KeyframesEditorView(app: app)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'shows every keyframe frame number for the rotation track; parameters without keys are left out',
      (tester) async {
    await pumpView(tester);

    expect(find.text('10'), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
    // anchor/scale/opacity have no keyframes on this fixture layer.
    expect(find.text('Rotation'), findsOneWidget);
    expect(find.text('Scale'), findsNothing);
    expect(find.text('Opacity'), findsNothing);
  });

  testWidgets('tapping a keyframe chip jumps the playhead to its global frame',
      (tester) async {
    await pumpView(tester);

    await tester.tap(find.text('40'));
    await tester.pump();

    expect(app.currentFrame,
        equals(40)); // layer.startFrame is 0 on the default project
  });

  testWidgets(
      'deleting a keyframe via its close icon actually removes it from the track',
      (tester) async {
    await pumpView(tester);

    // find the close icon that's a sibling of the '10' label - both are
    // the only close icons currently on screen (rotation is the only
    // keyframed track), so the first one suffices.
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();

    expect(layer.transform.rotation.keyframes.map((k) => k.frame),
        isNot(contains(10)));
    expect(
        layer.transform.rotation.keyframes.map((k) => k.frame), contains(40));
  });

  testWidgets(
      'the loop checkbox actually flips Track.loop, both ways across repeated taps',
      (tester) async {
    await pumpView(tester);
    expect(layer.transform.rotation.loop, isFalse);

    // only rotation has keys: its loop checkbox is the only one.
    final checkboxes = find.byType(Checkbox);
    await tester.tap(checkboxes.first);
    await tester.pump();
    expect(layer.transform.rotation.loop, isTrue);

    await tester.tap(checkboxes.first);
    await tester.pump();
    expect(layer.transform.rotation.loop, isFalse);
  });

  testWidgets(
      'the eye flips Track.hidden, both ways across repeated taps',
      (tester) async {
    await pumpView(tester);
    expect(layer.transform.rotation.hidden, isFalse);

    final eye = find.byKey(const ValueKey('track-eye-rotation'));
    await tester.tap(eye);
    await tester.pump();
    expect(layer.transform.rotation.hidden, isTrue);

    await tester.tap(eye);
    await tester.pump();
    expect(layer.transform.rotation.hidden, isFalse);
  });

  testWidgets('copy button is disabled with no keyframe selection, enabled once something is selected', (tester) async {
    await pumpView(tester);
    final copyButtonFinder = find.widgetWithIcon(IconButton, Icons.copy);
    expect(tester.widget<IconButton>(copyButtonFinder).onPressed, isNull);

    kfSelectedFrames = {10};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    await tester.pump();

    expect(tester.widget<IconButton>(copyButtonFinder).onPressed, isNotNull);
  });

  testWidgets('paste button pastes the copied keyframes at the current frame', (tester) async {
    await pumpView(tester);
    kfSelectedFrames = {10};
    app.copySelectedKfs();
    app.setFrame(100);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    await tester.pump();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.paste));
    await tester.pump();

    expect(layer.transform.rotation.keyframes.map((k) => k.frame), contains(100));
  });

  testWidgets('the list button folds and opens the parameters with keys (multiselect is in the top toolbar)',
      (tester) async {
    await pumpView(tester);
    expect(find.text('Rotation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('key-params-toggle')));
    await tester.pump();
    expect(find.text('Rotation'), findsNothing);
    expect(find.widgetWithIcon(IconButton, Icons.check_box_outline_blank), findsNothing);
  });

  testWidgets(
      'long-pressing a keyframe opens a retime dialog; submitting a new frame actually moves it and re-sorts the track',
      (tester) async {
    await pumpView(tester);

    await tester.longPress(find.text('10'));
    await tester.pumpAndSettle();
    expect(find.text('Move keyframe to frame'), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '55');
    await tester.tap(find.text('Move'));
    await tester.pumpAndSettle();

    final frames =
        layer.transform.rotation.keyframes.map((k) => k.frame).toList();
    expect(frames, contains(55));
    expect(frames, isNot(contains(10)));
    expect(frames, equals([...frames]..sort()),
        reason: 'track must stay sorted after retiming');
  });

  testWidgets('a frame number and + keys the field there with its value at that frame', (tester) async {
    await pumpView(tester);
    final before = layer.transform.rotation.keyframes.length;
    final row = find.byKey(const ValueKey('add-key-at-rotation'));
    await tester.enterText(find.descendant(of: row, matching: find.byType(TextField)), '7');
    await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.add)));
    await tester.pump();
    final ks = layer.transform.rotation.keyframes;
    expect(ks.length, before + 1);
    expect(ks.map((k) => k.frame), contains(7));
    expect(ks.map((k) => k.frame).toList(), equals([...ks.map((k) => k.frame)]..sort()));
  });
}
