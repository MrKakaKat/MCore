import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/graph_editor/graph_editor_view.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';

/// Real, run widget-level coverage of the new controls ported from
/// movement-core/src/ui/paramsPanel/{shared,movementSection}.js: the
/// per-track "ease" button (shared.js's makeParam, gated on
/// `trk.keyframes.length >= 2`) and the anchor-only path-tension +
/// whole-path-easing controls (movementSection.js, gated the same way).
void main() {
  late AppState app;
  late Layer layer;

  setUp(() {
    ParamEditor.resetModes(expanded: true);
    app = AppState();
    layer = findLayer(app.project, app.selection.selectedLayer)!;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ParamsPanelView(app: app))));
    await tester.pumpAndSettle();
  }

  final easeButtonFinder = find.widgetWithIcon(IconButton, Icons.show_chart);

  testWidgets('no ease button appears for a track with fewer than 2 keyframes', (tester) async {
    await pump(tester);
    expect(easeButtonFinder, findsNothing);
  });

  testWidgets('an ease button appears once a track has 2+ keyframes, and opens the graph editor for THAT track', (tester) async {
    layer.transform.rotation.keyframes.addAll([
      Keyframe(frame: 0, value: 0.0),
      Keyframe(frame: 30, value: 90.0),
    ]);
    await pump(tester);

    expect(easeButtonFinder, findsOneWidget);
    await tester.tap(easeButtonFinder);
    await tester.pumpAndSettle();

    expect(find.byType(GraphEditorView), findsOneWidget);
    final view = tester.widget<GraphEditorView>(find.byType(GraphEditorView));
    expect(identical(view.track, layer.transform.rotation), isTrue);
    expect(view.componentCount, equals(1));
    expect(view.wholePath, isFalse);
  });

  testWidgets('a vec2 track\'s ease button opens the graph editor with componentCount 2', (tester) async {
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [10.0, 10.0]),
    ]);
    await pump(tester);

    await tester.tap(easeButtonFinder.first);
    await tester.pumpAndSettle();

    final view = tester.widget<GraphEditorView>(find.byType(GraphEditorView));
    expect(view.componentCount, equals(2));
  });

  testWidgets('tension/whole-path controls stay hidden with fewer than 2 anchor keyframes', (tester) async {
    await pump(tester);
    expect(find.text('Tension'), findsNothing);
    expect(find.text('Whole path'), findsNothing);
  });

  testWidgets('tension/whole-path controls appear once anchor has 2+ keyframes; editing tension recomputes tangents', (tester) async {
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [10.0, 0.0]),
      Keyframe(frame: 60, value: [10.0, 10.0]),
    ]);
    autoComputeTangents(layer.transform.anchor);
    final tangentBefore = layer.transform.anchor.keyframes[1].spatialTangent.outTan[0];
    await pump(tester);

    expect(find.text('Tension'), findsOneWidget);
    expect(find.text('Whole path'), findsOneWidget);

    // tension field is the only TextField preceding scale's fields in
    // build order (parent selector has no TextField) - find it via the
    // 'tension' label's Row.
    final tensionRow = find.ancestor(of: find.text('Tension'), matching: find.byType(ParamEditor)).first;
    await tester.tap(find.descendant(of: tensionRow, matching: find.byTooltip('show number fields')));
    await tester.pump();
    final tensionField = find.descendant(of: tensionRow, matching: find.byType(TextField));
    await tester.enterText(tensionField, '0.2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(layer.transform.anchor.tension, equals(0.2));
    expect(layer.transform.anchor.keyframes[1].spatialTangent.outTan[0], isNot(equals(tangentBefore)), reason: 'changing tension must recompute spatial tangents via autoComputeTangents');
  });

  testWidgets('whole-path checkbox toggles globalEasing on/off, and only shows its ease button while checked', (tester) async {
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [10.0, 10.0]),
    ]);
    await pump(tester);

    expect(layer.transform.anchor.globalEasing, isNull);
    final wholePathRow = find.ancestor(of: find.text('Whole path'), matching: find.byType(Row)).first;
    final checkbox = find.descendant(of: wholePathRow, matching: find.byType(Checkbox));
    final easeButtonInRow = find.descendant(of: wholePathRow, matching: find.widgetWithIcon(IconButton, Icons.show_chart));

    expect(easeButtonInRow, findsNothing);

    await tester.tap(checkbox);
    await tester.pump();

    expect(layer.transform.anchor.globalEasing, isNotNull);
    expect(layer.transform.anchor.globalEasing!.x1, equals(0.42)); // easeInOut preset
    expect(easeButtonInRow, findsOneWidget);

    await tester.tap(checkbox);
    await tester.pump();

    expect(layer.transform.anchor.globalEasing, isNull);
    expect(easeButtonInRow, findsNothing);
  });

  testWidgets('the anchor\'s own per-segment ease button is hidden once whole-path easing is active', (tester) async {
    // with whole-path easing on, evaluateTrack's whole-path branch never reads
    // a segment's own temporal at all, so editing it via the per-segment graph
    // editor would silently do nothing - the button is hidden rather than left
    // as a dead control.
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [10.0, 10.0]),
    ]);
    await pump(tester);

    // before whole-path: the anchor's own ease button is present (only
    // control on screen with 2+ keyframes on this fixture).
    expect(easeButtonFinder, findsOneWidget);

    final wholePathRow = find.ancestor(of: find.text('Whole path'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: wholePathRow, matching: find.byType(Checkbox)));
    await tester.pump();

    // after enabling: exactly ONE ease button remains (whole-path row's
    // own), not two - the anchor param row's per-segment one is gone.
    expect(easeButtonFinder, findsOneWidget);
    expect(find.descendant(of: wholePathRow, matching: easeButtonFinder), findsOneWidget);
  });

  testWidgets('the whole-path ease button opens the graph editor in wholePath mode for the anchor track', (tester) async {
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [10.0, 10.0]),
    ]);
    await pump(tester);

    final wholePathRow = find.ancestor(of: find.text('Whole path'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: wholePathRow, matching: find.byType(Checkbox)));
    await tester.pump();

    await tester.tap(find.descendant(of: wholePathRow, matching: find.widgetWithIcon(IconButton, Icons.show_chart)));
    await tester.pumpAndSettle();

    final view = tester.widget<GraphEditorView>(find.byType(GraphEditorView));
    expect(identical(view.track, layer.transform.anchor), isTrue);
    expect(view.wholePath, isTrue);
    expect(view.componentCount, equals(2));
  });
}
