import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/num_field.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';

/// Sliders / endless rulers on every parameter, with a per-parameter
/// switch back to the number fields.
void main() {
  setUp(() => ParamEditor.resetModes(expanded: true));

  Future<void> pumpBox(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 400, child: child))));
    await tester.pump();
  }

  testWidgets('an endless ruler goes past 360 in either direction, and clamps at its min', (tester) async {
    var value = 0.0;
    var starts = 0;
    Widget ruler(ParamScale scale) => StatefulBuilder(
          builder: (context, setState) => EndlessRuler(
            value: value,
            scale: scale,
            onChangeStart: () => starts++,
            onChanged: (v) => setState(() => value = v),
          ),
        );
    await pumpBox(tester, ruler(ParamScale.degrees));

    // drag the tape left by 1000px at 0.5 deg/px -> +500 degrees
    await tester.drag(find.byType(EndlessRuler), const Offset(-1000, 0));
    await tester.pump();
    expect(value, closeTo(500, 1));
    expect(starts, 1);

    await tester.drag(find.byType(EndlessRuler), const Offset(2000, 0));
    await tester.pump();
    expect(value, closeTo(-500, 1), reason: 'and back through zero into negatives');

    value = 3;
    await pumpBox(tester, ruler(const ParamScale.ruler(unitsPerPixel: 0.5, minorTick: 5, majorTick: 25, min: 0)));
    await tester.drag(find.byType(EndlessRuler), const Offset(400, 0));
    await tester.pump();
    expect(value, 0, reason: 'feather never goes below 0');
  });

  testWidgets('the icon switches one parameter between sliders and number fields, remembered per key', (tester) async {
    Widget editor(String key) => ParamEditor(
          prefKey: key,
          label: key,
          values: const [0.5],
          scale: const ParamScale.slider(0, 1),
          onEditStart: () {},
          onChanged: (_) {},
          onCommit: (_) {},
        );
    await pumpBox(tester, Column(children: [editor('a'), editor('b')]));
    expect(find.byType(Slider), findsNWidgets(2));
    expect(find.byType(NumField), findsNothing);

    await tester.tap(find.byTooltip('show number fields').first);
    await tester.pump();
    expect(find.byType(NumField), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget, reason: 'the other parameter keeps its slider');

    // rebuilt from scratch: the choice is remembered for key "a"
    await pumpBox(tester, Column(children: [editor('b'), editor('a')]));
    expect(find.byType(NumField), findsOneWidget);
  });

  group('Movement tab', () {
    late AppState app;
    late Layer layer;
    setUp(() {
      app = AppState();
      layer = findLayer(app.project, app.selection.selectedLayer)!;
    });
    tearDown(() => app.dispose());

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 900, child: ParamsPanelView(app: app)))));
      await tester.pumpAndSettle();
    }

    testWidgets('rotation, anchor and scale are rulers (two for x/y), opacity a slider', (tester) async {
      await pump(tester);
      expect(find.byType(EndlessRuler), findsNWidgets(5), reason: 'anchor x/y, scale x/y, rotation');
      expect(find.byType(Slider), findsOneWidget, reason: 'opacity');
    });

    testWidgets('dragging the rotation ruler turns the layer past 360, one undo step', (tester) async {
      await pump(tester);
      final rotationRuler = find.byType(EndlessRuler).at(4);
      await tester.drag(rotationRuler, const Offset(-400, 0));
      await tester.pump();
      await tester.drag(rotationRuler, const Offset(-400, 0));
      await tester.pump();
      expect(layer.transform.rotation.defaultValue as double, closeTo(400, 2));

      app.performUndo();
      expect(findLayer(app.project, layer.id)!.transform.rotation.defaultValue as double, closeTo(200, 2),
          reason: 'each drag is one undo step');
    });

    testWidgets('dragging the opacity slider sets opacity', (tester) async {
      await pump(tester);
      // (the first: opacity - Free move's smoothing comes after it)
      await tester.ensureVisible(find.byType(Slider).first);
      await tester.pump();
      await tester.drag(find.byType(Slider).first, const Offset(-1000, 0));
      await tester.pump();
      expect(layer.transform.opacity.defaultValue as double, closeTo(0, 0.01));
    });
  });

  testWidgets('header: name, then the mode switch, then the icons and the expand arrow; the control spans the row below', (tester) async {
    Widget editor(String key, ParamScale scale) => ParamEditor(
          prefKey: key,
          label: key,
          values: const [0.5],
          scale: scale,
          onEditStart: () {},
          onChanged: (_) {},
          onCommit: (_) {},
          trailing: [IconButton(icon: const Icon(Icons.diamond_outlined), tooltip: 'key $key', onPressed: () {})],
        );
    await pumpBox(
        tester,
        Column(children: [
          editor('opacity', const ParamScale.slider(0, 1)),
          editor('rotation', ParamScale.degrees),
        ]));
    expect(find.text('Opacity'), findsOneWidget, reason: 'names are capitalised');
    final labelX = tester.getTopLeft(find.text('Opacity')).dx;
    final keyX = tester.getTopLeft(find.byTooltip('key opacity')).dx;
    final modeX = tester.getTopLeft(find.byTooltip('show number fields').first).dx;
    final arrowX = tester.getTopLeft(find.byTooltip('hide control').first).dx;
    expect(labelX, lessThan(modeX));
    expect(modeX, lessThan(keyX));
    expect(keyX, lessThan(arrowX));

    final sliderRect = tester.getRect(find.byType(Slider));
    final rulerRect = tester.getRect(find.byType(EndlessRuler));
    expect(sliderRect.top, greaterThan(tester.getRect(find.text('Opacity')).bottom), reason: 'below the header');
    expect(sliderRect.width, greaterThan(360), reason: 'the full row width (400)');
    // the ruler: between its - and + step buttons (26 px each).
    expect(sliderRect.width, closeTo(rulerRect.width + 52, 0.5));
    // the slider's control (value on top + track) is as tall as a ruler.
    final control = tester.getRect(find.ancestor(of: find.byType(Slider), matching: find.byType(Column)).first);
    expect(control.height, closeTo(rulerRect.height, 0.5));
  });

  testWidgets('rows start collapsed: no control, the value in the header; the arrow opens it and it stays open', (tester) async {
    ParamEditor.resetModes();
    Widget editor() => ParamEditor(
          prefKey: 'p',
          label: 'rotation',
          values: const [45],
          scale: ParamScale.degrees,
          onEditStart: () {},
          onChanged: (_) {},
          onCommit: (_) {},
        );
    await pumpBox(tester, editor());
    expect(find.byType(EndlessRuler), findsNothing);
    expect(find.text('45°'), findsOneWidget);
    await tester.tap(find.byTooltip('show control'));
    await tester.pump();
    expect(find.byType(EndlessRuler), findsOneWidget);

    // the choice is remembered for that parameter.
    await pumpBox(tester, const SizedBox());
    await pumpBox(tester, editor());
    expect(find.byType(EndlessRuler), findsOneWidget);

    // folded: no mode switch; opened: it switches to fields.
    await tester.tap(find.byTooltip('hide control'));
    await tester.pump();
    expect(find.byTooltip('show number fields'), findsNothing);
    await tester.tap(find.byTooltip('show control'));
    await tester.pump();
    await tester.tap(find.byTooltip('show number fields'));
    await tester.pump();
    expect(find.byType(NumField), findsOneWidget);
  });

  testWidgets('x / y labels sit left of their rulers, not over them', (tester) async {
    await pumpBox(
        tester,
        ParamEditor(
          prefKey: 'anchor',
          label: 'anchor',
          values: const [0.5, 0.5],
          scale: const ParamScale.ruler(unitsPerPixel: 0.002, minorTick: 0.05, majorTick: 0.25),
          componentLabels: const ['x', 'y'],
          onEditStart: () {},
          onChanged: (_) {},
          onCommit: (_) {},
        ));
    final rulers = find.byType(EndlessRuler);
    expect(tester.getRect(find.text('x')).right, lessThanOrEqualTo(tester.getRect(rulers.at(0)).left));
    expect(tester.getRect(find.text('y')).right, lessThanOrEqualTo(tester.getRect(rulers.at(1)).left));
  });

  test('angles label whole degrees; other rulers keep their decimals', () {
    expect(ParamScale.degrees.labelDecimals, 0);
    expect(ParamScale.degrees.decimals, 1, reason: 'the value itself is not rounded');
    expect(const ParamScale.ruler(unitsPerPixel: 0.005, minorTick: 0.1, majorTick: 0.5).labelDecimals, 2);
  });

  testWidgets('a ruler steps by its smallest unit with - / +, the step can be set; fields copy, paste and match x and y',
      (tester) async {
    ParamEditor.resetModes(expanded: true);
    var values = [0.5, 0.25];
    await pumpBox(
        tester,
        StatefulBuilder(
          builder: (context, set) => ParamEditor(
            prefKey: 'anchor',
            label: 'anchor',
            values: values,
            scale: const ParamScale.ruler(unitsPerPixel: 0.002, minorTick: 0.05, majorTick: 0.25, decimals: 3),
            onEditStart: () {},
            onChanged: (v) => set(() => values = v),
            onCommit: (v) => set(() => values = v),
          ),
        ));
    await tester.tap(find.byKey(const ValueKey('ruler-plus-anchor-0')));
    await tester.pump();
    expect(values[0], closeTo(0.501, 1e-9));
    await tester.enterText(find.byKey(const ValueKey('ruler-step-anchor')), '10');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ruler-minus-anchor-1')));
    await tester.pump();
    expect(values[1], closeTo(0.24, 1e-9));
    // number fields: copy, paste, the same.
    await tester.tap(find.byTooltip('show number fields'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('fields-copy-anchor')));
    await tester.pump();
    expect(ParamEditor.clipboard, [0.501, 0.24]);
    await tester.tap(find.byKey(const ValueKey('fields-same-anchor')));
    await tester.pump();
    expect(values, [0.501, 0.501]);
    await tester.tap(find.byKey(const ValueKey('fields-paste-anchor')));
    await tester.pump();
    expect(values, [0.501, 0.24]);
  });
}
