import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  testWidgets('chroma on a placed project while it plays: pixels kept stay few', (tester) async {
    fps = 60;
    setStageSize(400, 400);
    final l = createLayer('rect')..id = 'S'..durationFrames = 600..color = '#00ff00';
    l.transform.anchor.keyframes = [Keyframe(frame: 0, value: <double>[0.2, 0.5]), Keyframe(frame: 600, value: <double>[0.8, 0.5])];
    final src = RefSource(id: 'src', name: 'src', revision: 1, project: Project(layers: [l]), fps: 60, width: 400, height: 400, durationFrames: 600);
    final r = CanvasRenderer()..setSize(400, 400);
    r.refSources['src'] = src;
    r.refChain = ['host'];
    final ref = createProjectRefLayer(src, id: 'R', frameW: 400, frameH: 400, hostFps: 60)
      ..chromaKey.enabled = true
      ..chromaKey.color = '#00ff00';
    final host = Project(layers: [ref]);
    for (var f = 0; f < 60; f++) {
      r.renderFrame(host, f);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    expect(r.sourcePixelEntries, lessThan(8), reason: 'a placed project\'s frames are let go (they ran the phone out of memory)');
    await tester.pump(const Duration(seconds: 3));
  });
}
