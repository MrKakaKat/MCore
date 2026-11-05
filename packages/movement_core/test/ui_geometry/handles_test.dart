import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _rectLayer({List<double> anchor = const [0.5, 0.5], List<double> size = const [100, 60]}) {
  return Layer(
    id: 'L_test',
    name: 'test',
    parentId: null,
    transform: Transform(anchor: track(anchor), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
    content: Content(shape: 'rect', offset: [0, 0], size: size),
  );
}

void main() {
  // these check the mirrored (left-hand) layout's corners.
  setUp(() => handlesRightHanded = false);
  tearDown(() => handlesRightHanded = true);

  late Project project;

  setUp(() {
    setStageSize(640, 400); // fixed, known size - every pinned value below assumes exactly this
    project = Project();
  });

  group('getTransformBoxHandles', () {
    test('bbox corners/edges/scale/rotate/move handles land at exactly the expected frame-space pixels', () {
      final layer = _rectLayer();
      project.layers.add(layer);
      // matFromTRS([0.5,0.5], 0, [1,1]) -> identity linear part, translation
      // = anchor exactly -> mCanvas = [1,0,0,1, 0.5*640, 0.5*400] = [1,0,0,1,320,200],
      // so every screen point below is just its local point + [320,200].
      final tb = getTransformBoxHandles(project, layer, 0);
      expect(tb.bbox.minX, equals(-50));
      expect(tb.bbox.maxX, equals(50));
      expect(tb.bbox.minY, equals(-30));
      expect(tb.bbox.maxY, equals(30));

      expect(tb.screen['top'], equals([320, 170]));
      expect(tb.screen['bottom'], equals([320, 230]));
      expect(tb.screen['left'], equals([270, 200]));
      expect(tb.screen['right'], equals([370, 200]));
      expect(tb.screen['scaleCorner'], equals([270, 170])); // top-left
      expect(tb.screen['rotateCorner'], equals([370, 170])); // top-right
      // moveCorner defaults to the bbox's own top-left-adjacent corner
      // (bbox.minX, bbox.maxY) when no mesh-warp/corner-pin is active.
      expect(tb.screen['moveCorner'], equals([270, 230]));
      expect(tb.screen['tl'], equals([270, 170]));
      expect(tb.screen['tr'], equals([370, 170]));
      expect(tb.screen['br'], equals([370, 230]));
      expect(tb.screen['bl'], equals([270, 230]));
    });

    test('moveCorner recenters to the deformed shape centroid when mesh-warp/corner-pin is active', () {
      registerBuiltinEffects();
      final layer = _rectLayer();
      final inst = createEffectInstance('mesh_warp', 'fx1', layer);
      layer.effectStack.add(inst);
      project.layers.add(layer);

      final tb = getTransformBoxHandles(project, layer, 0);
      // ground truth via the SAME outline-averaging getContentOutline
      // uses internally (a 10x10 boundary trace through the -no-op-
      // mesh-warp effect stack, not simply the bbox's own center - the
      // boundary trace's point density isn't perfectly uniform around
      // a non-square rect's perimeter, so the two aren't quite equal)
      // - this test is about getTransformBoxHandles' OWN offset/
      // transform composition, not about re-deriving getContentOutline's
      // averaging algorithm by hand.
      final deformed = getContentOutline(layer.content, layer, 0);
      final expectedX = deformed.map((p) => p[0]).reduce((a, b) => a + b) / deformed.length;
      final expectedY = deformed.map((p) => p[1]).reduce((a, b) => a + b) / deformed.length;
      expect(tb.screen['moveCorner']![0], closeTo(expectedX + 320, 1e-9));
      expect(tb.screen['moveCorner']![1], closeTo(expectedY + 200, 1e-9));
    });
  });

  group('getCornerPinHandles', () {
    test('exact 3-point (triangle) mode: screen = natural vertex + this frame\'s offset, transformed', () {
      registerBuiltinEffects();
      final layer = Layer(
        id: 'L_tri',
        name: 'tri',
        parentId: null,
        transform: Transform(anchor: track([0.5, 0.5]), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
        content: Content(shape: 'triangle', offset: [0, 0], size: [100, 100]),
      );
      final inst = createEffectInstance('corner_pin', 'fx1', layer);
      inst.params['p0'] = track([5.0, -3.0]);
      inst.params['p1'] = track([0.0, 0.0]);
      inst.params['p2'] = track([0.0, 0.0]);
      layer.effectStack.add(inst);
      project.layers.add(layer);

      final naturalPts = shapePoints(layer.content); // ground truth for the 3 raw vertices
      final handles = getCornerPinHandles(project, layer, inst, 0);
      expect(handles.keys, equals(['p0', 'p1', 'p2']));
      expect(handles.natural['p0'], equals(naturalPts[0]));
      expect(handles.screen['p0'], equals([naturalPts[0][0] + 5.0 + 320, naturalPts[0][1] - 3.0 + 200]));
      expect(handles.screen['p1'], equals([naturalPts[1][0] + 320, naturalPts[1][1] + 200]));
    });

    test('bbox (tl/tr/br/bl) mode for a non-exact shape (e.g. circle)', () {
      registerBuiltinEffects();
      final layer = Layer(
        id: 'L_circ',
        name: 'circ',
        parentId: null,
        transform: Transform(anchor: track([0.5, 0.5]), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
        content: Content(shape: 'circle', offset: [0, 0], size: [100, 100], sides: 48),
      );
      final inst = createEffectInstance('corner_pin', 'fx1', layer);
      layer.effectStack.add(inst);
      project.layers.add(layer);

      final handles = getCornerPinHandles(project, layer, inst, 0);
      expect(handles.keys, equals(['tl', 'tr', 'br', 'bl']));
      expect(handles.natural['tl'], equals([-50.0, -50.0]));
      expect(handles.screen['tl'], equals([270, 150]));
    });
  });

  group('getMeshWarpHandles', () {
    test('4x4 grid: corner pins land at the bbox corners plus this frame\'s offset', () {
      registerBuiltinEffects();
      final layer = _rectLayer();
      final inst = createEffectInstance('mesh_warp', 'fx1', layer);
      (inst.params['r0c0'] as Track).defaultValue = [5.0, -2.0];
      layer.effectStack.add(inst);
      project.layers.add(layer);

      final mesh = getMeshWarpHandles(project, layer, inst, 0);
      expect(mesh.rows, equals(4));
      expect(mesh.cols, equals(4));
      final r0c0 = mesh.handles.firstWhere((h) => h.key == 'r0c0');
      expect(r0c0.natural, equals([-50.0, -30.0])); // bbox top-left
      expect(r0c0.screen, equals([-50 + 5.0 + 320, -30 - 2.0 + 200]));

      final r3c3 = mesh.handles.firstWhere((h) => h.key == 'r3c3');
      expect(r3c3.natural, equals([50.0, 30.0])); // bbox bottom-right, default offset [0,0]
      expect(r3c3.screen, equals([370, 230]));
    });
  });

  group('getEffectDeformationGridScreen', () {
    test('null when the layer has no enabled effect at all', () {
      final layer = _rectLayer();
      project.layers.add(layer);
      expect(getEffectDeformationGridScreen(project, layer, 0), isNull);
    });

    test('reflects the ACTUAL deformation from squeeze_axis, not just an undeformed preview grid', () {
      registerBuiltinEffects();
      final layer = _rectLayer(anchor: [0.5, 0.5], size: [100, 60]);
      final inst = createEffectInstance('squeeze_axis', 'fx1', layer);
      inst.params['axisX'] = track(2.0); // double the horizontal extent
      layer.effectStack.add(inst);
      project.layers.add(layer);

      final grid = getEffectDeformationGridScreen(project, layer, 0, n: 3);
      expect(grid, isNotNull);
      expect(grid!.rows, equals(3));
      expect(grid.cols, equals(3));
      expect(grid.screen.length, equals(9));

      // center row's leftmost point: undeformed bbox left edge is
      // x=-50 (local), squeezed 2x around the shape's own center
      // (x=0) -> x=-100 local -> screen 320-100=220. Right edge
      // mirrors to 420. If this test only checked "some grid exists"
      // without pinning actual deformed coordinates, an accidental
      // no-op (e.g. always sampling the pristine srcGrid instead of
      // applyEffectStack's dstGrid) would slip through undetected.
      final xs = [for (final p in grid.screen) p[0]];
      expect(xs.reduce((a, b) => a < b ? a : b), equals(220));
      expect(xs.reduce((a, b) => a > b ? a : b), equals(420));
    });

    test('null once the only effect instance is disabled', () {
      registerBuiltinEffects();
      final layer = _rectLayer();
      final inst = createEffectInstance('squeeze_axis', 'fx1', layer);
      inst.enabled = false;
      layer.effectStack.add(inst);
      project.layers.add(layer);

      expect(getEffectDeformationGridScreen(project, layer, 0), isNull);
    });
  });

  group('getPendulumPivotHandleScreen', () {
    test('uses the BASE (pre-swing) matrix - screen = pivotOffset default, transformed', () {
      final layer = _rectLayer();
      layer.pendulum = Pendulum(enabled: true, pivotOffset: track([10.0, -5.0], true));
      project.layers.add(layer);

      // static anchor (no keyframes) never excites the swing (see
      // pendulum_test.dart's own "no phantom swing" case) - baseMatrix
      // == matrix here, both the same identity+translation as the
      // plain rect layer above.
      final handle = getPendulumPivotHandleScreen(project, layer, 200);
      expect(handle.screen, equals([330, 195]));
    });
  });

  group('path: getAnchorStationsScreen + samplePathScreen', () {
    test('stations sit at each keyframe\'s own value; path samples at the endpoints match the stations exactly', () {
      final layer = _rectLayer(anchor: [0.5, 0.5]);
      layer.transform.anchor.spatial = true;
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.2, 0.5]),
        Keyframe(frame: 30, value: [0.8, 0.5]),
      ]);
      project.layers.add(layer);

      final stations = getAnchorStationsScreen(project, layer, 0);
      expect(stations.length, equals(2));
      expect(stations[0].screen, equals([0.2 * 640, 0.5 * 400]));
      expect(stations[1].screen, equals([0.8 * 640, 0.5 * 400]));

      // the centre's real path, about every frame of the layer (180).
      final samples = samplePathScreen(project, layer, 1);
      expect(samples.length, equals(layer.durationFrames + 1));
      expect(samples.first, equals(stations[0].screen));
      expect(samples.last, equals(stations[1].screen));
    });

    test('the path is where the centre really goes - also when only an animation layer moves it', () {
      final layer = _rectLayer(anchor: [0.5, 0.5]);
      addTransformAnimLayer(layer);
      layer.transform.anchor.animLayers.single.track.keyframes.addAll([
        Keyframe(frame: 0, value: [0.0, 0.0]),
        Keyframe(frame: 60, value: [0.0, 0.25]),
      ]);
      project.layers.add(layer);
      final samples = samplePathScreen(project, layer, 5);
      expect(samples, isNotEmpty);
      expect(samples.first, [320, 200]);
      expect(samples.last, [320, 300], reason: 'the layer\'s sway shows in the path');
    });

    test('non-spatial or single-keyframe tracks produce no stations/path samples', () {
      final layer = _rectLayer();
      project.layers.add(layer);
      expect(getAnchorStationsScreen(project, layer, 0), isEmpty);
      expect(samplePathScreen(project, layer, 10), isEmpty);
    });
  });

  group('instance lookups', () {
    test('getActiveMeshOrPinInstance/getCornerPinInstance/getMeshWarpInstance find only enabled instances', () {
      registerBuiltinEffects();
      final layer = _rectLayer();
      final inst = createEffectInstance('mesh_warp', 'fx1', layer)..enabled = false;
      layer.effectStack.add(inst);
      expect(getMeshWarpInstance(layer), isNull); // disabled -> not found
      expect(getActiveMeshOrPinInstance(layer), isNull);
      inst.enabled = true;
      expect(getMeshWarpInstance(layer), same(inst));
      expect(getActiveMeshOrPinInstance(layer), same(inst));
      expect(getCornerPinInstance(layer), isNull);
    });
  });

  group('distToSegment / distToPolyline', () {
    test('distance from a point to a polyline is the min distance to any of its segments', () {
      final poly = [
        [0.0, 0.0],
        [10.0, 0.0],
        [10.0, 10.0],
      ];
      expect(distToPolyline([5.0, 0.0], poly), closeTo(0, 1e-9)); // on the first segment
      expect(distToPolyline([10.0, 5.0], poly), closeTo(0, 1e-9)); // on the second segment
      expect(distToPolyline([5.0, 5.0], poly), closeTo(5.0, 1e-9)); // equidistant from both segments
    });
  });
}
