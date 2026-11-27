import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Filters' own time on the timeline, effects tied to another layer's
/// time, and Match Color as a list of matches.
void main() {
  const w = 100.0, h = 100.0;
  setUp(() {
    setStageSize(w, h);
    registerBuiltinEffects();
  });

  Future<List<int>> pixel(Project p, int frame, int x, int y) async {
    final r = CanvasRenderer()..setSize(w, h);
    r.backgroundColor = null;
    clearStateCaches();
    r.renderFrame(p, frame);
    final b = (await (await r.captureFrame()).toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return [for (var c = 0; c < 4; c++) b.getUint8((y * w.round() + x) * 4 + c)];
  }

  Layer square(String id, String color, {int start = 0, int duration = 100}) => createLayer('rect')
    ..id = id
    ..name = id
    ..color = color
    ..startFrame = start
    ..durationFrames = duration
    ..transform.anchor.defaultValue = [0.5, 0.5]
    ..content = Content(shape: 'rect', offset: [0, 0], size: [60, 60]);

  test('a filter part shows on the timeline over the whole layer and acts only within its range', () async {
    final l = square('a', '#ff0000');
    l.filters.negative = Track(1.0, false);
    final p = Project(layers: [l]);
    final span = effectSpans(l).singleWhere((s) => s.id == 'filter.negative');
    expect([span.start, span.end, span.filter], [0, 100, true]);
    setEffectRange(l, 'filter.negative', 0, 40);
    expect((await pixel(p, 20, 50, 50)).sublist(0, 3), [0, 255, 255], reason: 'inside: inverted');
    expect((await pixel(p, 60, 50, 50)).sublist(0, 3), [255, 0, 0], reason: 'past its range: as it is');
    expect(layerFromJson(layerToJson(l)).effectRanges['filter.negative'], [0, 40]);
  });

  test('tied to another layer: acts only while that layer runs', () async {
    final l = square('a', '#ff0000');
    final cue = square('cue', '#00000000', start: 30, duration: 20)..hidden = true;
    l.filters.negative = Track(1.0, false);
    setEffectBind(l, 'filter.negative', 'cue');
    final p = Project(layers: [l, cue]);
    expect((await pixel(p, 10, 50, 50)).sublist(0, 3), [255, 0, 0]);
    expect((await pixel(p, 40, 50, 50)).sublist(0, 3), [0, 255, 255]);
    expect((await pixel(p, 70, 50, 50)).sublist(0, 3), [255, 0, 0]);
    expect(boundSpan(p, l, 'filter.negative'), (30, 50));
    expect(effectActiveAt(l, 'filter.negative', 40, p), isTrue);
    expect(layerFromJson(layerToJson(l)).effectBinds, {'filter.negative': 'cue'});
    // an effect too (the same mechanics).
    l.motionBlur.enabled = true;
    setEffectBind(l, 'motionBlur', 'cue');
    expect([effectActiveAt(l, 'motionBlur', 10, p), effectActiveAt(l, 'motionBlur', 35, p)], [false, true]);
  });

  test('matches: strength mixes, two add up, each its own time', () async {
    final l = square('a', '#808080');
    // m1: red channel to 1 (a = 0, b = 1); m2: blue to 1.
    final m1 = ColorMatch(id: 'r', coeffs: Track(<double>[0, 1, 1, 1, 0, 0], false));
    final m2 = ColorMatch(id: 'b', coeffs: Track(<double>[1, 1, 0, 0, 0, 1], false));
    l.filters.matches.addAll([m1, m2]);
    final p = Project(layers: [l]);
    var px = await pixel(p, 0, 50, 50);
    expect(px.sublist(0, 3), [255, 128, 255]);
    m1.strength = Track(0.5, false);
    px = await pixel(p, 0, 50, 50);
    expect(px[0], inInclusiveRange(188, 194), reason: 'half way from 128 to 255');
    // the second only for a while.
    setEffectRange(l, m2.entryId, 50, 100);
    px = await pixel(p, 10, 50, 50);
    expect(px[2], 128);
    expect(effectSpans(l).where((s) => s.id.startsWith('match.')).length, 2);
    final back = layerFromJson(layerToJson(l));
    expect([back.filters.matches.length, back.filters.matches.first.id], [2, 'r']);
  });

  test('match keys: its colours change over time', () async {
    final l = square('a', '#808080');
    final m = ColorMatch(id: 'k')
      ..coeffs.keyframes.addAll([
        Keyframe(frame: 0, value: <double>[1, 1, 1, 0, 0, 0]),
        Keyframe(frame: 50, value: <double>[0, 1, 1, 0, 0, 0]),
      ]);
    l.filters.matches.add(m);
    final p = Project(layers: [l]);
    expect((await pixel(p, 0, 50, 50))[0], 128);
    expect((await pixel(p, 60, 50, 50))[0], 0);
  });

  test('a match onto a picked layer, only while it is there; again at a frame makes a key', () async {
    final app = AppState();
    app.setFrameSize(w, h);
    app.project.layers.clear();
    final a = square('a', '#404040');
    final blue = square('blue', '#2040ff', start: 20, duration: 30);
    app.project.layers.addAll([a, blue]);
    // nothing to match where the picked layer is not.
    expect(await app.addColorMatch('a', targetId: 'blue'), isNull);
    app.currentFrame = 30;
    final m = (await app.addColorMatch('a', targetId: 'blue', whileTarget: true))!;
    expect(a.filters.matches.single, m);
    expect(a.effectBinds[m.entryId], 'blue');
    final c = m.coeffs.defaultValue as List<double>;
    // onto blue: grey goes blue (a flat colour: its mean).
    expect(c[0] * 0.25 + c[3], closeTo(0x20 / 255, 0.02));
    expect(c[2] * 0.25 + c[5], closeTo(1.0, 0.02));
    expect([effectActiveAt(a, m.entryId, 10, app.project), effectActiveAt(a, m.entryId, 30, app.project)], [false, true]);
    app.currentFrame = 40;
    expect(await app.rematchColor('a', m.id, key: true), isTrue);
    expect(m.coeffs.keyframes.map((k) => k.frame), [0, 40]);
    app.currentFrame = 0;
    app.removeColorMatch('a', m.id);
    expect([a.filters.matches.isEmpty, a.effectBinds.isEmpty], [true, true]);
  });
}
