import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/crop/crop_view.dart';
import 'package:movement_mobile/ui/layer_panel/layer_panel_view.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';
import 'package:movement_mobile/ui/timeline/timeline_rows_view.dart';

void main() {
  setUp(() => ParamEditor.resetModes(expanded: true));

  Future<void> tall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  test('an empty project keeps the playhead at 0', () {
    final app = AppState();
    for (final l in [...app.project.layers]) {
      app.deleteLayerById(l.id);
    }
    app.setFrame(40);
    expect(app.currentFrame, 0);
  });

  testWidgets('linked scale: changing x changes y by the same factor', (tester) async {
    await tall(tester);
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ParamsPanelView(app: app))));
    // linked by default.
    expect(app.scaleLinked, isTrue);
    final link = find.byKey(const ValueKey('scale-link'));
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pump();
    expect(app.scaleLinked, isFalse);
    await tester.tap(link);
    await tester.pump();
    expect(app.scaleLinked, isTrue);
    final editor = tester.widget<ParamEditor>(find.byWidgetPredicate((w) => w is ParamEditor && w.label == 'scale'));
    final before = List<double>.from(editor.values);
    editor.onCommit([before[0] * 2, before[1]]);
    final now = evaluateTrack(app.project, layer.transform.scale, app.currentFrame.toDouble()) as List<double>;
    expect(now[0], closeTo(before[0] * 2, 1e-6));
    expect(now[1], closeTo(before[1] * 2, 1e-6));
    app.setAppPreference('scaleLinked', false);
  });

  testWidgets('the clip length and move-to-frame are in the Timeline tab', (tester) async {
    await tall(tester);
    final app = AppState();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelineRowsView(app: app))));
    expect(find.byKey(const ValueKey('clip-length')), findsOneWidget);
    expect(find.byKey(const ValueKey('move-layer-to-frame')), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LayerPanelView(app: app))));
    expect(find.byKey(const ValueKey('clip-length')), findsNothing);
  });

  testWidgets('Crop settings start folded', (tester) async {
    await tall(tester);
    final app = AppState();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CropView(app: app))));
    expect(find.text('Crop settings'), findsOneWidget);
    expect(find.text('Reset crop'), findsNothing);
    await tester.tap(find.text('Crop settings'));
    await tester.pumpAndSettle();
    expect(find.text('Reset crop'), findsOneWidget);
  });
}
