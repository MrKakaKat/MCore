import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    fps = 60;
    setStageSize(200, 100);
    clearStateCaches();
  });

  Layer trail() {
    final t = createTrailLayer()
      ..id = 't'
      ..startFrame = 0
      ..durationFrames = 60;
    t.transform.anchor.keyframes
      ..add(Keyframe(frame: 0, value: [0.1, 0.5], temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 40, value: [0.9, 0.5], temporal: const Easing(0, 0, 1, 1)));
    return t;
  }

  test('a moving trail point leaves a line up to the playhead', () {
    final t = trail();
    final p = Project(layers: [t]);
    final at20 = trailPolylines(p, t, 20).single;
    expect(at20.first[0], closeTo(20, 1e-6));
    expect(at20.last[0], closeTo(100, 1e-6));
    expect(trailPolylines(p, t, 40).single.last[0], closeTo(180, 1e-6));
  });

  test('the drawing switch is stepped: off and on again breaks the line, what is drawn stays', () {
    final t = trail();
    t.content.trailOn!.keyframes
      ..add(Keyframe(frame: 0, value: 1.0))
      ..add(Keyframe(frame: 10, value: 0.0))
      ..add(Keyframe(frame: 30, value: 1.0));
    final p = Project(layers: [t]);
    expect(trailDrawingAt(t.content, 9), isTrue);
    expect(trailDrawingAt(t.content, 10), isFalse);
    expect(trailDrawingAt(t.content, 29), isFalse, reason: 'no easing between the keys');
    final lines = trailPolylines(p, t, 40);
    expect(lines.length, 2);
    expect(lines[0].last[0], closeTo(20 + 9 * 4, 1e-6));
    expect(lines[1].first[0], closeTo(20 + 30 * 4, 1e-6));
  });

  test('carried by a parent it leaves a trail too; saved and loaded', () {
    final parent = createLayer('rect')
      ..id = 'p'
      ..startFrame = 0
      ..durationFrames = 60;
    parent.transform.anchor.keyframes
      ..add(Keyframe(frame: 0, value: [0.2, 0.2], temporal: const Easing(0, 0, 1, 1)))
      ..add(Keyframe(frame: 20, value: [0.2, 0.8], temporal: const Easing(0, 0, 1, 1)));
    final t = createTrailLayer()
      ..id = 't'
      ..startFrame = 0
      ..durationFrames = 60
      ..parentId = 'p';
    t.transform.anchor.defaultValue = [0.0, 0.0];
    final p = Project(layers: [parent, t]);
    final line = trailPolylines(p, t, 20).single;
    expect(line.last[1] - line.first[1], closeTo(60, 1e-6));
    final back = layerFromJson(layerToJson(t));
    expect(back.content.shape, 'trail');
    expect(back.content.trailOn, isNotNull);
    // the SVG has it as a stroked path.
    expect(exportProjectToSvg(p, 20, 200, 100), contains('stroke-linecap="round"'));
  });

  test('lens: 50 degrees shows (nearly) what is there; wide looks further out, narrow closer in', () {
    expect(lensSourceRadius(1, 50, 1), closeTo(1, 1e-9));
    expect(lensSourceRadius(1, 150, 1), greaterThan(5));
    expect(lensSourceRadius(1, 10, 1), lessThan(0.25));
    expect(lensSourceRadius(1, 50, 2), closeTo(0.5, 1e-9));
  });
}
