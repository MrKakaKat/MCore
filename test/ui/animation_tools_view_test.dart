import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/preset_store.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/effects/effects_view.dart';
import 'package:movement_mobile/ui/presets/presets_view.dart';
import 'package:movement_mobile/ui/settings/settings_view.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';

/// Reverse keys, animation presets, time quantize, copy/paste effect and
/// the Settings tab.
void main() {
  late AppState app;
  late Layer layer;

  setUpAll(registerBuiltinEffects);
  setUp(() {
    kfSelectedFrames = {};
    kfMultiselectMode = false;
    ParamEditor.resetModes(expanded: true);
    app = AppState();
    layer = findLayer(app.project, app.selection.selectedLayer)!;
  });

  Future<void> pump(WidgetTester tester, Widget view) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 900, child: view))));
    await tester.pumpAndSettle();
  }

  testWidgets('Keyframes tab: reverse adds a mirrored copy after the selection and selects it', (tester) async {
    layer.transform.rotation.keyframes.addAll([Keyframe(frame: 10, value: 5.0), Keyframe(frame: 40, value: 15.0)]);
    await pump(tester, KeyframesEditorView(app: app));
    final button = find.byTooltip('reverse: add a mirrored copy after the selected keys');
    expect(tester.widget<IconButton>(find.ancestor(of: button, matching: find.byType(IconButton)).first).onPressed, isNull,
        reason: 'nothing selected yet');

    kfSelectedFrames = {10, 40};
    app.commitEdit();
    await tester.pump();
    await tester.tap(button);
    await tester.pump();

    expect([for (final k in layer.transform.rotation.keyframes) k.frame], [10, 40, 70]);
    expect(layer.transform.rotation.keyframes.last.value, 5.0);
    expect(kfSelectedFrames, {70});
    app.performUndo();
    expect(findLayer(app.project, layer.id)!.transform.rotation.keyframes.length, 2);
  });

  testWidgets('Presets tab shows the object and the animation lists; saving animation needs keys', (tester) async {
    final dir = Directory.systemTemp.createTempSync('anim_presets');
    addTearDown(() => dir.deleteSync(recursive: true));
    app.presetStore = PresetStore(dir);
    await pump(tester, PresetsView(app: app));
    expect(find.text('Object presets'), findsOneWidget);
    expect(find.text('Animation presets'), findsOneWidget);
    OutlinedButton saveAnim() =>
        tester.widget<OutlinedButton>(find.ancestor(of: find.text('Save animation (keys only)'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
    expect(saveAnim().onPressed, isNull, reason: 'no keys on the object');
    layer.transform.opacity.keyframes.add(Keyframe(frame: 0, value: 1.0));
    app.commitEdit();
    await tester.pump();
    expect(saveAnim().onPressed, isNotNull);
  });

  test('animation presets live in their own folder and apply at the playhead', () async {
    final dir = Directory.systemTemp.createTempSync('anim_presets');
    addTearDown(() => dir.deleteSync(recursive: true));
    app.presetStore = PresetStore(dir);
    layer.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 20, value: 90.0)]);
    await app.animationPresetStore!.save('spin', animationPresetToJson(layer));
    expect(await app.presetStore!.list(), isEmpty, reason: 'not mixed into the object presets');
    final saved = (await app.animationPresetStore!.list()).single;

    layer.transform.rotation.keyframes.clear();
    layer.transform.rotation.defaultValue = 30.0;
    app.setFrame(50);
    app.applyAnimationPresetTo(layer.id, saved.params);
    final l = findLayer(app.project, layer.id)!;
    expect([for (final k in l.transform.rotation.keyframes) k.frame], [50, 70]);
    expect([for (final k in l.transform.rotation.keyframes) k.value], [30.0, 120.0]);
  });

  testWidgets('Time quantize is added from the effect list and sets the layer fps', (tester) async {
    // tall: the effect list (now with Outline) fits on screen.
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(tester, EffectsView(app: app));
    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Time quantize').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ effect'));
    await tester.pumpAndSettle();
    expect(layer.timeQuantize.enabled, isTrue);
    expect(find.text('1. Time quantize'), findsOneWidget);
    expect(find.text('Fps'), findsOneWidget);
  });

  testWidgets('copy effect on one object, paste it on another', (tester) async {
    layer.effectStack.add(createEffectInstance('squeeze_axis', 'fx1', layer));
    await pump(tester, EffectsView(app: app));
    expect(find.byTooltip('paste effect'), findsNothing);
    await tester.tap(find.byTooltip('copy effect'));
    await tester.pump();

    final other = findLayer(app.project, 'L_parent')!;
    app.selectLayer(other.id);
    await tester.pump();
    await tester.tap(find.byTooltip('paste effect'));
    await tester.pump();
    expect(findLayer(app.project, other.id)!.effectStack.single.effectId, 'squeeze_axis');
  });

  testWidgets('Settings tab: "Hide top icons" hides the stage buttons', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.ios_share), findsOneWidget);

    final tabRail = find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.horizontal);
    await tester.dragUntilVisible(find.text('Settings'), tabRail, const Offset(-100, 0));
    await tester.ensureVisible(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Hide top icons'), 60,
        scrollable: find.descendant(of: find.byType(SettingsView), matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(find.text('Hide top icons'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide top icons'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.ios_share), findsNothing);
  });
}
