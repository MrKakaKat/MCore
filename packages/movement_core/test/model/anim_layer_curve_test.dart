import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    activeAnimLayer = 0;
  });

  test('a key layer\'s place is a way: its curve handles bend it (as the base keys\')', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 100;
    l.transform.anchor.defaultValue = <double>[0.5, 0.5];
    final n = addTransformAnimLayer(l);
    final t = l.transform.anchor.animLayers[n - 1].track;
    expect(t.spatial, isTrue);
    t.keyframes = [
      Keyframe(frame: 0, value: <double>[0.0, 0.0], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 100, value: <double>[0.2, 0.0], temporal: const Easing(0, 0, 1, 1)),
    ];
    final p = Project(layers: [l]);
    double y(int f) => (evaluateTrack(p, l.transform.anchor, f.toDouble(), l) as List<double>)[1];
    expect(y(50), closeTo(0.5, 1e-9), reason: 'flat handles: straight, as before');
    activeAnimLayer = n;
    startHandTangents(t);
    t.keyframes.first.spatialTangent = SpatialTangent(inTan: [0, 0], outTan: [0.0, -0.2]);
    clearStateCaches();
    expect(y(50), lessThan(0.45), reason: 'bent up by its handle');
    expect(getPathTangentHandlesScreen(p, l), isNotEmpty);
  });

  test('older key layers (their place not a way) become one, nothing moving', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 100;
    final n = addTransformAnimLayer(l);
    final t = l.transform.anchor.animLayers[n - 1].track..spatial = false;
    t.keyframes = [Keyframe(frame: 0, value: <double>[0.0, 0.0]), Keyframe(frame: 100, value: <double>[0.2, 0.1])];
    final p = Project(layers: [l]);
    final before = evaluateTrack(p, l.transform.anchor, 30, l) as List<double>;
    tidyAnimLayers(l);
    expect(t.spatial, isTrue);
    clearStateCaches();
    final after = evaluateTrack(p, l.transform.anchor, 30, l) as List<double>;
    expect(after[0], closeTo(before[0], 1e-12));
    expect(after[1], closeTo(before[1], 1e-12));
  });
}
