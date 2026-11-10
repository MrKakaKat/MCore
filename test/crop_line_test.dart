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

  test('crop line: an open V keeps the same side (its left), never flipping by area', () {
    final l = createLayer('rect')
      ..content.offset = [0, 0]
      ..content.size = [100, 100];
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

    for (final depth in [10.0, 40.0, 49.0]) {
      final region = cutLineRegion(l, [[-45, -45], [0, depth], [45, -45]], closed: false);
      expect(inside(region, [0, -40]), isTrue, reason: 'inside the V (depth $depth)');
      expect(inside(region, [0, 49.5]), isFalse);
      expect(inside(region, [-49, 49]), isFalse);
    }
  });

  test('mirror line: a vertical line through the middle mirrors left to right, flipping it', () {
    final app = AppState();
    app.project.layers.clear();
    final l = createLayer('rect')
      ..id = 'r'
      ..content.size = [40, 20]
      ..transform.anchor.defaultValue = [0.25, 0.5]
      ..transform.rotation.defaultValue = 30.0;
    app.project.layers.add(l);
    app.selectLayer('r');
    app.startMirrorLine();
    app.applyMirrorLine();
    final a = l.transform.anchor.defaultValue as List;
    expect((a[0] as num).toDouble(), closeTo(0.75, 1e-9));
    expect((a[1] as num).toDouble(), closeTo(0.5, 1e-9));
    // a vertical line (90°): 180 - 30, flipped top to bottom.
    expect((l.transform.rotation.defaultValue as num).toDouble(), closeTo(150, 1e-9));
    expect(l.mirrorY, isTrue);
    // its ends snap: near the frame's corner, onto it.
    app.moveMirrorLine(0, [3, 2], 10);
    expect(app.mirrorLine![0], [0.0, 0.0]);
  });
}
