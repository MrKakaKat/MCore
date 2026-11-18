import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    activeAnimLayer = 0;
  });

  Layer layer() => createLayer('rect')
    ..id = 'A'
    ..durationFrames = 200
    ..transform.anchor.defaultValue = <double>[0.5, 0.5];

  List<double> at(Project p, int f) => evaluateTrack(p, p.layers.first.transform.anchor, f.toDouble(), p.layers.first) as List<double>;

  test('a key layer made from its end back: before it, where it starts - no jump at its first key', () {
    final l = layer();
    final p = Project(layers: [l]);
    final n = addTransformAnimLayer(l);
    final t = l.transform.anchor.animLayers[n - 1].track;
    // its first key at 100 (as it is), then one at 20 moved by 0.2.
    t.keyframes = [Keyframe(frame: 100, value: <double>[0.0, 0.0])];
    tidyAnimLayers(l);
    expect(t.openedAt, 100);
    t.keyframes = [Keyframe(frame: 20, value: <double>[0.2, 0.0]), ...t.keyframes];
    tidyAnimLayers(l);
    clearStateCaches();
    expect(at(p, 0)[0], closeTo(0.7, 1e-9), reason: 'before it: where it starts');
    expect(at(p, 19)[0], closeTo(0.7, 1e-9));
    expect(at(p, 20)[0], closeTo(0.7, 1e-9));
    expect(at(p, 150)[0], closeTo(0.5, 1e-9), reason: 'after it: where it ends');
    // saved and opened again: the same.
    final p2 = Project(layers: projectLayersFromJson(projectLayersToJson(p)));
    expect((evaluateTrack(p2, p2.layers.first.transform.anchor, 0, p2.layers.first) as List<double>)[0], closeTo(0.7, 1e-9));
  });

  test('made from its start on: before it, its first key too (as the base keys)', () {
    final l = layer();
    final p = Project(layers: [l]);
    final n = addTransformAnimLayer(l);
    final t = l.transform.anchor.animLayers[n - 1].track;
    t.keyframes = [Keyframe(frame: 20, value: <double>[0.2, 0.0])];
    tidyAnimLayers(l);
    t.keyframes.add(Keyframe(frame: 100, value: <double>[0.0, 0.0]));
    tidyAnimLayers(l);
    clearStateCaches();
    expect(at(p, 0)[0], closeTo(0.7, 1e-9));
    expect(at(p, 20)[0], closeTo(0.7, 1e-9));
  });

  test('keys of a key layer all taken away: the layer goes, the edited one follows', () {
    final l = layer();
    for (var i = 0; i < 3; i++) {
      final n = addTransformAnimLayer(l);
      l.transform.anchor.animLayers[n - 1].track.keyframes = [Keyframe(frame: 10 * i, value: <double>[0.1, 0.0])];
    }
    tidyAnimLayers(l, selected: true);
    activeAnimLayer = 3;
    l.transform.anchor.animLayers[1].track.keyframes.clear();
    expect(tidyAnimLayers(l, selected: true), isTrue);
    expect(l.transform.anchor.animLayers.length, 2);
    expect(l.transform.rotation.animLayers.length, 2);
    expect(activeAnimLayer, 2, reason: 'the third is the second now');
    // a new, never keyed layer stays (it is waiting for keys).
    addTransformAnimLayer(l);
    tidyAnimLayers(l, selected: true);
    expect(l.transform.anchor.animLayers.length, 3);
  });

  test('order keys from the end back after an earlier range: comes in from its end, nothing before shifted', () {
    final l = layer();
    // an earlier range, left to right.
    var n = orderKeyTarget(l, 0);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [Keyframe(frame: 0, value: <double>[0.0, 0.0])];
    tidyAnimLayers(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes.add(Keyframe(frame: 10, value: <double>[0.1, 0.0]));
    packOrderLayer(l, n);
    tidyAnimLayers(l);
    // a later one made from its end (100) back to 50.
    n = orderKeyTarget(l, 100);
    expect(n, 2);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [Keyframe(frame: 100, value: <double>[0.0, 0.0])];
    tidyAnimLayers(l);
    expect(orderKeyTarget(l, 50), 2, reason: 'closes it');
    l.transform.anchor.animLayers[1].track.keyframes.insert(0, Keyframe(frame: 50, value: <double>[0.0, 0.2]));
    final p = Project(layers: [l]);
    clearStateCaches();
    final before = [for (final f in [0, 5, 10, 30, 50, 75, 100]) at(p, f)];
    expect(before[1], [closeTo(0.55, 1e-9), closeTo(0.5, 1e-9)], reason: 'the earlier range as it was');
    expect(before[2], [closeTo(0.6, 1e-9), closeTo(0.5, 1e-9)]);
    expect(before[3][1], closeTo(0.6, 1e-9), reason: 'coming in from frame 10 to 50');
    expect(before[4], [closeTo(0.6, 1e-9), closeTo(0.7, 1e-9)]);
    expect(before[6], [closeTo(0.6, 1e-9), closeTo(0.5, 1e-9)]);
    // packed into one layer: exactly the same.
    expect(packOrderLayer(l, 2), 1);
    clearStateCaches();
    final after = [for (final f in [0, 5, 10, 30, 50, 75, 100]) at(p, f)];
    for (var i = 0; i < after.length; i++) {
      expect(after[i][0], closeTo(before[i][0], 1e-9));
      expect(after[i][1], closeTo(before[i][1], 1e-9));
    }
  });

  test('order keys: a key at 15, the object moved at 5 - a key at 5 closes the range, 15 stays where it was', () {
    keyMode = 'order';
    final l = layer();
    final p = Project(layers: [l]);
    orderKeyTarget(l, 15);
    final t = l.transform.anchor.animLayers[activeAnimLayer - 1].track;
    t.keyframes = [Keyframe(frame: 15, value: <double>[0.0, 0.0])];
    tidyAnimLayers(l, selected: true);
    clearStateCaches();
    List<double> c(int f) => computeLayerFrameGeometry(p, l, f, includeVertices: false).center;
    final at5 = c(5);
    final op = AnchorDragOp.grab(p, l, 5, at5);
    op.apply(p, 5, [at5[0] - 200, at5[1] + 80]);
    tidyAnimLayers(l, selected: true);
    clearStateCaches();
    expect(t.keyframes.map((k) => k.frame), [5, 15]);
    expect(c(15), [closeTo(500, 1e-6), closeTo(500, 1e-6)], reason: 'its end where it was');
    expect(c(0), [closeTo(300, 1e-6), closeTo(580, 1e-6)], reason: 'before it: where it starts');
    expect(c(5), [closeTo(300, 1e-6), closeTo(580, 1e-6)]);
    keyMode = 'base';
  });

  test('an appearance in a key layer (opacity 0 to 1 from frame 30): hidden before it, as with the base keys', () {
    final l = layer();
    final n = addTransformAnimLayer(l);
    l.transform.opacity.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 30, value: 0.0),
      Keyframe(frame: 60, value: 1.0),
    ];
    final p = Project(layers: [l]);
    double op(int f) => evaluateTrack(p, l.transform.opacity, f.toDouble(), l) as double;
    expect(op(0), 0);
    expect(op(29), 0);
    expect(op(45), closeTo(0.5, 0.2));
    expect(op(90), 1);
  });

  test('a later range in its own layer: what comes before stays, it comes in from there without a jump', () {
    final l = layer();
    var n = addTransformAnimLayer(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 0, value: <double>[0.0, 0.0]),
      Keyframe(frame: 10, value: <double>[0.1, 0.0]),
    ];
    n = addTransformAnimLayer(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 40, value: <double>[0.0, 0.2]),
      Keyframe(frame: 60, value: <double>[0.0, 0.3]),
    ];
    final p = Project(layers: [l]);
    expect(at(p, 5), [closeTo(0.55, 1e-9), closeTo(0.5, 1e-9)], reason: 'the first range as it was');
    expect(at(p, 10), [closeTo(0.6, 1e-9), closeTo(0.5, 1e-9)]);
    expect(at(p, 25)[1], closeTo(0.6, 1e-9), reason: 'half way in');
    expect(at(p, 40), [closeTo(0.6, 1e-9), closeTo(0.7, 1e-9)]);
  });
}
