import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Effect layers: filters and motion blur taken off a layer onto a layer
/// of their own, acting on the layers under it.
void main() {
  const w = 200.0, h = 150.0;
  setUp(() {
    setStageSize(w, h);
    registerBuiltinEffects();
  });

  Future<List<int> Function(int, int)> render(Project p, int frame) async {
    final r = CanvasRenderer()..setSize(w, h);
    r.backgroundColor = null;
    clearStateCaches();
    r.renderFrame(p, frame);
    final b = (await (await r.captureFrame()).toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return (x, y) => [for (var c = 0; c < 4; c++) b.getUint8((y * w.round() + x) * 4 + c)];
  }

  Layer mover(String id, double y) => createLayer('rect')
    ..id = id
    ..color = '#ffffff'
    ..content = Content(shape: 'rect', offset: [0, 0], size: [10, 10])
    ..transform.anchor.spatial = true
    ..transform.anchor.keyframes.addAll([
      Keyframe(frame: 9, value: [0.2, y]),
      Keyframe(frame: 11, value: [0.8, y]),
    ]);

  Layer effect({required bool blur}) => createLayer('rect')
    ..id = 'fx'
    ..adjustment = true
    ..transform.anchor.defaultValue = [0.5, 0.5]
    ..content = Content(shape: 'rect', offset: [0, 0], size: [w, h])
    ..motionBlur = MotionBlur(enabled: blur, shutterAngle: 720, samples: 2);

  test('motion blur on its own layer blurs the layers under it, not those above', () async {
    final under = mover('under', 0.25), over = mover('over', 0.75);
    final at = await render(Project(layers: [under, effect(blur: true), over]), 10);
    // under: two half-strength copies at the shutter's ends, none in the middle.
    expect(at(40, 37)[3], inInclusiveRange(100, 155));
    expect(at(160, 37)[3], inInclusiveRange(100, 155));
    expect(at(100, 37)[3], 0);
    // over: sharp, where it is at frame 10.
    expect(at(100, 112)[3], 255);
    expect(at(40, 112)[3], 0);
    // the effect layer is not drawn itself.
    expect(at(10, 10)[3], 0);
  });

  test('an effect layer outside its time blurs nothing', () async {
    final under = mover('under', 0.25);
    final fx = effect(blur: true)
      ..startFrame = 20
      ..durationFrames = 10;
    final at = await render(Project(layers: [under, fx]), 10);
    expect(at(100, 37)[3], 255);
  });

  test('detached filters act on the layers under; the layer loses them; one undo', () async {
    final app = AppState();
    app.setFrameSize(w, h);
    app.project.layers.clear();
    final bg = createLayer('rect')
      ..id = 'bg'
      ..color = '#ff0000'
      ..transform.anchor.defaultValue = [0.5, 0.5]
      ..content = Content(shape: 'rect', offset: [0, 0], size: [w, h]);
    final top = createLayer('rect')
      ..id = 'top'
      ..name = 'top'
      ..color = '#0000ff'
      ..transform.anchor.defaultValue = [0.5, 0.5]
      ..content = Content(shape: 'rect', offset: [0, 0], size: [20, 20]);
    top.filters.negative = Track(1.0, false);
    app.project.layers.addAll([bg, top]);
    final fx = app.detachToEffectLayer('top', 'filters')!;
    expect(app.project.layers.map((l) => l.id), ['bg', 'top', fx.id]);
    expect([fx.adjustment, fx.filters.scope, top.filters.any], [true, 'glass', false]);
    expect(app.selection.selectedLayer, fx.id);
    final at = await render(app.project, 0);
    expect(at(10, 10).sublist(0, 3), [0, 255, 255], reason: 'red under it, inverted');
    expect(at(100, 75).sublist(0, 3), [255, 255, 0], reason: 'blue under it too');
    expect(layerFromJson(layerToJson(fx)).adjustment, isTrue);
    app.performUndo();
    expect(app.project.layers.length, 2);
    expect(findLayer(app.project, 'top')!.filters.any, isTrue);
  });

  test('edge fade: solid in the middle, fading toward its own edge', () async {
    final l = createLayer('rect')
      ..id = 'c'
      ..color = '#ffffff'
      ..transform.anchor.defaultValue = [0.5, 0.5]
      ..content = Content(shape: 'rect', offset: [0, 0], size: [120, 120]);
    l.filters.edgeFade = Track(40.0, false);
    final at = await render(Project(layers: [l]), 0);
    expect(at(100, 75)[3], 255, reason: 'the middle stays');
    final near = at(42, 75)[3], mid = at(60, 75)[3];
    expect(near, lessThan(60), reason: 'at the edge: almost gone');
    expect(mid, greaterThan(near));
    expect(mid, lessThan(255));
    expect(LayerFilters.fromJson(l.filters.toJson()).edgeFade.defaultValue, 40.0);
  });

  test('a card of its own: the whole frame, fill colour, edges fading', () {
    final app = AppState();
    app.setFrameSize(w, h);
    app.project.layers.clear();
    final c = app.addCard();
    expect([c.content.size, c.color, app.selection.selectedLayer], [
      [w, h],
      app.fillColor,
      c.id
    ]);
    expect((c.filters.edgeFade.defaultValue as num) > 0, isTrue);
  });

  test('detached motion blur: the layer stops blurring, the new layer does', () {
    final app = AppState();
    app.project.layers.clear();
    final l = mover('m', 0.5)..motionBlur = MotionBlur(enabled: true, samples: 6);
    app.project.layers.add(l);
    final fx = app.detachToEffectLayer('m', 'motionBlur')!;
    expect([l.motionBlur.enabled, fx.motionBlur.enabled, fx.motionBlur.samples], [false, true, 6]);
    expect(blurringEffectLayer(app.project, l, 10), fx);
  });
}
