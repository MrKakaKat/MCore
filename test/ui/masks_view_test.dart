import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/masks/masks_view.dart';

/// Real, run widget-level coverage of the new Masks tab - the port of
/// movement-core/src/ui/paramsPanel/masksSection.js: mask stack
/// (enable/mode/source-layer/feather/delete) plus the "+ mask" button.
void main() {
  late AppState app;
  late Layer layer;
  late Layer otherLayer;

  setUp(() {
    ParamEditor.resetModes(expanded: true);
    app = AppState();
    layer = findLayer(app.project, app.selection.selectedLayer)!;
    otherLayer = app.project.layers.firstWhere((l) => l.id != layer.id);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MasksView(app: app))));
    await tester.pumpAndSettle();
    // folds start folded: open the masks, then their parameters.
    for (final prefix in ['fold-mask ', 'fold-mask params ']) {
      final folds = find.byWidgetPredicate((w) {
        final k = w.key;
        return k is ValueKey<String> && k.value.startsWith(prefix) && (prefix.contains('params') || !k.value.contains('params'));
      });
      for (var i = 0; i < folds.evaluate().length; i++) {
        await tester.tap(folds.at(i));
        await tester.pumpAndSettle();
      }
    }
  }

  testWidgets('+ mask button adds a new mask to the layer', (tester) async {
    await pump(tester);
    expect(layer.masks, isEmpty);

    await tester.tap(find.text('+ mask'));
    await tester.pump();

    expect(layer.masks, hasLength(1));
    expect(layer.masks.first.enabled, isTrue);
    expect(layer.masks.first.mode, equals('add'));
  });

  testWidgets('the enable checkbox toggles the mask\'s enabled flag', (tester) async {
    layer.masks.add(Mask());
    await pump(tester);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(layer.masks.first.enabled, isFalse);
  });

  testWidgets('the mode dropdown actually changes the mask\'s mode', (tester) async {
    layer.masks.add(Mask());
    await pump(tester);

    expect(layer.masks.first.mode, equals('add'));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subtract').last);
    await tester.pumpAndSettle();

    expect(layer.masks.first.mode, equals('subtract'));
  });

  testWidgets('the source dropdown lists every OTHER layer, and setting it updates sourceLayerId', (tester) async {
    layer.masks.add(Mask());
    await pump(tester);

    expect(layer.masks.first.sourceLayerId, isNull);
    await tester.tap(find.byType(DropdownButton<String?>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(otherLayer.name).last);
    await tester.pumpAndSettle();

    expect(layer.masks.first.sourceLayerId, equals(otherLayer.id));
  });

  testWidgets('the delete (x) button removes exactly that mask', (tester) async {
    final mask1 = Mask(mode: 'add');
    final mask2 = Mask(mode: 'subtract');
    layer.masks.addAll([mask1, mask2]);
    await pump(tester);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();

    expect(layer.masks, equals([mask2]));
  });

  testWidgets('editing feather commits to the track\'s default, and the keyframe toggle adds/removes a keyframe', (tester) async {
    layer.masks.add(Mask());
    await pump(tester);

    final featherRow = find.ancestor(of: find.text('Feather'), matching: find.byType(ParamEditor)).first;
    await tester.tap(find.descendant(of: featherRow, matching: find.byTooltip('show number fields')));
    await tester.pump();
    await tester.enterText(find.descendant(of: featherRow, matching: find.byType(TextField)), '5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(layer.masks.first.feather.defaultValue, equals(5.0));

    expect(layer.masks.first.feather.keyframes, isEmpty);
    final diamond = find.descendant(of: featherRow, matching: find.byIcon(Icons.diamond_outlined));
    await tester.ensureVisible(diamond);
    await tester.pump();
    await tester.tap(diamond);
    await tester.pump();
    expect(layer.masks.first.feather.keyframes, hasLength(1));
  });

  testWidgets('masks reorder by dragging their = handle', (tester) async {
    final a = Mask(mode: 'add'), b = Mask(mode: 'subtract');
    layer.masks.addAll([a, b]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MasksView(app: app))));
    await tester.pumpAndSettle();
    expect(find.text('Mask - Add'), findsOneWidget, reason: 'no numbers, capitalised');
    final handle = find.byIcon(Icons.drag_handle).last;
    final g = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    await g.moveBy(const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 100));
    await g.up();
    await tester.pumpAndSettle();
    expect(layer.masks, [b, a]);
  });

  testWidgets('Regions: the layer is one of its own shapes; its own areas are listed (inside the other, alone, Outer)',
      (tester) async {
    layer.masks.addAll([Mask(sourceLayerId: otherLayer.id)]);
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MasksView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regions'));
    await tester.pumpAndSettle();
    final mr = layer.maskRegions!;
    expect(mr.sources, [otherLayer.id, layer.id], reason: 'the layer itself goes in, last');
    expect(mr.opacity[3]!.defaultValue, 1.0, reason: 'the old add: inside the other shows');
    expect(mr.opacity[2]!.defaultValue, 0.0, reason: 'outside the other: hidden');
    expect(find.byKey(const ValueKey('region-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('region-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('region-0')), findsOneWidget, reason: 'Outer, off');
    expect(find.byKey(const ValueKey('region-1')), findsNothing, reason: 'the other shape alone is not this layer\'s');
    expect(find.textContaining('Quick set-up'), findsNothing);
    // back to the stack: the stack is as it was.
    await tester.tap(find.text('Stack'));
    await tester.pumpAndSettle();
    expect(mr.enabled, isFalse);
    expect(layer.masks, hasLength(1));
  });
}
