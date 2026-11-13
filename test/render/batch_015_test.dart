import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Future<int Function(int, int)> render(Project p, {int w = 200, int h = 100, CanvasRenderer? with_, int frame = 0}) async {
  final r = (with_ ?? CanvasRenderer())..setSize(w.toDouble(), h.toDouble());
  r.backgroundColor = null;
  clearStateCaches();
  r.renderFrame(p, frame);
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

  test('a trail point draws its line where it has been, not after the playhead', () async {
    final t = createTrailLayer(width: 6, color: '#ff0000')
      ..id = 't'
      ..startFrame = 0
      ..durationFrames = 60;
    t.transform.anchor.keyframes
      ..add(Keyframe(frame: 0, value: [0.1, 0.5], temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 40, value: [0.9, 0.5], temporal: const Easing(0, 0, 1, 1)));
    final at = await render(Project(layers: [t]), frame: 20);
    expect(at(60, 50), 0xff0000ff);
    expect(at(150, 50), 0, reason: 'not there yet');
    expect(at(60, 70), 0);
  });

  test('a lens: a telephoto magnifies what is under it; outside its circle nothing changes', () async {
    // a small red square under the middle of a big lens.
    final dot = rect('d', '#ff0000', 100, 50, 10);
    final lens = rect('l', '#00ff00', 100, 50, 80)
      ..lens.enabled = true
      ..lens.fov = Track(10.0, false)
      ..lens.softness = 0;
    final r = CanvasRenderer();
    final p = Project(layers: [dot, lens]);
    await render(p, with_: r); // starts loading the shader
    await ui.FragmentProgram.fromAsset('shaders/lens.frag');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final at = await render(p, with_: r);
    // 5 px from the middle is red at 1x; magnified ~5x it reaches 20 px out.
    expect(at(118, 50), 0xff0000ff, reason: 'magnified');
    expect(at(100, 50), 0xff0000ff);
    expect(at(150, 50), 0, reason: 'outside the lens');
    // the lens itself (green) is never drawn.
    expect(at(100, 20) & 0x00ff0000, 0);
  });

  test('light wrap / glass over many layers still draw the same (layers below replayed, not redrawn)', () async {
    final bg = rect('bg', '#ff0000', 100, 50, 200);
    final g = rect('g', '#00ff00', 50, 50, 40)
      ..filters.scope = 'glass'
      ..filters.negative = Track(1.0, false);
    final top = rect('top', '#ffffff', 150, 50, 20)..filters.lightWrap = 0.5;
    final at = await render(Project(layers: [bg, g, top]));
    expect(at(50, 50), 0x00ffffff);
    expect(at(10, 50), 0xff0000ff);
    expect(at(150, 50) >> 8, 0xffffff);
  });

  test('edge glow: light past the edge of the shape', () async {
    final l = rect('a', '#000000', 100, 50, 40);
    l.effectStack.add(createEffectInstance('edge_glow', 'g', l)..params['radius'] = Track(16.0, false));
    final at = await render(Project(layers: [l]));
    expect(at(100, 50), 0x000000ff, reason: 'the shape itself');
    expect(at(125, 50) & 0xff, greaterThan(40), reason: 'glow just outside it');
    expect(at(180, 50) & 0xff, lessThan(10));
  });

  test('merge with text: one picture layer in their place', () async {
    final app = AppState()..setFrameSize(200, 100);
    app.project.layers.clear();
    final a = rect('a', '#ff0000', 60, 50, 40);
    final b = rect('b', '#0000ff', 140, 50, 40);
    app.project.layers.addAll([a, b]);
    expect(await app.mergeLayersAsPicture(['a', 'b']), isTrue);
    final m = app.project.layers.single;
    expect(m.content.shape, 'image');
    // 40..160 wide, 30..70 high, in frame px.
    expect(m.content.size[0], closeTo(120, 1.5));
    expect(m.content.size[1], closeTo(40, 1.5));
    expect((m.transform.anchor.defaultValue as List)[0], closeTo(0.5, 0.01));
  });

  test('a new parent link follows position only', () {
    final l = createLayer('rect');
    newParentLinkDefaults(l);
    expect([l.inheritPosition, l.inheritRotation, l.inheritScale], [true, false, false]);
  });
}
