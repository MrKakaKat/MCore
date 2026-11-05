import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/app_settings.dart';
import 'package:movement_mobile/io/project_store.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/perf/perf_monitor.dart';
import 'package:movement_mobile/ui/perf/perf_hud.dart';
import 'package:movement_mobile/ui/settings/settings_view.dart';

/// Performance HUD (phase 1): it never reaches an export, its counters are
/// right, it is off by default and costs nothing then, and its controls.
void main() {
  final monitor = PerfMonitor.instance;
  tearDown(() => monitor.setVisible(false));

  /// Every reference scene's layers in one project: pendulum chain, motion
  /// blur, mesh warp, static shapes.
  AppState richApp() {
    final app = AppState()..setFrameSize(480, 480);
    app.project.layers
      ..clear()
      ..addAll([for (final s in perfReferenceScenes()) ...s.project.layers]);
    return app;
  }

  Future<Uint8List> exportFrame(WidgetTester tester, AppState app, int frame) async {
    app.renderer.renderFrame(app.project, frame);
    late Uint8List bytes;
    await tester.runAsync(() async {
      final img = await app.renderer.captureFrame();
      bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
    });
    return bytes;
  }

  testWidgets('an exported frame is pixel-identical with the HUD on and off', (tester) async {
    final app = richApp();
    expect(monitor.visible.value, isFalse, reason: 'off by default');
    final off = await exportFrame(tester, app, 37);

    // the HUD showing over the editor, instrumentation running.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    monitor.setVisible(true);
    await tester.pumpWidget(MovementMobileApp(appState: app));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('perf-hud')), findsOneWidget);
    final on = await exportFrame(tester, app, 37);

    expect(on.length, off.length);
    expect(on, off, reason: 'the HUD is never drawn by the renderer; counting changes nothing');
    expect(off.any((b) => b != 0), isTrue, reason: 'the frame has content');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('engine counters: top layers, pendulum, blur samples, grid cells, state cache', (tester) async {
    final app = richApp();
    monitor.setVisible(true);
    monitor.reset();
    app.renderer.renderFrame(app.project, 120);
    final s = monitor.snapshot();
    expect(s.topLayers.length, 3);
    expect(s.topLayers.first.ms, greaterThanOrEqualTo(s.topLayers.last.ms));
    expect(s.pendulumEvals, greaterThanOrEqualTo(5), reason: 'five links swing');
    expect(s.blurSamples, 8);
    expect(s.gridCells, greaterThan(0), reason: 'the mesh warp draws a grid');
    expect(s.stateHits + s.stateMisses, greaterThan(0));
    expect(s.stateHits, greaterThan(0), reason: 'children reuse their parents\' state');
  });

  testWidgets('off: nothing is counted', (tester) async {
    final app = richApp();
    monitor.setVisible(true);
    monitor.setVisible(false);
    expect(perfInstrumentation, isFalse);
    app.renderer.renderFrame(app.project, 10);
    final s = monitor.snapshot();
    expect(s.topLayers, isEmpty);
    expect(s.stateHits + s.stateMisses, 0);
  });

  testWidgets('frame statistics: dropped frames, averages, worst', (tester) async {
    monitor.setVisible(true);
    monitor.reset();
    for (final total in [10.0, 12.0, 30.0, 14.0]) {
      monitor.addFrame(total * 0.4, total * 0.6, total, budgetMs: 16.7);
    }
    final s = monitor.snapshot();
    expect(s.droppedFrames, 1);
    expect(s.recentTotalsMs, [10.0, 12.0, 30.0, 14.0]);
    expect(s.uiWorstMs, closeTo(12, 1e-9));
    expect(s.rasterAvgMs, closeTo(0.6 * 66 / 4, 1e-9));
    monitor.reset();
    expect(monitor.snapshot().droppedFrames, 0);
  });

  testWidgets('idle: no FPS, just the refresh rate and budget; activity shows frame time', (tester) async {
    final app = AppState();
    monitor.setVisible(true);
    monitor.reset();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: PerfHud(app: app)))));
    await tester.pump(const Duration(milliseconds: 400));
    final headline = find.byKey(const ValueKey('perf-headline'));
    String text() => (tester.widget<Text>(headline).textSpan!).toPlainText();
    expect(text(), startsWith('idle'));
    expect(text(), isNot(contains('fps')), reason: 'nothing animates: an FPS number would mean nothing');
    expect(text(), contains('Hz, budget'));
    await tester.tap(find.byKey(const ValueKey('perf-collapse'))); // starts folded
    await tester.pump();

    // the HUD's own refreshes don't count as activity.
    await tester.pump(const Duration(milliseconds: 400));
    expect(text(), startsWith('idle'));

    // playback: frame time is the headline.
    monitor.playbackStarted();
    for (final t in [5.0, 6.0, 7.0, 30.0]) {
      monitor.addFrame(t / 2, t / 2, t, budgetMs: 16.7);
    }
    await tester.pump(const Duration(milliseconds: 400));
    expect(text(), contains('p95'));
    expect(find.byKey(const ValueKey('perf-playback')), findsOneWidget);
    expect(find.byKey(const ValueKey('perf-other-ui')), findsOneWidget);
    expect(find.byKey(const ValueKey('perf-video-memory')), findsOneWidget);
    monitor.playbackStopped();
    await tester.pumpWidget(const SizedBox());
    monitor.setVisible(false);
  });

  testWidgets('playback statistics: p95, % over budget, drops reset at each playback start', (tester) async {
    monitor.setVisible(true);
    monitor.reset();
    monitor.addFrame(1, 40, 41, budgetMs: 8.3); // before playback
    expect(monitor.droppedFrames, 1);
    monitor.playbackStarted();
    expect(monitor.droppedFrames, 0, reason: 'each playback counts its own drops');
    for (var i = 1; i <= 20; i++) {
      monitor.addFrame(1, i.toDouble(), i.toDouble(), budgetMs: 8.3);
    }
    final s = monitor.snapshot();
    expect(s.playing, isTrue);
    expect(s.playbackFrames, 20);
    expect(s.playbackOverBudget, 12, reason: 'the frames of 9..20 ms are over 8.3 + 0.5');
    expect(s.playbackOverBudgetPercent, closeTo(60, 1e-9));
    expect(s.frameP95Ms, 20, reason: '95th percentile of 41 and 1..20');
    monitor.playbackStopped();
    expect(monitor.snapshot().playbackFrames, 20, reason: 'the last playback stays readable after it stops');
    monitor.setVisible(false);
  });

  testWidgets('HUD: starts folded to one line; unfolds with the debug warning; reset', (tester) async {
    final app = AppState();
    monitor.setVisible(true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: PerfHud(app: app)))));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('raster'), findsNothing, reason: 'folded by default');
    await tester.tap(find.byKey(const ValueKey('perf-collapse')));
    await tester.pump();
    expect(find.byKey(const ValueKey('perf-debug-warning')), findsOneWidget, reason: 'tests run a debug build');
    expect(find.textContaining('raster'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('perf-collapse')));
    await tester.pump();
    expect(find.textContaining('raster'), findsNothing);
    expect(find.byKey(const ValueKey('perf-headline')), findsOneWidget);
    monitor.addFrame(5, 50, 55, budgetMs: 16.7);
    await tester.tap(find.byKey(const ValueKey('perf-reset')));
    await tester.pump();
    expect(monitor.droppedFrames, 0);
    monitor.setVisible(false);
    await tester.pump();
    expect(find.byKey(const ValueKey('perf-hud')), findsNothing);
  });

  testWidgets('the Settings switch toggles it (not a stage icon); app-wide, kept in app_settings.json', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('perf_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    AppSettings.instance = AppSettings(File('${dir.path}/app_settings.json'));
    addTearDown(() => AppSettings.instance = null);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppState();
    await tester.pumpWidget(MovementMobileApp(appState: app));
    await tester.pumpAndSettle();
    expect(find.byTooltip('show performance'), findsNothing, reason: 'moved off the stage');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsView(app: AppState()))));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('perf-hud-switch')), 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(const ValueKey('perf-hud-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('perf-hud-switch')));
    await tester.pump();
    expect(monitor.visible.value, isTrue);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final saved = AppSettings(File('${dir.path}/app_settings.json'));
    await tester.runAsync(saved.load);
    expect(saved.perfHud, isTrue);
    // (the editor disposes its state when it closes: fresh ones from here)
    await tester.pumpWidget(MovementMobileApp(appState: AppState()));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('perf-hud')), findsOneWidget, reason: 'shown over the stage');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsView(app: AppState()))));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('perf-hud-switch')), 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.byKey(const ValueKey('perf-hud-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('perf-hud-switch')));
    await tester.pump();
    expect(monitor.visible.value, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  test('the reference projects are added to the project list', () async {
    final dir = Directory.systemTemp.createTempSync('perf_scenes');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = ProjectStore(dir);
    await store.addPerfScenes();
    final names = [for (final m in await store.list()) m.name]..sort();
    expect(names, [
      'Masks: Add, Subtract, Intersect, Exclude',
      'Masks: logic (Implication, Equivalence, Invert)',
      'Perf: mesh warp',
      'Perf: motion blur',
      'Perf: pendulum chain',
      'Perf: static shapes',
    ]);
  });
}
