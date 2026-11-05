import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  Layer square() => createLayer('rect')
    ..id = 'sq'
    ..content.offset = [0, 0]
    ..content.size = [100, 50]
    ..transform.anchor.defaultValue = [0.5, 0.5];

  test('glows sit at fractions of the box; radius is a fraction of its larger side', () {
    final l = square();
    expect(evaluateGlows(null, l, 0), isEmpty, reason: 'plain colour');
    final g = addGlow(l, 'point');
    g.position.defaultValue = [0.25, 1.0];
    g.radius.defaultValue = 0.3;
    final line = addGlow(l, 'line');
    final s = evaluateGlows(null, l, 0);
    expect(l.fill.gradient, isTrue);
    expect(s[0].a, [-25.0, 25.0]);
    expect(s[0].b, s[0].a);
    expect(s[0].radius, closeTo(30, 1e-9));
    expect(s[1].a, [-30.0, 0.0]);
    expect(s[1].b, [30.0, 0.0]);
    line.enabled = false;
    expect(evaluateGlows(null, l, 0).length, 1);
    l.fill.gradient = false;
    expect(evaluateGlows(null, l, 0), isEmpty, reason: 'off keeps the glows but draws the plain colour');
  });

  test('falloff: full at the centre, gone at the radius, smooth in between', () {
    expect(glowFalloff(0), 1);
    expect(glowFalloff(1), 0);
    expect(glowFalloff(2), 0);
    expect(glowFalloff(0.5), closeTo(0.5625, 1e-9));
    expect(glowFalloff(0.99), lessThan(0.001));
  });

  test('glow tracks animate, show on the timeline, survive save/load, clone and presets', () {
    final l = square();
    final g = addGlow(l, 'line', color: '#ff0000');
    g.strength.keyframes = [
      Keyframe(frame: 0, value: 0.0),
      Keyframe(frame: 60, value: 1.0),
    ];
    expect(evaluateGlows(null, l, 30).single.strength, closeTo(0.5, 0.2));
    expect(collectLayerKeyframeFrames(l), [0, 60]);

    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.fill.gradient, isTrue);
    expect(back.fill.glows.single.kind, 'line');
    expect(back.fill.glows.single.color, '#ff0000');
    expect(back.fill.glows.single.strength.keyframes.length, 2);
    expect(layerToJson(square()).containsKey('fill'), isFalse, reason: 'plain layers write nothing new');

    final copy = cloneLayer(l);
    copy.fill.glows.single.color = '#00ff00';
    expect(l.fill.glows.single.color, '#ff0000');

    final p = Project(layers: [l]);
    final other = createLayer('circle')..id = 'c';
    applyLayerParamsJson(p, other, layerParamsToJson(l));
    expect(other.fill.glows.single.color, '#ff0000');
  });

  test('dragging a glow handle on the stage moves it and keys it like other params', () {
    final l = square();
    final p = Project(layers: [l]);
    final g = addGlow(l, 'point');
    final h = getGlowHandles(p, l, 0).single;
    expect(h.screen, [100.0, 100.0]); // box middle at the frame centre
    final op = GlowDragOp.grab(p, l, h, 0, [102, 100]);
    op.apply(p, 0, [152, 125]);
    expect(g.position.defaultValue, [1.0, 1.0]);

    g.position.keyframes = [Keyframe(frame: 0, value: [0.5, 0.5]), Keyframe(frame: 100, value: [0.5, 0.5])];
    clearStateCaches();
    GlowDragOp.grab(p, l, getGlowHandles(p, l, 0).single, 0, [100, 100]).apply(p, 0, [75, 100]);
    expect(g.position.keyframes.first.value, [0.25, 0.5]);
    expect(g.position.keyframes.last.value, [0.5, 0.5]);
  });

  test('a line has two handles', () {
    final l = square();
    final p = Project(layers: [l]);
    addGlow(l, 'line');
    final hs = getGlowHandles(p, l, 0);
    expect(hs.map((h) => h.end), ['a', 'b']);
    expect(hs[1].screen, [130.0, 100.0]);
  });
}
