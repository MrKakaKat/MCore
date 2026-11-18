import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';

void main() {
  testWidgets('anchor keyed only in key layers (order ranges): its ease button is there', (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    activeAnimLayer = 0;
    final app = AppState();
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    l.transform.anchor.keyframes.clear();
    final n = addTransformAnimLayer(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 0, value: <double>[0.0, 0.0]),
      Keyframe(frame: 20, value: <double>[0.1, 0.0]),
    ];
    app.setFrame(l.startFrame + 10);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(height: 1700, child: ParamsPanelView(app: app)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('param-ease')), findsWidgets);
  });
}
