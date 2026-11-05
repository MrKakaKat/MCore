import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/text/text_view.dart';

void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });
  setUp(() => ParamEditor.resetModes(expanded: true));

  test('Typewriter at the halfway frame shows half the letters', () async {
    final l = createTextLayer(text: 'HHHH', fontSize: 60);
    l.durationFrames = 100;
    l.content.size = [300, 100];
    l.content.text!.animators.add(textAnimatorPreset('Typewriter', frames: 40));
    final r = CanvasRenderer()..setSize(400, 200);
    Future<(int, int)> inked(int f) async {
      r.renderFrame(Project(layers: [l]), f);
      final img = await r.captureFrame();
      final b = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      var left = 0, right = 0;
      for (var x = 0; x < 400; x++) {
        if (b.getUint8((100 * 400 + x) * 4 + 3) > 128) x < 200 ? left++ : right++;
      }
      return (left, right);
    }

    final (l0, r0) = await inked(0);
    expect(l0 + r0, 0, reason: 'nothing typed at the start');
    final (l1, r1) = await inked(20);
    expect(l1, greaterThan(10), reason: 'the first half typed');
    expect(r1, 0, reason: 'the second half not yet');
    final (l2, r2) = await inked(40);
    expect(r2, greaterThan(10));
    expect(l2, greaterThan(10));
  });

  testWidgets('Text tab: add a preset, edit its range and props; its keys show in the Text row', (tester) async {
    final app = AppState();
    app.addTextLayer();
    final layer = app.project.layers.last;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 560, child: TextView(app: app)))));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    final section = find.byKey(const ValueKey('text-section-Animators'));
    await tester.scrollUntilVisible(section, 200, scrollable: list);
    // a little further, so the header isn't at the very edge.
    await tester.drag(list, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(section);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('text-anim-add')), 150, scrollable: list);
    await tester.tap(find.byKey(const ValueKey('text-anim-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wave').last);
    await tester.pumpAndSettle();
    final t = layer.content.text!;
    expect(t.animators.single.name, 'Wave');
    expect(app.selectedTextAnimator, 0);
    // unit -> words, a property added.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('text-anim-unit-word')), 150, scrollable: list);
    await tester.tap(find.byKey(const ValueKey('text-anim-unit-word')));
    await tester.pump();
    expect(t.animators.single.unit, 'word');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('text-anim-prop-add')), 150, scrollable: list);
    await tester.drag(list, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text-anim-prop-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('rotation').last);
    await tester.pumpAndSettle();
    expect(t.animators.single.props.containsKey('rotation'), isTrue);
    // its offset keys are in the expanded Text row.
    final rows = keyDetailRows(layer);
    expect(rows['Text'], isNotEmpty);
  });
}
