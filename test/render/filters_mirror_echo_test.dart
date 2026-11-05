import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Future<int Function(int, int)> render(Project p, {int w = 200, int h = 100}) async {
  final r = CanvasRenderer()..setSize(w.toDouble(), h.toDouble());
  r.backgroundColor = null;
  clearStateCaches();
  r.renderFrame(p, 0);
  final img = await r.captureFrame();
  final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return (int x, int y) => [for (var c = 0; c < 4; c++) b.getUint8((y * w + x) * 4 + c)].fold<int>(0, (a, v) => a * 256 + v);
}

Layer rect(String id, String color, double x, double y, double s) => createLayer('rect')
  ..id = id
  ..color = color
  ..content.size = [s, s]
  ..transform.anchor.defaultValue = [x / 200, y / 100];

void main() {
  setUp(() => setStageSize(200, 100));

  test('Negative 100 % inverts the colours; 0 leaves them', () async {
    final l = rect('a', '#ff0000', 50, 50, 40);
    final at = await render(Project(layers: [l]));
    expect(at(50, 50), 0xff0000ff);
    l.filters.negative = Track(1.0, false);
    final inv = await render(Project(layers: [l]));
    expect(inv(50, 50), 0x00ffffff);
  });

  test('Make mirror: the copy is never drawn; the layer shows what lies under the copy', () async {
    final app = AppState();
    app.project.layers.clear();
    // red block on the right half, the mirror layer on the left.
    app.project.layers.add(rect('bg', '#ff0000', 150, 50, 100));
    final m = rect('m', '#00ff00', 50, 50, 40);
    app.project.layers.add(m);
    app.makeMirror('m');
    final probe = findLayer(app.project, m.mirrorSourceId)!;
    expect(probe.mirrorProbe, isTrue);
    probe.transform.anchor.defaultValue = [150 / 200, 0.5];
    final at = await render(app.project);
    expect(at(50, 50), 0xff0000ff, reason: 'the mirror shows the red under its copy');
    expect(at(150, 50), 0xff0000ff, reason: 'the copy itself draws nothing (red stays)');
    app.removeMirror('m');
    expect(findLayer(app.project, probe.id), isNull);
  });

  test('Echo: copies along the offset, the farthest the faintest', () async {
    final l = rect('a', '#000000', 30, 50, 10);
    l.fill.shadow
      ..enabled = true
      ..dx = 100
      ..dy = 0
      ..opacity = 1
      ..color = '#0000ff'
      ..echo = true
      ..echoCount = 5
      ..echoFade = Track(0.8, false);
    final at = await render(Project(layers: [l]));
    final near = at(50, 50) & 0xff, far = at(130, 50) & 0xff;
    expect(near, greaterThan(200));
    expect(far, inInclusiveRange(30, 80));
    expect(at(40, 50) & 0xff, 0, reason: 'gaps between the copies');
  });
}
