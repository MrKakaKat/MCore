import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Crop handles and the crop drag op. The rect layer is 100x60 at the
/// stage centre (320,200) with scale 1, so frame and local coordinates
/// differ only by that offset.
Layer _rect() => Layer(
      id: 'L_crop',
      name: 'crop',
      transform: Transform(
          anchor: track([0.5, 0.5], true),
          scale: track([1.0, 1.0]),
          rotation: track(0.0),
          opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [100, 60]),
    );

void main() {
  late Project project;
  late Layer layer;
  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
    clearStateCaches();
    layer = _rect();
    project = Project(layers: [layer]);
  });

  test('dragging the right edge in crops that side only', () {
    CropDragOp(layer: layer, handle: 'right').apply(project, 0, [320.0 + 25, 200.0]);
    expect(layer.crop[2], closeTo(0.25, 1e-9)); // 50 -> 25 of a 100-wide box
    expect([layer.crop[0], layer.crop[1], layer.crop[3]], equals([0.0, 0.0, 0.0]));
    expect(croppedBox(layer).maxX, closeTo(25, 1e-9));
  });

  test('a crop never goes past the box or below the minimum size', () {
    CropDragOp(layer: layer, handle: 'left').apply(project, 0, [320.0 - 500, 200.0]);
    expect(layer.crop[0], equals(0.0));
    CropDragOp(layer: layer, handle: 'left').apply(project, 0, [320.0 + 500, 200.0]);
    expect(1 - layer.crop[0] - layer.crop[2], closeTo(0.05, 1e-9));
  });

  test('with a 1:1 lock a corner drag keeps a square, anchored at the opposite corner', () {
    layer.cropAspect = '1:1';
    CropDragOp(layer: layer, handle: 'tl').apply(project, 0, [320.0 - 10, 200.0 - 20]);
    final b = croppedBox(layer);
    expect(b.maxX - b.minX, closeTo(b.maxY - b.minY, 1e-9));
    expect([b.maxX, b.maxY], equals([50.0, 30.0]));
  });

  test('choosing an aspect re-fits the crop to the largest centred rect', () {
    layer.cropAspect = '1:1';
    fitCropToAspect(project, layer, 0);
    final b = croppedBox(layer);
    expect([b.minX, b.maxX, b.minY, b.maxY], equals([-30.0, 30.0, -30.0, 30.0]));
  });

  test('handles sit on the cropped rect', () {
    layer.crop = [0.1, 0, 0, 0];
    final h = getCropHandles(project, layer, 0);
    expect(h.screen['left'], equals([320.0 - 40, 200.0]));
  });
}
