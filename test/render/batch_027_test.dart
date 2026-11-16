import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';

void main() {
  tearDown(() => rectExtendMode = false);
  const lin = Easing(0, 0, 1, 1);

  test('a lengthened rect is drawn with its keyed box at each frame', () async {
    setStageSize(200, 100);
    final r = createLayer('rect')
      ..id = 'r'
      ..color = '#ff0000'
      ..content.size = [40, 40]
      ..durationFrames = 60
      ..transform.anchor.defaultValue = [0.3, 0.5]; // 40..80 x 30..70
    r.transform.extend.keyframes = [
      Keyframe(frame: 0, value: <double>[0, 0, 0, 0], temporal: lin),
      Keyframe(frame: 40, value: <double>[0, 0, 80, 0], temporal: lin),
    ];
    final p = Project(layers: [r]);
    final rr = CanvasRenderer()
      ..setSize(200, 100)
      ..backgroundColor = null;
    Future<int> alphaAt(int f, int x) async {
      clearStateCaches();
      rr.renderFrame(p, f);
      final img = await rr.captureFrame();
      final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return b.getUint8((50 * 200 + x) * 4 + 3);
    }

    expect(await alphaAt(0, 120), 0);
    expect(await alphaAt(40, 120), 255, reason: 'grown 80 px to the right');
    expect(await alphaAt(40, 50), 255);
    expect(r.content.size, [40, 40]);
  });

  testWidgets('"Size handles lengthen it": four rulers under scale, a key like the scale\'s', (tester) async {
    ParamEditor.resetModes(expanded: true);
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    final r = app.project.layers.single;
    app.selectLayer(r.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ParamsPanelView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('extend-right')), findsNothing);
    app.setAppPreference('rectExtendMode', true);
    // an app preference (saved): back as it was for the other tests.
    addTearDown(() => app.setAppPreference('rectExtendMode', false));
    await tester.pumpAndSettle();
    for (final s in ['left', 'top', 'right', 'bottom']) {
      expect(find.byKey(ValueKey('extend-$s')), findsOneWidget);
    }
  });
}
