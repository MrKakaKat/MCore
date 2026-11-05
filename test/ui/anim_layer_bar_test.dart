import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';

void main() {
  tearDown(() {
    activeAnimLayer = 0;
    keyMode = 'base';
  });

  testWidgets('Keyframes tab: base / order / layer keys; layer list without numbers', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    expect(find.text('Base keys'), findsOneWidget);

    // order keys: a key opens a range, the next closes it.
    await tester.tap(find.text('Order keys'));
    await tester.pump();
    expect(keyMode, 'order');
    expect(find.text('Place a key to start a range'), findsOneWidget);
    app.pushUndo();
    keyAllTracks(app.project, layer, 10);
    app.commitEdit();
    await tester.pump();
    expect(find.textContaining('Range open from frame 10'), findsOneWidget);
    keyAllTracks(app.project, layer, 30);
    app.commitEdit();
    await tester.pump();
    expect(find.text('Place a key to start a range'), findsOneWidget);

    // layer keys: the list, by frames.
    await tester.tap(find.text('Layer keys'));
    await tester.pump();
    expect(find.textContaining('frames 10 - 30'), findsOneWidget);
    expect(find.textContaining('Layer 1'), findsNothing, reason: 'no numbering');
    await tester.tap(find.byKey(const ValueKey('anim-layer-eye-1')));
    await tester.pump();
    expect(layer.transform.anchor.animLayers.single.enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('anim-layer-delete-1')));
    await tester.pump();
    expect(layer.transform.anchor.animLayers, isEmpty);

    await tester.tap(find.text('Base keys'));
    await tester.pump();
    expect(activeAnimLayer, 0);
  });

  testWidgets('the parameters with keys fold away behind the list button', (tester) async {
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.transform.rotation.keyframes.add(Keyframe(frame: 5, value: 1.0));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    expect(find.text('Rotation'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('key-params-toggle')));
    await tester.pump();
    expect(find.text('Rotation'), findsOneWidget);
  });

  testWidgets('no banner in the Movement tab while a layer of movement is edited', (tester) async {
    final app = AppState();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    app.addAnimLayer(layer.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ParamsPanelView(app: app))));
    expect(find.byKey(const ValueKey('anim-layer-banner')), findsNothing);
    expect(find.text('Back to base'), findsNothing);
  });
}
