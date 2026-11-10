import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Future<int Function(int, int)> render(Project p, {int w = 200, int h = 100, CanvasRenderer? with_}) async {
  final r = (with_ ?? CanvasRenderer())..setSize(w.toDouble(), h.toDouble());
  r.backgroundColor = null;
  clearStateCaches();
  r.renderFrame(p, 0);
  final img = await r.captureFrame();
  final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return (int x, int y) => [for (var c = 0; c < 4; c++) b.getUint8((y * w + x) * 4 + c)].fold<int>(0, (a, v) => a * 256 + v);
}

Layer rect(String id, String color, double x, double y, double s) => createLayer('rect')
  ..id = id
  ..color = color
  ..content.size = [s, s]
  ..transform.anchor.defaultValue = [x / 200, y / 100];

void main() {
  setUp(() {
    setStageSize(200, 100);
    registerBuiltinEffects();
  });

  test('glass: what is under its shape is filtered, the glass itself is not drawn', () async {
    final bg = rect('bg', '#ff0000', 100, 50, 200);
    final g = rect('g', '#00ff00', 50, 50, 40)
      ..filters.scope = 'glass'
      ..filters.negative = Track(1.0, false);
    final at = await render(Project(layers: [bg, g]));
    expect(at(50, 50), 0x00ffffff, reason: 'red under the glass, inverted');
    expect(at(150, 50), 0xff0000ff, reason: 'outside the glass: as it was');
  });

  test('a negative glass over a negative glass cancels out', () async {
    final bg = rect('bg', '#ff0000', 100, 50, 200);
    Layer glass(String id, double x) => rect(id, '#00ff00', x, 50, 40)
      ..filters.scope = 'glass'
      ..filters.negative = Track(1.0, false);
    final at = await render(Project(layers: [bg, glass('g1', 60), glass('g2', 80)]));
    expect(at(50, 50), 0x00ffffff, reason: 'only the first glass');
    expect(at(70, 50), 0xff0000ff, reason: 'both: back to red');
    expect(at(95, 50), 0x00ffffff, reason: 'only the second glass');
  });

  test('scene: every layer goes through the filter', () async {
    final a = rect('a', '#ff0000', 50, 50, 40);
    final b = rect('b', '#0000ff', 150, 50, 40)
      ..filters.scope = 'scene'
      ..filters.negative = Track(1.0, false);
    final at = await render(Project(layers: [a, b]));
    expect(at(50, 50), 0x00ffffff);
    expect(at(150, 50), 0xffff00ff);
  });

  test('gain darkens, lift raises the shadows', () async {
    final l = rect('a', '#ffffff', 50, 50, 40)..filters.gain = [-0.5, -0.5, -0.5];
    final at = await render(Project(layers: [l]));
    expect((at(50, 50) >> 24) & 0xff, inInclusiveRange(125, 130));
    final d = rect('d', '#000000', 50, 50, 40)..filters.lift = [0.2, 0, 0];
    final at2 = await render(Project(layers: [d]));
    expect((at2(50, 50) >> 24) & 0xff, inInclusiveRange(49, 53));
    expect((at2(50, 50) >> 16) & 0xff, 0);
  });

  test('Match Color: the wheels map the layer\'s statistics onto the target\'s', () {
    final f = LayerFilters();
    matchColorInto(f, [0.2, 0.2, 0.2], [0.1, 0.1, 0.1], [0.6, 0.5, 0.4], [0.2, 0.1, 0.05]);
    final lin = liftGainLinear(f);
    for (var i = 0; i < 3; i++) {
      expect(lin.a[i] * 0.2 + lin.b[i], closeTo([0.6, 0.5, 0.4][i], 1e-9));
    }
    expect(lin.a[0], closeTo(2, 1e-9));
  });

  test('colour wheel <-> per-channel offsets', () {
    final rgb = wheelToRgb(0.3, -0.2, 0.1);
    final back = rgbToWheel(rgb);
    expect(back[0], closeTo(0.3, 1e-9));
    expect(back[1], closeTo(-0.2, 1e-9));
    expect(back[2], closeTo(0.1, 1e-9));
  });

  test('filters round-trip through the project file', () {
    final l = rect('a', '#ffffff', 50, 50, 40)
      ..filters.scope = 'glass'
      ..filters.blur = Track(5.0, false)
      ..filters.blurKind = 'zoom'
      ..filters.gamma = [0.1, 0, -0.2]
      ..filters.lightWrap = 0.5;
    final back = layerFromJson(layerToJson(l)).filters;
    expect(back.scope, 'glass');
    expect(back.blur.defaultValue, 5.0);
    expect(back.blurKind, 'zoom');
    expect(back.gamma, [0.1, 0, -0.2]);
    expect(back.lightWrap, 0.5);
  });

  test('edge blur fades the edge, the middle stays solid', () async {
    final l = rect('a', '#ffffff', 100, 50, 80);
    l.effectStack.add(createEffectInstance('edge_blur', 'eb', l)..params['radius'] = Track(16.0, false));
    final at = await render(Project(layers: [l]));
    expect(at(100, 50) & 0xff, greaterThan(240));
    expect(at(61, 50) & 0xff, lessThan(200));
  });

  test('the filters shader loads (warp, gamma)', () async {
    final p = await ui.FragmentProgram.fromAsset('shaders/filter.frag');
    expect(p.fragmentShader(), isNotNull);
  });

  test('fractal warp and gamma draw through the shader once it is loaded', () async {
    final l = rect('a', '#808080', 100, 50, 60)..filters.gamma = [1, 1, 1];
    final r = CanvasRenderer();
    await render(Project(layers: [l]), with_: r); // starts loading it
    await ui.FragmentProgram.fromAsset('shaders/filter.frag');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final at = await render(Project(layers: [l]), with_: r);
    // gamma 2^-1 = 0.5: 0.5^0.5 ~ 0.71 - brighter midtones.
    expect((at(100, 50) >> 24) & 0xff, greaterThan(160));
    l.filters
      ..gamma = [0, 0, 0]
      ..warp = Track(20.0, false);
    final w = await render(Project(layers: [l]), with_: r);
    expect(w(100, 50) & 0xff, 255, reason: 'the middle is still covered');
  });

  test('dig: a hole through every layer under it, down to the background', () async {
    final r = CanvasRenderer()..setSize(200, 100);
    final bg = rect('bg', '#ff0000', 100, 50, 200);
    final mid = rect('mid', '#00ff00', 50, 50, 60);
    final hole = rect('h', '#0000ff', 50, 50, 20)..dig = true;
    final top = rect('top', '#ffffff', 150, 50, 20);
    clearStateCaches();
    r.backgroundColor = const ui.Color(0xFF000000);
    r.renderFrame(Project(layers: [bg, mid, hole, top]), 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int at(int x, int y) => [for (var c = 0; c < 4; c++) b.getUint8((y * 200 + x) * 4 + c)].fold<int>(0, (a, v) => a * 256 + v);
    expect(at(50, 50), 0x000000ff, reason: 'the background shows through');
    expect(at(30, 50), 0x00ff00ff, reason: 'around the hole: as it was');
    expect(at(150, 50), 0xffffffff, reason: 'layers above it are not cut');
  });

  test('turned over: the back layer shows within it, and is not drawn on its own', () async {
    final front = rect('f', '#ff0000', 100, 50, 60)..showBack = true;
    final back = rect('b', '#0000ff', 85, 50, 20);
    front.backSourceId = 'b';
    final at = await render(Project(layers: [back, front]));
    // placed at x 85 on the turned layer: seen there.
    expect(at(85, 50), 0x0000ffff);
    expect(at(115, 50), 0xff0000ff, reason: 'the rest of the paper');
    expect(at(100, 10), 0, reason: 'nothing outside');
    front.showBack = false;
    final at2 = await render(Project(layers: [back, front]));
    expect(at2(85, 50), 0xff0000ff, reason: 'front side up: the back is hidden, and never drawn on its own');
  });

  test('backSame: turned over, a merged shape reads the right way round', () async {
    // two halves: red left, green right (a compound with colours).
    final l = createLayer('rect')
      ..id = 'm'
      ..content = Content(shape: 'compound', offset: [0, 0], size: [40, 20], contours: [
        [[-20, -10], [0, -10], [0, 10], [-20, 10]],
        [[0, -10], [20, -10], [20, 10], [0, 10]],
      ])
      ..transform.anchor.defaultValue = [0.5, 0.5];
    l.content.contourColors = ['#ff0000', '#00ff00'];
    final at = await render(Project(layers: [l]));
    expect(at(90, 50), 0xff0000ff);
    l.showBack = true;
    final mirrored = await render(Project(layers: [l]));
    expect(mirrored(90, 50), 0x00ff00ff, reason: 'seen from behind: mirrored');
    l.backSame = true;
    final same = await render(Project(layers: [l]));
    expect(same(90, 50), 0xff0000ff, reason: 'the back prints the front the right way round');
  });
}
