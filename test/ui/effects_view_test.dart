import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/effects/effects_view.dart';

/// Real, run widget-level coverage of the new Effects tab - the port of
/// movement-core/src/ui/paramsPanel/effectsSection.js's effect stack
/// (enable/reorder/delete/reset-pins/confirm-shape/generic param fields)
/// plus the motion-blur/wiggle/pendulum add-on sections.
void main() {
  late AppState app;
  late Layer layer;

  setUp(() {
    ParamEditor.resetModes(expanded: true);
    app = AppState();
    layer = findLayer(app.project, app.selection.selectedLayer)!;
  });

  Future<void> pump(WidgetTester tester) async {
    // the pendulum section (checkbox + 5 sliders + pivot controls) sits
    // well past the default 800x600 test surface's fold - a tall
    // viewport keeps every control hit-testable without needing a
    // scroll-into-view dance before each tap.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EffectsView(app: app))));
    await tester.pumpAndSettle();
  }

  // picks an entry in the "+ effect" dropdown (the last dropdown on the
  // tab - choice params have their own) and adds it.
  Future<void> addEffect(WidgetTester tester, String name) async {
    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ effect'));
    await tester.pumpAndSettle();
  }

  testWidgets('adding an effect via the dropdown actually pushes an instance onto the layer\'s effectStack', (tester) async {
    await pump(tester);
    expect(layer.effectStack, isEmpty);

    await tester.tap(find.text('+ effect'));
    await tester.pump();

    expect(layer.effectStack, hasLength(1));
  });

  testWidgets('the enable checkbox toggles the instance\'s enabled flag', (tester) async {
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));
    await pump(tester);
    expect(layer.effectStack.first.enabled, isTrue);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(layer.effectStack.first.enabled, isFalse);
  });

  testWidgets('dragging an effect card by its side handle reorders the stack (no arrow buttons)', (tester) async {
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));
    layer.effectStack.add(createEffectInstance('bend_arc', 'fx2', layer));
    await pump(tester);
    expect(find.byIcon(Icons.arrow_upward), findsNothing);

    final handle = find.byIcon(Icons.drag_indicator).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 25; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(layer.effectStack.map((i) => i.id), equals(['fx2', 'fx1']));
  });

  testWidgets('a card collapses to its header and expands back', (tester) async {
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));
    await pump(tester);
    expect(find.text('AxisX'), findsOneWidget);
    await tester.tap(find.byTooltip('collapse'));
    await tester.pump();
    expect(find.text('AxisX'), findsNothing);
    await tester.tap(find.byTooltip('expand'));
    await tester.pump();
    expect(find.text('AxisX'), findsOneWidget);
  });

  testWidgets('the delete (x) button removes exactly that instance', (tester) async {
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));
    layer.effectStack.add(createEffectInstance('bend_arc', 'fx2', layer));
    await pump(tester);

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();

    expect(layer.effectStack.map((i) => i.id), equals(['fx2']));
  });

  testWidgets('mesh_warp shows the pin-count note and reset button instead of per-pin fields', (tester) async {
    layer.effectStack.add(createEffectInstance('mesh_warp', 'fx1', layer));
    await pump(tester);

    expect(find.textContaining('pins - drag directly on the stage'), findsOneWidget);
    expect(find.text('Reset all pins'), findsOneWidget);
  });

  testWidgets('reset all pins actually clears every mesh_warp pin track back to neutral', (tester) async {
    final inst = createEffectInstance('mesh_warp', 'fx1', layer);
    layer.effectStack.add(inst);
    final somePin = inst.params['r0c0'] as Track;
    somePin.keyframes.add(Keyframe(frame: 5, value: [3.0, 4.0]));
    await pump(tester);

    await tester.tap(find.text('Reset all pins'));
    await tester.pump();

    expect(somePin.keyframes, isEmpty);
    expect(somePin.defaultValue, equals([0.0, 0.0]));
  });

  testWidgets('corner_pin shows a "Confirm shape" button that bakes the pinned bbox into a polygon and REMOVES the instance', (tester) async {
    final inst = createEffectInstance('corner_pin', 'fx1', layer);
    layer.effectStack.add(inst);
    (inst.params['tr'] as Track).defaultValue = [5.0, 0.0]; // nudge one corner so the bake produces a real quad
    await pump(tester);

    expect(find.text('Confirm shape'), findsOneWidget);
    await tester.tap(find.text('Confirm shape'));
    await tester.pump();

    expect(layer.content.shape, equals('polygon'));
    expect(layer.content.points, hasLength(4));
    expect(layer.effectStack, isEmpty, reason: 'a baked instance has nothing left to configure, so it is dropped, not left zeroed');
  });

  testWidgets('mesh_warp also shows a "Confirm shape" button that bakes the deformed grid into a polygon and REMOVES the instance', (tester) async {
    final inst = createEffectInstance('mesh_warp', 'fx1', layer);
    layer.effectStack.add(inst);
    (inst.params['r0c0'] as Track).defaultValue = [5.0, 5.0]; // nudge one pin so the bake produces a real deformation
    await pump(tester);

    expect(find.text('Confirm shape'), findsOneWidget);
    await tester.tap(find.text('Confirm shape'));
    await tester.pump();

    expect(layer.content.shape, equals('polygon'));
    expect(layer.content.points, isNotEmpty);
    expect(layer.effectStack, isEmpty);
  });

  testWidgets('a legacy bend_arc shows a baseAxis dropdown that actually changes the effect instance\'s param', (tester) async {
    final inst = EffectInstance(id: 'fx1', effectId: 'bend_arc', enabled: true, params: {'angle': track(0.0), 'base': track(0.0), 'baseAxis': 'bottom'});
    layer.effectStack.add(inst);
    await pump(tester);

    expect(inst.params['baseAxis'], equals('bottom'));
    // two DropdownButton<String> exist on screen - this one (baseAxis)
    // and the unrelated "add effect" dropdown - disambiguate by value.
    final axisDropdown = find.byWidgetPredicate((w) => w is DropdownButton<String> && w.value == 'bottom');
    await tester.tap(axisDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('left').last);
    await tester.pumpAndSettle();

    expect(inst.params['baseAxis'], equals('left'));
  });

  testWidgets('a generic effect param (squeeze_axis\'s axisX) shows a number field wired to its track', (tester) async {
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));
    await pump(tester);

    expect(find.text('AxisX'), findsOneWidget);
    expect(find.text('AxisY'), findsOneWidget);
  });

  testWidgets('editing a generic effect param field commits to the track\'s default (no keyframe at current frame)', (tester) async {
    final inst = createEffectInstance('squeeze_axis', 'fx1', layer);
    layer.effectStack.add(inst);
    await pump(tester);

    final axisXRow = find.ancestor(of: find.text('AxisX'), matching: find.byType(ParamEditor)).first;
    // params show sliders by default - switch this one to number fields.
    await tester.tap(find.descendant(of: axisXRow, matching: find.byTooltip('show number fields')));
    await tester.pump();
    await tester.enterText(find.descendant(of: axisXRow, matching: find.byType(TextField)), '2.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect((inst.params['axisX'] as Track).defaultValue, equals(2.5));
  });

  testWidgets('motion blur is added from the effect list, and removed again', (tester) async {
    await pump(tester);
    expect(layer.motionBlur.enabled, isFalse);
    expect(find.text('Shutter'), findsNothing);

    await addEffect(tester, 'Motion blur');
    expect(layer.motionBlur.enabled, isTrue);
    expect(find.text('Shutter'), findsOneWidget);
    expect(find.text('Samples'), findsOneWidget);

    await tester.tap(find.byTooltip('remove effect'));
    await tester.pumpAndSettle();
    expect(layer.motionBlur.enabled, isFalse);
    expect(find.text('Shutter'), findsNothing);
  });

  testWidgets('wiggle is added from the effect list, and its sliders mutate speed', (tester) async {
    await pump(tester);
    await addEffect(tester, 'Wiggle');

    expect(layer.wiggle.enabled, isTrue);
    expect(find.byType(Slider), findsNWidgets(3));

    final speedBefore = layer.wiggle.speed;
    await tester.drag(find.byType(Slider).first, const Offset(50, 0));
    await tester.pump();
    expect(layer.wiggle.speed, isNot(equals(speedBefore)));

    // one of each: Wiggle is no longer offered.
    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('1. Wiggle'), findsOneWidget);
    expect(find.text('Wiggle'), findsNothing, reason: 'no longer offered in the dropdown');
  });

  testWidgets('pendulum section: enabling shows rotateWithLine, pivot controls, and NOT the parent-pivot button without a parent', (tester) async {
    // the default project's own selected layer is L_child, which IS
    // parented (L_child -> L_parent) - select the ROOT layer instead for
    // the no-parent case.
    app.selectLayer('L_parent');
    layer = findLayer(app.project, 'L_parent')!;
    await pump(tester);
    await addEffect(tester, 'Pendulum');

    expect(layer.pendulum.enabled, isTrue);
    expect(find.text('Object rotates with line'), findsOneWidget);
    expect(find.text('Reset grip to center'), findsOneWidget);
    expect(find.text('Pivot to parent center'), findsNothing, reason: 'this layer has no parentId in this fixture');
    // removing the long grip-point description also left the pivot keyframe
    // button with nothing identifying it at all
    // - a short label must survive even though the long paragraph is gone.
    expect(find.text('Grip point'), findsOneWidget);
  });

  testWidgets('pendulum pivot keyframe button toggles a keyframe on pivotOffset at the current frame', (tester) async {
    await pump(tester);
    await addEffect(tester, 'Pendulum');

    expect(layer.pendulum.pivotOffset.keyframes, isEmpty);
    await tester.tap(find.byIcon(Icons.diamond_outlined));
    await tester.pump();

    expect(layer.pendulum.pivotOffset.keyframes, hasLength(1));
    expect(layer.pendulum.pivotOffset.keyframes.first.frame, equals(app.currentFrame));
  });

  testWidgets('pendulum pivot-to-parent button appears once the layer has a parentId, and moves the pivot toward the parent', (tester) async {
    // the default project's own child layer IS parented (L_child ->
    // L_parent) - select it instead of adding a fixture parent by hand.
    // Its default anchor ([0,0]) happens to compose to the SAME world
    // position as the parent's own anchor (an offset of zero within the
    // parent's frame), which would make this test trivially pass even
    // with a broken delta calculation - nudge it first so the two
    // layers occupy genuinely different world positions.
    app.selectLayer('L_child');
    layer = findLayer(app.project, 'L_child')!;
    layer.transform.anchor.defaultValue = [0.1, 0.1];
    app.commitEdit();
    await pump(tester);

    await addEffect(tester, 'Pendulum');

    expect(find.text('Pivot to parent center'), findsOneWidget);
    await tester.tap(find.text('Pivot to parent center'));
    await tester.pump();

    expect(layer.pendulum.pivotOffset.defaultValue, isNot(equals([0.0, 0.0])), reason: 'the default project\'s parent/child sit at different anchors, so the pivot must actually move');
  });

  testWidgets('3D Rotate: its numeric params get rows, and the back-side choice is a dropdown', (tester) async {
    final inst = createEffectInstance('rotate_3d', 'fx3d', layer);
    layer.effectStack.add(inst);
    await pump(tester);
    expect(find.text('Pivot (0-1)'), findsOneWidget);
    expect(find.text('Perspective'), findsOneWidget);
    // the choice sits at the very bottom of the effect's settings.
    expect(tester.getTopLeft(find.text('Backface')).dy,
        greaterThan(tester.getTopLeft(find.text('Shading')).dy));

    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('hide').last);
    await tester.pumpAndSettle();
    expect(inst.params['backface'], 'hide');
  });

  testWidgets('a legacy bend keeps its base-axis dropdown (now the generic choice row)', (tester) async {
    final inst = EffectInstance(id: 'fxb', effectId: 'bend_arc', enabled: true, params: {'angle': track(0.0), 'base': track(0.0), 'baseAxis': 'bottom'});
    layer.effectStack.add(inst);
    await pump(tester);
    await tester.tap(find.text('bottom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('left').last);
    await tester.pumpAndSettle();
    expect(inst.params['baseAxis'], 'left');
  });

  testWidgets('effects are grouped by type; a card is reordered within its type, the order is saved', (tester) async {
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));
    layer.effectStack.add(createEffectInstance('bend_arc', 'fx2', layer));
    addMotionPanelEntry(layer, 'wiggle');
    await pump(tester);
    expect(find.byKey(const ValueKey('fx-type-Shape')), findsOneWidget);
    expect(find.byKey(const ValueKey('fx-type-Motion')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('fx-type-Motion'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const ValueKey('fx-card-fx2'))).dy),
        reason: 'the Shape effects first, then Motion');

    // the second Shape card up above the first (the list's own reorder -
    // a drag gesture's landing depends on the screen).
    final list = tester.widget<ReorderableListView>(
        find.ancestor(of: find.byKey(const ValueKey('fx-card-fx1')), matching: find.byType(ReorderableListView)));
    // (nullable in newer Flutter: called the same way on both)
    Function.apply(list.onReorder as Function, [1, 0]);
    await tester.pumpAndSettle();

    expect(layer.effectPanelOrder, ['fx2', 'fx1', 'wiggle']);
    expect([for (final i in layer.effectStack) i.id], ['fx2', 'fx1'], reason: 'the render order follows');
  });
}
