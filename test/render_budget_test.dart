import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Project heavy() {
  final layers = <Layer>[];
  for (var i = 0; i < 6; i++) {
    final l = createLayer('rect')
      ..id = 'L$i'
      ..name = 'swinging $i'
      ..durationFrames = 20000
      ..parentId = i == 0 ? null : 'L${i - 1}';
    l.transform.anchor.keyframes = [
      for (var k = 0; k <= 40; k++) Keyframe(frame: k * 500, value: <double>[k.isEven ? 0.2 : 0.8, 0.5]),
    ];
    l.pendulum = Pendulum(enabled: true);
    l.follow.enabled = i == 5;
    layers.add(l);
  }
  return Project(layers: layers);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
  });

  test('a frame past its time stops part way and says where; with no limit it is drawn whole', () {
    final r = CanvasRenderer()
      ..setSize(200, 200)
      ..timeBudget = const Duration(milliseconds: 1);
    final sw = Stopwatch()..start();
    r.renderFrame(heavy(), 19000);
    expect(r.lastOverBudget?.frame, 19000);
    expect(sw.elapsedMilliseconds, lessThan(3000));
    final whole = CanvasRenderer()..setSize(200, 200);
    whole.renderFrame(heavy(), 100);
    expect(whole.lastOverBudget, isNull);
    expect(RenderBudget.over, isFalse, reason: 'no limit left behind');
  });

  test('playing: a frame past its time stops playback with a notice', () {
    final app = AppState();
    app.project.layers
      ..clear()
      ..addAll(heavy().layers);
    app.renderer.timeBudget = const Duration(microseconds: 1);
    app.setMaxFrame(20000);
    app.togglePlay();
    expect(app.playing, isTrue);
    app.setFrame(15000);
    expect(app.playing, isFalse);
    expect(app.overBudgetNotice, contains('15000'));
    app.dispose();
  });
}
