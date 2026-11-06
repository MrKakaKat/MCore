/// Origami fold lines on the stage: shown across the selected layer (also
/// at angle 0, so where a fold will be is visible), and dragged along the
/// fold direction to move them (Origami card: "Move folds on the stage").
library;

import 'dart:math' as math;

import '../core/math.dart' show applyAffine, invertAffine, snapToStops;
import '../effects/builtins/origami_fold.dart';
import '../geometry/shapes.dart' show buildGrid;
import '../model/project.dart';
import '../model/track_edit.dart' show setTrackValueAt, localFrameOf;
import '../effects/geometry_effect_registry.dart' show resolveEffectParams;
import 'drag_ops.dart' show DragOp;
import 'handles.dart' show getTransformBoxHandles;
import 'snapping.dart' show SnapGuideLine;

/// The layer's Origami effects, enabled.
List<EffectInstance> origamiInstances(Layer layer) =>
    [for (final i in layer.effectStack) if (i.enabled && i.effectId == 'origami_fold') i];

/// Every fold line of the layer in frame space: which effect and position
/// param, its ends and its middle (the handle).
List<({EffectInstance inst, String key, List<double> a, List<double> b, List<double> mid})> origamiFoldLinesFrame(
    Project project, Layer layer, int globalFrame) {
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final rest = buildGrid(layer.content, 2, 2);
  final lf = localFrameOf(layer, globalFrame).toDouble();
  final sc = origamiScale(layer, lf);
  return [
    for (final inst in origamiInstances(layer))
      for (final l in origamiFoldLines(resolveEffectParams(inst, lf), rest, scale: sc))
        () {
          final a = applyAffine(m, l.a), b = applyAffine(m, l.b);
          return (inst: inst, key: l.key, a: a, b: b, mid: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]);
        }()
  ];
}

/// Drags one fold line along the fold direction (it sticks at the
/// quarters and the middle, like its control).
class OrigamiFoldDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  final String key;
  OrigamiFoldDragOp(this.layer, this.inst, this.key);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
    final local = applyAffine(invertAffine(m), framePoint);
    final lf = localFrameOf(layer, globalFrame);
    final v = origamiPositionAt(resolveEffectParams(inst, lf.toDouble()), buildGrid(layer.content, 2, 2), local,
        scale: origamiScale(layer, lf.toDouble()));
    final t = inst.params[key];
    if (t is Track) setTrackValueAt(t, lf, snapToStops(v, origamiPositionStops, 0.025));
  }
}

/// The handle at one end of each effect's first fold line, that turns the
/// folds (their direction), frame space.
List<({EffectInstance inst, List<double> p})> origamiDirectionHandlesFrame(Project project, Layer layer, int globalFrame) {
  final seen = <EffectInstance>{};
  return [
    for (final l in origamiFoldLinesFrame(project, layer, globalFrame))
      if (seen.add(l.inst)) (inst: l.inst, p: l.a)
  ];
}

/// Turns the folds: the first fold line pivots about its middle to point
/// at the finger (sticking at every 45 degrees).
class OrigamiDirectionDragOp implements DragOp {
  final Layer layer;
  final EffectInstance inst;
  OrigamiDirectionDragOp(this.layer, this.inst);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final line = origamiFoldLinesFrame(project, layer, globalFrame).where((l) => l.inst == inst).firstOrNull;
    if (line == null) return;
    // on screen the line runs from its middle to the finger; the folds
    // point a quarter turn round from it.
    final dx = framePoint[0] - line.mid[0], dy = framePoint[1] - line.mid[1];
    if (dx * dx + dy * dy < 1) return;
    final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
    final lf = localFrameOf(layer, globalFrame);
    // the screen angle back into the layer's own (scaled) space.
    final inv = invertAffine(m);
    final a = applyAffine(inv, line.mid), b = applyAffine(inv, framePoint);
    final sc = origamiScale(layer, lf.toDouble()) ?? const [1.0, 1.0];
    final lineDeg = math.atan2((b[1] - a[1]) * sc[1], (b[0] - a[0]) * sc[0]) * 180 / math.pi;
    var dir = (lineDeg + 90) % 360;
    if (dir < 0) dir += 360;
    dir = snapToStops(dir, const [0, 45, 90, 135, 180, 225, 270, 315, 360], 4) % 360;
    final t = inst.params['direction'];
    if (t is Track) {
      setTrackValueAt(t, lf, dir);
    } else {
      inst.params['direction'] = track(dir);
    }
  }
}
