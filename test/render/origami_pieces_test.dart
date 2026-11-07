import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Future<int> _inked(Project p) async {
  final r = CanvasRenderer()..setSize(400, 400);
  r.renderFrame(p, 0);
  final img = await r.captureFrame();
  final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  var n = 0;
  for (var i = 3; i < b.lengthInBytes; i += 4) {
    if (b.getUint8(i) > 0) n++;
  }
  return n;
}

EffectInstance _fold(double angle) => EffectInstance(id: 'o', effectId: 'origami_fold', params: {
      'angle': track(angle),
      'direction': track(0.0),
      'position': track(0.5),
      'softness': track(0.0),
      'perspective': track(0.0),
    });

void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });

  for (final shape in ['rect', 'circle', 'triangle']) {
    test('a $shape folded flat over itself shows half its size (nothing cancels)', () async {
      final plain = createLayer(shape, size: 160);
      final base = await _inked(Project(layers: [plain]));
      final l = createLayer(shape, size: 160)..effectStack.add(_fold(180));
      final n = await _inked(Project(layers: [l]));
      expect(n, greaterThan(base * 0.35), reason: 'plain $base, folded $n');
      expect(n, lessThan(base * 0.75));
    });
  }

  test('a rounded rect keeps its rounded corners under origami', () async {
    final sharp = createLayer('rect', size: 160)..effectStack.add(_fold(30));
    final round = createLayer('rect', size: 160)
      ..fill.cornerRadius = 40
      ..effectStack.add(_fold(30));
    expect(await _inked(Project(layers: [round])), lessThan(await _inked(Project(layers: [sharp]))));
  });

  test('text folded flat still shows', () async {
    final l = createTextLayer()..effectStack.add(_fold(180));
    expect(await _inked(Project(layers: [l])), greaterThan(100));
  });
}
