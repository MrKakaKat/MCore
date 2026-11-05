import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Collide on concave shapes: convex parts, not the hull.
void main() {
  setUpAll(() {
    setStageSize(1000, 1000);
    enablePhysicsOffsets();
  });

  Layer shape(String id, double x, double y, List<List<List<double>>> contours, {bool immovable = true}) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = 100
      ..transform.anchor.defaultValue = [x / 1000, y / 1000];
    l.content = Content(shape: 'compound', offset: [0, 0], size: [100, 100], contours: contours);
    l.physics
      ..collide = true
      ..role = immovable ? 'immovable' : 'pushable';
    return l;
  }

  Layer cube(String id, double x, double y, {double size = 20}) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = 0
      ..durationFrames = 100
      ..content.offset = [0, 0]
      ..content.size = [size, size]
      ..transform.anchor.defaultValue = [x / 1000, y / 1000];
    l.physics.collide = true;
    return l;
  }

  void move(Layer l, List<double> from, List<double> to, int frames) {
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [from[0] / 1000, from[1] / 1000], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: frames, value: [to[0] / 1000, to[1] / 1000], temporal: const Easing(0, 0, 1, 1)),
    ];
  }

  double xOf(Project p, String id, int f) => getLayerStateAt(p, id, f).matrix[4] * 1000;

  // a "C", 100 x 100 around its centre, opening to the right (inner wall
  // at local x -20).
  final cRing = [
    [-50.0, -50.0], [50.0, -50.0], [50.0, -20.0], [-20.0, -20.0], [-20.0, 20.0], [50.0, 20.0], [50.0, 50.0], [-50.0, 50.0]
  ];

  test('a cube pushed into a C goes inside and stops at its inner wall', () {
    final c = shape('C', 500, 500, [cRing]);
    final k = cube('K', 700, 500);
    move(k, [700, 500], [470, 500], 40);
    final p = Project(layers: [c, k]);
    physicsWorldOf(p).bakeTo(50);
    expect(xOf(p, 'K', 50), closeTo(490, 1.5), reason: 'the inner wall is at 480, the cube is 20 wide');
  });

  test('a cube inside a donut\'s hole collides with the inner ring', () {
    final outer = [
      [-50.0, -50.0], [50.0, -50.0], [50.0, 50.0], [-50.0, 50.0]
    ];
    final hole = [
      [-30.0, -30.0], [-30.0, 30.0], [30.0, 30.0], [30.0, -30.0]
    ];
    final d = shape('D', 500, 500, [outer, hole]);
    final k = cube('K', 500, 500, size: 10);
    move(k, [500, 500], [560, 500], 30);
    final p = Project(layers: [d, k]);
    physicsWorldOf(p).bakeTo(40);
    expect(xOf(p, 'K', 40), closeTo(525, 1.5), reason: 'the hole\'s edge at 530, the cube 10 wide');
  });

  test('an L: a cube rests in the inner corner touching both faces', () {
    final l = shape('L', 500, 500, [
      [
        [-50.0, -50.0], [-20.0, -50.0], [-20.0, 20.0], [50.0, 20.0], [50.0, 50.0], [-50.0, 50.0]
      ]
    ]);
    final k = cube('K', 600, 400);
    move(k, [600, 400], [470, 520], 40);
    final p = Project(layers: [l, k]);
    physicsWorldOf(p).bakeTo(50);
    final m = getLayerStateAt(p, 'K', 50).matrix;
    expect(m[4] * 1000, closeTo(490, 1.5), reason: 'against the inner vertical face (x 480)');
    expect(m[5] * 1000, closeTo(510, 1.5), reason: 'on the inner floor (y 520)');
  });

  test('decomposition: convex parts, the same area, the cap kept', () {
    for (final rings in [
      [cRing],
      [
        [
          [-50.0, -50.0], [50.0, -50.0], [50.0, 50.0], [-50.0, 50.0]
        ],
        [
          [-30.0, -30.0], [-30.0, 30.0], [30.0, 30.0], [30.0, -30.0]
        ]
      ],
    ]) {
      final parts = convexParts(rings);
      expect(parts.length, greaterThan(1));
      var area = 0.0;
      for (final part in parts) {
        final pts = part.points;
        for (var i = 0; i < pts.length; i++) {
          final a = pts[i], b = pts[(i + 1) % pts.length], c = pts[(i + 2) % pts.length];
          expect((b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]), greaterThanOrEqualTo(-1e-9), reason: 'convex');
        }
        area += ringSignedArea(pts).abs();
      }
      final want = rings.map((r) => ringSignedArea(r).abs()).reduce((a, b) => a - b);
      expect((area - want).abs() / want, lessThan(0.005));
    }
    // a saw with many teeth: at most 32 parts.
    final saw = <List<double>>[];
    for (var i = 0; i <= 60; i++) {
      saw.add([i * 10.0, i.isEven ? 0.0 : 20.0]);
    }
    saw
      ..add([600.0, 100.0])
      ..add([0.0, 100.0]);
    expect(convexParts([saw]).length, lessThanOrEqualTo(32));
    // convex: one part.
    expect(convexParts([
      [
        [0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]
      ]
    ]), hasLength(1));
  });

  test('a line collides as a line, not as its box', () {
    final line = createLayer('line')
      ..id = 'L'
      ..startFrame = 0
      ..durationFrames = 100
      ..transform.anchor.defaultValue = [0.5, 0.5];
    line.content.lineNodes = [LineNode(-100, -100), LineNode(100, 100)];
    line.content.lineWidth = 6;
    syncLineBox(line.content);
    line.physics
      ..collide = true
      ..role = 'immovable';
    // inside the line's box, beside the line: nothing stops it.
    final k = cube('K', 580, 380);
    move(k, [580, 380], [580, 450], 20);
    final p = Project(layers: [line, k]);
    physicsWorldOf(p).bakeTo(20);
    expect(getLayerStateAt(p, 'K', 20).matrix[5] * 1000, closeTo(450, 0.5));
    // straight at it: stopped on the line.
    final k2 = cube('K2', 500, 300);
    move(k2, [500, 300], [500, 520], 30);
    final p2 = Project(layers: [line, k2]);
    physicsWorldOf(p2).bakeTo(30);
    expect(getLayerStateAt(p2, 'K2', 30).matrix[5] * 1000, lessThan(500));
  });
}
