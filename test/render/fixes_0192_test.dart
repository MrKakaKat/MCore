import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/stage/stage_camera.dart';
import 'package:movement_mobile/ui/stage/stage_view.dart';

void main() {
  tearDown(() {
    keyMode = 'base';
    activeAnimLayer = 0;
  });

  test('order keys: a third key (a new range) doesn\'t move the path before it; its stops stay in sight', () {
    setStageSize(200, 100);
    final app = AppState()..setFrameSize(200, 100);
    keyMode = 'order';
    activeAnimLayer = 0;
    final l = findLayer(app.project, app.selection.selectedLayer)!..durationFrames = 60;
    void key(int f, List<double> to) {
      app.setFrame(l.startFrame + f);
      orderKeyTarget(l, f);
      final trk = editTrackOf(l.transform.anchor);
      if (!trk.keyframes.any((k) => k.frame == f)) {
        trk.keyframes
          ..add(Keyframe(frame: f, value: evaluateTrackOwn(app.project, trk, f.toDouble()), temporal: newKeyEasing()))
          ..sort((a, b) => a.frame.compareTo(b.frame));
      }
      if (activeAnimLayer > 0) packOrderLayer(l, activeAnimLayer);
      clearStateCaches();
      final st = getLayerStateAt(app.project, l.id, l.startFrame + f);
      AnchorDragOp.grab(app.project, l, l.startFrame + f, [st.matrix[4] * 200, st.matrix[5] * 100])
          .apply(app.project, l.startFrame + f, to);
      clearStateCaches();
    }

    key(0, [40, 50]);
    key(20, [100, 20]);
    key(40, [160, 50]);
    List<int> at(int f) {
      final s = getLayerStateAt(app.project, l.id, l.startFrame + f);
      return [(s.matrix[4] * 200).round(), (s.matrix[5] * 100).round()];
    }

    expect(at(0), [40, 50]);
    expect(at(20), [100, 20]);
    expect(at(40), [160, 50]);
    // the stops of the other range show while the new one is edited.
    expect(getOtherStationsScreen(app.project, l).length, greaterThanOrEqualTo(2));
  });

  testWidgets('pick several: an object under the selected one\'s handles is picked too', (tester) async {
    final app = AppState()..setFrameSize(400, 400);
    app.project.layers.clear();
    Layer rect(String id, double x, double y, double s) => createLayer('rect')
      ..id = id
      ..content.size = [s, s]
      ..transform.anchor.defaultValue = [x / 400, y / 400];
    app.project.layers.addAll([rect('a', 150, 200, 60), rect('b', 260, 200, 40), rect('c', 182, 232, 20)]);
    clearStateCaches();
    app.selectLayer('a');
    app.setAppPreference('stageMultiSelect', true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 400, height: 400, child: StageView(app: app)))));
    await tester.pumpAndSettle();
    final cam = (tester.state(find.byType(StageView)) as dynamic).debugCamera as StageCamera;
    final origin = tester.getTopLeft(find.byType(StageView));
    for (final p in const [Offset(260, 200), Offset(182, 232)]) {
      await tester.tapAt(origin + cam.frameToScreen(p));
      await tester.pumpAndSettle();
    }
    expect(app.selectedGroup, {'a', 'b', 'c'});
    app.setAppPreference('stageMultiSelect', false);
  });
}
