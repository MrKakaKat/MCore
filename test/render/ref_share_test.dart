import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  testWidgets('a picture on the stage and in placed projects is decoded once, shown in all', (tester) async {
    fps = 60;
    setStageSize(400, 400);
    final dir = Directory.systemTemp.createTempSync('ref_share_');
    final path = (await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 64, 64), ui.Paint()..color = const ui.Color(0xFFFF0000));
      final img = await rec.endRecording().toImage(64, 64);
      final b = await img.toByteData(format: ui.ImageByteFormat.png);
      return (File('${dir.path}/a.png')..writeAsBytesSync(b!.buffer.asUint8List())).path;
    }))!;
    Layer pic(String id) => createImageLayer(imageSourceType: 'file', imagePath: path, naturalWidth: 400, naturalHeight: 400)
      ..id = id
      ..durationFrames = 600;
    final src = RefSource(id: 'src', name: 'src', revision: 1, project: Project(layers: [pic('in')]), fps: 60, width: 400, height: 400, durationFrames: 600);
    final src2 = RefSource(id: 'src2', name: 'src2', revision: 1, project: Project(layers: [pic('in2')]), fps: 60, width: 400, height: 400, durationFrames: 600);
    final host = Project(layers: [
      pic('top')..content.size = [100, 100],
      createProjectRefLayer(src, id: 'R1', frameW: 400, frameH: 400, hostFps: 60),
      createProjectRefLayer(src2, id: 'R2', frameW: 400, frameH: 400, hostFps: 60),
    ]);
    final r = CanvasRenderer()..setSize(400, 400);
    r.refSources
      ..['src'] = src
      ..['src2'] = src2;
    r.refChain = ['host'];
    r.onImageDecoded = () => r.renderFrame(host, 0);
    final out = await tester.runAsync(() async {
      r.renderFrame(host, 0);
      for (var i = 0; i < 100 && r.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      r.renderFrame(host, 0);
      final im = await r.captureFrame();
      return (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    expect(r.imageStats().count, 1);
    // the placed projects show it (the whole frame red, not only the top
    // picture's middle).
    expect(out!.getUint8((100 * 400 + 100) * 4), 255);
    r.onImageDecoded = null;
    r.dispose();
    await tester.pump(const Duration(seconds: 1));
    dir.deleteSync(recursive: true);
  });
}
