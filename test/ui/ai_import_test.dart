import 'dart:io';

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/ai/ai_dialogs.dart';

void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });

  test('every guide recipe renders its first and last frame', () async {
    for (final r in mcjRecipes) {
      final res = expandMcj(extractMcjJson(r.json));
      expect(res.report, isEmpty, reason: r.title);
      final rd = CanvasRenderer()..setSize(res.width, res.height);
      for (final f in [0, res.duration]) {
        clearStateCaches();
        rd.renderFrame(res.project, f);
        final img = await rd.captureFrame();
        expect(img.width, res.width.round(), reason: '${r.title} @$f');
        img.dispose();
      }
    }
  });

  testWidgets('paste a reply: its report shows before importing', (tester) async {
    McjResult? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await showAiImportDialog(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-paste')), '{"layers": [{"shape": "rect", "opacity": 7}');
    await tester.tap(find.byKey(const ValueKey('ai-read')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-error')), findsOneWidget, reason: 'cut off');
    await tester.enterText(find.byKey(const ValueKey('ai-paste')),
        'Here:\n```json\n{"layers": [{"shape": "rect", "opacity": 7}, {"shape": "blob"}]}\n```');
    await tester.tap(find.byKey(const ValueKey('ai-read')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Changed on the way in (2)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-import')));
    await tester.pumpAndSettle();
    expect(got!.project.layers, hasLength(1));
  });

  test('edit with AI: the layers are replaced in one undo step; a placeholder keeps the old media', () {
    final app = AppState();
    final photo = createImageLayer(imageSourceType: 'file', imagePath: 'p.png', naturalWidth: 100, naturalHeight: 80)
      ..name = 'photo';
    app.project.layers
      ..clear()
      ..add(photo);
    final before = app.project.layers.length;
    final r = expandMcj(extractMcjJson('{"layers": [{"name": "photo", "shape": "placeholder", "size": [300, 200]},'
        ' {"name": "dot", "shape": "circle"}]}'));
    app.replaceWithMcj(r);
    expect(app.project.layers.map((l) => l.name), ['photo', 'dot']);
    expect(app.project.layers.first.content.shape, photo.content.shape, reason: 'the media kept');
    expect(app.project.layers.first.content.size, [300.0, 200.0]);
    app.performUndo();
    expect(app.project.layers, hasLength(before));
    expect(app.project.layers.single.name, 'photo');
  });
}
