import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/export.dart';

/// GIF export keeps transparency: what nothing covers is the GIF's
/// transparent index; covered pixels are opaque.
void main() {
  testWidgets('a shape over no background exports as a transparent GIF', (tester) async {
    final app = AppState()..setFrameSize(40, 40);
    app.renderer.backgroundColor = null;
    app.project.layers
      ..clear()
      ..add(createLayer('rect')
        ..id = 'r'
        ..color = '#00ff00'
        ..content.offset = [0, 0]
        ..content.size = [20, 20]
        ..transform.anchor.defaultValue = [0.5, 0.5]);
    late List<int> covered, empty;
    await tester.runAsync(() async {
      final gif = await exportGif(renderer: app.renderer, project: app.project, startFrame: 0, endFrame: 2, fps: 30);
      final codec = await ui.instantiateImageCodec(gif);
      final img = (await codec.getNextFrame()).image;
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      List<int> at(int x, int y) => [for (var c = 0; c < 4; c++) px.getUint8((y * 40 + x) * 4 + c)];
      covered = at(20, 20);
      empty = at(2, 2);
    });
    expect(covered, [0, 255, 0, 255]);
    expect(empty[3], 0, reason: 'uncovered pixels are transparent');
  });
}
