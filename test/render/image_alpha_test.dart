import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/export.dart';

/// A transparent PNG keeps its transparency: the layer below shows
/// through its transparent part - on the plain draw path, through an
/// effect warp (texture path), with chroma key on, and in a PNG export.
void main() {
  setUpAll(registerBuiltinEffects);

  Future<List<int>> transparentHalfPng(WidgetTester tester) async {
    late List<int> png;
    await tester.runAsync(() async {
      // 20x20: left half opaque blue, right half fully transparent.
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 10, 20), ui.Paint()..color = const ui.Color(0xFF0000FF));
      final img = await rec.endRecording().toImage(20, 20);
      png = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    });
    return png;
  }

  Future<(AppState, Layer)> setUpApp(WidgetTester tester, {bool background = true}) async {
    final png = await transparentHalfPng(tester);
    final app = AppState()..setFrameSize(100, 100);
    app.project.layers.clear();
    app.renderer.backgroundColor = null;
    if (background) {
      app.project.layers.add(createLayer('rect')
        ..id = 'bg'
        ..color = '#ff0000'
        ..content.offset = [0, 0]
        ..content.size = [100, 100]
        ..transform.anchor.defaultValue = [0.5, 0.5]);
    }
    app.addImageLayer(imageSourceType: 'embedded', imageData: base64Encode(png), naturalWidth: 20, naturalHeight: 20);
    final image = app.project.layers.last
      ..content.size = [100, 100]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    return (app, image);
  }

  Future<ByteData> render(WidgetTester tester, AppState app, Layer image) async {
    late ByteData px;
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        app.renderer.renderFrame(app.project, 0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (app.renderer.decodedImageOf(image, 0) != null && i > 5) break;
      }
      app.renderer.renderFrame(app.project, 0);
      final out = await app.renderer.captureFrame();
      px = (await out.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    });
    return px;
  }

  List<int> at(ByteData px, int x, int y) => [for (var c = 0; c < 4; c++) px.getUint8((y * 100 + x) * 4 + c)];

  for (final variant in ['plain', 'effect', 'chroma']) {
    testWidgets('$variant: the background shows through the transparent half', (tester) async {
      final (app, image) = await setUpApp(tester);
      if (variant == 'effect') {
        image.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', image));
      }
      if (variant == 'chroma') {
        image.chromaKey
          ..enabled = true
          ..color = '#00ff00';
      }
      final px = await render(tester, app, image);
      expect(at(px, 20, 50)[2], greaterThan(200), reason: 'the opaque half of the image');
      expect(at(px, 80, 50), [255, 0, 0, 255], reason: 'the red layer below shows through');
    });
  }

  testWidgets('PNG export keeps the transparency', (tester) async {
    final (app, image) = await setUpApp(tester, background: false);
    await render(tester, app, image);
    late ByteData px;
    await tester.runAsync(() async {
      final bytes = await exportStillFrame(renderer: app.renderer, project: app.project, frame: 0, format: 'png');
      final codec = await ui.instantiateImageCodec(bytes);
      final img = (await codec.getNextFrame()).image;
      px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    });
    expect(at(px, 20, 50)[3], 255);
    expect(at(px, 80, 50)[3], 0, reason: 'transparent in the file too');
  });

  test('every file pick goes through pickOriginalFiles (no OS re-encode that drops alpha)', () {
    final offenders = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && !f.path.endsWith('file_pick.dart') && f.readAsStringSync().contains('FilePicker.platform.pickFiles'))
          f.path
    ];
    expect(offenders, isEmpty);
    expect(File('lib/io/file_pick.dart').readAsStringSync(), contains('allowCompression: false'));
  });
}
