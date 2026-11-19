import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  Track track() {
    final t = Track(0.0);
    t.keyframes = [
      Keyframe(frame: 0, value: 0.0, temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 10, value: 10.0, temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 20, value: 30.0, temporal: const Easing(0, 0, 1, 1)),
    ];
    t.loop = true;
    return t;
  }

  double at(Track t, double f) => (evaluateTrack(null, t, f) as num).toDouble();

  test('loop from a key: the keys before it play once, the rest repeats', () {
    final t = track()..loopFrom = 10;
    expect(at(t, 5), 5, reason: 'the start, once');
    expect(at(t, 25), 20, reason: 'again from the key at 10 (10 frames: 10 -> 30)');
    expect(at(t, 30), 10, reason: 'and again');
    expect(at(t, 35), 20);
    // the whole loop as before without it.
    final w = track();
    expect(at(w, 25), 5);
  });

  test('loop until a frame: after it, held where it got to', () {
    final t = track()..loopEnd = 35;
    expect(at(t, 25), 5);
    expect(at(t, 35), 20);
    expect(at(t, 50), 20, reason: 'held');
    expect(at(t, 200), 20);
  });

  test('offset loop from a key: each pass goes on from where the last ended', () {
    final t = track()
      ..loopFrom = 10
      ..loopMode = 'offset';
    expect(at(t, 25), closeTo(40, 1e-9), reason: 'second pass: 30 -> 50');
    expect(at(t, 35), closeTo(60, 1e-9), reason: 'third: 50 -> 70');
  });

  test('set for the layer: every looping parameter, each from its own key at or before', () {
    final l = createLayer('rect')..durationFrames = 100;
    l.transform.rotation.keyframes = [Keyframe(frame: 0, value: 0.0), Keyframe(frame: 8, value: 5.0), Keyframe(frame: 20, value: 9.0)];
    l.transform.rotation.loop = true;
    expect(loopStartFrames(l), [0, 8]);
    setLayerLoopRange(l, from: 8, end: 60);
    expect(l.transform.rotation.loopFrom, 8);
    expect(l.transform.rotation.loopEnd, 60);
    final back = layerFromJson(layerToJson(l));
    expect(back.transform.rotation.loopFrom, 8);
    expect(back.transform.rotation.loopEnd, 60);
  });

  test('the loop\'s faint repeated keys on the key rows: from its loop key, none past until frame', () {
    final l = createLayer('rect')..durationFrames = 200;
    l.transform.rotation.keyframes = [Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 5.0), Keyframe(frame: 20, value: 9.0)];
    l.transform.rotation.loop = true;
    var g = keyDetailLoopGhosts(l).values.first;
    expect(g.keys.reduce((a, b) => a > b ? a : b), greaterThan(150), reason: 'on to the end');
    setLayerLoopRange(l, from: 10, end: 55);
    g = keyDetailLoopGhosts(l).values.first;
    expect(g.keys, [30, 40, 50], reason: 'every 10 frames from the key at 10, none after 55');
    expect(g.spans.last.$2, 55);
  });
}
