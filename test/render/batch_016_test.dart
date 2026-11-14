import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/params_panel/free_move_field.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';
import 'package:movement_mobile/ui/timeline/timeline_rows_view.dart';
import 'package:movement_mobile/ui/timeline/timeline_toolbar.dart';

void main() {
  setUpAll(() => registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync()));
  setUp(() {
    setStageSize(200, 100);
    registerBuiltinEffects();
  });

  test('a new layer starts at the playhead', () {
    final app = AppState()..setFrameSize(200, 100);
    app.setFrame(12);
    app.addLayer('rect');
    final l = app.project.layers.last;
    expect(l.startFrame, 12);
  });

  test('free move: the dragged way becomes a key layer of two keys, a second apart', () {
    final app = AppState()..setFrameSize(200, 100);
    app.project.layers.clear();
    app.addLayer('rect');
    final l = app.project.layers.last;
    l.transform.anchor.defaultValue = [0.25, 0.5];
    clearStateCaches();
    app.startFreeMove();
    expect(app.freeMoveRecording, isTrue);
    // grabbed 10 px off its middle, dragged right along an arc.
    app.beginFreeMoveStroke([60, 50]);
    for (var i = 1; i <= 20; i++) {
      app.addFreeMovePoint([60.0 + 5 * i, 50 - 20 * (1 - ((i - 10) / 10) * ((i - 10) / 10))]);
    }
    expect(app.freeMovePath.first, [50, 50], reason: 'from where it stands');
    app.confirmFreeMove();
    expect(app.freeMoveRecording, isFalse);
    final al = l.transform.anchor.animLayers.single.track;
    expect(al.keyframes.length, greaterThanOrEqualTo(2));
    expect(al.keyframes.last.frame - al.keyframes.first.frame, (app.freeMoveSeconds * fps).round());
    expect((al.keyframes.last.value as List)[0], closeTo(100 / 200, 1e-6));
    app.performUndo();
    expect(findLayer(app.project, l.id)!.transform.anchor.animLayers, isEmpty, reason: 'one undo step');
  });

  test('a text separated into word layers, the first selected', () {
    final app = AppState()..setFrameSize(200, 100);
    app.project.layers.clear();
    app.addTextLayer();
    final t = app.project.layers.last;
    app.editText(t.id, (s) => s.text = 'one two');
    app.separateTextLayers(t.id, 'word');
    expect(app.project.layers.map((l) => l.content.text?.text), ['one', 'two']);
    expect(app.selection.selectedLayer, app.project.layers.first.id);
    expect(app.project.layers.map((l) => l.name).toSet(), hasLength(2));
  });

  test('edit the whole object follows the selected layer', () {
    final app = AppState()..setFrameSize(200, 100);
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    l.editAll = true;
    app.notifyListeners();
    expect(editAllKeys, isTrue);
    l.editAll = false;
    app.notifyListeners();
    expect(editAllKeys, isFalse);
  });

  test('the path: moved, turned and sized as a whole; a selected key line only its stretch', () {
    final app = AppState()..setFrameSize(200, 100);
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [0.1, 0.5]),
      Keyframe(frame: 10, value: [0.9, 0.5]),
      Keyframe(frame: 20, value: [0.9, 0.9]),
    ];
    expect(app.pathTarget!.line, isFalse);
    expect(app.pathTarget!.b, 20);
    app.pushUndo();
    app.movePathTo([20, 0]);
    expect((l.transform.anchor.keyframes.first.value as List)[0], closeTo(0.2, 1e-9));
    app.movePathTo([0, 0]);
    expect((l.transform.anchor.keyframes.first.value as List)[0], closeTo(0.1, 1e-9), reason: 'back');
    app.selectKeyDetailSpan((layerId: l.id, tab: 'Movement', a: 0, b: 10, track: null));
    expect(app.pathTarget!.line, isTrue);
    // a half turn of the first stretch round its middle (0.5, 0.5).
    app.turnPathTo(180);
    expect(l.pathTurn, 180);
    final v = l.transform.anchor.keyframes.first.value as List;
    expect(v[0], closeTo(0.9, 1e-9));
    expect(v[1], closeTo(0.5, 1e-9));
    expect(l.transform.anchor.keyframes.last.value, [0.9, 0.9], reason: 'outside the line');
    app.scalePathTo(0.5);
    expect((l.transform.anchor.keyframes.first.value as List)[0], closeTo(0.7, 1e-9));
  });

  testWidgets('the Timeline tab shows the Path', (tester) async {
    final app = AppState()..setFrameSize(200, 100);
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    l.transform.anchor.keyframes = [
      Keyframe(frame: 0, value: [0.1, 0.5]),
      Keyframe(frame: 10, value: [0.9, 0.5]),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelineRowsView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('path-section')), findsOneWidget);
    expect(find.byKey(const ValueKey('path-turn')), findsOneWidget);
  });

  testWidgets('Keyframes tab: the free move field and the shared key\'s ease', (tester) async {
    final app = AppState()..setFrameSize(200, 100);
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    keyAllTracks(app.project, l, 0);
    keyAllTracks(app.project, l, 10);
    app.setFrame(l.startFrame + 10);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('master-key-ease')), findsOneWidget);
    expect(find.byKey(const ValueKey('key-edit-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('loop-all')), findsOneWidget);
    // free move: in the Movement tab now.
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: FreeMoveField(app: app)))));
    await tester.tap(find.byKey(const ValueKey('free-move-start')));
    await tester.pump();
    expect(app.freeMoveRecording, isTrue);
  });

  testWidgets('undo, play and redo on the stage', (tester) async {
    final app = AppState()..setFrameSize(200, 100);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StageTransportRow(app: app))));
    expect(find.byKey(const ValueKey('stage-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('stage-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('stage-redo')), findsOneWidget);
    final play = tester.getCenter(find.byKey(const ValueKey('stage-play'))).dx;
    expect(tester.getCenter(find.byKey(const ValueKey('stage-undo'))).dx, lessThan(play));
    expect(tester.getCenter(find.byKey(const ValueKey('stage-redo'))).dx, greaterThan(play));
  });
}
