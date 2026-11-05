import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

Layer _rectLayer({List<double> anchor = const [0.5, 0.5], String? color, String renderMode = 'fill', bool hidden = false}) {
  return Layer(
    id: 'L_rect',
    name: 'rect',
    parentId: null,
    transform: Transform(anchor: track(anchor), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
    content: Content(shape: 'rect', offset: const [0, 0], size: [100, 60]),
    color: color,
    renderMode: renderMode,
    hidden: hidden,
  );
}

void main() {
  late Project project;

  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
    project = Project();
  });

  group('exportProjectToSvg', () {
    test('produces a well-formed SVG root with the requested frame size', () {
      final svg = exportProjectToSvg(project, 0, 640, 400);
      final doc = XmlDocument.parse(svg); // throws on malformed output - this alone is a real assertion
      final root = doc.rootElement;
      expect(root.name.local, equals('svg'));
      expect(root.getAttribute('width'), equals('640'));
      expect(root.getAttribute('height'), equals('400'));
      expect(root.getAttribute('viewBox'), equals('0 0 640 400'));
    });

    test('a rect layer at the stage center exports a <rect> with the right size and an identity-ish transform', () {
      project.layers.add(_rectLayer(anchor: [0.5, 0.5], color: '#ff0000'));
      final svg = exportProjectToSvg(project, 0, 640, 400);
      final doc = XmlDocument.parse(svg);
      final rects = doc.findAllElements('rect');
      expect(rects, hasLength(1));
      final rect = rects.first;
      expect(rect.getAttribute('width'), equals('100'));
      expect(rect.getAttribute('height'), equals('60'));
      expect(rect.getAttribute('x'), equals('-50')); // offset [0,0] - w/2
      expect(rect.getAttribute('y'), equals('-30'));
      expect(rect.getAttribute('fill'), equals('#ff0000'));
      // anchor [0.5,0.5] at a 640x400 stage -> translation (320,200), no
      // rotation/scale -> matrix(1,0,0,1,320,200).
      expect(rect.getAttribute('transform'), equals('matrix(1,0,0,1,320,200)'));
    });

    test('renderMode "outline" exports stroke instead of fill', () {
      project.layers.add(_rectLayer(color: '#00ff00', renderMode: 'outline'));
      final svg = exportProjectToSvg(project, 0, 640, 400);
      final rect = XmlDocument.parse(svg).findAllElements('rect').first;
      expect(rect.getAttribute('fill'), equals('none'));
      expect(rect.getAttribute('stroke'), equals('#00ff00'));
    });

    test('a hidden layer is skipped entirely', () {
      project.layers.add(_rectLayer(hidden: true));
      final svg = exportProjectToSvg(project, 0, 640, 400);
      expect(XmlDocument.parse(svg).findAllElements('rect'), isEmpty);
    });

    test('a layer outside its own frame range is skipped', () {
      final layer = _rectLayer()..startFrame = 100;
      project.layers.add(layer);
      final svg = exportProjectToSvg(project, 0, 640, 400); // frame 0 is before startFrame 100
      expect(XmlDocument.parse(svg).findAllElements('rect'), isEmpty);
    });

    test('an image-content layer is skipped (SVG export is shape-only)', () {
      final layer = _rectLayer();
      layer.content = Content(shape: 'image', offset: const [0, 0], size: [100, 60], imageSourceType: 'file', imagePath: '/tmp/x.png');
      project.layers.add(layer);
      final svg = exportProjectToSvg(project, 0, 640, 400);
      final doc = XmlDocument.parse(svg);
      expect(doc.findAllElements('rect'), isEmpty);
      expect(doc.findAllElements('image'), isEmpty);
    });

    test('a triangle layer exports a <polygon> with its own local vertices', () {
      final layer = Layer(
        id: 'L_tri',
        name: 'tri',
        parentId: null,
        transform: Transform(anchor: track([0.5, 0.5]), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
        content: Content(shape: 'triangle', offset: const [0, 0], size: [100, 100]),
      );
      project.layers.add(layer);
      final svg = exportProjectToSvg(project, 0, 640, 400);
      final polygons = XmlDocument.parse(svg).findAllElements('polygon');
      expect(polygons, hasLength(1));
      final pointsAttr = polygons.first.getAttribute('points')!;
      expect(pointsAttr.trim().split(' '), hasLength(3)); // shapePoints' own triangle: exactly 3 vertices
    });

    test('sub-1.0 opacity is carried through as an opacity attribute', () {
      final layer = _rectLayer();
      layer.transform.opacity = track(0.4);
      project.layers.add(layer);
      final svg = exportProjectToSvg(project, 0, 640, 400);
      expect(XmlDocument.parse(svg).findAllElements('rect').first.getAttribute('opacity'), equals('0.4'));
    });
  });

  group('importShapesFromSvg', () {
    test('rejects malformed XML with a clear top-level error, no crash', () {
      final result = importShapesFromSvg('<svg><rect x="0"'); // truncated/invalid
      expect(result.layers, isEmpty);
      expect(result.errors, hasLength(1));
    });

    test('rejects a document whose root is not <svg>', () {
      final result = importShapesFromSvg('<notsvg></notsvg>');
      expect(result.layers, isEmpty);
      expect(result.errors.single, contains('svg'));
    });

    test('imports a <rect> - anchor lands at its own center, content size matches width/height', () {
      final result = importShapesFromSvg('<svg><rect x="100" y="50" width="40" height="20"/></svg>');
      expect(result.errors, isEmpty);
      expect(result.layers, hasLength(1));
      final layer = result.layers.single;
      expect(layer.content.shape, equals('rect'));
      expect(layer.content.size, equals([40.0, 20.0]));
      // center = (100+20, 50+10) = (120, 60); anchor is that as a
      // fraction of the 640x400 stage set in setUp.
      final anchor = layer.transform.anchor.defaultValue as List<double>;
      expect(anchor[0], closeTo(120 / 640, 1e-9));
      expect(anchor[1], closeTo(60 / 400, 1e-9));
    });

    test('imports a <circle> as shape "circle" sized by its own radius', () {
      final result = importShapesFromSvg('<svg><circle cx="10" cy="10" r="5"/></svg>');
      expect(result.errors, isEmpty);
      final layer = result.layers.single;
      expect(layer.content.shape, equals('circle'));
      expect(layer.content.size, equals([10.0, 10.0]));
    });

    test('imports an <ellipse> as a sampled polygon, preserving its actual aspect ratio', () {
      final result = importShapesFromSvg('<svg><ellipse cx="0" cy="0" rx="20" ry="5"/></svg>');
      expect(result.errors, isEmpty);
      final layer = result.layers.single;
      expect(layer.content.shape, equals('polygon'));
      // bbox of a 20x5-radius ellipse centered at origin is 40x10.
      expect(layer.content.size[0], closeTo(40, 0.5));
      expect(layer.content.size[1], closeTo(10, 0.5));
    });

    test('imports a <polygon> with its own explicit points list', () {
      final result = importShapesFromSvg('<svg><polygon points="0,0 10,0 10,10 0,10"/></svg>');
      expect(result.errors, isEmpty);
      final layer = result.layers.single;
      expect(layer.content.shape, equals('polygon'));
      expect(layer.content.points, hasLength(4));
      expect(layer.content.size, equals([10.0, 10.0]));
    });

    test('imports a <path> using only straight M/L/Z segments', () {
      final result = importShapesFromSvg('<svg><path d="M0,0 L10,0 L10,10 Z"/></svg>');
      expect(result.errors, isEmpty);
      final layer = result.layers.single;
      expect(layer.content.shape, equals('polygon'));
      expect(layer.content.points, hasLength(3));
    });

    test('a <path> with curves and arcs is flattened into a polygon', () {
      final result = importShapesFromSvg('<svg><path d="M0,0 C10,0 10,10 0,10 A5 5 0 0 1 0,0 Z"/></svg>');
      expect(result.errors, isEmpty);
      expect(result.layers.single.content.points!.length, greaterThan(10));
    });

    test('an unsupported element type is a per-element error, and other elements still import', () {
      final result = importShapesFromSvg('<svg><text>hello</text><rect x="0" y="0" width="10" height="10"/></svg>');
      expect(result.layers, hasLength(1));
      expect(result.errors, hasLength(1));
      expect(result.errors.single, contains('text'));
    });

    test('<g> wrapper elements are transparent - their children still import, the group itself is not an error', () {
      final result = importShapesFromSvg('<svg><g><rect x="0" y="0" width="10" height="10"/></g></svg>');
      expect(result.errors, isEmpty);
      expect(result.layers, hasLength(1));
    });

    test('exportProjectToSvg then importShapesFromSvg round-trips a rect layer\'s position', () {
      project.layers.add(_rectLayer(anchor: [0.25, 0.75], color: '#123456'));
      final svg = exportProjectToSvg(project, 0, 640, 400);
      final result = importShapesFromSvg(svg);
      expect(result.errors, isEmpty);
      expect(result.layers, hasLength(1));
      final anchor = result.layers.single.transform.anchor.defaultValue as List<double>;
      // the rect's own on-stage center is (0.25*640, 0.75*400) = (160,300);
      // re-importing it (fresh stage still 640x400) must land back there.
      expect(anchor[0], closeTo(0.25, 1e-6));
      expect(anchor[1], closeTo(0.75, 1e-6));
    });
  });
}
