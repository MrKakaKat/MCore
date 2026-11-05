import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// The paint gradient's colour (rgb, opacity) at a content px point.
(int, int, int, double) colourAt(FillGradient g, double x, double y) {
  final m = g.matrix;
  final det = m[0] * m[3] - m[1] * m[2];
  final dx = x - m[4], dy = y - m[5];
  final u = (m[3] * dx - m[2] * dy) / det, v = (-m[1] * dx + m[0] * dy) / det;
  double t;
  if (g.type == 'linear') {
    final ax = g.x2 - g.x1, ay = g.y2 - g.y1;
    t = ((u - g.x1) * ax + (v - g.y1) * ay) / (ax * ax + ay * ay);
  } else {
    t = ((u - g.cx) * (u - g.cx) + (v - g.cy) * (v - g.cy)) / (g.r * g.r);
    t = t <= 0 ? 0 : t == 1 ? 1 : t > 1 ? 1 : t;
    t = t == 0 ? 0 : t;
  }
  t = t.clamp(0.0, 1.0);
  final st = g.stops;
  var i = 0;
  while (i < st.length - 1 && st[i + 1].offset < t) {
    i++;
  }
  final a = st[i], b = st[i + 1 < st.length ? i + 1 : i];
  final k = b.offset == a.offset ? 0.0 : ((t - a.offset) / (b.offset - a.offset)).clamp(0.0, 1.0);
  int ch(String hex, int sh) => (int.parse(hex.substring(1), radix: 16) >> sh) & 255;
  int mix(int sh) => (ch(a.color, sh) + (ch(b.color, sh) - ch(a.color, sh)) * k).round();
  return (mix(16), mix(8), mix(0), a.opacity + (b.opacity - a.opacity) * k);
}

void main() {
  setUp(() => setStageSize(400, 400));

  test('fills, classes and parent groups give each shape its own colour', () {
    final r = importShapesFromSvg('''<svg xmlns="http://www.w3.org/2000/svg">
      <style>.a{fill:#ff0000}</style>
      <rect class="a" x="0" y="0" width="10" height="10"/>
      <g fill="#00ff00"><circle cx="5" cy="5" r="5"/></g>
      <polygon points="0,0 10,0 10,10" style="fill:rgb(0,0,255)"/>
      <rect x="0" y="0" width="10" height="10"/>
    </svg>''');
    expect([for (final l in r.layers) l.color], ['#ff0000', '#00ff00', '#0000ff', '#000000']);
  });

  test('a linear gradient in objectBoundingBox units: its ends at the shape sides', () {
    final r = importShapesFromSvg('''<svg xmlns="http://www.w3.org/2000/svg"><defs>
      <linearGradient id="g"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient>
      </defs><rect x="100" y="100" width="200" height="50" fill="url(#g)"/></svg>''');
    final g = r.layers.single.fill.paint!;
    expect(colourAt(g, -100, 0), (255, 0, 0, 1.0));
    expect(colourAt(g, 100, 0), (0, 0, 255, 1.0));
    expect(r.report, isEmpty);
  });

  test('userSpaceOnUse: the gradient stays where it was drawn', () {
    final r = importShapesFromSvg('''<svg xmlns="http://www.w3.org/2000/svg"><defs>
      <linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="400" y2="0">
      <stop offset="0" stop-color="#000000"/><stop offset="1" stop-color="#ffffff"/></linearGradient>
      </defs><rect x="200" y="0" width="200" height="10" fill="url(#g)"/></svg>''');
    final g = r.layers.single.fill.paint!;
    // content px 0 = x 300 in the file: three quarters along.
    expect(colourAt(g, 0, 0).$1, closeTo(191, 1));
  });

  test('stop-opacity 0 is transparent; style="stop-color" works; href inherits the stops', () {
    final r = importShapesFromSvg('''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><defs>
      <linearGradient id="base"><stop offset="0" style="stop-color:#00ff00;stop-opacity:0"/><stop offset="1" stop-color="#00ff00"/></linearGradient>
      <linearGradient id="g" xlink:href="#base" x1="0" x2="0" y1="0" y2="1"/>
      </defs><rect x="0" y="0" width="100" height="100" fill="url(#g)"/></svg>''');
    final g = r.layers.single.fill.paint!;
    expect(colourAt(g, 0, -50).$4, 0);
    expect(colourAt(g, 0, 50), (0, 255, 0, 1.0));
  });

  test('fill-opacity and opacity become the layer opacity', () {
    final r = importShapesFromSvg('<svg><g opacity="0.5"><polygon points="0,0 10,0 10,10" fill="#123456" fill-opacity="0.5"/></g></svg>');
    expect(r.layers.single.transform.opacity.defaultValue, 0.25);
    expect(r.layers.single.color, '#123456');
  });

  test('a big metadata block is skipped', () {
    final meta = '<x:blob>${'A' * 2000000}</x:blob>';
    final sw = Stopwatch()..start();
    final r = importShapesFromSvg(
        '<svg xmlns="http://www.w3.org/2000/svg"><metadata>$meta</metadata><rect width="10" height="10" fill="#abcdef"/></svg>');
    expect(r.errors, isEmpty);
    expect(r.layers.single.color, '#abcdef');
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('a focal radial gradient falls back to its average colour, and says so', () {
    final r = importShapesFromSvg('''<svg><defs><radialGradient id="g" fx="0.2">
      <stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></radialGradient></defs>
      <circle cx="50" cy="50" r="50" fill="url(#g)"/></svg>''');
    expect(r.layers.single.fill.paint, isNull);
    expect(r.layers.single.color, '#800080');
    expect(r.report.single, contains('average'));
  });

  test('transforms of groups and elements are baked in', () {
    final r = importShapesFromSvg('<svg><g transform="translate(100,0)"><rect transform="scale(2)" width="10" height="10"/></g></svg>');
    final l = r.layers.single;
    expect(l.content.size[0], closeTo(20, 1e-9));
    expect((l.transform.anchor.defaultValue as List)[0] * 400, closeTo(110, 1e-9));
  });

  test('paint gradient survives JSON', () {
    final r = importShapesFromSvg('''<svg><defs><linearGradient id="g"><stop offset="0" stop-color="#ff0000"/>
      <stop offset="1" stop-color="#0000ff" stop-opacity="0.5"/></linearGradient></defs>
      <rect width="10" height="10" fill="url(#g)"/></svg>''');
    final back = layerFromJson(layerToJson(r.layers.single));
    expect(back.fill.paint!.stops.last.opacity, 0.5);
    expect(back.fill.paint!.matrix, r.layers.single.fill.paint!.matrix);
  });
}
