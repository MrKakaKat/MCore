import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/perf/perf_monitor.dart';

/// Perf fixes §2.3: playback and scrubbing move the current frame on its
/// own notifier - only the stage, the playhead and the frame counter
/// follow it; the rest of the UI catches up when the frame rests. And the
/// stage no longer renders each frame a second time.
void main() {
  setUp(() => fps = 60);

  Future<AppState> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppState()..timelineCenterPlayheadEnabled = false;
    await tester.pumpWidget(MovementMobileApp(appState: app));
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('playback ticks: no app-wide notification, the frame notifier and the counter follow', (tester) async {
    final app = await pumpEditor(tester);
    var notifies = 0, frames = 0;
    app.addListener(() => notifies++);
    app.frameNotifier.addListener(() => frames++);
    for (var ms = 0; ms <= 500; ms += 16) {
      app.playTick(Duration(milliseconds: ms), 0);
      await tester.pump();
    }
    expect(notifies, 0, reason: 'panels, lists and lanes are not rebuilt on every frame');
    expect(frames, greaterThan(20));
    expect(app.frameNotifier.value, app.currentFrame);
    final counter = tester.widget<EditableText>(
        find.descendant(of: find.byKey(const ValueKey('toolbar-frame')), matching: find.byType(EditableText)));
    expect(counter.controller.text, '${app.currentFrame}', reason: 'the frame counter follows live');

    app.frameSettled();
    expect(notifies, 1, reason: 'the rest of the UI catches up once the frame rests');
    app.frameSettled();
    expect(notifies, 1, reason: 'nothing new to announce');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one scene render per frame change, not two', (tester) async {
    final app = await pumpEditor(tester);
    final monitor = PerfMonitor.instance;
    monitor.setVisible(true);
    addTearDown(() => monitor.setVisible(false));
    await tester.pump();
    var before = monitor.rendersRecorded;
    app.setFrame(20);
    await tester.pump();
    expect(monitor.rendersRecorded - before, 1, reason: 'the stage draws the picture AppState rendered');
    before = monitor.rendersRecorded;
    app.setFrame(21, quiet: true);
    await tester.pump();
    expect(monitor.rendersRecorded - before, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
