import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/timeline/timeline_drawer_row.dart';

/// Real, run widget-level coverage of TimelineDrawerRow - the secondary
/// row of layer-timeline toggles tucked behind TimelineToolbar's own
/// caret button. Houses the layer-edge-snapping toggle plus (moved here
/// from TimelineToolbar - see that file's own doc comment) layer
/// quick-switch/drag-to-edge auto-scroll/center-pin playhead; same
/// toggle-icon convention as TimelineToolbar's own buttons.
void main() {
  late AppState app;

  setUp(() {
    app = AppState();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TimelineDrawerRow(app: app))));
    await tester.pumpAndSettle();
  }

  testWidgets('snap-layer-edges toggle flips AppState.snapTimelineLayersEnabled both ways', (tester) async {
    await pump(tester);
    expect(app.snapTimelineLayersEnabled, isFalse);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.push_pin_outlined));
    await tester.pump();
    expect(app.snapTimelineLayersEnabled, isTrue);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.push_pin));
    await tester.pump();
    expect(app.snapTimelineLayersEnabled, isFalse);
  });

  testWidgets('layer quick-switch toggle flips AppState.layerQuickSwitchEnabled both ways', (tester) async {
    await pump(tester);
    expect(app.layerQuickSwitchEnabled, isFalse);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.swap_horiz_outlined));
    await tester.pump();
    expect(app.layerQuickSwitchEnabled, isTrue);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.swap_horiz));
    await tester.pump();
    expect(app.layerQuickSwitchEnabled, isFalse);
  });

  testWidgets('drag-to-edge auto-scroll toggle flips AppState.timelineEdgeAutoScrollEnabled both ways', (tester) async {
    await pump(tester);
    expect(app.timelineEdgeAutoScrollEnabled, isFalse);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_circle_right_outlined));
    await tester.pump();
    expect(app.timelineEdgeAutoScrollEnabled, isTrue);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_circle_right));
    await tester.pump();
    expect(app.timelineEdgeAutoScrollEnabled, isFalse);
  });

  testWidgets('the playhead is always pinned to the middle: no toggle for it', (tester) async {
    await pump(tester);
    expect(app.timelineCenterPlayheadEnabled, isTrue);
    expect(find.widgetWithIcon(IconButton, Icons.center_focus_strong), findsNothing);
    expect(find.widgetWithIcon(IconButton, Icons.center_focus_strong_outlined), findsNothing);
  });

  /// Keys on the selected layer at these frames (the key selection only
  /// keeps frames that have a key).
  void keysAt(List<int> frames) {
    final l = findLayer(app.project, app.selection.selectedLayer)!;
    for (final f in frames) {
      addKeyframe(app.project, l.id, 'rotation', f - l.startFrame, 0.0, 'linear');
    }
  }

  testWidgets('keep-playhead toggle: selecting a keyframe no longer moves the playhead', (tester) async {
    await pump(tester);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.location_disabled_outlined));
    await tester.pump();
    expect(app.keyframeSelectKeepsPlayhead, isTrue);

    keysAt([40, 60]);
    app.setFrame(5);
    app.selectKeyframeFrame(40);
    expect(kfSelectedFrames, equals({40}));
    expect(app.currentFrame, equals(5));

    app.toggleKeyframeSelectKeepsPlayhead();
    app.selectKeyframeFrame(60);
    expect(app.currentFrame, equals(60), reason: 'off again: selecting jumps the playhead');
  });

  testWidgets('multiselect toggle mirrors the Keyframes tab\'s kfMultiselectMode', (tester) async {
    kfMultiselectMode = false;
    addTearDown(() => kfMultiselectMode = false);
    await pump(tester);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.check_box_outline_blank));
    await tester.pump();
    expect(kfMultiselectMode, isTrue);

    keysAt([10, 20]);
    kfSelectedFrames = {};
    app.selectKeyframeFrame(10);
    app.selectKeyframeFrame(20);
    expect(kfSelectedFrames, equals({10, 20}), reason: 'taps add to the selection');
  });

  testWidgets('the "all" button turns every drawer toggle on, and all off again', (tester) async {
    kfMultiselectMode = false;
    addTearDown(() => kfMultiselectMode = false);
    app.toggleSnapTimelineLayers(); // one already on
    await pump(tester);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.done_all));
    await tester.pump();
    expect(app.allTimelineToggles, isTrue);
    expect(app.snapTimelineLayersEnabled && app.layerQuickSwitchEnabled && app.timelineEdgeAutoScrollEnabled, isTrue);
    expect(app.timelineCenterPlayheadEnabled && app.keyframeSelectKeepsPlayhead && kfMultiselectMode, isTrue);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.done_all));
    await tester.pump();
    expect(app.snapTimelineLayersEnabled || app.layerQuickSwitchEnabled || app.timelineEdgeAutoScrollEnabled, isFalse);
    expect(app.timelineCenterPlayheadEnabled || app.keyframeSelectKeepsPlayhead || kfMultiselectMode, isFalse);
  });
}
