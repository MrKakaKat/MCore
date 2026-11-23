import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

Future<String> png(String dir) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(const ui.Rect.fromLTWH(0, 0, 64, 64), ui.Paint()..color = const ui.Color(0xFF00FF00));
  c.drawRect(const ui.Rect.fromLTWH(16, 16, 32, 32), ui.Paint()..color = const ui.Color(0xFFFF0000));
  final img = await rec.endRecording().toImage(64, 64);
  final b = await img.toByteData(format: ui.ImageByteFormat.png);
  final f = File('$dir/a.png')..writeAsBytesSync(b!.buffer.asUint8List());
  return f.path;
}

void main() {
  setUpAll(registerBuiltinEffects);
  for (final where in ['on the placed project', 'inside it']) {
    testWidgets('chroma $where: the picture shows and new frames stop', (tester) async {
      fps = 60;
      setStageSize(400, 400);
      final dir = Directory.systemTemp.createTempSync('ref_chroma_');
      final path = await tester.runAsync(() => png(dir.path));
      final img = createImageLayer(imageSourceType: 'file', imagePath: path, naturalWidth: 200, naturalHeight: 200)
        ..id = 'I'
        ..durationFrames = 600;
      if (where == 'inside it') {
        img.chromaKey
          ..enabled = true
          ..color = '#00ff00';
      }
      final src = RefSource(id: 'src', name: 'src', revision: 1, project: Project(layers: [img]), fps: 60, width: 400, height: 400, durationFrames: 600);
      final r = CanvasRenderer()..setSize(400, 400);
      r.refSources['src'] = src;
      r.refChain = ['host'];
      final refs = [
        for (var i = 0; i < 2; i++)
          createProjectRefLayer(src, id: 'R$i', frameW: 400, frameH: 400, hostFps: 60)..startFrame = i * 30
      ];
      if (where == 'on the placed project') {
        for (final ref in refs) {
          ref.chromaKey
            ..enabled = true
            ..color = '#00ff00';
        }
      }
      final host = Project(layers: refs);
      var renders = 0;
      r.onImageDecoded = () {
        renders++;
        r.renderFrame(host, 40);
      };
      await tester.runAsync(() async {
        r.renderFrame(host, 40);
        await Future<void>.delayed(const Duration(seconds: 3));
        r.renderFrame(host, 40);
      });
      final out = await tester.runAsync(() async {
        final im = await r.captureFrame();
        return (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      });
      int px(int x, int y, int c) => out!.getUint8((y * 400 + x) * 4 + c);
      // the placed project shows (its red middle), its green keyed out,
      // and the new frames pictures asked for came to an end.
      expect([px(200, 200, 0), px(200, 200, 3)], [255, 255]);
      expect(px(120, 120, 3), 0);
      expect(renders, lessThan(20));
      await tester.pump(const Duration(seconds: 3));
      dir.deleteSync(recursive: true);
    });
  }
}
