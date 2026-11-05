/// Text parts on the stage: the selected part's box (Text tab, an open
/// part) and dragging it - its move value, a key at this frame when it
/// has keys.
library;

import 'dart:math' as math;

import '../core/interpolation.dart' show evaluateTrack;
import '../core/math.dart' show applyAffine, invertAffine;
import '../model/project.dart';
import '../model/track_edit.dart' show setTrackValueAt, localFrameOf;
import '../text/open_type_font.dart' show flattenPath;
import '../text/text_animators.dart' show textPartCmds;
import 'drag_ops.dart' show DragOp;
import 'handles.dart' show getTransformBoxHandles;
import 'snapping.dart' show SnapGuideLine;

/// The part open in the Text tab (shown and dragged on the stage).
int? selectedTextPart;

/// The selected part's box corners in frame space, or null.
List<List<double>>? textPartBoxFrame(Project project, Layer layer, int globalFrame) {
  final t = layer.content.text, i = selectedTextPart;
  if (t == null || i == null || i >= t.spans.length) return null;
  final lf = localFrameOf(layer, globalFrame);
  final rings = flattenPath(textPartCmds(t.atFrame(lf), layer.content.offset, layer.content.size, lf, i));
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final r in rings) {
    for (final p in r) {
      x0 = math.min(x0, p[0]);
      y0 = math.min(y0, p[1]);
      x1 = math.max(x1, p[0]);
      y1 = math.max(y1, p[1]);
    }
  }
  if (!x0.isFinite) return null;
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  return [for (final p in [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]) applyAffine(m, p)];
}

/// Drags the selected part (its move, in the text's own space).
class TextPartDragOp implements DragOp {
  final Layer layer;
  final int part;
  final List<double> grabLocal;
  final List<double> startMove;
  TextPartDragOp._(this.layer, this.part, this.grabLocal, this.startMove);

  factory TextPartDragOp.grab(Project project, Layer layer, int part, int globalFrame, List<double> framePoint) {
    final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
    final sp = layer.content.text!.spans[part];
    final lf = localFrameOf(layer, globalFrame);
    final v = sp.move == null ? const [0.0, 0.0] : _vec(sp.move!, lf);
    return TextPartDragOp._(layer, part, applyAffine(invertAffine(m), framePoint), [...v]);
  }

  static List<double> _vec(Track t, int f) =>
      [for (final e in evaluateTrack(null, t, f.toDouble()) as List) (e as num).toDouble()];

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
    final q = applyAffine(invertAffine(m), framePoint);
    final sp = layer.content.text!.spans[part];
    final t = sp.move ??= Track(<double>[0, 0], false);
    setTrackValueAt(t, localFrameOf(layer, globalFrame), [startMove[0] + q[0] - grabLocal[0], startMove[1] + q[1] - grabLocal[1]]);
  }
}
