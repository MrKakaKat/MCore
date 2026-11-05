/// Origami fold lines on the stage: shown across the selected layer (also
/// at angle 0, so where a fold will be is visible), and dragged along the
/// fold direction to move them (Origami card: "Move folds on the stage").
library;

import '../core/math.dart' show applyAffine, invertAffine;
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
  return [
    for (final inst in origamiInstances(layer))
      for (final l in origamiFoldLines(resolveEffectParams(inst, lf), rest))
        () {
          final a = applyAffine(m, l.a), b = applyAffine(m, l.b);
          return (inst: inst, key: l.key, a: a, b: b, mid: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]);
        }()
  ];
}

/// Drags one fold line along the fold direction.
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
    final v = origamiPositionAt(resolveEffectParams(inst, lf.toDouble()), buildGrid(layer.content, 2, 2), local);
    final t = inst.params[key];
    if (t is Track) setTrackValueAt(t, lf, v);
  }
}
