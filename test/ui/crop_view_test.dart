import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/crop/crop_view.dart';
import 'package:movement_mobile/ui/presets/presets_view.dart';

void main() {
  late AppState app;
  setUp(() => app = AppState());
  tearDown(() {
    cropEditing = false;
    app.dispose();
  });

  Future<void> pump(WidgetTester tester, Widget view) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 600, child: view))));
    await tester.pumpAndSettle();
  }

  testWidgets('Crop tab: aspect chips, canvas editing and mirror', (tester) async {
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    await pump(tester, CropView(app: app));

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(cropEditing, isTrue);

    await tester.tap(find.widgetWithText(ChoiceChip, '1:1'));
    await tester.pump();
    expect(layer.cropAspect, '1:1');

    await tester.scrollUntilVisible(find.widgetWithText(FilterChip, 'Horizontal'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Horizontal'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Horizontal'));
    await tester.pump();
    expect(layer.mirrorX, isTrue);
  });

  testWidgets('Presets tab without a preset folder explains itself instead of failing', (tester) async {
    await pump(tester, PresetsView(app: app));
    expect(find.textContaining('home screen'), findsOneWidget);
  });

  testWidgets('Crop tab: Fit / Fill / Stretch fit the object to the frame, one undo step each', (tester) async {
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    await pump(tester, CropView(app: app));
    await tester.scrollUntilVisible(find.text('Stretch'), 100,
        scrollable: find.descendant(of: find.byType(CropView), matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(find.text('Stretch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stretch'));
    await tester.pump();
    final s = findLayer(app.project, layer.id)!.transform.scale.defaultValue as List<double>;
    expect(s[0], closeTo(app.frameWidth / layer.content.size[0], 1e-6));
    expect(s[1], closeTo(app.frameHeight / layer.content.size[1], 1e-6));
    app.performUndo();
    expect(findLayer(app.project, layer.id)!.transform.scale.defaultValue, [1.0, 1.0]);
  });
}
