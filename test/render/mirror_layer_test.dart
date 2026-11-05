import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// A red block in the left half of a base frame; the mirror (same size,
/// on the right) shows it flipped - in the mirror's right half.
void main() {
  test('a mirror shows, flipped, what its base covers below it', () async {
    final app = AppState()..setFrameSize(100, 50);
    app.project.layers.clear();
    app.renderer.backgroundColor = const ui.Color(0xFF000000);
    Layer rect(String id, String color, double w, double h, double x, double y) => createLayer('rect')
      ..id = id
      ..color = color
      ..content.size = [w, h]
      ..transform.anchor.defaultValue = [x, y];
    final red = rect('red', '#ff0000', 10, 10, 0.1, 0.5); // x 5..15
    final base = rect('base', '#000000', 40, 40, 0.25, 0.5)..transform.opacity.defaultValue = 0.0; // x 5..45, invisible
    final mirror = rect('mirror', '#ffffff', 40, 40, 0.75, 0.5)..mirrorSourceId = 'base'; // x 55..95
    app.project.layers.addAll([red, base, mirror]);

    Future<List<int>> at(int x, int y) async {
      app.renderer.renderFrame(app.project, 0);
      final img = await app.renderer.captureFrame();
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      return [for (var c = 0; c < 3; c++) px.getUint8((y * 100 + x) * 4 + c)];
    }

    expect(await at(10, 25), [255, 0, 0], reason: 'the original');
    expect(await at(90, 25), [255, 0, 0], reason: 'flipped: at the mirror\'s right edge');
    expect(await at(60, 25), [0, 0, 0], reason: 'not unflipped');
    // moving the base so the block is no longer under it: nothing to reflect.
    base.transform.anchor.defaultValue = [0.45, 0.5]; // x 25..65
    expect(await at(90, 25), [0, 0, 0]);
    mirror.mirrorAxis = 'none';
    base.transform.anchor.defaultValue = [0.25, 0.5];
    expect(await at(60, 25), [255, 0, 0], reason: 'not flipped: same side');
  });

  test('a mirror of a mirror shows it again (bounded, no endless loop)', () async {
    final app = AppState()..setFrameSize(100, 50);
    app.project.layers.clear();
    app.renderer.backgroundColor = const ui.Color(0xFF000000);
    Layer rect(String id, double w, double x) => createLayer('rect')
      ..id = id
      ..color = '#ff0000'
      ..content.size = [w, 20]
      ..transform.anchor.defaultValue = [x, 0.5];
    final red = rect('red', 10, 0.1); // x 5..15
    final m1 = rect('m1', 30, 0.5)..mirrorSourceId = 'red'; // x 35..65 shows the block, stretched
    final m2 = rect('m2', 30, 0.85)..mirrorSourceId = 'm1'; // x 70..100 shows the first mirror
    final self = rect('self', 10, 0.5)..mirrorSourceId = 'self';
    app.project.layers.addAll([red, m1, m2, self]);
    app.renderer.renderFrame(app.project, 0);
    final img = await app.renderer.captureFrame();
    final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    expect(px.getUint8((25 * 100 + 85) * 4), 255, reason: 'the second mirror shows the first one');
  });
}
