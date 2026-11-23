import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

void main() {
  testWidgets('a big picture is decoded no bigger than drawing needs; trimming lets caches go', (tester) async {
    setStageSize(400, 400);
    final dir = Directory.systemTemp.createTempSync('img_mem_');
    final path = await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 4000, 200), ui.Paint()..color = const ui.Color(0xFFFF0000));
      final img = await rec.endRecording().toImage(4000, 200);
      final b = await img.toByteData(format: ui.ImageByteFormat.png);
      return (File('${dir.path}/big.png')..writeAsBytesSync(b!.buffer.asUint8List())).path;
    });
    final layer = createImageLayer(imageSourceType: 'file', imagePath: path, naturalWidth: 4000, naturalHeight: 200)
      ..id = 'big'
      ..chromaKey.enabled = true
      ..chromaKey.color = '#00ff00';
    final p = Project(layers: [layer]);
    final r = CanvasRenderer()
      ..setSize(400, 400)
      ..maxImageSide = 1000;
    await tester.runAsync(() async {
      r.renderFrame(p, 0);
      for (var i = 0; i < 100 && r.decodedImageOf(layer, 0) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final img = r.decodedImageOf(layer, 0)!;
      expect([img.width, img.height], [1000, 50]);
      r.renderFrame(p, 0);
      for (var i = 0; i < 100 && r.busy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(r.sourcePixelEntries, greaterThan(0));
      r.trimMemory();
      expect(r.sourcePixelEntries, 0);
    });
    r.dispose();
    await tester.pump(const Duration(seconds: 3));
    dir.deleteSync(recursive: true);
  });
}
