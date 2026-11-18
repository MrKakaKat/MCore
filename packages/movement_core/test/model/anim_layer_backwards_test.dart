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

  test('made from its start on: nothing before its first key (as before)', () {
    final l = layer();
    final p = Project(layers: [l]);
    final n = addTransformAnimLayer(l);
    final t = l.transform.anchor.animLayers[n - 1].track;
    t.keyframes = [Keyframe(frame: 20, value: <double>[0.2, 0.0])];
    tidyAnimLayers(l);
    t.keyframes.add(Keyframe(frame: 100, value: <double>[0.0, 0.0]));
    tidyAnimLayers(l);
    clearStateCaches();
    expect(at(p, 0)[0], closeTo(0.5, 1e-9));
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

  test('order keys from the end back: kept a layer of its own, holding its start before it', () {
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
    expect(packOrderLayer(l, 2), 2, reason: 'not merged into the earlier one');
    tidyAnimLayers(l);
    final p = Project(layers: [l]);
    clearStateCaches();
    expect(at(p, 30), [closeTo(0.6, 1e-9), closeTo(0.7, 1e-9)]);
    expect(at(p, 5)[1], closeTo(0.7, 1e-9));
  });
}
