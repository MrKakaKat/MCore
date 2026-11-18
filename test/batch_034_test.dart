import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/timeline/keyframes_editor_view.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';

void main() {
  late AppState app;
  setUp(() {
    fps = 60;
    app = AppState()..timelineCenterPlayheadEnabled = false;
    app.maxFrame = 300;
    app.project.layers.clear();
  });
  tearDown(() => app.dispose());

  Layer add(String id, int start, {String? folder}) {
    final l = createLayer('rect')
      ..id = id
      ..startFrame = start
      ..durationFrames = 40
      ..folder = folder;
    app.project.layers.add(l);
    return l;
  }

  test('all layers selected together move in time together', () {
    final a = add('A', 0), b = add('B', 50), c = add('C', 100);
    app.selectLayer('A');
    app.selectLayerGroup([for (final l in app.project.layers) l.id]);
    expect(app.selectedGroup, {'A', 'B', 'C'});
    app.beginLayerDrag('B', LayerDragMode.move);
    app.updateLayerDrag(20);
    app.endLayerDrag();
    expect([a.startFrame, b.startFrame, c.startFrame], [20, 70, 120]);
  });

  testWidgets('a folder row held selects its layers; held and dragged moves them', (tester) async {
    final a = add('A', 0, folder: 'F'), b = add('B', 60, folder: 'F'), c = add('C', 10);
    app.selectLayer('C');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 600, height: 300, child: LayersTimelineView(app: app)))));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('timeline-folder-box-F'));
    expect(box, findsOneWidget);
    final at = tester.getRect(box).center;
    final g = await tester.startGesture(at);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(app.selectedGroup, {'A', 'B'});
    await g.moveBy(const Offset(60, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(a.startFrame, greaterThan(0));
    expect(b.startFrame - a.startFrame, 60);
    expect(c.startFrame, 10);
  });

  testWidgets('the keys tab lists every mark: tap goes there, the cross takes it away', (tester) async {
    add('A', 0);
    app.selectLayer('A');
    app.toggleMarker(30);
    app.toggleMarker(90);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: KeyframesEditorView(app: app))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mark-30')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mark-90')));
    await tester.pumpAndSettle();
    expect(app.currentFrame, 90);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('mark-30')), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    expect(app.project.markers, [90]);
    await tester.tap(find.byKey(const ValueKey('marks-here')));
    await tester.pumpAndSettle();
    expect(app.project.markers, isEmpty, reason: 'the playhead is on 90: unmarked');
  });
}
