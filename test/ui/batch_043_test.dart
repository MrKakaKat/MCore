import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/filters/filters_view.dart';
import 'package:movement_mobile/ui/params_panel/params_panel_view.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';
import 'package:movement_mobile/ui/timeline/timeline_rows_view.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  late AppState app;
  late Layer l;
  setUp(() {
    app = AppState()..setFrameSize(200, 100);
    app.project.layers.clear();
    l = createLayer('rect')
      ..id = 'top'
      ..name = 'top'
      ..durationFrames = 100;
    app.project.layers.add(l);
    app.selectLayer('top');
    kfSelectedFrames = {};
  });
  tearDown(() => kfSelectedFrames = {});

  Future<void> pump(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: w)));
    await tester.pumpAndSettle();
  }

  testWidgets('Edit the whole object: at the very top of Movement', (tester) async {
    await pump(tester, ParamsPanelView(app: app));
    final sw = find.byKey(const ValueKey('key-edit-all'));
    expect(sw, findsOneWidget);
    final y = tester.getTopLeft(sw).dy;
    expect(y, lessThan(tester.getTopLeft(find.byKey(const ValueKey('fit-contour'))).dy));
    await tester.tap(sw);
    await tester.pump();
    expect(l.editAll, isTrue);
  });

  testWidgets('colour wheels: the ticked ones move together; a list under the wheel', (tester) async {
    await pump(tester, FiltersView(app: app));
    final wheel = find.byKey(const ValueKey('wheel'));
    await tester.ensureVisible(wheel);
    await tester.pumpAndSettle();
    // Gamma ticked by default; Lift too.
    await tester.tap(find.byKey(const ValueKey('wheel-pick-lift')));
    await tester.pump();
    final c = tester.getCenter(wheel);
    await tester.dragFrom(c, const Offset(40, 0));
    await tester.pump();
    expect(l.filters.gamma[0], greaterThan(0), reason: 'gamma toward red');
    expect(l.filters.lift[0], greaterThan(0), reason: 'lift too, with it');
    expect(l.filters.gain, [0, 0, 0], reason: 'gain not ticked');
    expect(l.filters.lift[0], lessThan(l.filters.gamma[0]), reason: 'each by its own span');
    await tester.tap(find.byKey(const ValueKey('wheel-reset-lift')));
    await tester.pump();
    expect(l.filters.lift, [0, 0, 0]);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('picked keys: loop them, repeat them, base into a key layer', (tester) async {
    l.transform.rotation.keyframes.addAll([
      Keyframe(frame: 0, value: 0.0),
      Keyframe(frame: 10, value: 90.0),
    ]);
    kfSelectedFrames = {0, 10};
    await pump(tester, KeyframesEditorView(app: app));
    await tester.tap(find.byKey(const ValueKey('picked-keys-loop')));
    await tester.pump();
    expect(l.transform.rotation.loop, isTrue);
    app.performUndo();
    await tester.pump();
    final r = findLayer(app.project, 'top')!.transform.rotation;
    expect(r.loop, isFalse);
    await tester.tap(find.byKey(const ValueKey('picked-keys-repeat-plus')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('picked-keys-repeat')));
    await tester.pump();
    expect(findLayer(app.project, 'top')!.transform.rotation.keyframes.length, 6);
    await tester.tap(find.byKey(const ValueKey('picked-keys-to-layer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Into a new key layer'));
    await tester.pumpAndSettle();
    final lay = findLayer(app.project, 'top')!.transform.rotation;
    expect(lay.animLayers.single.track.keyframes.map((k) => k.frame), [0, 10]);
  });

  testWidgets('Timeline: take params and keys from the layer below', (tester) async {
    final below = createLayer('rect')
      ..id = 'under'
      ..name = 'under'
      ..durationFrames = 100;
    below.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 20, value: 45.0)]);
    app.project.layers.insert(0, below);
    l.transform.rotation.keyframes.add(Keyframe(frame: 20, value: 10.0));
    await pump(tester, TimelineRowsView(app: app));
    final b = find.byKey(const ValueKey('take-from-below'));
    await tester.ensureVisible(b);
    await tester.tap(b);
    await tester.pump();
    expect(l.transform.rotation.keyframes.map((k) => '${k.frame}:${k.value}'), ['0:0.0', '20:10.0']);
  });
}
