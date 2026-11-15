import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/links/links_view.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';

void main() {
  testWidgets('after undoing a merge the layers on the timeline can be picked again', (tester) async {
    fps = 60;
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('circle');
    final ids = [for (final l in app.project.layers) l.id];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 600, height: 300, child: LayersTimelineView(app: app)))));
    await tester.pumpAndSettle();
    Finder areas() => find.byWidgetPredicate((w) => w is GestureDetector && w.onLongPressStart != null);
    await tester.tap(areas().first); // focus the first
    await tester.pump();
    // pick the other to go with it, then merge them.
    app.toggleTimelineGroupPick();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('group-pick-${ids[1]}')));
    await tester.pumpAndSettle();
    expect(app.selectedGroup, ids.toSet());
    expect(app.mergeLayersById(ids), isTrue);
    await tester.pumpAndSettle();
    app.performUndo();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(app.timelineGroupPick, isFalse, reason: 'picking ended with its layer');
    app.selectLayer(null);
    await tester.pumpAndSettle();
    final n = areas().evaluate().length;
    await tester.tap(areas().at(n - 1));
    await tester.pumpAndSettle();
    expect(ids, contains(app.selection.selectedLayer));
    expect(app.multiSelection, isEmpty, reason: 'a tap picks the layer, not a group');
  });

  test('after undoing a merge the layers can be picked on the stage', () {
    final app = AppState();
    app.project.layers.clear();
    Layer make(String id, double x) => createLayer('rect')
      ..id = id
      ..name = id
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [x, 0.5];
    app.project.layers.addAll([make('a', 0.25), make('b', 0.75)]);
    app.selectLayer(null);
    final camera = StageCamera();
    final c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    var p = 0;
    void tapAt(double fx) {
      final at = camera.frameToScreen(Offset(app.frameWidth * fx, app.frameHeight / 2));
      p++;
      c.onPointerDown(PointerDownEvent(pointer: p, position: at));
      c.onPointerUp(PointerUpEvent(pointer: p, position: at));
    }

    tapAt(0.25);
    expect(app.selection.selectedLayer, 'a');
    expect(app.mergeLayersById(['a', 'b']), isTrue);
    app.performUndo();
    app.selectLayer(null);
    tapAt(0.75);
    expect(app.selection.selectedLayer, 'b');
    tapAt(0.25);
    expect(app.selection.selectedLayer, 'a');
  });

  group('magnifier', () {
    Future<int Function(int, int)> render(Project p, CanvasRenderer r) async {
      r
        ..setSize(200, 100)
        ..backgroundColor = null;
      clearStateCaches();
      r.renderFrame(p, 0);
      final img = await r.captureFrame();
      final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return (int x, int y) => [for (var c = 0; c < 4; c++) b.getUint8((y * 200 + x) * 4 + c)].fold<int>(0, (a, v) => a * 256 + v);
    }

    Layer rect(String id, String color, double x, double y, double w, double h) => createLayer('rect')
      ..id = id
      ..color = color
      ..content.size = [w, h]
      ..transform.anchor.defaultValue = [x / 200, y / 100];

    setUp(() {
      setStageSize(200, 100);
      registerBuiltinEffects();
    });

    Future<int Function(int, int)> through(Layer glass, List<Layer> under) async {
      final r = CanvasRenderer();
      final p = Project(layers: [...under, glass]);
      await render(p, r); // starts loading the shader
      await ui.FragmentProgram.fromAsset('shaders/lens.frag');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return render(p, r);
    }

    test('a magnifier of its own shape (a wide rect) enlarges what is under it, only inside the shape', () async {
      final bar = rect('d', '#ff0000', 100, 50, 10, 4); // 95..105 x 48..52
      final glass = rect('g', '#00ff00', 100, 50, 160, 30)
        ..lens.enabled = true
        ..lens.shaped = true
        ..lens.zoom = 3
        ..lens.softness = 0;
      final at = await through(glass, [bar]);
      expect(at(112, 50), 0xff0000ff, reason: 'enlarged 3x: the red reaches 15 px out');
      expect(at(100, 54), 0xff0000ff, reason: 'and up and down too');
      // a circle in its box would end 15 px from the middle; the shape goes on.
      expect(at(170, 50), 0, reason: 'inside the shape, past the enlarged red: empty');
      expect(at(100, 70), 0, reason: 'outside the shape nothing is drawn');
      expect(at(100, 40) & 0x00ff0000, 0, reason: 'the glass itself is not drawn');
    });

    test('below 1 it shrinks; with a wide angle it bends like a fish eye', () async {
      final bar = rect('d', '#ff0000', 100, 50, 40, 40); // 80..120
      final glass = rect('g', '#00ff00', 100, 50, 100, 60)
        ..lens.enabled = true
        ..lens.shaped = true
        ..lens.zoom = 0.5
        ..lens.softness = 0;
      var at = await through(glass, [bar]);
      expect(at(100, 50), 0xff0000ff);
      expect(at(115, 50), 0, reason: 'shrunk to half: 10 px out only');
      glass.lens
        ..zoom = 1
        ..fov = Track(150.0, false);
      at = await through(glass, [bar]);
      expect(at(100, 50), 0xff0000ff);
      expect(at(115, 50), 0, reason: 'a fish eye squeezes it toward the middle');
    });

    test('over a round lens it enlarges what that lens shows (they add up)', () async {
      final bar = rect('d', '#ff0000', 100, 50, 2, 2); // 99..101
      final round = rect('l', '#0000ff', 100, 50, 80, 80)
        ..lens.enabled = true
        ..lens.fov = Track(10.0, false) // ~5x
        ..lens.softness = 0;
      final glass = rect('g', '#00ff00', 100, 50, 60, 30)
        ..lens.enabled = true
        ..lens.shaped = true
        ..lens.zoom = 2
        ..lens.softness = 0;
      final r = CanvasRenderer();
      final p = Project(layers: [bar, round, glass]);
      await render(p, r);
      await ui.FragmentProgram.fromAsset('shaders/lens.frag');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      var at = await render(p, r);
      expect(at(108, 50), 0xff0000ff, reason: 'about 10x: the 1 px half-width reaches ~10 px');
      glass.hidden = true;
      at = await render(p, r);
      expect(at(108, 50), 0, reason: 'the round lens alone: ~5 px only');
      expect(at(103, 50), 0xff0000ff);
    });

    test('saved with the project', () {
      final l = createLayer('triangle')
        ..lens.enabled = true
        ..lens.shaped = true;
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
      expect(back.lens.shaped, isTrue);
      expect(cloneLayer(l).lens.shaped, isTrue);
    });
  });

  testWidgets('links: the follow kind and the time it works in', (tester) async {
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('rect');
    final a = app.project.layers[0], b = app.project.layers[1];
    b.links.add(PropLink(sourceId: a.id, from: 'rotation', to: 'rotation'));
    app.selectLayer(b.id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LinksView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-mode-0-follow')));
    await tester.pumpAndSettle();
    final k = b.links.single;
    expect(k.mode, 'follow');
    expect(k.to, 'y', reason: 'rotation is not something it can follow: a position axis instead');
    expect([k.base, k.baseY], everyElement(isNotNull));
    app.currentFrame = 12;
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('link-0-from-now')));
    await tester.tap(find.byKey(const ValueKey('link-0-from-now')));
    await tester.pumpAndSettle();
    expect(k.fromFrame, 12);
    await tester.tap(find.byKey(const ValueKey('link-0-from-clear')));
    await tester.pumpAndSettle();
    expect(k.fromFrame, isNull);
  });
}
