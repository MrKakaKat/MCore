import 'dart:math' as math;
import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
    activeAnimLayer = 0;
    keyMode = 'base';
  });
  tearDown(() => keyMode = 'base');

  test('a drawn way takes its end key\'s ease over the whole way', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 200;
    l.transform.anchor.defaultValue = <double>[0.2, 0.5];
    final p = Project(layers: [l]);
    final path = [for (var i = 0; i <= 60; i++) [200.0 + i * 10, 500 + 80 * math.sin(i / 60 * 2 * math.pi)]];
    expect(addFreeMoveInto(p, l, l.transform.anchor, path, 0, 100, smoothing: 0), isTrue);
    final trk = l.transform.anchor;
    final end = trk.keyframes.lastWhere((k) => !k.passive);
    end.temporal = const Easing(0, 0, 1, 1);
    clearStateCaches();
    double x(int f) => (evaluateTrack(p, trk, f.toDouble(), l) as List<double>)[0];
    final linearQuarter = x(25) - x(0);
    end.temporal = const Easing(0.6, 0, 1, 1); // a slow start
    clearStateCaches();
    expect(x(25) - x(0), lessThan(linearQuarter * 0.7), reason: 'slower at first');
    expect(x(100), closeTo(0.8, 1e-6), reason: 'still ends where it ends');
  });

  test('order keys: the stage edit goes to the range at the playhead, outside them to the object\'s own keys', () {
    keyMode = 'order';
    final l = createLayer('rect')..id = 'A'..durationFrames = 200;
    var n = addTransformAnimLayer(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 10, value: <double>[0.0, 0.0]),
      Keyframe(frame: 40, value: <double>[0.1, 0.0]),
    ];
    n = addTransformAnimLayer(l);
    l.transform.anchor.animLayers[n - 1].track.keyframes = [
      Keyframe(frame: 80, value: <double>[0.0, 0.0]),
      Keyframe(frame: 120, value: <double>[0.0, 0.1]),
    ];
    orderEditLayerAt(l, 20);
    expect(activeAnimLayer, 1);
    orderEditLayerAt(l, 100);
    expect(activeAnimLayer, 2);
    orderEditLayerAt(l, 0);
    expect(activeAnimLayer, 0, reason: 'its start: its own place');
    orderEditLayerAt(l, 60);
    expect(activeAnimLayer, 0);
  });

  test('every key layer\'s stops can be picked and moved, not only the edited one\'s', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 200;
    l.transform.anchor.defaultValue = <double>[0.5, 0.5];
    final p = Project(layers: [l]);
    for (final fs in [
      [10, 40],
      [80, 120]
    ]) {
      final n = addTransformAnimLayer(l);
      l.transform.anchor.animLayers[n - 1].track.keyframes = [
        Keyframe(frame: fs[0], value: <double>[0.0, 0.0]),
        Keyframe(frame: fs[1], value: <double>[0.1, 0.0]),
      ];
    }
    activeAnimLayer = 2;
    final st = getAnchorStationsScreen(p, l, 0);
    final first = st.firstWhere((s) => s.track != null && identical(s.track, l.transform.anchor.animLayers[0].track) && s.idx == 1);
    final op = StationDragOp.grab(p, l, first.idx, 40, first.screen, track: first.track);
    op.apply(p, 40, [first.screen[0], first.screen[1] + 100]);
    expect(l.transform.anchor.animLayers[0].track.keyframes[1].value, [closeTo(0.1, 1e-9), closeTo(0.1, 1e-9)]);
  });
}
