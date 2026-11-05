import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Layer _shape(String shape, String id, double side, double x, {String color = '#3060c0', bool hidden = false}) =>
    createLayer(shape)
      ..id = id
      ..color = color
      ..hidden = hidden
      ..content.size = [side, side]
      ..transform.anchor.defaultValue = [x, 0.5];

Future<List<int>> _render(Layer target, {double bOpacity = 1}) async {
  setStageSize(400, 400);
  clearStateCaches();
  clearCutCaches();
  final p = Project(layers: [
    _shape('circle', 'a', 160, 0.42, hidden: true),
    _shape('circle', 'b', 160, 0.58, hidden: true)..transform.opacity.defaultValue = bOpacity,
    target,
  ]);
  final r = CanvasRenderer()..setSize(400, 400);
  r.backgroundColor = null;
  r.renderFrame(p, 0);
  final img = await r.captureFrame();
  final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return b.buffer.asUint8List();
}

void main() {
  for (final mode in ['add', 'subtract', 'intersect', 'exclude', 'implication', 'equivalence', 'invert']) {
    test('regions preset "$mode" draws the same pixels as the old mask', () async {
      final viaStack = await _render(_shape('rect', 't', 360, 0.5)
        ..masks.addAll(mode == 'invert'
            ? [Mask(sourceLayerId: 'a', invert: true)]
            : [Mask(sourceLayerId: 'a'), Mask(mode: mode, sourceLayerId: 'b')]));
      final viaRegions = await _render(_shape('rect', 't', 360, 0.5)
        ..maskRegions = MaskRegions(
            sources: mode == 'invert' ? ['a'] : ['a', 'b'],
            opacity: {for (final e in regionPreset(mode).entries) e.key: track(e.value)}));
      // anti-aliased edges may differ by a little; count pixels off by much.
      var off = 0, shown = 0;
      for (var i = 3; i < viaStack.length; i += 4) {
        if ((viaStack[i] - viaRegions[i]).abs() > 64) off++;
        if (viaStack[i] > 128) shown++;
      }
      expect(shown, greaterThan(0));
      expect(off, lessThan(40), reason: '$off pixels differ');
    });
  }

  test('a region at half opacity shows the layer half see-through there', () async {
    final px = await _render(_shape('rect', 't', 360, 0.5)
      ..maskRegions = MaskRegions(sources: ['a', 'b'], opacity: {3: track(0.5)}));
    int alphaAt(int x, int y) => px[(y * 400 + x) * 4 + 3];
    expect(alphaAt(200, 200), inInclusiveRange(110, 145), reason: 'inside A·B');
    expect(alphaAt(120, 200), 0, reason: 'A only: hidden');
  });

  test('a soft edge blends: about half way at the edge, full inside, none far out', () async {
    final px = await _render(_shape('rect', 't', 360, 0.5)
      ..maskRegions = MaskRegions(sources: ['a'], opacity: {1: track(1.0)}, feather: [12]));
    int alphaAt(int x, int y) => px[(y * 400 + x) * 4 + 3];
    // A: centre x 168, radius 80 -> right edge at 248.
    expect(alphaAt(168, 200), greaterThan(240));
    expect(alphaAt(248, 200), inInclusiveRange(90, 170));
    expect(alphaAt(300, 200), lessThan(10));
  });

  test('a see-through source covers by its opacity: its regions blend', () async {
    final px = await _render(
        _shape('rect', 't', 360, 0.5)..maskRegions = MaskRegions(sources: ['b'], opacity: {1: track(1.0)}),
        bOpacity: 0.5);
    int alphaAt(int x, int y) => px[(y * 400 + x) * 4 + 3];
    expect(alphaAt(232, 200), inInclusiveRange(110, 145), reason: 'inside B at half: 1 x 0.5');
    expect(alphaAt(60, 200), 0, reason: 'outside B: the outside region is hidden');
  });
}
