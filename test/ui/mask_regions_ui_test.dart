import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/masks/masks_view.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';
import 'package:movement_mobile/ui/timeline/layer_detail_rows.dart';

/// A: a 40 px square in the middle of a 200x150 frame; B: a 16 px circle
/// crossing it from frame 0 to 40; T: masked by regions of A and B.
({Project p, Layer t}) scene({bool numbered = true}) {
  setStageSize(200, 150);
  clearStateCaches();
  clearRegionBakes();
  final a = createLayer('rect')
    ..id = 'a'
    ..name = 'Square'
    ..durationFrames = 60
    ..content.size = [40, 40]
    ..transform.anchor.defaultValue = [0.5, 0.5];
  final b = createLayer('circle')
    ..id = 'b'
    ..name = 'Circle'
    ..durationFrames = 60
    ..content.size = [16, 16];
  b.transform.anchor.keyframes = [
    Keyframe(frame: 0, value: [0.25, 0.5]),
    Keyframe(frame: 40, value: [0.75, 0.5]),
  ];
  // content masked by the two shapes (a picture: it stays that way).
  final t = createLayer('image')
    ..id = 't'
    ..durationFrames = 60
    ..content.size = [180, 130]
    ..transform.anchor.defaultValue = [0.5, 0.5]
    ..maskRegions = MaskRegions(sources: ['a', 'b'], numbered: numbered, opacity: {3: track(1.0)});
  return (p: Project(layers: [a, b, t]), t: t);
}

void main() {
  testWidgets('Number regions: on with its notice; a picture source has no such switch', (tester) async {
    final app = AppState();
    final s = scene(numbered: false);
    app.project.layers
      ..clear()
      ..addAll(s.p.layers);
    app.selection.selectedLayer = 't';
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MasksView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('region-numbered')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('region-numbered')));
    await tester.pumpAndSettle();
    expect(s.t.maskRegions!.numbered, isTrue);
    expect(find.textContaining('not in the list in advance'), findsOneWidget);
    // the numbered piece shows under A·B.
    expect(find.byKey(const ValueKey('region-3-n1')), findsOneWidget);
    // a command.
    await tester.tap(find.byKey(const ValueKey('region-command-add')));
    await tester.pumpAndSettle();
    expect(s.t.maskRegions!.commands, hasLength(1));
    expect(find.byKey(const ValueKey('region-command-0')), findsOneWidget);
    // a picture as source: no numbering.
    final img = createLayer('image')..id = 'img';
    app.project.layers.insert(0, img);
    s.t.maskRegions!.sources[1] = 'img';
    clearStateCaches();
    app.commitEdit();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('region-numbered')), findsNothing);
  });

  testWidgets('the timeline shows each episode as a bar named after its region', (tester) async {
    final app = AppState();
    final s = scene();
    app.project.layers
      ..clear()
      ..addAll(s.p.layers);
    // baked (in the app a step at a time, see AppState).
    final eps = regionEpisodes(app.project, s.t).episodes.where((e) => e.sig == 3).toList();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 800,
                height: 60,
                child: RegionEpisodeRows(app: app, layer: s.t, pixelsPerFrame: 10)))));
    expect(eps, hasLength(1));
    final bar = find.byKey(ValueKey('region-episode-${eps.single.key()}'));
    expect(bar, findsOneWidget);
    await tester.tap(bar);
    await tester.pump();
    expect(app.selectedRegionSig, 3);
    expect(app.selectedRegionNumber, 1);
    expect(app.currentFrame, eps.single.peakFrame, reason: 'jumps to its largest frame');
  });

  test('the orange footprint is dashed while the piece runs, solid after', () async {
    final s = scene();
    final bake = regionEpisodes(s.p, s.t);
    final ep = bake.episodes.firstWhere((e) => e.sig == 3);
    final fp = bake.footprints.single;
    showFootprints = true;
    addTearDown(() => showFootprints = false);
    Future<ByteData> render(int frame) async {
      clearStateCaches();
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, 200, 150));
      paintStage(
        canvas: canvas,
        size: const ui.Size(200, 150),
        contentPicture: null,
        frameWidth: 200,
        frameHeight: 150,
        project: s.p,
        selectedLayer: s.t,
        globalFrame: frame,
        camera: StageCamera(),
        activeDrag: null,
      );
      final img = await rec.endRecording().toImage(200, 150);
      return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }

    // the share of points along the footprint that are orange.
    Future<double> orange(int frame) async {
      final b = await render(frame);
      final m = toFrameMatrix(getLayerStateAt(s.p, 'a', frame).matrix);
      final ring = fp.local.first;
      var hit = 0, n = 0;
      for (var i = 0; i < ring.length; i++) {
        final q = applyAffine(m, ring[i]), r = applyAffine(m, ring[(i + 1) % ring.length]);
        for (var t = 0.0; t < 1; t += 0.25) {
          final x = (q[0] + (r[0] - q[0]) * t).round(), y = (q[1] + (r[1] - q[1]) * t).round();
          if (x < 0 || y < 0 || x >= 200 || y >= 150) continue;
          final o = (y * 200 + x) * 4;
          n++;
          if (b.getUint8(o) > 200 && b.getUint8(o + 1) > 100 && b.getUint8(o + 1) < 190 && b.getUint8(o + 2) < 80) hit++;
        }
      }
      return n == 0 ? 0 : hit / n;
    }

    final during = await orange(ep.peakFrame);
    final after = await orange(ep.end! + 5);
    expect(after, greaterThan(0.75), reason: 'solid ($after; dashed $during)');
    expect(during, lessThan(after - 0.15), reason: 'dashed: gaps along it');
  });

  test('the areas\' rows show under the layer by themselves, one per area that comes and goes', () {
    final app = AppState();
    final s = scene(numbered: false);
    app.project.layers
      ..clear()
      ..addAll(s.p.layers);
    regionEpisodes(app.project, s.t);
    expect(app.showMaskRows, isFalse);
    final rows = regionEpisodeRows(app.project, s.t);
    expect(maskRowCount(app, s.t), rows.length);
    expect(rows.first.first.sig, 3, reason: 'Square + Circle first');
    expect(regionName(app.project, s.t.maskRegions!, rows.first.first.sig), 'Square + Circle');
    // each shape outside the overlap is an area too.
    final sigs = {for (final r in rows) for (final e in r) e.sig};
    expect(sigs, containsAll([3, 1, 2]));
    expect(regionName(app.project, s.t.maskRegions!, 1), 'Square − Circle');
  });

  testWidgets('a reaction reads "When Rect 1 + Rect 2 Appears / Make Rect 1 + Rect 2 Disappear" and works', (tester) async {
    final app = AppState();
    final s = scene();
    s.p.layers[0].name = 'Rect 1';
    s.p.layers[1].name = 'Rect 2';
    app.project.layers
      ..clear()
      ..addAll(s.p.layers);
    app.selection.selectedLayer = 't';
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MasksView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('region-command-add')));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('region-command-0'));
    expect(find.descendant(of: card, matching: find.text('When')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Make')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Rect 1 + Rect 2')), findsNWidgets(2));
    expect(find.descendant(of: card, matching: find.text('Appears')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Disappear')), findsOneWidget);
    final c = s.t.maskRegions!.commands.single;
    expect(c.timed, isFalse, reason: 'at once by default');
    // it works: when the overlap appears, it fades out.
    final bake = regionEpisodes(app.project, s.t);
    final e = bake.episodes.firstWhere((x) => x.sig == 3).start;
    expect(regionOpacityAt(app.project, s.t, bake, 3, null, e - 1), 1.0);
    expect(regionOpacityAt(app.project, s.t, bake, 3, null, e + c.frames), 0.0);
    // the piece field stays after "Any piece".
    expect(find.byKey(const ValueKey('rc-when-n-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rc-when-n-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any piece').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rc-when-n-0')), findsOneWidget);
    // an area picked on the stage fills the field.
    await tester.tap(find.byKey(const ValueKey('rc-target-sig-0-pick')));
    await tester.pumpAndSettle();
    expect(app.regionPickKey, 'rc-target-sig-0');
    app.regionPick!(1, null);
    await tester.pumpAndSettle();
    expect(c.targetSig, 1);
  });

  test('undo brings the picked keys back', () {
    final app = AppState();
    final l = app.project.layers.last;
    l.transform.rotation.keyframes = [Keyframe(frame: 10, value: 0.0)];
    app.selection.selectedLayer = l.id;
    kfSelectedFrames = {l.startFrame + 10};
    app.pushUndo();
    l.transform.rotation.keyframes.first.frame = 20; // a move
    kfSelectedFrames = {l.startFrame + 20};
    app.commitEdit();
    app.performUndo();
    expect(kfSelectedFrames, {l.startFrame + 10});
  });

  testWidgets('Rect 2 with regions over Rect 1 (made before): its three areas are listed, a reaction can use them, '
      'and with the panel open a tap on the stage picks them', (tester) async {
    final app = AppState();
    setStageSize(400, 400);
    clearStateCaches();
    clearRegionBakes();
    Layer sq(String id, String name, double x) => createLayer('rect')
      ..id = id
      ..name = name
      ..content.size = [160, 160]
      ..transform.anchor.defaultValue = [x, 0.5];
    final r1 = sq('r1', 'Rect 1', 0.4);
    final r2 = sq('r2', 'Rect 2', 0.6)..maskRegions = MaskRegions(sources: ['r1'], opacity: {0: track(1.0), 1: track(1.0)});
    app.project.layers
      ..clear()
      ..addAll([r1, r2]);
    app.selection.selectedLayer = 'r2';
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MasksView(app: app))));
    await tester.pumpAndSettle();
    expect(r2.maskRegions!.sources, ['r1', 'r2']);
    expect(find.text('Rect 1 + Rect 2 · Rect 2'), findsOneWidget);
    expect(find.text('Rect 2 − Rect 1'), findsOneWidget);
    expect(find.text('Outer'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('region-command-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rc-target-sig-0')));
    await tester.pumpAndSettle();
    expect(find.text('Rect 2 − Rect 1').hitTestable(), findsWidgets, reason: 'in the Make list');
    await tester.tap(find.text('Rect 2 − Rect 1').last);
    await tester.pumpAndSettle();
    expect(r2.maskRegions!.commands.single.targetSig, 2);
    // the stage: the panel is open, so a tap picks an area (no switch on).
    final c = StageGestureController(app: app, camera: StageCamera(), onNeedsRepaint: () {});
    c.onPointerDown(const PointerDownEvent(pointer: 1, position: Offset(300, 200)));
    c.onPointerUp(const PointerUpEvent(pointer: 1, position: Offset(300, 200)));
    expect(app.selectedRegionSig, 2, reason: 'Rect 2 − Rect 1');
  });
}
