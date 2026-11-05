import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  test('animated SVG: a moving shape gets transform animations; it parses', () {
    final l = createLayer('rect')..durationFrames = 60;
    l.transform.anchor.keyframes
      ..add(Keyframe(frame: 0, value: [0.2, 0.5]))
      ..add(Keyframe(frame: 59, value: [0.8, 0.5]));
    final still = createLayer('line')..durationFrames = 60;
    final p = Project(layers: [l, still]);
    final svg = exportProjectToAnimatedSvg(p, 0, 59, 30, 480, 270);
    final doc = XmlDocument.parse(svg);
    final groups = doc.findAllElements('g').toList();
    expect(groups.length, 2);
    expect(groups[0].findElements('animateTransform').length, 4);
    expect(groups[1].findElements('animateTransform'), isEmpty, reason: 'a still line stays a plain transform');
    expect(groups[1].findElements('path'), hasLength(1), reason: 'a line is a stroked path');
    expect(svg, contains('dur="2s"'));
  });
}
