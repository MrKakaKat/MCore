import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('crop line: a diagonal erases one side; inverted the other; New layer takes the side out', () {
    final app = AppState();
    app.project.layers.clear();
    final l = createLayer('rect')
      ..id = 'r'
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(l);
    app.selectLayer('r');
    final w = stageSize.width, h = stageSize.height;
    final c = [w / 2, h / 2];
    app.startCropLine();
    // a diagonal through the middle, drawn top-left to bottom-right.
    app.cropLineTap([c[0] - 40, c[1] - 40], 0);
    app.cropLineTap([c[0] + 40, c[1] + 40], 0);
    final region = app.cropLineRegion(l);
    expect(region.length, greaterThan(3));
    // the marked side: left of the way it was drawn (the top right corner,
    // screen y down).
    bool inside(List<List<double>> poly, List<double> p) {
      var r = false;
      for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        if ((poly[i][1] > p[1]) != (poly[j][1] > p[1]) &&
            p[0] < (poly[j][0] - poly[i][0]) * (p[1] - poly[i][1]) / (poly[j][1] - poly[i][1]) + poly[i][0]) {
          r = !r;
        }
      }
      return r;
    }

    expect(inside(region, [40, -40]), isTrue);
    expect(inside(region, [-40, 40]), isFalse);
    app.applyCropLine(extract: false);
    expect(app.cropLine, isNull);
    expect(l.pieceClips.single.inside, isFalse, reason: 'erased: only what is outside the area stays');

    // New layer, inverted: the new layer takes the other side.
    app.startCropLine();
    app.setCropLineInvert(true);
    app.cropLineTap([c[0] - 40, c[1] - 40], 0);
    app.cropLineTap([c[0] + 40, c[1] + 40], 0);
    final piece = app.applyCropLine(extract: true)!;
    expect(app.project.layers.length, 2);
    expect(piece.pieceClips.last.inside, isFalse);
    expect(l.pieceClips.last.inside, isTrue);
  });

  test('crop line points snap onto the layer corners', () {
    final app = AppState();
    app.project.layers.clear();
    final l = createLayer('rect')
      ..id = 'r'
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(l);
    app.selectLayer('r');
    final c = [stageSize.width / 2, stageSize.height / 2];
    app.startCropLine();
    app.cropLineTap([c[0] - 47, c[1] - 52], 10);
    expect(app.cropLine!.single[0], closeTo(c[0] - 50, 1e-6));
    expect(app.cropLine!.single[1], closeTo(c[1] - 50, 1e-6));
  });
}
