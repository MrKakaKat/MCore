import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/effects/effects_view.dart';
import 'package:movement_mobile/ui/text/text_view.dart';

void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });
  setUp(() => ParamEditor.resetModes(expanded: true));

  testWidgets('Follow: the target picker refuses a layer that already follows this one', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = AppState();
    final a = findLayer(app.project, app.selection.selectedLayer)!..name = 'Alpha';
    app.addLayer('rect');
    final b = app.project.layers.last..name = 'Beta';
    b.follow
      ..enabled = true
      ..targetId = a.id;
    app.selection.selectedLayer = a.id;
    a.follow.enabled = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EffectsView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('follow-section')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('follow-target')));
    await tester.pumpAndSettle();
    expect(find.text('Beta (circle)'), findsWidgets);
    await tester.tap(find.text('Beta (circle)').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(a.follow.targetId, isNull, reason: 'a circle is not picked');
  });

  testWidgets('Text shadow: Lag shows its speed and bounciness and sets the flag', (tester) async {
    final app = AppState();
    app.addTextLayer();
    final layer = app.project.layers.last;
    layer.content.text!.shadow.enabled = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 560, child: TextView(app: app)))));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    final section = find.byKey(const ValueKey('text-section-Shadow'));
    await tester.scrollUntilVisible(section, 200, scrollable: list);
    // the sections remember being open (another test may have opened it).
    // a little further, so the header isn't at the very edge.
    await tester.drag(list, const Offset(0, -150));
    await tester.pumpAndSettle();
    if (find.descendant(of: section, matching: find.byIcon(Icons.expand_more)).evaluate().isNotEmpty) {
      await tester.tap(section);
      await tester.pumpAndSettle();
    }
    final lag = find.byKey(const ValueKey('text-shadow-lag'));
    await tester.scrollUntilVisible(lag, 150, scrollable: list);
    tester.widget<SwitchListTile>(lag).onChanged!(true);
    await tester.pumpAndSettle();
    expect(layer.content.text!.shadow.lag, isTrue);
    Finder editor(String label) => find.byWidgetPredicate((w) => w is ParamEditor && w.label == label);
    await tester.scrollUntilVisible(editor('lag bounciness %'), 150, scrollable: list);
    expect(editor('lag speed'), findsOneWidget);
    expect(find.byKey(const ValueKey('text-shadow-per-letter')), findsNothing, reason: 'no animators yet');
  });
}
