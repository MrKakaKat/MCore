import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Mask feather is drawn as geometry (a stack of strokes around the
/// outline), not with a blur filter: the same mask must look the same
/// wherever it sits, however it's turned, and its softness must follow
/// the layer's scale once (not squared).
void main() {
  const width = 200.0, height = 160.0;

  Future<List<int>> alphaOf({
    double dx = 0,
    double rotation = 0,
    double targetScale = 1,
    double feather = 6,
  }) async {
    final project = Project();
    final renderer = CanvasRenderer()..setSize(width, height);
    final source = createLayer('rect')
      ..id = 'L_mask'
      ..hidden = true
      ..content = Content(shape: 'rect', offset: [0, 0], size: [60, 60]);
    source.transform.anchor.defaultValue = [0.5 + dx / width, 0.5];
    source.transform.rotation.defaultValue = rotation;
    final target = createLayer('rect')
      ..id = 'L_target'
      ..color = '#ffffff'
      ..content = Content(shape: 'rect', offset: [0, 0], size: [width / targetScale, height / targetScale]);
    target.transform.anchor.defaultValue = [0.5, 0.5];
    target.transform.scale.defaultValue = [targetScale, targetScale];
    target.masks.add(Mask(sourceLayerId: source.id, feather: track(feather)));
    project.layers
      ..add(source)
      ..add(target);
    clearStateCaches();
    renderer.renderFrame(project, 0);
    final image = await renderer.captureFrame();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    return [for (var i = 3; i < bytes.length; i += 4) bytes[i]];
  }

  double total(List<int> a) => a.fold<double>(0, (s, v) => s + v) / 255;
  int soft(List<int> a) => a.where((v) => v > 25 && v < 230).length;
  List<int> row(List<int> a, int y) => a.sublist(y * width.toInt(), (y + 1) * width.toInt());

  test('the edge falls off like a Gaussian: half at the edge, almost nothing 2 sigma out', () async {
    final r = row(await alphaOf(), 80);
    // the mask's left edge sits at x = 70 (pixel centres at 69.5 / 70.5)
    expect((r[69] + r[70]) / 2 / 255, closeTo(0.5, 0.06));
    expect(r[70 - 12] / 255, lessThan(0.05)); // 2 sigma outside
    expect(r[70 + 12] / 255, greaterThan(0.95)); // 2 sigma inside
    expect(r[100], 255);
    expect(r[10], 0);
  });

  test('moving the mask by a fraction of a pixel keeps the same amount of glow', () async {
    final base = await alphaOf();
    for (final dx in [0.25, 0.5, 0.75, 1.0, 3.3]) {
      final moved = await alphaOf(dx: dx);
      expect(total(moved), closeTo(total(base), total(base) * 0.004), reason: 'dx $dx');
      expect(row(moved, 80).reduce(math.max), 255);
    }
  });

  test('turning the mask keeps the same amount of glow', () async {
    final base = total(await alphaOf());
    for (final rot in [10.0, 30.0, 45.0, 77.0]) {
      expect(total(await alphaOf(rotation: rot)), closeTo(base, base * 0.02), reason: 'rotation $rot');
    }
  });

  test('a layer scaled 2x gets a feather twice as wide, not four times', () async {
    final one = soft(row(await alphaOf(), 80));
    final two = soft(row(await alphaOf(targetScale: 2), 80));
    expect(two / one, closeTo(2, 0.25));
  });
}
