import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });
  tearDown(() {
    keyMode = 'base';
    activeAnimLayer = 0;
  });

  test('order keys: each pair of keys is a movement layer of its own; rows show A..C and B..D apart', () {
    final l = createLayer('rect')..durationFrames = 100;
    final p = Project(layers: [l]);
    keyMode = 'order';
    keyAllTracks(p, l, 0); // A: opens layer 1
    expect(openOrderLayer(l), 1);
    keyAllTracks(p, l, 20); // B: closes layer 1? no - frames A and B
    expect(openOrderLayer(l), isNull, reason: 'the second key closes the range');
    keyAllTracks(p, l, 10); // C: opens layer 2
    expect(openOrderLayer(l), 2);
    keyAllTracks(p, l, 40); // D: closes layer 2
    expect(l.transform.anchor.keyframes, isEmpty, reason: 'nothing in the base');
    final rows = keyDetailRows(l);
    expect(rows['Layer 1'], [0, 20]);
    expect(rows['Layer 2'], [10, 40], reason: 'the layers overlap but keep their own spans');
  });

  test('a layer key moved on the stage moves the stop, and the stops are that layer\'s keys', () {
    final l = createLayer('rect')..durationFrames = 100;
    final p = Project(layers: [l]);
    addTransformAnimLayer(l);
    activeAnimLayer = 1;
    final t = l.transform.anchor.animLayers.single.track;
    t.keyframes.addAll([Keyframe(frame: 0, value: [0.0, 0.0]), Keyframe(frame: 50, value: [0.1, 0.0])]);
    final stations = getAnchorStationsScreen(p, l, 0);
    expect(stations, hasLength(2));
    expect(stations[1].screen[0], closeTo(0.6 * 200, 1e-9));
    final op = StationDragOp.grab(p, l, 1, 50, stations[1].screen);
    op.apply(p, 50, [stations[1].screen[0] + 20, stations[1].screen[1]]);
    expect((t.keyframes[1].value as List<double>)[0], closeTo(0.2, 1e-9));
    expect(l.transform.anchor.defaultValue, [0.5, 0.5], reason: 'the base is untouched');
  });

  test('ranges that don\'t overlap share one layer, the movement unchanged', () {
    final l = createLayer('rect')..durationFrames = 100;
    final p = Project(layers: [l]);
    keyMode = 'order';
    keyAllTracks(p, l, 0);
    keyAllTracks(p, l, 20);
    // the first range moves the object right by 0.2.
    setTrackValueAt(l.transform.anchor, 20, [0.7, 0.5]);
    keyAllTracks(p, l, 40);
    keyAllTracks(p, l, 60);
    expect(l.transform.anchor.animLayers, hasLength(1), reason: '40..60 fits after 0..20 in the same layer');
    setTrackValueAt(l.transform.anchor, 60, [0.7, 0.8]);
    List<double> at(int f) => evaluateTrack(null, l.transform.anchor, f.toDouble()) as List<double>;
    expect(at(30), [closeTo(0.7, 1e-9), closeTo(0.5, 1e-9)], reason: 'holds between the ranges');
    expect(at(60), [closeTo(0.7, 1e-9), closeTo(0.8, 1e-9)]);
    // an overlapping range gets a layer of its own.
    keyAllTracks(p, l, 10);
    keyAllTracks(p, l, 50);
    expect(l.transform.anchor.animLayers, hasLength(2));
  });

  test('merging two layers keeps the total exactly', () {
    final l = createLayer('rect')..durationFrames = 100;
    addTransformAnimLayer(l);
    addTransformAnimLayer(l);
    final a = l.transform.rotation.animLayers[0].track, b = l.transform.rotation.animLayers[1].track;
    a.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 30.0)]);
    b.keyframes.addAll([Keyframe(frame: 50, value: 5.0), Keyframe(frame: 70, value: -10.0)]);
    final before = [for (var f = 0; f <= 100; f += 5) evaluateTrack(null, l.transform.rotation, f.toDouble()) as double];
    mergeAnimLayerInto(l, 1, 2);
    expect(l.transform.rotation.animLayers, hasLength(1));
    final after = [for (var f = 0; f <= 100; f += 5) evaluateTrack(null, l.transform.rotation, f.toDouble()) as double];
    for (var i = 0; i < before.length; i++) {
      expect(after[i], closeTo(before[i], 1e-9), reason: 'frame ${i * 5}');
    }
  });
}
