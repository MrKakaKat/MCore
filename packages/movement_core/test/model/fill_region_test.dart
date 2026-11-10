import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double area(List<List<List<double>>> rings) {
  var a = 0.0;
  for (final r in rings) {
    var s = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      s += p[0] * q[1] - q[0] * p[1];
    }
    a += s / 2;
  }
  return a.abs();
}

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    setStageSize(400, 200);
    clearStateCaches();
  });

  Layer sq(String id, double x, double y, double s) => createLayer('rect')
    ..id = id
    ..content.offset = [0, 0]
    ..content.size = [s, s]
    ..transform.anchor.defaultValue = [x / 400, y / 200];

  test('a tap on a square fills exactly the square', () {
    final p = Project(layers: [sq('a', 100, 100, 80)]);
    final r = fillRegionAt(p, 0, [100, 100]);
    expect(area(r), closeTo(6400, 1));
  });

  test('two overlapping squares: their overlap; ignoring one, the whole other', () {
    final p = Project(layers: [sq('a', 100, 100, 80), sq('b', 140, 100, 80)]);
    // a: 60..140, b: 100..180 -> overlap 100..140 (40 x 80).
    expect(area(fillRegionAt(p, 0, [120, 100])), closeTo(3200, 1));
    // only a counts: all of a.
    expect(area(fillRegionAt(p, 0, [120, 100], only: {'a'})), closeTo(6400, 1));
    // in a but not b: a less the overlap.
    expect(area(fillRegionAt(p, 0, [80, 100])), closeTo(3200, 1));
  });

  test('outside everything: the frame less the layers; a new Fill layer on top', () {
    final p = Project(layers: [sq('a', 100, 100, 80)]);
    expect(area(fillRegionAt(p, 0, [300, 20])), closeTo(400 * 200 - 6400, 2));
    final l = addFillLayer(p, 0, [100, 100], 'f', color: '#00ff00')!;
    expect(p.layers.last, same(l));
    expect(l.content.shape, 'compound');
    expect(l.color, '#00ff00');
  });

  test('a cropped square fills only what is left of it', () {
    final a = sq('a', 100, 100, 80)..crop = [0.5, 0, 0, 0]; // the left half cut away
    final p = Project(layers: [a]);
    expect(area(fillRegionAt(p, 0, [120, 100])), closeTo(3200, 1));
    // where the crop took it away: the frame less the half that shows.
    expect(area(fillRegionAt(p, 0, [80, 100])), closeTo(400 * 200 - 3200, 2));
  });

  test('a circle fills round, not as a polygon', () {
    final c = createLayer('circle')
      ..id = 'c'
      ..content.offset = [0, 0]
      ..content.size = [160, 160]
      ..transform.anchor.defaultValue = [200 / 400, 100 / 200];
    final r = fillRegionAt(Project(layers: [c]), 0, [200, 100]);
    expect(area(r), closeTo(3.141592653589793 * 80 * 80, 25));
  });

  test('only the selected: fills drawn before still bound it', () {
    final a = sq('a', 100, 100, 80);
    final p = Project(layers: [a]);
    final first = addFillLayer(p, 0, [100, 100], 'f1')!;
    expect(first.drawing, isTrue);
    // a second square, inside the first fill: chosen alone, the fill still counts.
    final b = sq('b', 300, 100, 60);
    p.layers.add(b);
    final r = fillRegionAt(p, 0, [100, 100], only: {'b'});
    expect(area(r), closeTo(6400, 1));
  });

  test('outside a square: the fill goes under it and bleeds a little under its edge', () {
    final a = sq('a', 100, 100, 80);
    final p = Project(layers: [a]);
    final f = addFillLayer(p, 0, [300, 20], 'f', bleed: 1)!;
    expect(p.layers.indexOf(f), 0, reason: 'under the square that bounds it');
    // bigger than the frame less the square by the bleed along its edge.
    final ringsArea = area([for (final c in f.content.contours!) c]);
    expect(ringsArea, greaterThan(400 * 200 - 6400 + 100));
    expect(ringsArea, lessThan(400 * 200 - 6400 + 400));
  });

  test('inside a square: above it, and no bleed past its edge', () {
    final a = sq('a', 100, 100, 80);
    final p = Project(layers: [a]);
    final f = addFillLayer(p, 0, [100, 100], 'f', bleed: 1)!;
    expect(p.layers.indexOf(f), 1);
    expect(area([for (final c in f.content.contours!) c]), closeTo(6400, 1));
  });

  test('a raster edge: the given rings bound it; over pictures, a mask by the picture instead', () {
    final img = createImageLayer(imageSourceType: 'embedded', imageData: 'AAAA', naturalWidth: 10, naturalHeight: 10)
      ..id = 'img'
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final p = Project(layers: [img]);
    // its opaque core: a 40 x 40 square in the middle of the frame.
    List<List<List<double>>>? core(Layer l) => l.id == 'img'
        ? [
            [[180.0, 80.0], [220.0, 80.0], [220.0, 120.0], [180.0, 120.0]]
          ]
        : null;
    final r = fillRegionAt(p, 0, [20, 20], raster: core);
    expect(area(r), closeTo(400 * 200 - 1600, 2));
    final under = addFillLayer(p, 0, [20, 20], 'u', raster: core)!;
    expect(p.layers.indexOf(under), 0, reason: 'under the picture');
    p.layers.remove(under);
    final over = addFillLayer(p, 0, [20, 20], 'o', raster: core, overPictures: true)!;
    expect(p.layers.last, same(over));
    expect(over.masks.single.mode, 'subtract');
    expect(over.masks.single.sourceLayerId, 'img');
    expect(area([for (final c in over.content.contours!) c]), closeTo(400 * 200, 2), reason: 'the mask cuts it, not its shape');
  });

  test('all pixels: the flood stops at another colour; grow reaches one pixel past', () {
    // 6 x 4: a white field split by a black column at x = 3.
    const w = 6, h = 4;
    final px = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      final black = i % w == 3;
      px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = black ? 0 : 255;
      px[i * 4 + 3] = 255;
    }
    final m = floodFillMask(px, w, h, 0, 0, 10);
    expect([for (var x = 0; x < w; x++) m[x]], [1, 1, 1, 0, 0, 0]);
    final g = floodFillMask(px, w, h, 0, 0, 10, grow: 1);
    expect([for (var x = 0; x < w; x++) g[x]], [1, 1, 1, 1, 0, 0]);
  });
}
