/// ============================================================
/// EXPRESSIONS
///
/// Ported from movement-core/src/core/expressions.js, with one real gap:
/// the JS original evaluates a user-typed expression STRING via
/// `new Function(...)` - i.e. it embeds the browser's own JS engine as
/// the expression language. Dart has no equivalent (no `eval`, no
/// runtime code generation in a compiled app), so a real port needs a
/// small expression parser/evaluator of its own - genuinely new
/// infrastructure, not a mechanical translation, and out of scope for
/// this pass.
///
/// What's kept faithful: the DATA shape (`Track.expression` is still a
/// plain string field, so a project file containing expressions still
/// round-trips through save/load unchanged) and the fail-safe CONTRACT -
/// the JS falls back to `trk.defaultValue` whenever the expression
/// string fails to evaluate (syntax error, wrong shape, cycle). Since
/// nothing here can evaluate an expression string at all yet,
/// [evaluateExpression] always takes that same fallback path - it's the
/// existing "broken expression" behavior applied unconditionally, not a
/// new failure mode. `layerRef`/[withExpressionContext] stay in place so
/// the rest of the call graph (evaluateTrack's expression branch) is
/// structurally complete once a real evaluator lands.
/// ============================================================
library;

import 'dart:math' as math;

import '../model/project.dart';
import 'interpolation.dart';
import 'state_cache.dart';

int _exprGlobalFrame = 0;
Layer? _exprLayer;
final Set<Track> _exprEvalStack = <Track>{};

/// swaps in the (globalFrame, layer) an expression should see for the
/// duration of [fn], then restores whatever was there before.
T withExpressionContext<T>(int globalFrame, Layer layer, T Function() fn) {
  final prevFrame = _exprGlobalFrame, prevLayer = _exprLayer;
  _exprGlobalFrame = globalFrame;
  _exprLayer = layer;
  try {
    return fn();
  } finally {
    _exprGlobalFrame = prevFrame;
    _exprLayer = prevLayer;
  }
}

class LayerRef {
  final String id;
  final String name;
  final double x, y;
  final double rotation;
  final double scaleX, scaleY;
  final double opacity;
  LayerRef({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.rotation,
    required this.scaleX,
    required this.scaleY,
    required this.opacity,
  });
}

LayerRef? layerRef(Project project, dynamic idOrName) {
  Layer? found = findLayer(project, idOrName as String?);
  found ??= project.layers.cast<Layer?>().firstWhere((l) => l!.name == idOrName, orElse: () => null);
  if (found == null) return null;
  final state = getLayerStateAt(project, found.id, _exprGlobalFrame);
  final localFrame = math.min(found.durationFrames, math.max(0, _exprGlobalFrame - found.startFrame)).toDouble();
  return LayerRef(
    id: found.id,
    name: found.name,
    x: state.matrix[4],
    y: state.matrix[5],
    rotation: state.rot,
    scaleX: state.scale[0],
    scaleY: state.scale[1],
    opacity: evaluateTrack(project, found.transform.opacity, localFrame, found) as double,
  );
}

/// Always takes the "broken expression" fallback path - see the file
/// doc comment. `project` is threaded through only so this keeps the
/// same signature shape a real evaluator would need. Still pushes/pops
/// [trk] on `_exprEvalStack` around the (currently trivial) evaluation,
/// so the cycle-guard bookkeeping a real evaluator needs is already
/// exercised rather than dead code waiting to be wired up later.
dynamic evaluateExpression(Project project, Track trk) {
  if (_exprEvalStack.contains(trk)) return trk.defaultValue; // cycle - bail out safely
  _exprEvalStack.add(trk);
  try {
    return trk.defaultValue;
  } finally {
    _exprEvalStack.remove(trk);
  }
}
