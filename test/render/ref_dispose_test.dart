import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  testWidgets('frames of a placed project let go are freed by the next frame, not piled up', (tester) async {
    fps = 60;
    setStageSize(400, 400);
    final box = createLayer('rect')
      ..id = 'b'
      ..durationFrames = 600;
    box.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 600, value: 360.0)]);
    final src = RefSource(id: 'src', name: 'src', revision: 1, project: Project(layers: [box]), fps: 60, width: 400, height: 400, durationFrames: 600);
    final refs = [for (var i = 0; i < 5; i++) createProjectRefLayer(src, id: 'R$i', frameW: 400, frameH: 400, hostFps: 60)..startFrame = i * 7];
    final r = CanvasRenderer()..setSize(400, 400);
    r.refSources['src'] = src;
    r.refChain = ['host'];
    final host = Project(layers: refs);
    for (var f = 0; f < 200; f++) {
      r.renderFrame(host, f);
    }
    final m = r.memoryReport();
    // at most a frame's worth waits (5 placed copies, 400 x 400).
    expect(m['waiting to go'] ?? 0, lessThanOrEqualTo(4));
    expect(m['placed frames'] ?? 0, lessThanOrEqualTo(96));
    r.dispose();
    await tester.pump(const Duration(seconds: 1));
  });
}
