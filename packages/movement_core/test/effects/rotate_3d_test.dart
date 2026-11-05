import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// 3D Rotate: the grid turned about an in-plane axis and projected back.
void main() {
  setUpAll(registerBuiltinEffects);

  // a 3x3 grid over the box (-50..50) x (-30..30).
  final grid = [
    for (final y in [-30.0, 0.0, 30.0]) [for (final x in [-50.0, 0.0, 50.0]) <double>[x, y]]
  ];
  Map<String, dynamic> params({double angle = 0, double axis = 90, double perspective = 0, String backface = 'show', List<double> pivot = const [0.5, 0.5]}) =>
      {'angle': angle, 'axis': axis, 'pivot': pivot, 'perspective': perspective, 'shading': 0.3, 'backface': backface};
  Grid turn(Map<String, dynamic> p) => effectRegistry['rotate_3d']!.apply(grid, p, 0);

  test('angle 0 leaves the grid alone', () {
    expect(turn(params()), equals(grid));
  });

  test('180 degrees about the vertical axis, flat: mirrored left-right', () {
    final out = turn(params(angle: 180));
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 3; c++) {
        expect(out[r][c][0], closeTo(-grid[r][c][0], 1e-9));
        expect(out[r][c][1], closeTo(grid[r][c][1], 1e-9));
      }
    }
  });

  test('90 degrees, flat: the object is edge-on - every x on the pivot line', () {
    final out = turn(params(angle: 90, pivot: const [0.0, 0.5])); // pivot on the left edge
    for (final row in out) {
      for (final p in row) {
        expect(p[0], closeTo(-50, 1e-9));
      }
    }
  });

  test('horizontal axis (axis 0) tips the object forward/back instead', () {
    final out = turn(params(angle: 180, axis: 0));
    expect(out[0][0][1], closeTo(30, 1e-9), reason: 'top row lands at the bottom');
    expect(out[0][0][0], closeTo(-50, 1e-9), reason: 'x unchanged');
  });

  test('with perspective, the edge turned toward you is taller than the far edge', () {
    final out = turn(params(angle: 45, perspective: 0.8));
    double height(int col) => (out[2][col][1] - out[0][col][1]).abs();
    expect(height(0), isNot(closeTo(height(2), 1)));
    final near = height(0) > height(2) ? height(0) : height(2);
    expect(near, greaterThan(60), reason: 'nearer than the flat object');
  });

  test('backface hide: seen from behind, nothing is left to draw', () {
    final out = turn(params(angle: 180, backface: 'hide'));
    final pts = out.expand((r) => r).toSet().map((p) => '${p[0]},${p[1]}').toSet();
    expect(pts.length, 1);
  });

  test('brightness follows the angle and the shading amount', () {
    final b = effectRegistry['rotate_3d']!.brightness!;
    expect(b(params()), closeTo(1, 1e-9));
    expect(b({...params(angle: 90), 'shading': 1.0}), closeTo(0, 1e-9));
    expect(b({...params(angle: 180), 'shading': 1.0}), closeTo(1, 1e-9), reason: 'the back side, flat on');
  });

  test('layerEffectBrightness and the pivot drag op on a real layer', () {
    setStageSize(640, 400);
    final layer = Layer(
      id: 'L_3d',
      name: '3d',
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [100, 60]),
    );
    final inst = createEffectInstance('rotate_3d', 'fx_3d', layer);
    (inst.params['angle'] as Track).defaultValue = 90.0;
    (inst.params['shading'] as Track).defaultValue = 0.5;
    layer.effectStack.add(inst);
    final project = Project(layers: [layer]);
    expect(layerEffectBrightness(layer, 0), closeTo(0.5, 1e-9));

    final h = getRotate3dPivotHandle(project, layer, inst, 0);
    expect(h.screen, [320.0, 200.0], reason: 'box centre at the stage centre');
    final op = Rotate3dPivotDragOp.grab(project, layer, inst, 0, [320.0, 200.0]);
    op.apply(project, 0, [320.0 + 50, 200.0 - 30]); // the top-right corner
    expect((inst.params['pivot'] as Track).defaultValue, [1.0, 0.0]);

    final back = effectInstanceFromJson(effectInstanceToJson(inst));
    expect(back.params['backface'], 'show');
  });
}
