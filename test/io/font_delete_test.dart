import 'dart:io';

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/font_store.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/text/text_view.dart';

/// Deleting a loaded font: gone from the library and its folder; text that
/// used it falls back to the built-in font.
void main() {
  final roboto = File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync();
  setUpAll(() => registerFont(defaultFontId, roboto));

  test('FontStore.delete removes the file and unloads the font', () async {
    final dir = await Directory.systemTemp.createTemp('fonts_');
    addTearDown(() => dir.delete(recursive: true));
    final store = FontStore(dir);
    final id = await store.import(roboto, 'Mine.ttf');
    expect(registeredFonts().containsKey(id), isTrue);
    expect(File('${dir.path}/fonts/$id').existsSync(), isTrue);

    await store.delete(id);
    expect(registeredFonts().containsKey(id), isFalse);
    expect(File('${dir.path}/fonts/$id').existsSync(), isFalse);
    expect(unregisterFont(defaultFontId), isFalse, reason: 'the built-in font stays');
  });

  testWidgets('Text tab: delete a font from the library; its text layers switch to the default', (tester) async {
    ParamEditor.resetModes(expanded: true);
    final app = AppState();
    app.addTextLayer();
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    registerFont('font_x', roboto, name: 'Mine');
    app.editText(layer.id, (t) => t.fontId = 'font_x');
    expect(app.textLayersUsingFont('font_x'), 1);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 600, child: TextView(app: app)))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('loaded fonts'));
    await tester.pumpAndSettle();
    expect(find.text('used by 1 text layer(s) here'), findsOneWidget);
    await tester.tap(find.byTooltip('delete Mine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(registeredFonts().containsKey('font_x'), isFalse);
    expect(findLayer(app.project, layer.id)!.content.text!.fontId, defaultFontId);
    expect(find.text('Only the built-in font is left.'), findsOneWidget);
  });
}
