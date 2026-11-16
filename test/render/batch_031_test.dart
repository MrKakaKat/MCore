import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';

void main() {
  test('a frame to a layer: a picture of how it looks at the playhead, above it, from the playhead on; it stays', () async {
    final app = AppState()..setFrameSize(200, 100);
    app.project.layers.clear();
    final v = createLayer('rect')
      ..id = 'v'
      ..name = 'clip'
      ..color = '#ff0000'
      ..content.size = [60, 40]
      ..durationFrames = 100
      ..transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(v);
    app.setFrame(30);
    expect(await app.frameToLayer('v'), isTrue);
    expect(app.project.layers, hasLength(2));
    final pic = app.project.layers.last;
    expect(pic.content.shape, 'image');
    expect(identical(app.project.layers.first, v), isTrue, reason: 'the clip stays, under it');
    expect(pic.startFrame, 30);
    expect(pic.startFrame + pic.durationFrames, 100);
    expect(pic.content.size[0], closeTo(60, 1.5));
    expect(pic.name, contains('frame 30'));
    app.performUndo();
    expect(app.project.layers, hasLength(1));
  });

  testWidgets('the sound\'s loudness shows behind the lanes', (tester) async {
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 600, height: 300, child: LayersTimelineView(app: app)))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline-volume')), findsNothing);
    app.project.layers.add(createAudioLayer(path: 'x', assetId: 'A', durationSeconds: 2));
    app.setFrame(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline-volume')), findsOneWidget);
  });

  testWidgets("scale's switches live in its fold", (tester) async {
    ParamEditor.resetModes(expanded: false);
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.selectLayer(app.project.layers.single.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ParamsPanelView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scale-keeps-opposite')), findsNothing, reason: 'folded: hidden');
    ParamEditor.resetModes(expanded: true);
    app.setFrame(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scale-keeps-opposite')), findsOneWidget, reason: 'open: under its rulers');
  });
}
