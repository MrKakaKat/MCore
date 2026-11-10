import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/export/export_dialog.dart';

/// Real, run widget-level coverage of ExportView's own "SVG" segment
/// visibility - (vector export only when the project has no media, only
/// shapes). Deliberately does NOT tap Export itself - that drives the real
/// exportProjectToSvg/renderer path, same "unverified in this sandbox"
/// category as the rest of io/ (see export_dialog.dart's own doc comment);
/// this file only checks the widget's own conditional segment-list logic,
/// which is plain Dart, not an encode call.
void main() {
  late AppState app;

  setUp(() {
    app = AppState();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExportView(app: app))));
    await tester.pumpAndSettle();
  }

  testWidgets('the SVG export segment is offered for a shape-only project', (tester) async {
    await pump(tester);
    expect(find.text('SVG'), findsOneWidget);
  });

  testWidgets('SVG is offered with pictures too (it is the stage as it looks)', (tester) async {
    // deliberately NOT AppState.addImageLayer - that calls _render(),
    // which for an image-content layer triggers a real
    // ui.instantiateImageCodec decode, a documented hang risk in this
    // sandbox's test harness (see canvas_renderer.dart's own doc
    // comment: "exactly ONE instantiateImageCodec call per test file/
    // process" before it hangs). createLayer is pure data construction
    // (no rendering at all) - inserting it directly is enough to
    // exercise this widget's own conditional segment-list logic without
    // ever touching the decode path.
    app.project.layers.add(createImageLayer(imageSourceType: 'embedded', imageData: 'AAAA', naturalWidth: 10, naturalHeight: 10));
    await pump(tester);
    expect(find.text('SVG'), findsOneWidget);
  });

  testWidgets('selecting SVG: animation or one frame', (tester) async {
    await pump(tester);
    await tester.tap(find.text('SVG'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Plays by itself'), findsNothing);
    await tester.tap(find.text('One frame'));
    await tester.pump();
    expect(find.textContaining('Current frame'), findsOneWidget);
  });
}
