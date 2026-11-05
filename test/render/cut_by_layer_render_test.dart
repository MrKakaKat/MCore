import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform, Easing;
import 'package:movement_mobile/ui/masks/masks_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';

Layer diamond(String id, double x, double y, double r) {
  final l = createLayer('rect')
    ..id = id
    ..color = '#3060c0'
    ..content.size = [r * math.sqrt2, r * math.sqrt2]
    ..transform.rotation.defaultValue = 45.0
    ..transform.anchor.defaultValue = [x / 1000, y / 1000];
  // the "notched diamond" look: a black centred outline, mitred.
  final o = createEffectInstance('outline', 'o_$id', l);
  setTrackValueAt(o.params['width'] as Track, 0, 16.0);
  setTrackValueAt(o.params['smoothness'] as Track, 0, 0.0);
  o.params['color'] = '#000000';
  o.params['position'] = 'center';
  o.params['join'] = 'miter';
  l.effectStack.add(o);
  return l;
}

void main() {
  setUpAll(registerBuiltinEffects);

  for (final (name, sx, sy) in [('1', 500.0, 700.0), ('2', 440.0, 690.0), ('5', 650.0, 550.0)]) {
    test('notched diamond, position $name: stroke along the notch, the gap between them see-through', () async {
      setStageSize(1000, 1000);
      clearCutCaches();
      clearStateCaches();
      final big = diamond('big', 500, 500, 200), small = diamond('small', sx, sy, 70);
      big.cuts.add(CutByLayer(cutterId: 'small', gap: Track(20.0, false)));
      final p = Project(layers: [big, small]);
      final r = CanvasRenderer()..setSize(1000, 1000);
      r.backgroundColor = null;
      r.renderFrame(p, 0);
      final img = await r.captureFrame();
      final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      List<int> px(double x, double y) => [for (var c = 0; c < 4; c++) b.getUint8((y.round() * 1000 + x.round()) * 4 + c)];

      // the notch's edges: the cut outline's edges not on the big diamond.
      final m = toFrameMatrix(getLayerStateAt(p, 'big', 0).matrix);
      final rings = [
        for (final ring in layerVectorRings(p, big, 0)!) [for (final q in ring) applyAffine(m, q)]
      ];
      double distBig(List<double> q) => ((q[0] - 500).abs() + (q[1] - 500).abs() - 200).abs() / math.sqrt2;
      var checked = 0;
      for (final ring in rings) {
        for (var i = 0; i < ring.length; i++) {
          final a = ring[i], c = ring[(i + 1) % ring.length];
          final mid = [(a[0] + c[0]) / 2, (a[1] + c[1]) / 2];
          final len = math.sqrt(math.pow(c[0] - a[0], 2) + math.pow(c[1] - a[1], 2));
          if (distBig(mid) < 0.5 || len < 24) continue;
          // on the notch edge: the black stroke.
          final on = px(mid[0], mid[1]);
          expect(on[3], greaterThan(200), reason: 'stroke at $mid');
          expect(on[0], lessThan(60));
          // 10 px toward the small diamond: between the two strokes.
          var nx = -(c[1] - a[1]) / len, ny = (c[0] - a[0]) / len;
          if ((sx - mid[0]) * nx + (sy - mid[1]) * ny < 0) {
            nx = -nx;
            ny = -ny;
          }
          expect(px(mid[0] + nx * 10, mid[1] + ny * 10)[3], lessThan(40), reason: 'gap by $mid');
          checked++;
        }
      }
      expect(checked, greaterThan(0));
    });
  }

  testWidgets('Cut by layer UI: add a cut, the cutter picker refuses a circle', (tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ParamEditor.resetModes(expanded: true);
    final app = AppState();
    final a = findLayer(app.project, app.selection.selectedLayer)!..name = 'Alpha';
    app.addLayer('rect');
    final b = app.project.layers.last..name = 'Beta';
    b.cuts.add(CutByLayer(cutterId: a.id));
    app.selection.selectedLayer = a.id;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MasksView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fold-cut by layer'))); // folds start folded
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cut-add')));
    await tester.pumpAndSettle();
    expect(a.cuts, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('cut-cutter-0')));
    await tester.pumpAndSettle();
    expect(find.text('Beta (circle)'), findsWidgets);
    await tester.tap(find.text('Beta (circle)').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(a.cuts.single.cutterId, isNull, reason: 'a circle is not picked');
    if (find.text('None').evaluate().length > 1) {
      await tester.tap(find.text('None').last);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(const ValueKey('cut-mode-0-intersect')));
    await tester.pumpAndSettle();
    expect(a.cuts.single.mode, 'intersect');
  });

  test('the outline follows the cutter as it moves (no stale contour)', () async {
    setStageSize(1000, 1000);
    clearCutCaches();
    final big = diamond('big', 500, 500, 200), small = diamond('small', 500, 700, 70);
    small.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [0.5, 0.7], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 60, value: [0.65, 0.55]),
    ];
    big.cuts.add(CutByLayer(cutterId: 'small', gap: Track(20.0, false), hideCutter: true));
    final p = Project(layers: [big, small]);
    final r = CanvasRenderer()..setSize(1000, 1000);
    r.backgroundColor = null;
    Future<int> alphaAt(int f, int x, int y) async {
      clearStateCaches();
      r.renderFrame(p, f);
      final img = await r.captureFrame();
      final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return b.getUint8((y * 1000 + x) * 4 + 3);
    }

    // frame 0: the notch apex (500, 601.7) - just below it is cut away;
    // frame 60 the cutter has gone to the side and it's filled again.
    expect(await alphaAt(0, 500, 640), lessThan(40), reason: 'cut at frame 0 (and the cutter hidden)');
    expect(await alphaAt(60, 500, 640), greaterThan(200), reason: 'filled again at frame 60');
  });
}
