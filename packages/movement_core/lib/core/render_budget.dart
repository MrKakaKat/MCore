/// A time limit for drawing one frame on the stage: long work (a swing or
/// a follow worked out over a long timeline, many placed projects) stops
/// part way instead of freezing the app - the frame is drawn as far as it
/// got, and the stage is told so (playback stops). Export sets none.
library;

class RenderBudget {
  RenderBudget._();

  static final Stopwatch _sw = Stopwatch();
  static int? _limitUs;
  static bool _tripped = false;

  /// What was being worked on when the time ran out.
  static String? trippedAt;

  /// Starts a frame's time (null: no limit).
  static void start(Duration? limit) {
    _tripped = false;
    trippedAt = null;
    _limitUs = limit?.inMicroseconds;
    _sw
      ..reset()
      ..start();
  }

  /// No limit any more (the frame is done).
  static void end() => _limitUs = null;

  /// Whether the frame's time ran out (from then on: yes, at once).
  static bool get over {
    final l = _limitUs;
    if (l == null) return false;
    if (_tripped) return true;
    if (_sw.elapsedMicroseconds > l) _tripped = true;
    return _tripped;
  }

  /// The time ran out this frame.
  static bool get tripped => _tripped;

  /// Marks what is being worked on (said when the time runs out there).
  static void at(String what) {
    if (!_tripped) trippedAt = what;
  }
}
