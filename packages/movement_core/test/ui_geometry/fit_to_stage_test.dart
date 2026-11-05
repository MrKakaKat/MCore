import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _rect(String id, {String? parentId}) => Layer(
      id: id,
      name: id,
      parentId: parentId,
      transform: Transform(
          anchor: track([0.3, 0.3], true), scale: track([1.0, 1.0]), rotation: track(20.0), opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [10, 5], size: [100, 50]),
    );

BoundingBox _frameBox(Project p, Layer l) {
  clearStateCaches();
  final m = toFrameMatrix(getLayerStateAt(p, l.id, 0).matrix);
  final b = croppedBox(l);
  final pts = [
    [b.minX, b.minY], [b.maxX, b.minY], [b.maxX, b.maxY], [b.minX, b.maxY]
  ].map((q) => applyAffine(m, q)).toList();
  double mn(int i) => pts.map((q) => q[i]).reduce((a, c) => a < c ? a : c);
  double mx(int i) => pts.map((q) => q[i]).reduce((a, c) => a > c ? a : c);
  return BoundingBox(minX: mn(0), maxX: mx(0), minY: mn(1), maxY: mx(1));
}

void main() {
  setUp(() => setStageSize(400, 400));

  void expectBox(BoundingBox b, List<double> ltrb) {
    expect(b.minX, closeTo(ltrb[0], 1e-6));
    expect(b.minY, closeTo(ltrb[1], 1e-6));
    expect(b.maxX, closeTo(ltrb[2], 1e-6));
    expect(b.maxY, closeTo(ltrb[3], 1e-6));
  }

  test('fit / fill / stretch put the box on the frame, unrotated', () {
    final l = _rect('a');
    final p = Project(layers: [l]);
    fitLayerToStage(p, l, 0, 'fit');
    expectBox(_frameBox(p, l), [0, 100, 400, 300]);
    expect(l.transform.rotation.defaultValue, 0.0);
    fitLayerToStage(p, l, 0, 'fill');
    expectBox(_frameBox(p, l), [-200, 0, 600, 400]);
    fitLayerToStage(p, l, 0, 'stretch');
    expectBox(_frameBox(p, l), [0, 0, 400, 400]);
  });

  test('the cropped part is what gets fitted', () {
    final l = _rect('a')..crop = [0.5, 0, 0, 0];
    final p = Project(layers: [l]);
    fitLayerToStage(p, l, 0, 'fit');
    expectBox(_frameBox(p, l), [0, 0, 400, 400]);
  });

  test('a scaled, rotated, moved parent is compensated', () {
    final parent = _rect('p')
      ..transform.scale.defaultValue = [2.0, 2.0]
      ..transform.rotation.defaultValue = 30.0;
    final child = _rect('c', parentId: 'p');
    final p = Project(layers: [parent, child]);
    fitLayerToStage(p, child, 0, 'fit');
    expectBox(_frameBox(p, child), [0, 100, 400, 300]);
  });

  test('keyed tracks get a key at the frame (the usual rule)', () {
    final l = _rect('a');
    l.transform.scale.keyframes.add(Keyframe(frame: 0, value: [1.0, 1.0]));
    final p = Project(layers: [l]);
    fitLayerToStage(p, l, 0, 'fit');
    expect(l.transform.scale.keyframes.single.value, [4.0, 4.0]);
  });
}
