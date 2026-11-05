import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    registerFont(defaultFontId, File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });
  setUp(() {
    setStageSize(1000, 1000);
    fps = 60;
    clearShadowLagCaches();
    clearStateCaches();
  });

  Layer textLayer(String text) => createLayer('text')
    ..id = 'T'
    ..startFrame = 0
    ..durationFrames = 300
    ..content.text = (TextSpec(text: text, fontSize: 60)..shadow.enabled = true)
    ..transform.anchor.defaultValue = [0.3, 0.5];

  Float64List? lagAt(Project p, int f) {
    clearStateCaches();
    return textShadowLag(p, findLayer(p, 'T')!, f);
  }

  test('lag off: none; the JSON stays as before', () {
    final l = textLayer('Hi');
    final p = Project(layers: [l]);
    expect(lagAt(p, 50), isNull);
    final j = textSpecToJson(l.content.text!)['shadow'] as Map;
    expect(j.keys.toSet(), {'enabled', 'dx', 'dy', 'color', 'opacity'});
  });

  test('lag on, text still: the shadow sits in its usual place', () {
    final l = textLayer('Hi');
    l.content.text!.shadow.lag = true;
    final p = Project(layers: [l]);
    for (final f in [0, 30, 299]) {
      expect(lagAt(p, f)!.toList(), [0.0, 0.0]);
    }
  });

  test('lag on, text moves: the shadow trails, then settles', () {
    final l = textLayer('Hi');
    l.content.text!.shadow
      ..lag = true
      ..lagBounciness = 0;
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [0.3, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 20, value: [0.7, 0.5]),
    ];
    final p = Project(layers: [l]);
    expect(lagAt(p, 15)![0], lessThan(-5), reason: 'behind: to the left of a text moving right');
    expect(lagAt(p, 250)![0].abs(), lessThan(0.5));
  });

  test('per letter: each unit has its own spring', () {
    final l = textLayer('ab');
    final t = l.content.text!;
    t.shadow
      ..lag = true
      ..perLetter = true;
    // a drop of the second letter only (a still first letter).
    final a = textAnimatorPreset('Drop in');
    t.animators.add(a);
    final p = Project(layers: [l]);
    var moving = false;
    for (var f = 1; f < 60; f++) {
      final lag = lagAt(p, f)!;
      expect(lag.length, 4, reason: 'two units');
      if ((lag[1] - lag[3]).abs() > 1e-6) moving = true;
    }
    expect(moving, isTrue, reason: 'letters dropping at different times lag differently');
  });

  test('old projects load: a shadow without the lag fields', () {
    final j = jsonDecode('{"text":"x","shadow":{"enabled":true,"dx":3,"dy":2,"color":"#000000","opacity":0.5}}');
    final t = textSpecFromJson(j as Map<String, dynamic>);
    expect(t.shadow.lag, isFalse);
    expect(t.shadow.lagSpeed, 60);
    expect(t.shadow.perLetter, isFalse);
    expect(t.shadow.dx, 3);
  });

  test('a shape shadow lags too: behind while moving, settled at rest', () {
    final l = createLayer('rect')
      ..id = 'S'
      ..startFrame = 0
      ..durationFrames = 300
      ..transform.anchor.defaultValue = [0.3, 0.5];
    l.fill.shadow
      ..enabled = true
      ..lag = true
      ..lagBounciness = 0;
    final p = Project(layers: [l]);
    Float64List? at(int f) {
      clearStateCaches();
      return shapeShadowLag(p, l, f);
    }

    expect(at(50)!.toList(), [0.0, 0.0], reason: 'still: no lag');
    clearShadowLagCaches();
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [0.3, 0.5], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 20, value: [0.7, 0.5]),
    ];
    expect(at(15)![0], lessThan(-5));
    expect(at(250)![0].abs(), lessThan(0.5));
    l.fill.shadow.lag = false;
    expect(at(15), isNull);
  });
}
