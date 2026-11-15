import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/layer_panel/layer_panel_view.dart';
import 'package:movement_mobile/ui/links/links_view.dart';
import 'package:movement_mobile/ui/stage/stage_view.dart';

void main() {
  test('a copied link pastes onto another layer; never onto its own source', () {
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('rect');
    app.addLayer('rect');
    final a = app.project.layers[0], b = app.project.layers[1], c = app.project.layers[2];
    final k = PropLink(sourceId: a.id, to: 'scaleBottom', mode: 'follow', factor: 2, fromFrame: 5);
    b.links.add(k);
    app.copyLink(k);
    expect(app.pasteLink(c.id), isTrue);
    final pasted = c.links.single;
    expect([pasted.sourceId, pasted.to, pasted.mode, pasted.factor, pasted.fromFrame], [a.id, 'scaleBottom', 'follow', 2, 5]);
    expect(identical(pasted, k), isFalse);
    expect(app.pasteLink(a.id), isFalse, reason: 'a layer following itself');
    app.performUndo();
    expect(findLayer(app.project, c.id)!.links, isEmpty);
  });

  testWidgets('links: the newest first', (tester) async {
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('rect');
    final b = app.project.layers[1];
    b.links
      ..add(PropLink(to: 'x'))
      ..add(PropLink(to: 'y'));
    app.selectLayer(b.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LinksView(app: app))));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(find.byKey(const ValueKey('link-1'))).dy;
    final second = tester.getTopLeft(find.byKey(const ValueKey('link-0'))).dy;
    expect(first, lessThan(second));
  });

  testWidgets('order on stage: a key from the folder; only keyed layers listed with "from .. to .., now at .."', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('rect');
    app.addLayer('rect');
    final bottom = app.project.layers.first;
    app.selectLayer(bottom.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LayerPanelView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stack-order-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('stack-place')).first, '1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    app.setFrame(10);
    await tester.tap(find.byKey(const ValueKey('stack-key-add')));
    await tester.pumpAndSettle();
    expect(findLayer(app.project, bottom.id)!.stackKeys.single.position, 1);
    expect(find.byKey(ValueKey('stack-layer-${bottom.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('stack-layer-${app.project.layers[1].id}')), findsNothing, reason: 'only the keyed ones');
    expect(find.text('from 1 to 1, now at 1'), findsOneWidget);
    app.setFrame(0);
    await tester.pumpAndSettle();
    expect(find.text('from 1 to 1, now at 3'), findsOneWidget);
    findLayer(app.project, bottom.id)!.startFrame = 500;
    app.setFrame(0);
    await tester.pumpAndSettle();
    expect(find.text('from 1 to 1, now absent'), findsOneWidget);
  });

  test('order keys change what is drawn on top (the list stays)', () async {
    setStageSize(100, 100);
    Layer sq(String id, String color) => createLayer('rect')
      ..id = id
      ..color = color
      ..content.size = [40, 40]
      ..durationFrames = 60
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final red = sq('r', '#ff0000'), blue = sq('b', '#0000ff');
    final p = Project(layers: [red, blue]);
    setStackKey(red, 20, 1);
    final r = CanvasRenderer()
      ..setSize(100, 100)
      ..backgroundColor = null;
    Future<int> centre(int f) async {
      clearStateCaches();
      r.renderFrame(p, f);
      final img = await r.captureFrame();
      final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return b.getUint8((50 * 100 + 50) * 4 + 2);
    }

    expect(await centre(10), 255, reason: 'blue on top before the key');
    expect(await centre(30), 0, reason: 'red jumps on top');
    expect(p.layers, [red, blue]);
  });

  testWidgets('crop on the stage: Done in the corner ends it', (tester) async {
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.selectLayer(app.project.layers.single.id);
    cropEditing = false;
    addTearDown(() => cropEditing = false);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 400, height: 400, child: StageView(app: app)))));
    await tester.pump();
    expect(find.byKey(const ValueKey('stage-crop-done')), findsNothing);
    app.toggleCropEditing();
    await tester.pump();
    final done = find.byKey(const ValueKey('stage-crop-done'));
    expect(done, findsOneWidget);
    final r = tester.getRect(done);
    expect(r.right, greaterThan(300), reason: 'bottom right');
    expect(r.bottom, greaterThan(300));
    await tester.tap(done);
    await tester.pump();
    expect(cropEditing, isFalse);
  });

  testWidgets('follows it: its place or one of its size handles; the whole size in the lists', (tester) async {
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('rect');
    final a = app.project.layers[0], b = app.project.layers[1];
    b.links.add(PropLink(sourceId: a.id, from: 'x', to: 'x'));
    app.selectLayer(b.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LinksView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-head-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-to-0')));
    await tester.pumpAndSettle();
    expect(find.text('my whole size (both scales)'), findsWidgets);
    await tester.tap(find.text('my whole size (both scales)').last);
    await tester.pumpAndSettle();
    expect(b.links.single.to, 'scale');
    await tester.tap(find.byKey(const ValueKey('link-mode-0-follow')));
    await tester.pumpAndSettle();
    expect(b.links.single.from, 'position');
    await tester.tap(find.byKey(const ValueKey('link-follow-from-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('its right size handle').last);
    await tester.pumpAndSettle();
    final k = b.links.single;
    expect([k.mode, k.from, k.to], ['follow', 'scaleRight', 'scale']);
    expect(k.base, isNotNull);
  });
}
