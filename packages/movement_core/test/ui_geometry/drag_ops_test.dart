import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _rectLayer({List<double> anchor = const [0.5, 0.5]}) {
  return Layer(
    id: 'L_test',
    name: 'test',
    parentId: null,
    transform: Transform(anchor: track(anchor), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
    content: Content(shape: 'rect', offset: [0, 0], size: [100, 60]),
  );
}

void main() {
  // these check the mirrored (left-hand) layout's corners.
  setUp(() => handlesRightHanded = false);
  tearDown(() => handlesRightHanded = true);

  late Project project;

  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
    project = Project();
  });

  test('CornerDragOp: dragging p0 writes the offset from its natural vertex, not an absolute position', () {
    final layer = Layer(
      id: 'L_tri', name: 'tri', parentId: null,
      transform: Transform(anchor: track([0.5, 0.5]), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'triangle', offset: [0, 0], size: [100, 100]),
    );
    final inst = createEffectInstance('corner_pin', 'fx1', layer);
    inst.params['p0'] = track([0.0, 0.0]);
    inst.params['p1'] = track([0.0, 0.0]);
    inst.params['p2'] = track([0.0, 0.0]);
    layer.effectStack.add(inst);
    project.layers.add(layer);

    final natural = shapePoints(layer.content)[0]; // p0's own natural vertex
    final op = CornerDragOp(layer: layer, inst: inst, corner: 'p0');
    op.apply(project, 0, [natural[0] + 320 + 7, natural[1] + 200 - 4]);
    final result = (inst.params['p0'] as Track).defaultValue as List<double>;
    expect(result[0], closeTo(7.0, 1e-9)); // natural[0] involves trig (triangle vertex) - not bit-exact
    expect(result[1], closeTo(-4.0, 1e-9));
  });

  test('MeshDragOp: dragging r0c0 writes the offset from its captured natural point', () {
    final layer = _rectLayer();
    final inst = createEffectInstance('mesh_warp', 'fx1', layer);
    layer.effectStack.add(inst);
    project.layers.add(layer);

    final mesh = getMeshWarpHandles(project, layer, inst, 0);
    final entry = mesh.handles.firstWhere((h) => h.key == 'r0c0');
    final op = MeshDragOp(layer: layer, inst: inst, pinKey: 'r0c0', natural: entry.natural);
    op.apply(project, 0, [entry.natural[0] + 320 + 3, entry.natural[1] + 200 + 9]);
    expect((inst.params['r0c0'] as Track).defaultValue, equals([3.0, 9.0]));
  });

  test('PendulumPivotDragOp: grab-then-apply moves the pivot by exactly the pointer\'s own delta', () {
    final layer = _rectLayer();
    layer.pendulum = Pendulum(enabled: true, pivotOffset: track([10.0, -5.0], true));
    project.layers.add(layer);

    // grabbing exactly on the handle's own current screen position ->
    // grabDelta is zero, so apply()'s output should equal the new
    // point's local offset directly.
    final handle = getPendulumPivotHandleScreen(project, layer, 0);
    final op = PendulumPivotDragOp.grab(project, layer, 0, handle.screen);
    expect(op.grabDelta, equals([0.0, 0.0]));

    op.apply(project, 0, [handle.screen[0] + 20, handle.screen[1] - 10]);
    expect(layer.pendulum.pivotOffset.defaultValue, equals([30.0, -15.0])); // 10-5 base handle local + 20,-10 delta
  });

  test('StationDragOp: dragging an existing keyframe station moves ONLY that keyframe\'s value', () {
    final layer = _rectLayer();
    layer.transform.anchor.spatial = true;
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.2, 0.5]),
      Keyframe(frame: 30, value: [0.8, 0.5]),
    ]);
    project.layers.add(layer);

    final grabPoint = [0.2 * 640, 0.5 * 400]; // grab exactly on station 0
    final op = StationDragOp.grab(project, layer, 0, 0, grabPoint);
    op.apply(project, 0, [0.3 * 640, 0.5 * 400]);
    expect(layer.transform.anchor.keyframes[0].value, equals([0.3, 0.5]));
    expect(layer.transform.anchor.keyframes[1].value, equals([0.8, 0.5])); // untouched
  });

  test('AnchorDragOp: dragging the move handle writes the DEFAULT when no keyframe sits at the current frame', () {
    final layer = _rectLayer();
    project.layers.add(layer);

    final grabPoint = [320.0, 200.0]; // exactly on the anchor (default [0.5,0.5])
    final op = AnchorDragOp.grab(project, layer, 0, grabPoint);
    op.apply(project, 0, [320.0 + 64, 200.0 + 40]); // +0.1,+0.1 in fraction terms
    expect(layer.transform.anchor.defaultValue[0], closeTo(0.6, 1e-9));
    expect(layer.transform.anchor.defaultValue[1], closeTo(0.6, 1e-9));
  });

  test('AnchorDragOp: writes the EXISTING keyframe at the current local frame instead, when one is there', () {
    final layer = _rectLayer();
    layer.transform.anchor.keyframes.add(Keyframe(frame: 0, value: [0.5, 0.5]));
    project.layers.add(layer);

    final op = AnchorDragOp.grab(project, layer, 0, [320.0, 200.0]);
    op.apply(project, 0, [320.0 + 64, 200.0]);
    expect(layer.transform.anchor.keyframes[0].value[0], closeTo(0.6, 1e-9));
    expect(layer.transform.anchor.defaultValue, equals([0.5, 0.5])); // default untouched
  });

  test('AnchorDragOp: dragging BEFORE the first keyframe edits that boundary keyframe, not defaultValue', () {
    final layer = _rectLayer();
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 10, value: [0.2, 0.5]),
      Keyframe(frame: 30, value: [0.8, 0.5]),
    ]);
    project.layers.add(layer);

    // frame 0 is before the first keyframe (frame 10) - no exact match.
    final op = AnchorDragOp.grab(project, layer, 0, [320.0, 200.0]);
    op.apply(project, 0, [320.0 + 64, 200.0]); // +0.1 in fraction terms
    expect(layer.transform.anchor.keyframes[0].value[0], closeTo(0.3, 1e-9)); // 0.2 + 0.1
    expect(layer.transform.anchor.keyframes[1].value, equals([0.8, 0.5])); // untouched
    expect(layer.transform.anchor.defaultValue, equals([0.5, 0.5])); // never written - unreachable via evaluateTrack anyway
  });

  test('AnchorDragOp: dragging AFTER the last keyframe edits that boundary keyframe', () {
    final layer = _rectLayer();
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.2, 0.5]),
      Keyframe(frame: 10, value: [0.8, 0.5]),
    ]);
    project.layers.add(layer);

    // frame 20 is after the last keyframe (frame 10) - no exact match.
    final op = AnchorDragOp.grab(project, layer, 20, [320.0, 200.0]);
    op.apply(project, 20, [320.0 + 64, 200.0]);
    expect(layer.transform.anchor.keyframes[1].value[0], closeTo(0.9, 1e-9)); // 0.8 + 0.1
    expect(layer.transform.anchor.keyframes[0].value, equals([0.2, 0.5])); // untouched
  });

  test('AnchorDragOp: strictly between two keyframes with no exact match leaves both keyframes untouched', () {
    final layer = _rectLayer();
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.2, 0.5]),
      Keyframe(frame: 30, value: [0.8, 0.5]),
    ]);
    project.layers.add(layer);

    // frame 15 sits strictly between the two keyframes - no exact match,
    // and inside the animation's own span, so per spec neither keyframe
    // moves (the write instead falls through to defaultValue, same as
    // pre-existing behavior - harmless since evaluateTrack never reads
    // defaultValue once keyframes exist, so it has no visible effect).
    final op = AnchorDragOp.grab(project, layer, 15, [320.0, 200.0]);
    op.apply(project, 15, [320.0 + 64, 200.0]);
    expect(layer.transform.anchor.keyframes[0].value, equals([0.2, 0.5]));
    expect(layer.transform.anchor.keyframes[1].value, equals([0.8, 0.5]));
  });

  test('PathDragOp: drags the WHOLE path (default + every keyframe) by the same uniform delta', () {
    final layer = _rectLayer();
    layer.transform.anchor.spatial = true;
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.2, 0.5]),
      Keyframe(frame: 30, value: [0.8, 0.5]),
    ]);
    project.layers.add(layer);

    final op = PathDragOp.grab(project, layer, 0, [0.0, 0.0]);
    op.apply(project, 0, [64.0, 40.0]); // delta = [0.1, 0.1] in fraction terms
    expect(layer.transform.anchor.defaultValue[0], closeTo(0.6, 1e-9));
    expect(layer.transform.anchor.defaultValue[1], closeTo(0.6, 1e-9));
    expect(layer.transform.anchor.keyframes[0].value[0], closeTo(0.3, 1e-9));
    expect(layer.transform.anchor.keyframes[0].value[1], closeTo(0.6, 1e-9));
    expect(layer.transform.anchor.keyframes[1].value[0], closeTo(0.9, 1e-9));
    expect(layer.transform.anchor.keyframes[1].value[1], closeTo(0.6, 1e-9));
  });

  test('RotateDragOp: rotation delta tracks the pointer angle change around the anchor', () {
    final layer = _rectLayer();
    project.layers.add(layer);

    final op = RotateDragOp.grab(project, layer, 0, [420.0, 200.0]); // due "east" of anchor [320,200] -> angle 0
    op.apply(project, 0, [320.0, 300.0]); // due "south" of anchor -> angle +90deg
    expect(layer.transform.rotation.defaultValue, closeTo(90.0, 1e-6));
  });

  test('ScaleDragOp scaleCorner: uniform ratio from distance-to-anchor', () {
    final layer = _rectLayer();
    project.layers.add(layer);
    final op = ScaleDragOp(layer: layer, handle: 'scaleCorner');
    // bbox is (-50,-30)-(50,30); origDist = hypot(50,30); pick a point
    // at exactly 2x that distance for a clean ratio.
    op.apply(project, 0, [320.0 + 100, 200.0 + 60]);
    expect(layer.transform.scale.defaultValue[0], closeTo(2.0, 1e-9));
    expect(layer.transform.scale.defaultValue[1], closeTo(2.0, 1e-9));
  });

  test('ScaleDragOp scaleCorner keeps a non-uniform scale\'s aspect ratio', () {
    final layer = _rectLayer();
    layer.transform.scale.defaultValue = [2.0, 1.0];
    project.layers.add(layer);
    final op = ScaleDragOp(layer: layer, handle: 'scaleCorner');
    // the corner is drawn at (-50*2, -30*1) = (-100,-30) from the anchor;
    // dragging it to 1.5x that point scales both axes by 1.5.
    op.apply(project, 0, [320.0 - 150, 200.0 - 45]);
    expect(layer.transform.scale.defaultValue[0], closeTo(3.0, 1e-9));
    expect(layer.transform.scale.defaultValue[1], closeTo(1.5, 1e-9));
  });

  test('ScaleDragOp left edge: only the X axis changes, Y stays at its current value', () {
    final layer = _rectLayer();
    project.layers.add(layer);
    final op = ScaleDragOp(layer: layer, handle: 'left');
    op.apply(project, 0, [320.0 - 25, 200.0]); // localPt.x = -25, half of bbox.minX(-50)
    expect(layer.transform.scale.defaultValue[0], closeTo(0.5, 1e-9));
    expect(layer.transform.scale.defaultValue[1], closeTo(1.0, 1e-9)); // unchanged
  });

  test('ScaleDragOp edges never flip the object: past the anchor the size grows again', () {
    final layer = _rectLayer();
    project.layers.add(layer);
    ScaleDragOp(layer: layer, handle: 'left').apply(project, 0, [320.0 + 25, 200.0]);
    expect(layer.transform.scale.defaultValue[0], closeTo(0.5, 1e-9));
    ScaleDragOp(layer: layer, handle: 'top').apply(project, 0, [320.0, 200.0 + 60]);
    expect(layer.transform.scale.defaultValue[1], greaterThan(0));
  });

  group('off-canvas: anchor/pivotOffset values far outside [0,1] stay finite and unclamped', () {
    test('getLayerStateAt never clamps an extreme anchor value', () {
      final layer = _rectLayer(anchor: [50.0, -30.0]); // way outside the frame
      project.layers.add(layer);
      final state = getLayerStateAt(project, layer.id, 0);
      expect(state.matrix[4], equals(50.0));
      expect(state.matrix[5], equals(-30.0));
      expect(state.matrix.every((v) => v.isFinite), isTrue);
    });

    test('getPendulumPivotHandleScreen stays finite and unclamped for a pivot far outside the object\'s own bounds', () {
      final layer = _rectLayer();
      layer.pendulum = Pendulum(enabled: true, pivotOffset: track([5000.0, -5000.0], true));
      project.layers.add(layer);
      final handle = getPendulumPivotHandleScreen(project, layer, 0);
      expect(handle.screen.every((v) => v.isFinite), isTrue);
      expect(handle.screen, equals([5000.0 + 320, -5000.0 + 200]));
    });
  });
}
