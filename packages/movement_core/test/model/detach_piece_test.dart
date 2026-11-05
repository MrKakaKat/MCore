import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
    // the cut geometry below is checked in the original's content space.
    recenterDetachedPieces = false;
  });

  Layer square() => createLayer('rect')
    ..id = 'sq'
    ..name = 'Rect 1'
    ..content.offset = [0, 0]
    ..content.size = [100, 100]
    ..transform.anchor.defaultValue = [0.5, 0.5];

  test('a rectangle region splits the layer into two complementary parts', () {
    final l = square();
    final p = Project(layers: [l, createLayer('circle')..id = 'c']);
    // left half of the square in frame space: x 50..100, y 50..150.
    final region = rectRegion(p, l, 0, [40, 40], [100, 160]);
    expect(region.first, [-60.0, -60.0]);
    final piece = detachPiece(p, l, region, 'piece')!;
    expect(p.layers.map((e) => e.id), ['sq', 'piece', 'c'], reason: 'right above the original');
    expect(piece.name, 'Rect 1 part 1');
    for (final pt in [
      [-30.0, 0.0],
      [30.0, 0.0],
      [-49.0, 49.0]
    ]) {
      expect(insidePieceClips(l, pt) != insidePieceClips(piece, pt), isTrue, reason: 'exactly one owns $pt');
    }
    expect(insidePieceClips(piece, [-30, 0]), isTrue);
    expect(timelineRows(p).length, 3, reason: 'the piece has its own row');
  });

  test('a rotated layer gets the rectangle in its own space; pieces of pieces keep both cuts', () {
    final l = square()..transform.rotation.defaultValue = 90.0;
    final p = Project(layers: [l]);
    final region = rectRegion(p, l, 0, [40, 40], [100, 160]);
    // frame x < 100 is local y > 0 after a 90° turn.
    final piece = detachPiece(p, l, region, 'a')!;
    expect(insidePieceClips(piece, [0, 30]), isTrue);
    expect(insidePieceClips(piece, [0, -30]), isFalse);
    final sub = detachPiece(p, piece, rectRegion(p, piece, 0, [0, 0], [200, 100]), 'b')!;
    expect(sub.pieceClips.length, 2);
    expect(sub.name, 'Rect 1 part 1 part 1');
  });

  test('the shape of another layer is the region', () {
    final l = square();
    final circle = createLayer('circle')
      ..id = 'c'
      ..content.offset = [0, 0]
      ..content.size = [40, 40]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final p = Project(layers: [l, circle]);
    final piece = detachPiece(p, l, layerShapeRegion(p, l, circle, 0), 'p')!;
    expect(insidePieceClips(piece, [0, 0]), isTrue);
    expect(insidePieceClips(piece, [30, 0]), isFalse);
    expect(insidePieceClips(l, [30, 0]), isTrue);
  });

  test('cuts are saved', () {
    final l = square()..pieceClips.add(PieceClip(points: [[0, 0], [1, 0], [1, 1]], inside: false));
    final back = layerFromJson(layerToJson(l));
    expect(back.pieceClips.single.inside, isFalse);
    expect(back.pieceClips.single.points.last, [1.0, 1.0]);
    expect(layerToJson(square()).containsKey('pieces'), isFalse);
  });

  test('the contour is cut too: box, corners and transform box of each part', () {
    final l = square();
    final p = Project(layers: [l]);
    final piece = detachPiece(p, l, rectRegion(p, l, 0, [40, 40], [100, 160]), 'piece')!;
    BoundingBox box(Layer x) => pieceBoundingBox(x);
    expect([box(piece).minX, box(piece).maxX, box(piece).minY, box(piece).maxY], [-50.0, 0.0, -50.0, 50.0]);
    expect([box(l).minX, box(l).maxX, box(l).minY, box(l).maxY], [0.0, 50.0, -50.0, 50.0]);

    final corners = pieceOutlinePoints(piece);
    for (final c in [
      [-50.0, -50.0],
      [0.0, -50.0],
      [0.0, 50.0],
      [-50.0, 50.0]
    ]) {
      expect(corners.any((q) => (q[0] - c[0]).abs() < 1e-9 && (q[1] - c[1]).abs() < 1e-9), isTrue, reason: 'corner $c');
    }
    expect(corners.every((q) => q[0] <= 1e-9), isTrue, reason: 'nothing from the other half');

    // transform box in frame space: the piece is x 50..100.
    final tb = getTransformBoxHandles(p, piece, 0);
    expect(tb.screen['tl'], [50.0, 50.0]);
    expect(tb.screen['br'], [100.0, 150.0]);
    expect(getTransformBoxHandles(p, l, 0).screen['tl'], [100.0, 50.0]);
    // snapping sees the cut corners.
    final g = computeLayerFrameGeometry(p, piece, 0);
    expect(g.bbox.maxX, 100.0);
  });

  test('a cut through the middle of a triangle: the box follows the slanted edges', () {
    final t = createLayer('triangle')
      ..id = 't'
      ..content.offset = [0, 0]
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final p = Project(layers: [t]);
    final full = shapeBoundingBox(t.content);
    final piece = detachPiece(p, t, [
      [full.minX - 10, -5],
      [full.maxX + 10, -5],
      [full.maxX + 10, 5],
      [full.minX - 10, 5]
    ], 'band')!;
    final b = pieceBoundingBox(piece);
    expect(b.minY, closeTo(-5, 1e-9));
    expect(b.maxY, closeTo(5, 1e-9));
    expect(b.maxX - b.minX, lessThan(full.maxX - full.minX), reason: 'a band across a triangle is narrower than its base');
    expect(insidePiece(piece, [0, 0]), isTrue);
    expect(insidePiece(piece, [0, 20]), isFalse);
  });

  group('recenter detached pieces', () {
    setUp(() => recenterDetachedPieces = true);
    tearDown(() => recenterDetachedPieces = true);

    /// Where a point of the original content lands on screen at a frame,
    /// through `layer` (whose content may have been shifted by `shift`).
    List<double> screenOf(Project p, Layer layer, int f, List<double> pt, List<double> shift) =>
        applyAffine(toFrameMatrix(getLayerStateAt(p, layer.id, f).matrix), [pt[0] - shift[0], pt[1] - shift[1]]);

    for (final animated in [false, true]) {
      test(animated ? 'animated turn and size: same picture every frame (keys per frame)' : 'static turn: a constant shift', () {
        final l = square();
        final p = Project(layers: [l]);
        addKeyframe(p, l.id, 'anchor', 0, [0.3, 0.4], 'linear');
        addKeyframe(p, l.id, 'anchor', 30, [0.7, 0.6], 'linear');
        if (animated) {
          addKeyframe(p, l.id, 'rotation', 0, 0.0, 'linear');
          addKeyframe(p, l.id, 'rotation', 30, 120.0, 'linear');
          addKeyframe(p, l.id, 'scale', 0, [1.0, 1.0], 'linear');
          addKeyframe(p, l.id, 'scale', 30, [2.0, 0.5], 'linear');
        } else {
          l.transform.rotation.defaultValue = 30.0;
        }
        l.durationFrames = 30;
        // where three points of the right half are on screen, every frame.
        final pts = [
          [10.0, -20.0],
          [40.0, 30.0],
          [25.0, 0.0]
        ];
        final before = {
          for (var f = 0; f <= 30; f += 3) f: [for (final q in pts) screenOf(p, l, f, q, [0, 0])]
        };
        // the right half (local x 0..50) becomes the piece.
        final piece = detachPiece(p, l, [
          [0, -60],
          [60, -60],
          [60, 60],
          [0, 60]
        ], 'piece')!;
        clearStateCaches();
        final shift = [25.0, 0.0]; // its centre in the old content space
        expect(piece.content.offset, [-25.0, 0.0]);
        for (final f in before.keys) {
          for (var i = 0; i < pts.length; i++) {
            final now = screenOf(p, piece, f, pts[i], shift);
            expect(now[0], closeTo(before[f]![i][0], 1e-6), reason: 'frame $f point $i x');
            expect(now[1], closeTo(before[f]![i][1], 1e-6), reason: 'frame $f point $i y');
          }
          // the piece's origin (its motion path) is the centre of its part.
          final origin = applyAffine(toFrameMatrix(getLayerStateAt(p, piece.id, f).matrix), [0, 0]);
          final centre = screenOf(p, l, f, shift, [0, 0]);
          expect(origin[0], closeTo(centre[0], 1e-6));
          expect(origin[1], closeTo(centre[1], 1e-6));
        }
        expect(piece.transform.anchor.keyframes.length, animated ? 31 : 2);
        // the original keeps its own origin and keys.
        expect(l.transform.anchor.keyframes.length, 2);
        expect(l.content.offset, [0.0, 0.0]);
      });
    }

    test('setting off: the piece keeps the original\'s origin', () {
      recenterDetachedPieces = false;
      final l = square();
      final p = Project(layers: [l]);
      final piece = detachPiece(p, l, rectRegion(p, l, 0, [40, 40], [100, 160]), 'piece')!;
      expect(piece.content.offset, [0.0, 0.0]);
      expect(piece.transform.anchor.defaultValue, l.transform.anchor.defaultValue);
    });

    test('the pendulum grip point stays the same point of the picture', () {
      final l = square()..pendulum.pivotOffset.defaultValue = [10.0, -40.0];
      final p = Project(layers: [l]);
      final piece = detachPiece(p, l, [
        [0, -60],
        [60, -60],
        [60, 60],
        [0, 60]
      ], 'piece')!;
      expect(piece.pendulum.pivotOffset.defaultValue, [-15.0, -40.0]);
    });
  });
}
