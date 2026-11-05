import 'dart:collection';
import 'dart:io' show ProcessInfo;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:movement_core/movement_core.dart' show perfCounters, perfInstrumentation;

/// One layer's cost in one render.
class LayerCost {
  final String name;
  final double ms;
  const LayerCost(this.name, this.ms);
}

/// What the HUD shows, taken a few times per second (PerfMonitor.snapshot).
class PerfSnapshot {
  /// Something animated since the last snapshot (playback or a drag);
  /// frame numbers are meaningless otherwise.
  final bool active;
  final bool playing;
  final double fps;
  final double targetFps;
  final int droppedFrames;
  final double uiAvgMs, uiWorstMs, rasterAvgMs, rasterWorstMs;

  /// Frame time (UI + raster, as the display saw it): average and 95th
  /// percentile over the recent active frames.
  final double frameAvgMs, frameP95Ms;

  /// Frames over budget during the current / last playback, and how many
  /// frames it had.
  final int playbackFrames, playbackOverBudget;
  final List<double> recentTotalsMs; // oldest first, up to 120
  final double rendersPerSecond;
  final double notifiesPerSecond;
  final double stateMs, recordMs; // averages per render
  final List<LayerCost> topLayers; // the latest render's 3 most expensive
  final int gridCells, blurSamples, pendulumEvals; // latest render
  final int stateHits, stateMisses; // since reset
  final int rssBytes;
  const PerfSnapshot({
    required this.active,
    required this.playing,
    required this.frameAvgMs,
    required this.frameP95Ms,
    required this.playbackFrames,
    required this.playbackOverBudget,
    required this.fps,
    required this.targetFps,
    required this.droppedFrames,
    required this.uiAvgMs,
    required this.uiWorstMs,
    required this.rasterAvgMs,
    required this.rasterWorstMs,
    required this.recentTotalsMs,
    required this.rendersPerSecond,
    required this.notifiesPerSecond,
    required this.stateMs,
    required this.recordMs,
    required this.topLayers,
    required this.gridCells,
    required this.blurSamples,
    required this.pendulumEvals,
    required this.stateHits,
    required this.stateMisses,
    required this.rssBytes,
  });

  double get budgetMs => 1000 / targetFps;
  double get playbackOverBudgetPercent => playbackFrames == 0 ? 0 : playbackOverBudget * 100 / playbackFrames;

  /// UI time not spent in the scene renderer (layouts, rebuilds, painting
  /// the panels): average UI time minus render time per frame.
  double get otherUiMs {
    final rendersPerFrame = fps > 0 ? rendersPerSecond / fps : 1.0;
    return (uiAvgMs - (stateMs + recordMs) * rendersPerFrame).clamp(0, double.infinity).toDouble();
  }
  double get stateHitRatio => stateHits + stateMisses == 0 ? 0 : stateHits / (stateHits + stateMisses);
}

/// Collects performance samples for the HUD. Samples are taken cheaply as
/// things happen (every frame / render); the HUD reads aggregates on its
/// own slow timer. Nothing here draws - the HUD is a widget above the
/// stage, never part of what the renderer (and so exports) draws.
///
/// App-wide, not part of any project.
class PerfMonitor {
  PerfMonitor._();
  static final PerfMonitor instance = PerfMonitor._();

  /// Whether the HUD is on (and the engine instrumented).
  final ValueNotifier<bool> visible = ValueNotifier(false);

  bool _registered = false;

  void setVisible(bool on) {
    if (visible.value == on) return;
    visible.value = on;
    perfInstrumentation = on;
    if (on && !_registered) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      _registered = true;
    } else if (!on && _registered) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      _registered = false;
    }
    reset();
  }

  // ===== activity =====

  /// Playback is running (AppState sets it).
  bool playing = false;
  final Stopwatch _sinceActive = Stopwatch();

  /// The picture changes because the user does something (a drag, a scrub,
  /// a frame step): frames in the next moment count. Frames when nothing
  /// animates (the HUD's own refresh, a blinking cursor) don't.
  void markActive() {
    _sinceActive
      ..reset()
      ..start();
  }

  /// A finger moving on the screen (drag, scrub, scroll, pinch) is
  /// activity; a tap alone or the HUD's own refresh isn't.
  void _onPointer(PointerEvent e) {
    if (e is PointerMoveEvent) markActive();
  }

  bool get active => playing || (_sinceActive.isRunning && _sinceActive.elapsedMilliseconds < 300);

  int _playbackFrames = 0, _playbackOver = 0;

  /// Playback started: its own drop count from zero.
  void playbackStarted() {
    playing = true;
    droppedFrames = 0;
    _playbackFrames = 0;
    _playbackOver = 0;
  }

  void playbackStopped() => playing = false;

  // ===== frames (FrameTiming, works in release builds) =====

  static const window = 120;
  final Float64List _total = Float64List(window), _ui = Float64List(window), _raster = Float64List(window);
  int _count = 0, _pos = 0;
  int _framesSinceSnapshot = 0;
  int droppedFrames = 0;

  /// The display's refresh rate - what a smooth stage would reach.
  double get targetFps {
    try {
      final r = ui.PlatformDispatcher.instance.displays.first.refreshRate;
      return r > 1 ? r : 60;
    } catch (_) {
      return 60;
    }
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    final budget = 1000 / targetFps;
    if (!active) return; // idle frames say nothing about performance
    for (final t in timings) {
      addFrame(
        t.buildDuration.inMicroseconds / 1000,
        t.rasterDuration.inMicroseconds / 1000,
        t.totalSpan.inMicroseconds / 1000,
        budgetMs: budget,
      );
    }
  }

  /// One finished frame (from FrameTiming; tests feed it directly).
  @visibleForTesting
  void addFrame(double uiMs, double rasterMs, double totalMs, {required double budgetMs}) {
    _ui[_pos] = uiMs;
    _raster[_pos] = rasterMs;
    _total[_pos] = totalMs;
    _pos = (_pos + 1) % window;
    if (_count < window) _count++;
    _framesSinceSnapshot++;
    // over budget: the display showed the previous frame again.
    final over = totalMs > budgetMs + 0.5;
    if (over) droppedFrames++;
    if (playing) {
      _playbackFrames++;
      if (over) _playbackOver++;
    }
  }

  // ===== engine (CanvasRenderer.renderFrame) =====

  static const _renderWindow = 30;
  final ListQueue<(double, double)> _renders = ListQueue(); // (stateMs, recordMs)
  List<LayerCost> _top = const [];
  int _gridCells = 0, _blurSamples = 0, _pendulumEvals = 0;
  int _stateHits = 0, _stateMisses = 0;
  int _rendersSinceSnapshot = 0;
  int _notifiesSinceSnapshot = 0;

  /// Called by the renderer at the end of a render while instrumented.
  /// Scene renders recorded since the HUD went on (tests).
  int rendersRecorded = 0;

  void recordRender({required double totalMs, required List<LayerCost> layers}) {
    rendersRecorded++;
    final stateMs = perfCounters.stateMicros / 1000;
    _renders.addLast((stateMs, (totalMs - stateMs).clamp(0, double.infinity).toDouble()));
    while (_renders.length > _renderWindow) {
      _renders.removeFirst();
    }
    final sorted = [...layers]..sort((a, b) => b.ms.compareTo(a.ms));
    _top = sorted.take(3).toList();
    _gridCells = perfCounters.gridCells;
    _blurSamples = perfCounters.blurSamples;
    _pendulumEvals = perfCounters.pendulumEvals;
    _stateHits += perfCounters.stateHits;
    _stateMisses += perfCounters.stateMisses;
    _rendersSinceSnapshot++;
  }

  /// AppState notified its listeners (every one rebuilds the UI that
  /// listens to it) - counted to show how often that happens.
  void countNotify() => _notifiesSinceSnapshot++;

  // ===== snapshots =====

  final Stopwatch _sinceSnapshot = Stopwatch()..start();
  bool _framesSinceSnapshotWasActive = false;

  PerfSnapshot snapshot() {
    final secs = _sinceSnapshot.elapsedMicroseconds / 1e6;
    _sinceSnapshot
      ..reset()
      ..start();
    double rate(int n) => secs <= 0 ? 0 : n / secs;
    final fps = rate(_framesSinceSnapshot);
    _framesSinceSnapshotWasActive = _framesSinceSnapshot > 0;
    final rps = rate(_rendersSinceSnapshot);
    final nps = rate(_notifiesSinceSnapshot);
    _framesSinceSnapshot = 0;
    _rendersSinceSnapshot = 0;
    _notifiesSinceSnapshot = 0;

    double avg(Float64List l) {
      if (_count == 0) return 0;
      var s = 0.0;
      for (var i = 0; i < _count; i++) {
        s += l[i];
      }
      return s / _count;
    }

    double worst(Float64List l) {
      var m = 0.0;
      for (var i = 0; i < _count; i++) {
        if (l[i] > m) m = l[i];
      }
      return m;
    }

    final recent = <double>[
      for (var i = 0; i < _count; i++) _total[(_pos - _count + i + window) % window],
    ];
    final sorted = [...recent]..sort();
    final p95 = sorted.isEmpty ? 0.0 : sorted[((sorted.length - 1) * 0.95).round()];
    var stateMs = 0.0, recordMs = 0.0;
    for (final r in _renders) {
      stateMs += r.$1;
      recordMs += r.$2;
    }
    final n = _renders.isEmpty ? 1 : _renders.length;
    int rss = 0;
    try {
      rss = ProcessInfo.currentRss;
    } catch (_) {}
    return PerfSnapshot(
      active: _framesSinceSnapshotWasActive,
      playing: playing,
      frameAvgMs: avg(_total),
      frameP95Ms: p95,
      playbackFrames: _playbackFrames,
      playbackOverBudget: _playbackOver,
      fps: fps,
      targetFps: targetFps,
      droppedFrames: droppedFrames,
      uiAvgMs: avg(_ui),
      uiWorstMs: worst(_ui),
      rasterAvgMs: avg(_raster),
      rasterWorstMs: worst(_raster),
      recentTotalsMs: recent,
      rendersPerSecond: rps,
      notifiesPerSecond: nps,
      stateMs: stateMs / n,
      recordMs: recordMs / n,
      topLayers: _top,
      gridCells: _gridCells,
      blurSamples: _blurSamples,
      pendulumEvals: _pendulumEvals,
      stateHits: _stateHits,
      stateMisses: _stateMisses,
      rssBytes: rss,
    );
  }

  /// Back to zero: frames, drops, renders, cache counts.
  void reset() {
    _count = 0;
    _pos = 0;
    _playbackFrames = 0;
    _playbackOver = 0;
    _framesSinceSnapshot = 0;
    droppedFrames = 0;
    _renders.clear();
    _top = const [];
    _gridCells = _blurSamples = _pendulumEvals = 0;
    _stateHits = _stateMisses = 0;
    _rendersSinceSnapshot = 0;
    _notifiesSinceSnapshot = 0;
    _sinceSnapshot
      ..reset()
      ..start();
  }
}
