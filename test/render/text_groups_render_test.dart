import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });

  Future<List<int>> inkColumns(Project p) async {
    final r = CanvasRenderer()..setSize(400, 200);
    r.renderFrame(p, 0);
    final img = await r.captureFrame();
    final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return [
      for (var x = 0; x < 400; x++)
        [for (var y = 0; y < 200; y++) b.getUint8((y * 400 + x) * 4 + 3) > 128].where((v) => v).length
    ];
  }

  test('a group layer draws its letters in place; moved, they go with it', () async {
    setStageSize(400, 200);
    Layer text() => createTextLayer(text: 'HHH', fontSize: 60)
      ..id = 'T'
      ..content.size = [300, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final plain = await inkColumns(Project(layers: [text()]));
    final t = text()..content.text!.text = 'H#H#H';
    t.content.text!.groupsEnabled = true;
    final p = Project(layers: [t]);
    final g = addTextGroupLayers(p, t).single;
    final grouped = await inkColumns(p);
    var diff = 0;
    for (var x = 0; x < 400; x++) {
      diff += (plain[x] - grouped[x]).abs();
    }
    expect(diff, lessThan(40), reason: 'same picture while the group sits in place');
    final a = g.transform.anchor.defaultValue as List<double>;
    g.transform.anchor.defaultValue = [a[0], a[1] + 0.3];
    clearStateCaches();
    final moved = await inkColumns(p);
    expect(moved.reduce((s, v) => s + v), closeTo(grouped.reduce((s, v) => s + v), 60), reason: 'all letters still drawn');
    // the middle H's columns: still inked (moved down, not removed), and
    // the text no longer draws it in its old place.
    final mid = [for (var x = 180; x < 220; x++) moved[x]].reduce((s, v) => s + v);
    expect(mid, greaterThan(0));
  });
}
