/// ============================================================
/// GRAPH EDITOR - pure-Dart state/math layer
/// - edits the temporal easing {x1,y1,x2,y2} stored on a keyframe (or,
///   in whole-path mode, a spatial track's single `globalEasing`) -
///   exactly the same numbers solveCubicBezierY() already consumes.
/// - the Flutter widget (movement_mobile/lib/ui/graph_editor/) owns the
///   two canvases (the classic 0..1 easing square, and the real
///   value-vs-time curve sampled here via evaluateTrack); this file only
///   owns the state transitions and the curve sampling, so both get
///   real `dart test` coverage independent of dart:ui.
///
/// Ported from movement-core/src/ui/graphEditor.js's `graphState` object
/// + `getEditingTemporal`/`currentSegmentKeyframes`/`drawCurvePreview`'s
/// sampling loop. One real implementation-detail difference from the JS
/// source: `Easing` is immutable in this port (see model/project.dart),
/// so editing replaces the whole {x1,y1,x2,y2} rather than mutating its
/// fields in place - `setEditingTemporal` is the replacement for JS's
/// `t.x1 = ...` field assignments.
/// ============================================================
library;

import '../core/interpolation.dart';
import '../model/project.dart';

class GraphEditorState {
  final Track track;
  final int componentCount; // 1 (scalar) or 2 (vec2, X/Y toggle shown)
  int component; // 0 or 1 - only meaningful when componentCount > 1
  int segmentIndex; // per-segment mode only - which keyframe transition
  final bool wholePath;

  GraphEditorState({
    required this.track,
    required this.componentCount,
    this.component = 0,
    int? segmentIndex,
    this.wholePath = false,
  }) : segmentIndex = segmentIndex ?? (track.keyframes.length - 2);

  /// the segment currently being edited (per-segment mode only) - JS's
  /// `currentSegmentKeyframes()`.
  (Keyframe, Keyframe) currentSegmentKeyframes() {
    final kfs = track.keyframes;
    return (kfs[segmentIndex], kfs[segmentIndex + 1]);
  }

  /// JS's `getEditingTemporal()` - the single abstraction point that lets
  /// the rest of the editor work identically for both modes.
  Easing getEditingTemporal() {
    if (wholePath) return track.globalEasing!;
    final (_, k1) = currentSegmentKeyframes();
    return k1.temporal;
  }

  /// replaces the edited easing - see this file's own doc comment on why
  /// this exists instead of in-place field mutation (Easing is
  /// immutable here, unlike JS's plain mutable object literal).
  void setEditingTemporal(Easing next) {
    if (wholePath) {
      track.globalEasing = next;
    } else {
      final (_, k1) = currentSegmentKeyframes();
      k1.temporal = next;
    }
  }

  /// JS's pointermove handler: x clamped to [0,1] (time can't run
  /// backward or past the segment), y clamped to [-0.6,1.6] (allows
  /// slight overshoot beyond 0..1 for anticipation/overshoot curves).
  static double clampX(double v) => v.clamp(0.0, 1.0);
  static double clampY(double v) => v.clamp(-0.6, 1.6);

  /// segment tab labels for per-segment mode - JS's `${kfs[i].frame}→
  /// ${kfs[i+1].frame}` loop in renderGraphEditor().
  List<String> segmentLabels() => [
        for (var i = 0; i < track.keyframes.length - 1; i++) '${track.keyframes[i].frame}→${track.keyframes[i + 1].frame}',
      ];

  static double _componentValue(dynamic v, int? comp) => comp == null ? (v as double) : (v as List<double>)[comp];

  /// JS's `drawCurvePreview()` sampling loop, minus the canvas drawing -
  /// samples the REAL value-vs-time curve for the segment (or whole
  /// path) via evaluateTrack, so the widget can show the actual motion
  /// the handles produce rather than just the abstract easing shape.
  List<double> sampleCurve({int steps = 40}) {
    final kfs = track.keyframes;
    final comp = componentCount > 1 ? component : null;
    final int f0, fN;
    if (wholePath) {
      f0 = kfs.isEmpty ? 0 : kfs.first.frame;
      fN = kfs.isEmpty ? 0 : kfs.last.frame;
    } else {
      final (k0, k1) = currentSegmentKeyframes();
      f0 = k0.frame;
      fN = k1.frame;
    }
    return [
      for (var s = 0; s <= steps; s++) _componentValue(evaluateTrack(null, track, f0 + (fN - f0) * s / steps), comp),
    ];
  }
}
