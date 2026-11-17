import 'dart:io';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/save_load.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';

/// Red marks on the timeline ruler: hold the playhead to put one at its
/// frame (or take it away), tap one to jump there; saved with the project.
void main() {
  late AppState app;
  setUp(() {
    fps = 60;
    app = AppState()..timelineCenterPlayheadEnabled = false;
    app.maxFrame = 180;
  });
  tearDown(() => app.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 600, height: 220, child: LayersTimelineView(app: app)))));
    await tester.pumpAndSettle();
  }

  Finder playhead() => find.byWidgetPredicate(
      (w) => w is Listener && w.behavior == HitTestBehavior.translucent && w.onPointerMove != null);

  testWidgets('hold the playhead: a mark at its frame; hold again: gone', (tester) async {
    app.setFrame(40);
    await pump(tester);
    final at = tester.getRect(playhead().first).center;
    var g = await tester.startGesture(at);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pumpAndSettle();
    expect(app.project.markers, [40]);
    expect(find.byKey(const ValueKey('ruler-marker-40')), findsOneWidget);

    // tap the mark from elsewhere: the playhead goes to it.
    app.setFrame(100);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ruler-marker-40')));
    await tester.pumpAndSettle();
    expect(app.currentFrame, 40);

    // holding where the mark is takes it away.
    await tester.longPress(find.byKey(const ValueKey('ruler-marker-40')));
    await tester.pumpAndSettle();
    expect(app.project.markers, isEmpty);
    expect(find.byKey(const ValueKey('ruler-marker-40')), findsNothing);
  });

  testWidgets('pinned playhead: holding it puts a mark too', (tester) async {
    app.timelineCenterPlayheadEnabled = true;
    app.setFrame(50);
    await pump(tester);
    await tester.longPress(find.byKey(const ValueKey('playhead-play')));
    await tester.pumpAndSettle();
    expect(app.project.markers, [50]);
    // drawn over the pinned playhead.
    expect(find.descendant(of: find.byKey(const ValueKey('pinned-playhead-mark')), matching: find.byType(CustomPaint)),
        findsOneWidget);
    await tester.longPress(find.byKey(const ValueKey('playhead-play')));
    await tester.pumpAndSettle();
    expect(app.project.markers, isEmpty);
  });

  testWidgets('dragging the playhead puts no mark', (tester) async {
    app.setFrame(40);
    await pump(tester);
    final g = await tester.startGesture(tester.getRect(playhead().first).center);
    await g.moveBy(const Offset(40, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pumpAndSettle();
    expect(app.project.markers, isEmpty);
  });

  test('marks are saved with the project', () async {
    final dir = await Directory.systemTemp.createTemp('markers_');
    final f = File('${dir.path}/p.json');
    final p = createDefaultProject()..markers = [12, 90];
    await saveProjectToFile(f, p, maxFrame: 180, playbackSpeed: 1, selectedLayer: null, frameWidth: 100, frameHeight: 100, backgroundRgb: null);
    expect((await loadProjectFromFile(f)).project.markers, [12, 90]);
    await dir.delete(recursive: true);
  });
}
