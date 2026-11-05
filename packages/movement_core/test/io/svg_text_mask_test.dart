import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  test('a masked text is clipped by its mask in SVG; a masked shape is cut to it', () {
    stageSize.width = 480;
    stageSize.height = 480;
    final project = Project(fps: 30);
    final r = createLayer('rect', size: 200);
    final c = createLayer('circle', size: 100)..hidden = true;
    final t = createTextLayer(text: 'Hi', fontSize: 80);
    project.layers.addAll([r, c, t]);
    r.masks.add(Mask(sourceLayerId: c.id));
    t.masks.add(Mask(sourceLayerId: c.id));
    final svg = exportProjectToSvg(project, 0, 480, 480);
    expect(svg, contains('<clipPath id="mask-${t.id}"'));
    expect(svg, contains('clip-path="url(#mask-${t.id})"'));
    expect(svg, isNot(contains('<rect')), reason: 'the rect is drawn as its masked outline');
  });

  test('animated SVG: a shape that changes over time (a line drawn on) steps through its shapes', () {
    stageSize.width = 480;
    stageSize.height = 480;
    final project = Project(fps: 30);
    final l = createLayer('line')..durationFrames = 10;
    l.content.lineTrimEnd = Track(1.0, false)
      ..keyframes = [
        Keyframe(frame: 0, value: 0.1, temporal: const Easing(0, 0, 1, 1)),
        Keyframe(frame: 9, value: 1.0, temporal: const Easing(0, 0, 1, 1)),
      ];
    project.layers.add(l);
    final svg = exportProjectToAnimatedSvg(project, 0, 9, 30, 480, 480);
    expect('attributeName="display"'.allMatches(svg).length, greaterThan(3));
    // a still one stays one element.
    l.content.lineTrimEnd = null;
    final still = exportProjectToAnimatedSvg(project, 0, 9, 30, 480, 480);
    expect(still, isNot(contains('attributeName="display"')));
  });
}
