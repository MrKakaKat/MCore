/// "Detach a piece" (Crop tab): a part of a layer becomes a layer of its
/// own. Nothing is deleted - the original keeps everything outside the
/// region, the new layer (a copy with the same animation and effects,
/// drawn right above it) keeps everything inside, so at first the picture
/// looks exactly the same; then the piece can be moved, animated or
/// deleted on its own. The region is a rectangle drawn on the stage or
/// the shape of another layer, taken once at the current frame.
library;

import '../core/math.dart';
import '../core/state_cache.dart';
import '../core/interpolation.dart';
import '../core/stage_size.dart';
import '../geometry/piece_outline.dart';
import '../geometry/shapes.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;
import '../ui_geometry/drag_ops.dart' show DragOp;
import '../ui_geometry/snapping.dart' show SnapGuideLine;
import 'layer_names.dart';
import 'project.dart';
import 'timeline_rows.dart' show normalizeTimelineRows;

/// Frame-space points -> `layer`'s content-local space at `globalFrame`.
List<List<double>> frameToLayerLocal(Project project, Layer layer, int globalFrame, List<List<double>> framePts) {
  final inv = invertAffine(toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix));
  return [for (final p in framePts) applyAffine(inv, p)];
}

/// A rectangle dragged on the stage (two frame-space corners) as a
/// region of `layer` (a parallelogram when the layer is rotated).
List<List<double>> rectRegion(Project project, Layer layer, int globalFrame, List<double> a, List<double> b) =>
    frameToLayerLocal(project, layer, globalFrame, [
      [a[0], a[1]],
      [b[0], a[1]],
      [b[0], b[1]],
      [a[0], b[1]],
    ]);

/// The shape of `reference` (its outline after its own effects) at
/// `globalFrame`, as a region of `layer`.
List<List<double>> layerShapeRegion(Project project, Layer layer, Layer reference, int globalFrame) {
  final m = toFrameMatrix(getLayerStateAt(project, reference.id, globalFrame).matrix);
  final outline = getContentOutline(reference.content, reference, globalFrame, project: project);
  return frameToLayerLocal(project, layer, globalFrame, [for (final p in outline) applyAffine(m, p)]);
}

/// Splits `region` (content-local, at least 3 points) off `layer` into a
/// new layer right above it, which is returned. The new layer keeps the
/// original's earlier cuts too, so pieces of pieces work.
Layer? detachPiece(Project project, Layer layer, List<List<double>> region, String newId) {
  if (region.length < 3) return null;
  final pts = [for (final p in region) [...p]];
  final piece = cloneLayer(layer)
    ..id = newId
    ..rowId = null
    ..splitRoot = null;
  piece.name = nextFreeLayerName(project, '${layer.name} part');
  piece.pieceClips.add(PieceClip(points: pts, inside: true));
  layer.pieceClips.add(PieceClip(points: [for (final p in pts) [...p]], inside: false));
  // the piece shares the original's place and time: its own timeline row,
  // drawn over the original.
  project.layers.insert(project.layers.indexOf(layer) + 1, piece);
  // its motion path, pendulum and handles follow its own centre.
  if (recenterDetachedPieces) recenterPiece(project, piece);
  normalizeTimelineRows(project);
  clearStateCaches();
  return piece;
}

/// Settings: a detached piece gets its own origin (anchor) at the centre
/// of its part, so its motion path, rotation, scale and pendulum are about
/// the piece - not about the whole object it came from. Off: the piece
/// keeps the original's origin.
bool recenterDetachedPieces = true;

/// Moves `layer`'s origin to the centre of what is left of it after its
/// cuts, without changing anything on screen at any frame: the content,
/// its cuts and the pendulum grip point shift back by as much, and the
/// position track forward. When the turn or size of the layer (or its
/// parent) is animated the shift differs per frame - then the position
/// gets a key on every frame of the layer. A path-following layer is
/// left as it is (its position comes from the path).
void recenterPiece(Project project, Layer layer) {
  if (layer.transform.pathFollow.enabled) return;
  final box = pieceBoundingBox(layer);
  final c = [(box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2];
  if (c[0].abs() < 1e-9 && c[1].abs() < 1e-9) return;
  final w = stageSize.width, h = stageSize.height;

  // how far the origin moves (in its parent's space, stage fractions) at a
  // global frame: the centre's offset from the origin, turned and scaled
  // like the layer, taken back through the parent's own turn and scale.
  List<double> shiftAt(int globalFrame) {
    final base = getLayerBaseStateAt(project, layer.id, globalFrame);
    final local = matFromTRS(const [0, 0], base.baseRot, base.scale);
    final parent = layer.parentId == null ? const <double>[1, 0, 0, 1, 0, 0] : parentMatrixFor(project, layer, globalFrame);
    final parentLin = [parent[0], parent[1], parent[2], parent[3], 0.0, 0.0];
    final world = applyAffine(matMul(parentLin, local), c); // px
    return applyAffine(invertAffine(parentLin), [world[0] / w, world[1] / h]);
  }

  clearStateCaches();
  final frames = [for (var f = 0; f <= layer.durationFrames; f++) f];
  final shifts = [for (final f in frames) shiftAt(f + layer.startFrame)];
  final constant = shifts.every((d) => (d[0] - shifts.first[0]).abs() < 1e-9 && (d[1] - shifts.first[1]).abs() < 1e-9);
  final anchor = layer.transform.anchor;
  if (constant) {
    final d = shifts.first;
    final v = anchor.defaultValue as List<double>;
    anchor.defaultValue = [v[0] + d[0], v[1] + d[1]];
    for (final k in anchor.keyframes) {
      final kv = k.value as List<double>;
      k.value = [kv[0] + d[0], kv[1] + d[1]];
    }
  } else {
    final values = [
      for (var i = 0; i < frames.length; i++)
        () {
          final a = evaluateTrack(project, anchor, frames[i].toDouble(), layer) as List<double>;
          return [a[0] + shifts[i][0], a[1] + shifts[i][1]];
        }()
    ];
    anchor.keyframes
      ..clear()
      ..addAll([for (var i = 0; i < frames.length; i++) Keyframe(frame: frames[i], value: values[i])]);
    if (anchor.spatial) autoComputeTangents(anchor);
  }
  List<double> back(List<double> p) => [p[0] - c[0], p[1] - c[1]];
  layer.content.offset = back(layer.content.offset);
  for (final clip in layer.pieceClips) {
    clip.points = [for (final p in clip.points) back(p)];
  }
  final pivot = layer.pendulum.pivotOffset;
  pivot.defaultValue = back(pivot.defaultValue as List<double>);
  for (final k in pivot.keyframes) {
    k.value = back(k.value as List<double>);
  }
  if (pivot.spatial) autoComputeTangents(pivot);
  clearStateCaches();
}

/// Crop tab's quick tool: drag a rectangle on the stage over the selected
/// layer; lifting the finger detaches what is inside it.
bool pieceRectTool = false;

/// The rectangle being dragged (frame space). Nothing changes until the
/// finger lifts.
class PieceRectDragOp implements DragOp {
  final Layer layer;
  List<double>? a, b;
  PieceRectDragOp(this.layer);

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    a ??= [...framePoint];
    b = [...framePoint];
  }
}
