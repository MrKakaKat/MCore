import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  test('the background block grows on every side', () async {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
    final l = createTextLayer();
    l.content.size = [100, 40];
    l.content.text!.background
      ..enabled = true
      ..opacity = 1
      ..color = '#ff0000'
      ..padding = 30;
    final r = CanvasRenderer()..setSize(400, 400);
    r.renderFrame(Project(layers: [l]), 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int red(int x, int y) => b.getUint8((y * 400 + x) * 4);
    // around the word "Text" (about 100 x 58 at 48 px) in the middle,
    // padded by 30 on every side - wider than the 100 px box would be.
    final layout = layoutText(l.content.text!, const [0, 0], l.content.size);
    final left = (200 - layout.width / 2 - 30).round(), right = (200 + layout.width / 2 + 30).round();
    expect(red(left + 3, 200), 255, reason: 'left, inside the padding');
    expect(red(right - 3, 200), 255, reason: 'right');
    expect(red(200, (200 - layout.height / 2 - 27).round()), 255, reason: 'above');
    expect(red(left - 6, 200), 0, reason: 'past the padding');
    expect(red(right + 6, 200), 0);
  });
}
