import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';

void main() {
  setUp(() {
    setStageSize(200, 100);
    registerBuiltinEffects();
  });

  test('a vignette darkens the edges, not the middle', () async {
    final l = createLayer('rect')
      ..id = 'r'
      ..color = '#ffffff'
      ..content.size = [200, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    l.filters.vignette = Track(1.0, false);
    l.filters.vignetteSize = 0.2;
    l.filters.vignetteSoft = 0.6;
    final r = CanvasRenderer()..setSize(200, 100);
    r.backgroundColor = null;
    clearStateCaches();
    r.renderFrame(Project(layers: [l]), 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int red(int x, int y) => b.getUint8((y * 200 + x) * 4);
    expect(red(100, 50), greaterThan(240));
    expect(red(2, 2), lessThan(120));
    expect(b.getUint8((2 * 200 + 2) * 4 + 3), 255, reason: 'darker, not see-through');
  });

  test('a new fold through two points (the first one stays as it was)', () {
    final app = AppState()..setFrameSize(200, 100);
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    final inst = createEffectInstance('origami_fold', 'o', l);
    (inst.params['angle'] as Track).defaultValue = 60.0;
    l.effectStack.add(inst);
    final before = (inst.params['direction'] as Track).defaultValue;
    app.startOrigamiPick('o', 1);
    final m = toFrameMatrix(getLayerStateAt(app.project, l.id, app.currentFrame).matrix);
    final a = applyAffine(m, [0, -10]), c = applyAffine(m, [0, 10]);
    app.origamiPickTap(a, 0.001);
    app.origamiPickTap(c, 0.001);
    expect(origamiFolds(inst.params), hasLength(2));
    expect((inst.params['direction'] as Track).defaultValue, before);
    expect(app.origamiSelectedFold['o'], 2);
  });

  test('the centre to a corner of its box; the object stays put', () {
    final app = AppState()..setFrameSize(200, 100);
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    clearStateCaches();
    final b0 = computeLayerFrameGeometry(app.project, l, app.currentFrame, includeVertices: false).bbox;
    app.setPivotToBox(0, 0);
    clearStateCaches();
    final b1 = computeLayerFrameGeometry(app.project, l, app.currentFrame, includeVertices: false).bbox;
    expect(b1.minX, closeTo(b0.minX, 1e-6));
    expect(b1.maxY, closeTo(b0.maxY, 1e-6));
    expect(l.content.offset[0], isNot(0), reason: 'the content moved the other way');
    app.performUndo();
    expect(findLayer(app.project, l.id)!.content.offset, [0, 0]);
  });

  testWidgets('Keyframes tab: loop all its parameters, on from where it ended', (tester) async {
    final app = AppState()..setFrameSize(200, 100);
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    l.transform.scale.keyframes = [
      Keyframe(frame: 0, value: [1.0, 1.0]),
      Keyframe(frame: 10, value: [0.5, 0.5]),
    ];
    l.transform.rotation.keyframes = [
      Keyframe(frame: 0, value: 0.0),
      Keyframe(frame: 10, value: 90.0),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('loop-all')));
    await tester.pumpAndSettle();
    expect(l.transform.scale.loop && l.transform.rotation.loop, isTrue);
    await tester.tap(find.byKey(const ValueKey('loop-offset')));
    await tester.pumpAndSettle();
    expect(l.transform.scale.loopMode, 'offset');
    expect(l.transform.scale.loopMin, 0);
    expect(layerLoopStops(l), [l.startFrame + 20]);
    expect(find.textContaining('stops at frame'), findsOneWidget);
  });
}
