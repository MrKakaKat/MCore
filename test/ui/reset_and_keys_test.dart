import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';
import 'package:movement_mobile/ui/stage/snapping_settings_dialog.dart';
import 'package:movement_mobile/ui/stage/stage_settings_dialog.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';

/// Reset buttons, the master key, the background dialog and
/// resolution-relative shape sizes.
void main() {
  late AppState app;
  setUp(() => app = AppState());
  tearDown(() => app.dispose());

  Future<void> pumpView(WidgetTester tester, Widget view) async {
    // tall: each open ruler has its station row under it.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 1600, child: view))));
    await tester.pumpAndSettle();
  }

  test('new shapes scale with the frame: 46px at 480, ~103px at 1080', () {
    app.addLayer('rect');
    expect(app.project.layers.last.content.size, equals([46.0, 46.0]));
    app.setFrameSize(1080, 1080);
    app.addLayer('circle');
    expect(app.project.layers.last.content.size[0], closeTo(103.5, 1e-9));
  });

  testWidgets('Movement: rotation reset puts the default back', (tester) async {
    ParamEditor.resetModes(expanded: true); // reset shows on an opened row
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.transform.rotation.defaultValue = 45.0;
    await pumpView(tester, ParamsPanelView(app: app));

    // rows: anchor, scale, rotation, opacity (no tension without anchor keys)
    await tester.tap(find.byIcon(Icons.restart_alt).at(2));
    await tester.pump();
    expect(layer.transform.rotation.defaultValue, equals(0.0));
  });

  testWidgets('Movement: resetting an animated parameter changes the key being shown, not the animation', (tester) async {
    ParamEditor.resetModes(expanded: true); // reset shows on an opened row
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    layer.transform.opacity.keyframes
        .addAll([Keyframe(frame: 0, value: 0.2), Keyframe(frame: 10, value: 0.4)]);
    app.setFrame(layer.startFrame + 50); // after the last key
    await pumpView(tester, ParamsPanelView(app: app));

    await tester.tap(find.byIcon(Icons.restart_alt).at(3));
    await tester.pump();
    expect(layer.transform.opacity.keyframes.map((k) => k.value), equals([0.2, 1.0]));
  });

  testWidgets('Snapping: a sensitivity reset restores its default', (tester) async {
    app.toggleSnapEnabled();
    app.toggleSnapEdgeToEdge();
    app.setSnapSensitivityEdgeToEdgePx(25);
    await pumpView(tester, SnappingSettingsView(app: app));

    await tester.tap(find.byIcon(Icons.restart_alt).first);
    await tester.pump();
    expect(app.snapSensitivityEdgeToEdgePx, equals(8));
  });

  testWidgets('Keyframes tab: the master key keys every parameter, and removes them again', (tester) async {
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    await pumpView(tester, KeyframesEditorView(app: app));
    final local = localFrameOf(layer, app.currentFrame);

    await tester.tap(find.byIcon(Icons.key_outlined));
    await tester.pumpAndSettle();
    expect(allTracksKeyedAt(layer, local), isTrue);

    await tester.tap(find.byIcon(Icons.key));
    await tester.pumpAndSettle();
    expect(allTracksKeyedAt(layer, local), isFalse);
  });

  testWidgets('Stage: background opens in its own dialog', (tester) async {
    await pumpView(tester, StageSettingsView(app: app));
    expect(find.byType(BackgroundPicker), findsNothing, reason: 'swatches are no longer inline');

    await tester.tap(find.text('Transparent'));
    await tester.pumpAndSettle();
    expect(find.byType(BackgroundPicker), findsOneWidget);

    await tester.tap(find.byTooltip('#000000'));
    await tester.pump();
    expect(app.background, equals(const Color(0xFF000000)));
  });

  testWidgets('Movement: every parameter\'s key icon sits in the same column', (tester) async {
    await pumpView(tester, ParamsPanelView(app: app));
    final keys = find.byTooltip('toggle keyframe at current frame');
    final rights = [for (final e in keys.evaluate()) tester.getRect(find.byWidget(e.widget)).right];
    expect(rights.length, 4, reason: 'anchor, scale, rotation, opacity');
    expect(rights.toSet().length, 1, reason: 'one right edge for single- and two-value rows');
  });

  testWidgets('Stage: "Scale objects with resolution" sits above the custom size, and the stage mirror toggles', (tester) async {
    await pumpView(tester, StageSettingsView(app: app));
    expect(tester.getTopLeft(find.text('Scale objects with resolution')).dy,
        lessThan(tester.getTopLeft(find.text('Custom size (px)')).dy));

    await tester.ensureVisible(find.text('Mirror stage'));
    await tester.tap(find.widgetWithText(FilterChip, 'Horizontal'));
    await tester.pump();
    expect(app.stageMirrorX, isTrue);
    expect(app.renderer.mirrorX, isTrue, reason: 'exports follow');
  });
}
