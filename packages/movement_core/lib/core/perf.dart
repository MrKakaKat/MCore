/// Diagnostics counters for the app's performance HUD. Everything here is
/// behind one boolean, [perfInstrumentation]: off (the default), the
/// engine pays a single `if` per instrumented spot and nothing else.
/// Counters only observe - they never change what is evaluated or drawn.
library;

/// Turns the engine's timing and counting on (the HUD sets it).
bool perfInstrumentation = false;

/// Per-render counters, reset at the start of each render by the renderer.
class PerfCounters {
  /// State cache (getLayerStateAt): answered from the cache / computed.
  int stateHits = 0;
  int stateMisses = 0;

  /// Time inside top-level getLayerStateAt calls (matrices, parents,
  /// pendulum, wiggle, expressions), microseconds.
  int stateMicros = 0;

  /// Pendulum evaluations (each walks its simulation from the start).
  int pendulumEvals = 0;

  /// Deformation grid cells drawn (warped textures and bent rects).
  int gridCells = 0;

  /// Motion-blur samples drawn.
  int blurSamples = 0;

  void reset() {
    stateHits = 0;
    stateMisses = 0;
    stateMicros = 0;
    pendulumEvals = 0;
    gridCells = 0;
    blurSamples = 0;
  }
}

final PerfCounters perfCounters = PerfCounters();

int _stateDepth = 0;
final Stopwatch _stateWatch = Stopwatch();

/// Times `body` as layer-state evaluation - only the outermost call of a
/// nested chain counts, so parents evaluated inside a child aren't
/// counted twice.
T timeStateEval<T>(T Function() body) {
  if (_stateDepth++ == 0) {
    _stateWatch
      ..reset()
      ..start();
  }
  try {
    return body();
  } finally {
    if (--_stateDepth == 0) {
      _stateWatch.stop();
      perfCounters.stateMicros += _stateWatch.elapsedMicroseconds;
    }
  }
}
