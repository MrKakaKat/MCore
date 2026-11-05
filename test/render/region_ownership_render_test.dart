import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_painter.dart';

/// Two opaque squares, A (red) over B (blue), overlapping in the middle;
/// both with Regions of their own over {A, B}.
({Project p, Layer a, Layer b}) scene() {
  setStageSize(400, 400);
  clearStateCaches();
  clearCutCaches();
  clearRegionBakes();
  Layer sq(String id, String color, double x) => createLayer('rect')
    ..id = id
    ..name = id.toUpperCase()
    ..color = color
    ..content.size = [160, 160]
    ..transform.anchor.defaultValue = [x, 0.5];
  final b = sq('b', '#0000ff', 0.55)..maskRegions = MaskRegions(sources: ['b', 'a'], opacity: {1: track(1.0), 3: track(1.0)});
  final a = sq('a', '#ff0000', 0.45)..maskRegions = MaskRegions(sources: ['a', 'b'], opacity: {1: track(1.0), 3: track(1.0)});
  return (p: Project(layers: [b, a]), a: a, b: b);
}

Future<List<int>> px(Project p, int x, int y) async {
  final r = CanvasRenderer()..setSize(400, 400);
  r.backgroundColor = null;
  r.renderFrame(p, 0);
  final img = await r.captureFrame();
  final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final o = (y * 400 + x) * 4;
  return [d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2), d.getUint8(o + 3)];
}

void main() {
  // the overlap's middle: x 200, y 200.
  test('hiding A·B · A shows B through the overlap', () async {
    final s = scene();
    s.a.maskRegions!.opacity[3] = track(0.0);
    final c = await px(s.p, 200, 200);
    expect(c[2], greaterThan(200));
    expect(c[0], lessThan(40));
  });

  test('hiding A·B · B changes nothing while A is on top', () async {
    final s = scene();
    s.b.maskRegions!.opacity[3] = track(0.0);
    final c = await px(s.p, 200, 200);
    expect(c[0], greaterThan(200));
    expect(c[3], 255);
  });

  test('hiding both leaves a hole; A − B and B − A stay', () async {
    final s = scene();
    s.a.maskRegions!.opacity[3] = track(0.0);
    s.b.maskRegions!.opacity[3] = track(0.0);
    expect((await px(s.p, 200, 200))[3], 0);
    expect((await px(s.p, 120, 200))[0], greaterThan(200), reason: 'A − B');
    expect((await px(s.p, 280, 200))[2], greaterThan(200), reason: 'B − A');
  });

  test('picking an owned region outlines its owner layer too', () async {
    final s = scene();
    showRegionTints = true;
    stageSelectedRegionSig = 3;
    addTearDown(() {
      showRegionTints = false;
      stageSelectedRegionSig = null;
    });
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, 400, 400));
    paintStage(
      canvas: canvas,
      size: const ui.Size(400, 400),
      contentPicture: null,
      frameWidth: 400,
      frameHeight: 400,
      project: s.p,
      selectedLayer: s.a,
      globalFrame: 0,
      camera: StageCamera(),
      activeDrag: null,
    );
    final img = await rec.endRecording().toImage(400, 400);
    final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    bool whiteNear(int x, int y) {
      for (var dx = -2; dx <= 2; dx++) {
        final o = (y * 400 + x + dx) * 4;
        if (d.getUint8(o) > 180 && d.getUint8(o + 1) > 180 && d.getUint8(o + 2) > 180) return true;
      }
      return false;
    }

    // A's left edge (x = 180 - 80 = 100) is outside the overlap: only the
    // owner outline is drawn there.
    expect(whiteNear(100, 160), isTrue);
  });
}
