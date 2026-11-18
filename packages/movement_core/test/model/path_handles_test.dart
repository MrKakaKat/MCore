import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 600);
    clearStateCaches();
  });
  test('a path key\'s curve handle dragged bends the way; the tension no longer resets it', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 100;
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: <double>[0.2, 0.5]),
      Keyframe(frame: 50, value: <double>[0.5, 0.5]),
      Keyframe(frame: 100, value: <double>[0.8, 0.5]),
    ];
    final p = Project(layers: [l]);
    autoComputeTangents(l.transform.anchor);
    expect(getPathTangentHandlesScreen(p, l), isEmpty, reason: 'off: none');
    startHandTangents(l.transform.anchor);
    final hs = getPathTangentHandlesScreen(p, l);
    expect(hs.length, 4);
    final h = hs.firstWhere((h) => h.idx == 1 && h.out);
    final op = TangentDragOp(layer: l, idx: 1, out: true, station: h.station);
    op.apply(p, 0, [h.station[0] + 100, h.station[1] - 120]);
    final k = l.transform.anchor.keyframes[1];
    expect(k.spatialTangent.outTan[0], closeTo(0.1, 1e-9));
    expect(k.spatialTangent.outTan[1], closeTo(-0.2, 1e-9));
    // the one across turned with it.
    expect(k.spatialTangent.inTan[0], lessThan(0));
    expect(k.spatialTangent.inTan[1], greaterThan(0));
    clearStateCaches();
    final mid = evaluateTrack(p, l.transform.anchor, 75.0) as List<double>;
    expect(mid[1], lessThan(0.5), reason: 'the way bends up after the key');
    autoComputeTangents(l.transform.anchor);
    expect(k.spatialTangent.outTan[1], closeTo(-0.2, 1e-9), reason: 'kept');
  });
}
