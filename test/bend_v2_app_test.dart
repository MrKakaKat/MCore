import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_gesture_controller.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';

/// Bend v2 on the stage: no seam at an angled line (filled and textured
/// paths), the line / angle handles, and the zone tints.
void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    hideHandles = false;
    hideVisualLayer = false;
    clearStateCaches();
  });
  tearDown(() => hideVisualLayer = false);

  EffectInstance bend({double angle = 60, double axis = -53}) {
    final i = createEffectInstance('bend_arc', 'b', null);
    (i.params['angle'] as Track).defaultValue = angle;
    (i.params['axisAngle'] as Track).defaultValue = axis;
    return i;
  }

  Layer layer(String shape) => createLayer(shape)
    ..id = 'L'
    ..content.offset = [0, 0]
    ..content.size = [60, 120]
    ..color = '#ffffff'
    ..effectStack.add(bend());

  for (final shape in ['rect', 'circle']) {
    test('$shape: bent at an angled line, no gap or seam across either line', () async {
      setStageSize(240, 240);
      final l = layer(shape);
      final p = Project(layers: [l]);
      final r = CanvasRenderer()..setSize(240, 240);
      r.renderFrame(p, 0);
      final img = await r.captureFrame();
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int alpha(double x, double y) => px.getUint8((y.round() * 240 + x.round()) * 4 + 3);
      final h = getBendHandles(p, l, 0).single;
      for (final line in [h.startLine, h.endLine]) {
        // across the middle of the line (inside the shape for both kinds),
        // and a pixel to either side of it.
        for (final t in [0.4, 0.5, 0.6]) {
          final x = line[0][0] + (line[1][0] - line[0][0]) * t, y = line[0][1] + (line[1][1] - line[0][1]) * t;
          for (final d in [-1.0, 0.0, 1.0]) {
            expect(alpha(x + d, y), greaterThan(240), reason: '$shape at ($x, $y)');
          }
        }
      }
    });
  }

  group('handles', () {
    late AppState app;
    late StageCamera camera;
    late StageGestureController c;
    late Layer l;
    setUp(() {
      app = AppState();
      setStageSize(640, 400);
      app.renderer.setSize(640, 400);
      app.project.layers.clear();
      l = layer('rect')
        ..transform.anchor.defaultValue = [0.5, 0.5]
        ..content.size = [80, 240];
      (l.effectStack.single.params['axisAngle'] as Track).defaultValue = -90.0;
      app.project.layers.add(l);
      app.selectLayer('L');
      camera = StageCamera();
      c = StageGestureController(app: app, camera: camera, onNeedsRepaint: () {});
    });

    Offset screen(List<double> p) => camera.frameToScreen(Offset(p[0], p[1]));
    double param(String k) => (l.effectStack.single.params[k] as Track).defaultValue as double;

    test('dragging the end line along the axis moves it; one undo step', () {
      final h = getBendHandles(app.project, l, 0).single;
      final start = screen(h.endHandle);
      c.onPointerDown(PointerDownEvent(pointer: 1, position: start));
      expect(c.activeDrag?.family, 'bendLine');
      expect(c.activeDrag?.activeKey, '0:end');
      // the end line (start 0.25, end 0.75) is still straight up the
      // unbent part: moving the finger up the stage moves it toward the tip.
      c.onPointerMove(PointerMoveEvent(pointer: 1, position: start + const Offset(0, -30)));
      c.onPointerUp(PointerUpEvent(pointer: 1, position: start + const Offset(0, -30)));
      expect(param('end'), greaterThan(0.75));
      app.performUndo();
      expect((findLayer(app.project, 'L')!.effectStack.single.params['end'] as Track).defaultValue, 0.75);
    });

    test('the angle knob turns the bend axis', () {
      final h = getBendHandles(app.project, l, 0).single;
      final knob = screen(h.angleHandle), pivot = screen(h.pivot);
      c.onPointerDown(PointerDownEvent(pointer: 1, position: knob));
      expect(c.activeDrag?.activeKey, '0:angle');
      // swing the knob a quarter turn around the start line's centre.
      final v = knob - pivot;
      final turned = pivot + Offset(-v.dy, v.dx);
      c.onPointerMove(PointerMoveEvent(pointer: 1, position: turned));
      c.onPointerUp(PointerUpEvent(pointer: 1, position: turned));
      expect((param('axisAngle') - (-90)).abs(), closeTo(90, 1));
    });
  });

  test('zone tints are part of the visual layer', () async {
    const w = 200.0, hgt = 200.0;
    setStageSize(w, hgt);
    final l = layer('rect')..content.size = [60, 160];
    (l.effectStack.single.params['axisAngle'] as Track).defaultValue = -90.0;
    final p = Project(layers: [l]);
    Future<ByteData> paint() async {
      final rec = ui.PictureRecorder();
      paintStage(
        canvas: ui.Canvas(rec),
        size: const ui.Size(w, hgt),
        contentPicture: null,
        frameWidth: w,
        frameHeight: hgt,
        project: p,
        selectedLayer: l,
        globalFrame: 0,
        camera: StageCamera(),
        activeDrag: null,
      );
      final img = await rec.endRecording().toImage(w.round(), hgt.round());
      return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    }

    final camera = StageCamera()..updateLayout(frame: const ui.Size(w, hgt), viewport: const ui.Size(w, hgt));
    // inside the static zone (bottom of the stick), away from any line.
    final pt = camera.frameToScreen(const Offset(100, 100 + 70));
    int blue(ByteData d) => d.getUint8((pt.dy.round() * w.round() + pt.dx.round()) * 4 + 2);
    final shown = blue(await paint());
    hideVisualLayer = true;
    final hidden = blue(await paint());
    expect(shown, greaterThan(hidden), reason: 'the blue tint is drawn only with the visual layer on');
  });
}
