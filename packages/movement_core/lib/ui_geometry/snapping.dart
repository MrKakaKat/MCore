/// ============================================================
/// Snapping system (movement-mobile-snapping-spec.md) - candidate
/// finding + conflict resolution, pure Dart (no Flutter/camera), same
/// separation as drag_ops.dart/handles.dart. Hooked from
/// AnchorDragOp.apply (position categories: edge-to-edge, center-to-
/// center H/V/diagonal+continue-line/equal-spacing, corner-to-corner,
/// grid, frame boundary) and ScaleDragOp.apply (equal-size only) - per
/// the user's own confirmed scope: resizing never triggers position
/// snapping, moving never triggers size-matching.
///
/// Conflict resolution: X and Y axes resolve INDEPENDENTLY ("nearest
/// wins" per axis - the standard "smart guides" behavior in every real
/// design tool, letting an object snap X to one neighbor and Y to a
/// completely different one). Only genuinely non-decomposable
/// candidates - a non-orthogonal center-to-center line, and the
/// continue-line/equal-spacing candidate - are resolved as a single 2D
/// "joint" candidate that moves both axes together, and only when
/// strictly nearer than each axis's own winner. Frame-boundary
/// candidates override an equally-or-more-distant ordinary candidate on
/// their axis outright (the one boundary that's always structurally
/// meaningful - what actually ends up in the export).
/// ============================================================
library;

import 'dart:math' as math;

import '../core/math.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../geometry/piece_outline.dart';
import '../geometry/shapes.dart';
import '../model/project.dart';
import 'handles.dart';
import 'text_snap.dart';

enum SnapCategory {
  edgeToEdge,
  centerHorizontal,
  centerVertical,
  centerDiagonal,
  centerExact,
  cornerToCorner,
  grid,
  frameBoundary,
  continueLine,
  centerLine, // any-angle P-Q line (axis form for aligned pairs, joint form otherwise)
  rotationAngle, // rotation snapped to a fixed H/V/diagonal angle
  rotationMatch, // rotation snapped to another layer's own current rotation
  textLetter, // a text's letter onto another text's letter (middle or edge)
}

class SnapGuideLine {
  final SnapCategory category;
  final List<double> a;
  final List<double> b;
  SnapGuideLine({required this.category, required this.a, required this.b});
}

class AnchorSnapResult {
  final List<double> newLocal;
  final List<SnapGuideLine> guides;
  AnchorSnapResult({required this.newLocal, required this.guides});
}

class SizeSnapResult {
  final List<double> newScale;
  final SnapGuideLine? guide;
  SizeSnapResult({required this.newScale, this.guide});
}

class RotationSnapResult {
  final double newRotation;
  final SnapGuideLine? guide;
  RotationSnapResult({required this.newRotation, this.guide});
}

class GridLine {
  final List<double> a;
  final List<double> b;
  GridLine({required this.a, required this.b});
}

/// N x M, always evenly auto-fit - sectors divide the frame evenly,
/// never a fixed pixel size that might not divide cleanly. Skips the
/// i=0/cols and j=0/rows lines (those coincide with the frame boundary,
/// already drawn elsewhere) - lines are constructed only within
/// [0,frameWidth]x[0,frameHeight] by construction, so "never drawn
/// beyond the canvas boundary" holds with no extra clip needed.
List<GridLine> computeSnapGridLines(
    double frameWidth, double frameHeight, int cols, int rows, {int? kinds}) {
  final k = kinds ?? gridLineKinds;
  final lines = <GridLine>[];
  if (k & 1 != 0) {
    for (var i = 1; i < cols; i++) {
      final x = frameWidth * i / cols;
      lines.add(GridLine(a: [x, 0], b: [x, frameHeight]));
    }
  }
  if (k & 2 != 0) {
    for (var j = 1; j < rows; j++) {
      final y = frameHeight * j / rows;
      lines.add(GridLine(a: [0, y], b: [frameWidth, y]));
    }
  }
  if (k & 4 != 0) lines.addAll(gridDiagonals(0, 0, frameWidth, frameHeight, cols, rows));
  return lines;
}

/// Both diagonals of every cell of a cols x rows grid over the box.
List<GridLine> gridDiagonals(double x0, double y0, double w, double h, int cols, int rows) => [
      for (var i = 0; i < cols; i++)
        for (var j = 0; j < rows; j++) ...[
          GridLine(a: [x0 + w * i / cols, y0 + h * j / rows], b: [x0 + w * (i + 1) / cols, y0 + h * (j + 1) / rows]),
          GridLine(a: [x0 + w * (i + 1) / cols, y0 + h * j / rows], b: [x0 + w * i / cols, y0 + h * (j + 1) / rows]),
        ]
    ];

double _orOne(double v) => v == 0 ? 1 : v;

double _pointDistance(List<double> a, List<double> b) =>
    math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));

double _edgeGap(BoundingBox a, BoundingBox b) {
  final dx = math.max(0.0, math.max(a.minX - b.maxX, b.minX - a.maxX));
  final dy = math.max(0.0, math.max(a.minY - b.maxY, b.minY - a.maxY));
  return math.sqrt(dx * dx + dy * dy);
}

/// walks UP from `l`'s own parent chain - true if it ever reaches
/// `ancestorId`. Mirrors layer_ops.dart's existing wouldCreateCycle
/// (same walk-up shape, opposite question: "is l a descendant of
/// ancestorId" rather than "would assigning a parent create a cycle").
bool _isDescendantOf(Project project, Layer l, String ancestorId) {
  var cur = l.parentId != null ? findLayer(project, l.parentId) : null;
  while (cur != null) {
    if (cur.id == ancestorId) return true;
    cur = cur.parentId != null ? findLayer(project, cur.parentId) : null;
  }
  return false;
}

/// every OTHER in-range layer, excluding the dragged layer's own
/// descendants (their position/size is a function of the dragged
/// layer's own value - snapping against them would be circular).
List<Layer> _snapCandidates(Project project, Layer dragged, int globalFrame, {LayerFrameGeometry? own}) {
  final all = project.layers
      .where((l) =>
          l.id != dragged.id &&
          !isAudioShape(l.content.shape) &&
          !_isDescendantOf(project, l, dragged.id) &&
          getLayerStateAt(project, l.id, globalFrame).inRange)
      .toList();
  if (own == null || snapReachBySize <= 0) return all;
  // only the ones near it: within its own size (times the setting).
  final b = own.bbox;
  final reach = snapReachBySize * math.max(b.maxX - b.minX, b.maxY - b.minY);
  return [
    for (final l in all)
      () {
        final o = computeLayerFrameGeometry(project, l, globalFrame, includeVertices: false).bbox;
        final gx = math.max(0.0, math.max(o.minX - b.maxX, b.minX - o.maxX));
        final gy = math.max(0.0, math.max(o.minY - b.maxY, b.minY - o.maxY));
        return math.sqrt(gx * gx + gy * gy) <= reach ? l : null;
      }()
  ].whereType<Layer>().toList();
}

// ===== position categories (edge/center/corner/grid/frame-boundary) =====

class _AxisCandidate {
  final SnapCategory category;
  final double ownValue;
  final double targetValue;
  final double radius;
  final List<double>? otherPoint; // for guide-line construction only
  _AxisCandidate(
      {required this.category,
      required this.ownValue,
      required this.targetValue,
      required this.radius,
      this.otherPoint});
  double get distance => (ownValue - targetValue).abs();
}

_AxisCandidate? _nearestInRange(List<_AxisCandidate> list) {
  _AxisCandidate? best;
  var bestDist = double.infinity;
  for (final c in list) {
    final d = c.distance;
    if (d <= c.radius && d < bestDist) {
      bestDist = d;
      best = c;
    }
  }
  return best;
}

void _addEdgeToEdge(List<_AxisCandidate> xs, List<_AxisCandidate> ys,
    LayerFrameGeometry own, LayerFrameGeometry other) {
  if (!snapEdgeToEdgeEnabled) return;
  for (final ov in [own.bbox.minX, own.bbox.maxX]) {
    for (final tv in [other.bbox.minX, other.bbox.maxX]) {
      xs.add(_AxisCandidate(
          category: SnapCategory.edgeToEdge,
          ownValue: ov,
          targetValue: tv,
          radius: snapEdgeToEdgeFrameRadius,
          otherPoint: other.center));
    }
  }
  for (final ov in [own.bbox.minY, own.bbox.maxY]) {
    for (final tv in [other.bbox.minY, other.bbox.maxY]) {
      ys.add(_AxisCandidate(
          category: SnapCategory.edgeToEdge,
          ownValue: ov,
          targetValue: tv,
          radius: snapEdgeToEdgeFrameRadius,
          otherPoint: other.center));
    }
  }
}

/// H and V are NOT modeled as center-line/angle candidates at all - a
/// horizontal (0 deg) line's perpendicular projection only ever moves
/// Y, a vertical (90 deg) one only ever moves X, so they're plain
/// scalar axis candidates from the start (toggle-independent from the
/// diagonal machinery below, matching the spec's three separate H/V/
/// diagonal sub-toggles).
void _addCenterHV(List<_AxisCandidate> xs, List<_AxisCandidate> ys,
    LayerFrameGeometry own, LayerFrameGeometry other) {
  if (!snapCenterToCenterEnabled) return;
  if (snapCenterVerticalEnabled) {
    xs.add(_AxisCandidate(
        category: SnapCategory.centerVertical,
        ownValue: own.center[0],
        targetValue: other.center[0],
        radius: snapCenterToCenterFrameRadius,
        otherPoint: other.center));
  }
  if (snapCenterHorizontalEnabled) {
    ys.add(_AxisCandidate(
        category: SnapCategory.centerHorizontal,
        ownValue: own.center[1],
        targetValue: other.center[1],
        radius: snapCenterToCenterFrameRadius,
        otherPoint: other.center));
  }
}

/// each vertex contributes its x to the X-pool and its y to the Y-pool
/// INDEPENDENTLY - own can snap X to one vertex and Y to a different
/// one, same as every other axis category (own.vertices/other.vertices
/// already carry the mesh-warp/corner-pin-aware midpoint branching from
/// computeLayerFrameGeometry - see handles.dart).
/// A 2-D match (a corner onto a corner, an edge's middle onto an edge's
/// middle): it counts only when BOTH axes are close - so it never acts as
/// a one-axis edge snap with a wider reach (it used to win over edge to
/// edge that way). When it matches it moves both axes; edge to edge still
/// wins an axis where it is closer (the two add up).
class _PointCandidate {
  final SnapCategory category;
  final List<double> own, target;
  final double radius;
  _PointCandidate(this.category, this.own, this.target, this.radius);
  double get dx => target[0] - own[0];
  double get dy => target[1] - own[1];
  bool get inRange => dx.abs() <= radius && dy.abs() <= radius;
  double get distance => math.sqrt(dx * dx + dy * dy);
}

void _addCornerToCorner(List<_PointCandidate> out, LayerFrameGeometry own, LayerFrameGeometry other) {
  if (!snapCornerToCornerEnabled) return;
  for (final ov in own.vertices) {
    for (final tv in other.vertices) {
      out.add(_PointCandidate(SnapCategory.cornerToCorner, ov, tv, snapCornerToCornerFrameRadius));
    }
  }
}

List<List<double>> _edgeMids(BoundingBox b) => [
      [(b.minX + b.maxX) / 2, b.minY],
      [b.maxX, (b.minY + b.maxY) / 2],
      [(b.minX + b.maxX) / 2, b.maxY],
      [b.minX, (b.minY + b.maxY) / 2],
    ];

/// Edge to edge, middles: an edge's middle onto another's.
void _addEdgeMidpoints(List<_PointCandidate> out, LayerFrameGeometry own, LayerFrameGeometry other) {
  if (!snapEdgeToEdgeEnabled || !snapEdgeMidpointsEnabled) return;
  for (final ov in _edgeMids(own.bbox)) {
    for (final tv in _edgeMids(other.bbox)) {
      out.add(_PointCandidate(SnapCategory.edgeToEdge, ov, tv, snapEdgeToEdgeFrameRadius));
    }
  }
}

/// Edge to edge: also an edge's middle onto another's.
bool snapEdgeMidpointsEnabled = true;

/// Snapping only reaches objects near the dragged one: within this many
/// of its own sizes (its bigger side) - not across the whole stage. 0:
/// everywhere, as before.
double snapReachBySize = 1.5;

/// Fixed angle, not a px radius. Routing a near-horizontal P-Q line into
/// the Y axis pool measures |dy| where the true value is the
/// perpendicular distance |dy|*cos(theta) - the ranking error depends
/// only on the angle (cos 5 deg = 0.9962, under 0.4%). A px threshold
/// would call short, steep pairs "aligned" (8px over dx=20 is 22 deg).
/// It's also zoom-independent, unlike a pixel tolerance. _addCenterHV
/// has no pair-alignment concept to reuse - this is new.
const double _kAlignedPairToleranceDeg = 5;

/// 0 = P->Q runs (near-)horizontally, 1 = (near-)vertically, -1 =
/// neither/degenerate (a genuinely diagonal pair, handled by the joint
/// pool instead - see _buildJointCandidates).
int _alignedAxis(List<double> pC, List<double> qC) {
  final dx = (qC[0] - pC[0]).abs(), dy = (qC[1] - pC[1]).abs();
  if (dx < 1e-6 && dy < 1e-6) return -1;
  final t = math.tan(_kAlignedPairToleranceDeg * math.pi / 180);
  if (dy <= dx * t) return 0;
  if (dx <= dy * t) return 1;
  return -1;
}

/// Independent of snapCenterLineEnabled (the Any-angle-line toggle) - equal
/// spacing works on its own switch regardless of whether the any-angle line is
/// separately on - a direct reversal of a prior round's design choice to
/// couple the two). Previously also gated on the DIAGONAL toggle instead, a
/// completely different, fixed-angle-only feature - traced to that earlier
/// mismatch.
bool get _equalSpacingActive =>
    snapCenterToCenterEnabled && snapEqualSpacingEnabled;

/// for a (near-)aligned pair - the textbook "3 objects in a row" equal-spacing
/// case - the equal-spacing/any-angle- line candidates used to live ONLY in
/// the joint (2D) pool, ranked by full point/perpendicular distance. But the
/// ORDINARY axis pool's own center-H/V candidate for that SAME pair is ranked
/// by a single component distance (|dy| or |dx|), always <= the joint pool's
/// own 2D distance - so the joint pool (which only wins by beating BOTH axis
/// winners at once) almost never won for an aligned pair. Fix: route aligned
/// pairs' own line/equal-spacing candidates into the AXIS pool instead, so
/// they compete in the same 1D units as everything else on that axis.
/// Non-aligned pairs are unaffected - they still go through the joint pool
/// (see _buildJointCandidates, which skips pairs this function already
/// covers).
void _addPairAxisCandidates(List<_AxisCandidate> xs, List<_AxisCandidate> ys,
    LayerFrameGeometry own, Map<String, LayerFrameGeometry> others) {
  if (!snapCenterToCenterEnabled) return;
  if (!snapCenterLineEnabled && !_equalSpacingActive) return;
  double extent(LayerFrameGeometry g, int i) =>
      i == 0 ? g.bbox.maxX - g.bbox.minX : g.bbox.maxY - g.bbox.minY;
  final ids = others.keys.toList();
  for (final pId in ids) {
    for (final qId in ids) {
      if (pId == qId) continue;
      final p = others[pId]!, q = others[qId]!;
      final pC = p.center, qC = q.center;
      final a = _alignedAxis(pC, qC); // along-axis index (0=X, 1=Y)
      if (a == -1) continue;
      final b = 1 - a; // perpendicular-axis index
      final alongPool = a == 0 ? xs : ys, perpPool = a == 0 ? ys : xs;
      final d = [qC[0] - pC[0], qC[1] - pC[1]];
      // exact line (not just Q's own b-coordinate), evaluated at own's
      // own along-coordinate - correct even for a slightly-tilted
      // "aligned" pair, not just a perfectly flat one.
      final linePerpAt = pC[b] + (own.center[a] - pC[a]) * (d[b] / d[a]);
      // (1) any-angle line, 1D form - unordered pair, added once.
      // Independently gated: this candidate is the any-angle-line
      // toggle's own effect, decoupled from equal spacing below.
      if (snapCenterLineEnabled && pId.compareTo(qId) < 0) {
        perpPool.add(_AxisCandidate(
            category: SnapCategory.centerLine,
            ownValue: own.center[b],
            targetValue: linePerpAt,
            radius: snapCenterToCenterFrameRadius,
            otherPoint: qC));
      }
      // (2) equal spacing, 1D form - ordered pair, continues P->Q past Q.
      // Band-gated on the perpendicular axis so X isn't pulled to "the
      // next slot" while own is nowhere near the row's own height.
      if (_equalSpacingActive) {
        final band = math.max(math.max(extent(p, b), extent(q, b)) / 2,
            snapCenterToCenterFrameRadius);
        if ((own.center[b] - linePerpAt).abs() <= band) {
          alongPool.add(_AxisCandidate(
              category: SnapCategory.continueLine,
              ownValue: own.center[a],
              targetValue: qC[a] + d[a],
              radius: snapCenterToCenterFrameRadius,
              otherPoint: qC));
        }
      }
    }
  }
}

/// Texts: letter onto letter by their outlines (text_snap.dart) - middles
/// as a 2-D match, edges per axis.
void _addTextLetters(List<_AxisCandidate> xs, List<_AxisCandidate> ys, List<_PointCandidate> points, Project project,
    Layer layer, int globalFrame, LayerFrameGeometry own, List<Layer> candidates) {
  if (!snapTextCentersEnabled && !snapTextEdgesEnabled) return;
  final mine = textLetterFrameBoxes(project, layer, globalFrame);
  if (mine == null || mine.isEmpty) return;
  final others = [
    for (final c in candidates)
      if (c.content.shape == 'text') textLetterFrameBoxes(project, c, globalFrame) ?? const <BoundingBox>[]
  ];
  if (others.every((o) => o.isEmpty)) return;
  // where the drag puts them: moved like the whole text.
  final now = computeLayerFrameGeometry(project, layer, globalFrame, includeVertices: false).center;
  final dx = own.center[0] - now[0], dy = own.center[1] - now[1];
  final moved = [
    for (final b in mine) BoundingBox(minX: b.minX + dx, maxX: b.maxX + dx, minY: b.minY + dy, maxY: b.maxY + dy)
  ];
  final r = snapCenterToCenterFrameRadius;
  for (final s in textLetterSnaps(moved, others, r)) {
    if (s.middle) {
      points.add(_PointCandidate(SnapCategory.textLetter, s.own, s.target, r));
    } else {
      (s.axis == 0 ? xs : ys).add(_AxisCandidate(
          category: SnapCategory.textLetter,
          ownValue: s.own[s.axis],
          targetValue: s.target[s.axis],
          radius: r,
          otherPoint: s.target));
    }
  }
}

void _addGrid(
    List<_AxisCandidate> xs, List<_AxisCandidate> ys, LayerFrameGeometry own) {
  if (!snapGridEnabled) return;
  // diagonals: the middle snaps onto where they cross (cell middles).
  if (gridLineKinds & 4 != 0) {
    final w = stageSize.width, h = stageSize.height;
    for (var i = 0; i < snapGridCols; i++) {
      xs.add(_AxisCandidate(
          category: SnapCategory.grid,
          ownValue: own.center[0],
          targetValue: w * (i + 0.5) / snapGridCols,
          radius: snapGridFrameRadius));
    }
    for (var j = 0; j < snapGridRows; j++) {
      ys.add(_AxisCandidate(
          category: SnapCategory.grid,
          ownValue: own.center[1],
          targetValue: h * (j + 0.5) / snapGridRows,
          radius: snapGridFrameRadius));
    }
  }
  for (final line in computeSnapGridLines(
      stageSize.width, stageSize.height, snapGridCols, snapGridRows)) {
    final isVertical = line.a[0] == line.b[0];
    final isHorizontal = line.a[1] == line.b[1];
    if (!isVertical && !isHorizontal) continue; // a diagonal: above
    if (isVertical) {
      // its edges and its middle.
      for (final ov in [own.bbox.minX, own.bbox.maxX, own.center[0]]) {
        xs.add(_AxisCandidate(
            category: SnapCategory.grid,
            ownValue: ov,
            targetValue: line.a[0],
            radius: snapGridFrameRadius));
      }
    } else {
      for (final ov in [own.bbox.minY, own.bbox.maxY, own.center[1]]) {
        ys.add(_AxisCandidate(
            category: SnapCategory.grid,
            ownValue: ov,
            targetValue: line.a[1],
            radius: snapGridFrameRadius));
      }
    }
  }
}

/// generated exactly like edge-to-edge, just against the fixed rect
/// [0,frameWidth]x[0,frameHeight] instead of another layer's bbox - the
/// spec's own framing ("the canvas edge... always structurally
/// meaningful") is what earns it the override in computeAnchorSnap
/// below, not anything different about how the candidate itself is
/// built.
void _addFrameBoundary(
    List<_AxisCandidate> xs, List<_AxisCandidate> ys, LayerFrameGeometry own) {
  if (!snapFrameBoundaryEnabled) return;
  for (final ov in [own.bbox.minX, own.bbox.maxX]) {
    for (final tv in [0.0, stageSize.width]) {
      xs.add(_AxisCandidate(
          category: SnapCategory.frameBoundary,
          ownValue: ov,
          targetValue: tv,
          radius: snapFrameBoundaryFrameRadius));
    }
  }
  for (final ov in [own.bbox.minY, own.bbox.maxY]) {
    for (final tv in [0.0, stageSize.height]) {
      ys.add(_AxisCandidate(
          category: SnapCategory.frameBoundary,
          ownValue: ov,
          targetValue: tv,
          radius: snapFrameBoundaryFrameRadius));
    }
  }
}

// ===== center-to-center diagonal + continue-line/equal-spacing (joint 2D pool) =====

class _JointCandidate {
  final SnapCategory category;
  final List<double> referencePoint;
  final double angleDeg;
  final double? matchDistance; // non-null only for the continue-line candidate
  _JointCandidate(
      {required this.category,
      required this.referencePoint,
      required this.angleDeg,
      this.matchDistance});
}

double _perpDistanceToLine(List<double> p, List<double> ref, double angleDeg) {
  final rad = angleDeg * math.pi / 180;
  final dx = math.cos(rad), dy = math.sin(rad);
  final px = p[0] - ref[0], py = p[1] - ref[1];
  return (px * dy - py * dx).abs();
}

List<double> _projectOntoLine(
    List<double> p, List<double> ref, double angleDeg) {
  final rad = angleDeg * math.pi / 180;
  final dx = math.cos(rad), dy = math.sin(rad);
  final px = p[0] - ref[0], py = p[1] - ref[1];
  final t = px * dx + py * dy;
  return [ref[0] + t * dx, ref[1] + t * dy];
}

List<double> _pointAlongAngle(List<double> ref, double angleDeg, double dist) {
  final rad = angleDeg * math.pi / 180;
  return [ref[0] + math.cos(rad) * dist, ref[1] + math.sin(rad) * dist];
}

/// fixed-angle candidates (any angle in the increment set that ISN'T a
/// multiple of 90 - those are H/V, handled as plain axis candidates above)
/// against every other object, PLUS the any-angle line/continue-
/// line-equal-spacing candidates for NON-ALIGNED pairs only (aligned pairs are
/// handled by _addPairAxisCandidates instead, in the axis pool, where they can
/// actually compete - see that function's own doc comment). Also always
/// contributes a plain exact-center-match candidate per other object
/// (matchDistance: 0, so _resolveJoint's own matchDistance branch collapses
/// the "projected point" to exactly `referencePoint` regardless of angleDeg -
/// no new resolution code needed) - gated ONLY by the category master,
/// independent of which H/V/diagonal/line sub-toggle is on. with those
/// line-based sub-toggles gating the ONLY center candidates that existed
/// before, an object could never be pulled exactly onto another's center
/// unless BOTH H and V happened to be on together -
List<_JointCandidate> _buildJointCandidates(
    Map<String, LayerFrameGeometry> others, [List<List<double>> gridPoints = const []]) {
  if (!snapCenterToCenterEnabled) return const [];
  final ids = others.keys.toList();
  final list = <_JointCandidate>[
    // a rect's own grid: its crossings pull a centre onto them.
    for (final p in gridPoints)
      _JointCandidate(category: SnapCategory.centerExact, referencePoint: p, angleDeg: 0, matchDistance: 0),
  ];
  for (final id in ids) {
    list.add(_JointCandidate(
        category: SnapCategory.centerExact,
        referencePoint: others[id]!.center,
        angleDeg: 0,
        matchDistance: 0));
  }
  // this used to be `if (!snapCenterDiagonalEnabled) return list;` - an early
  // return that ALSO skipped the equal-spacing block below whenever Diagonal
  // was off, even though the UI's own Equal-spacing switch is shown/enabled
  // independent of Diagonal. Diagonal and the any-angle line (below) are now
  // two fully independent blocks.
  if (snapCenterDiagonalEnabled) {
    for (final id in ids) {
      final center = others[id]!.center;
      for (var angle = 0.0;
          angle < 360;
          angle += snapDiagonalAngleIncrementDeg) {
        if (angle % 90 == 0) continue;
        list.add(_JointCandidate(
            category: SnapCategory.centerDiagonal,
            referencePoint: center,
            angleDeg: angle));
      }
    }
  }
  if (snapCenterLineEnabled) {
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final pC = others[ids[i]]!.center, qC = others[ids[j]]!.center;
        if (_alignedAxis(pC, qC) != -1) {
          continue; // aligned: handled in the axis pool instead
        }
        if (_pointDistance(pC, qC) < 1e-6) {
          continue; // coincident centers - no well-defined line
        }
        final angle = math.atan2(qC[1] - pC[1], qC[0] - pC[0]) * 180 / math.pi;
        list.add(_JointCandidate(
            category: SnapCategory.centerLine,
            referencePoint: qC,
            angleDeg: angle)); // matchDistance null = free-slide line
      }
    }
  }
  if (_equalSpacingActive) {
    for (final pId in ids) {
      for (final qId in ids) {
        if (pId == qId) continue;
        final pC = others[pId]!.center, qC = others[qId]!.center;
        if (_alignedAxis(pC, qC) != -1) {
          continue; // aligned: handled in _addPairAxisCandidates instead
        }
        final angle = math.atan2(qC[1] - pC[1], qC[0] - pC[0]) * 180 / math.pi;
        final dist = _pointDistance(pC, qC);
        list.add(_JointCandidate(
            category: SnapCategory.continueLine,
            referencePoint: qC,
            angleDeg: angle,
            matchDistance: dist));
      }
    }
  }
  return list;
}

class _JointResolution {
  final _JointCandidate candidate;
  final double distance;
  final List<double> snappedPoint;
  _JointResolution(
      {required this.candidate,
      required this.distance,
      required this.snappedPoint});
}

/// Point candidates (centerExact, continueLine) and line candidates
/// (centerDiagonal, centerLine) are ranked in SEPARATE PRIORITY TIERS,
/// point-tier first. A point that lies ON a line always has
/// perpendicular distance <= its own point distance (the line is the
/// nearest-point set to itself), so a single nearest-wins pool would
/// let a line candidate silently swallow every point candidate for the
/// same pair - e.g. the new any-angle line would always beat its own
/// pair's equal-spacing point, since they share the exact same angle.
/// Returned in priority order: [bestPoint?, bestLine?] - the caller
/// tries each in turn, only falling through to the line tier if no
/// point candidate won.
List<_JointResolution> _resolveJoint(
    List<_JointCandidate> candidates, List<double> ownCenter) {
  _JointResolution? bestPoint, bestLine;
  for (final c in candidates) {
    final isPoint = c.matchDistance != null;
    final snapped = isPoint
        ? _pointAlongAngle(c.referencePoint, c.angleDeg, c.matchDistance!)
        : _projectOntoLine(ownCenter, c.referencePoint, c.angleDeg);
    final dist = isPoint
        ? _pointDistance(ownCenter, snapped)
        : _perpDistanceToLine(ownCenter, c.referencePoint, c.angleDeg);
    if (dist > snapCenterToCenterFrameRadius) continue;
    final r =
        _JointResolution(candidate: c, distance: dist, snappedPoint: snapped);
    if (isPoint) {
      if (bestPoint == null || dist < bestPoint.distance) bestPoint = r;
    } else if (bestLine == null || dist < bestLine.distance) {
      bestLine = r;
    }
  }
  return [if (bestPoint != null) bestPoint, if (bestLine != null) bestLine];
}

SnapGuideLine _axisGuide(SnapCategory category, bool isX, double snappedValue,
    List<double> ownCenter, List<double>? otherPoint) {
  if (category == SnapCategory.continueLine && otherPoint != null) {
    // the equal-spacing axis candidate's guide runs from the reference
    // object (Q) to the snapped slot, not a zero-length perpendicular
    // stub - otherwise a horizontal row's own X guide would be an
    // invisible vertical sliver.
    return SnapGuideLine(
        category: category,
        a: otherPoint,
        b: isX ? [snappedValue, otherPoint[1]] : [otherPoint[0], snappedValue]);
  }
  if (isX) {
    return SnapGuideLine(
        category: category,
        a: [snappedValue, ownCenter[1]],
        b: [snappedValue, otherPoint?[1] ?? (ownCenter[1] + 40)]);
  }
  return SnapGuideLine(
      category: category,
      a: [ownCenter[0], snappedValue],
      b: [otherPoint?[0] ?? (ownCenter[0] + 40), snappedValue]);
}

/// converts a FRAME-space delta (a vector, not a point - no
/// translation) into the layer's own parent-local coordinate space, by
/// diffing two point-conversions through the same parent matrix
/// (translation cancels automatically). Same idiom AnchorDragOp.apply
/// itself already uses for its own delta math (nowLocal - startLocal) -
/// expressed via two throwaway point conversions rather than a
/// separately-derived linear-part-only matrix multiply, so it's
/// obviously correct by inspection.
List<double> frameDeltaToLocal(Project project, Layer layer, int globalFrame,
    List<double> from, List<double> delta) {
  final parentMatrix = layer.parentId != null
      ? parentMatrixFor(project, layer, globalFrame)
      : <double>[1, 0, 0, 1, 0, 0];
  final inv = invertAffine(parentMatrix);
  final beforeLocal =
      applyAffine(inv, [from[0] / stageSize.width, from[1] / stageSize.height]);
  final afterLocal = applyAffine(inv, [
    (from[0] + delta[0]) / stageSize.width,
    (from[1] + delta[1]) / stageSize.height
  ]);
  return [afterLocal[0] - beforeLocal[0], afterLocal[1] - beforeLocal[1]];
}

/// called from AnchorDragOp.apply right before its existing
/// `k != null ? k.value = newLocal : trk.defaultValue = newLocal` write
/// - receives the ALREADY-computed `newLocal` (AnchorDragOp's own
/// delta-based math has already run), so this never needs to touch
/// drag_ops.dart's private _keyframeAt/_localFrame helpers (library-
/// private there anyway) or re-derive the default-vs-keyframe branch
/// itself. Every enabled/threshold/mode/gap/angle setting is read
/// directly off project.dart's plain globals - no params needed for
/// those, same as stage_painter.dart reading hideHandles directly.
AnchorSnapResult computeAnchorSnap({
  required Project project,
  required Layer layer,
  required int globalFrame,
  required List<double> newLocal,
}) {
  if (!snapEnabled) {
    return AnchorSnapResult(newLocal: newLocal, guides: const []);
  }

  final own = computeLayerFrameGeometry(project, layer, globalFrame,
      anchorOverride: newLocal, includeVertices: snapCornerToCornerEnabled);
  final candidates = _snapCandidates(project, layer, globalFrame, own: own);
  final otherGeoms = <String, LayerFrameGeometry>{
    for (final c in candidates)
      c.id: computeLayerFrameGeometry(project, c, globalFrame,
          includeVertices: snapCornerToCornerEnabled),
  };

  final xOrdinary = <_AxisCandidate>[], yOrdinary = <_AxisCandidate>[];
  final points = <_PointCandidate>[];
  for (final geom in otherGeoms.values) {
    _addEdgeToEdge(xOrdinary, yOrdinary, own, geom);
    _addCenterHV(xOrdinary, yOrdinary, own, geom);
    _addCornerToCorner(points, own, geom);
    _addEdgeMidpoints(points, own, geom);
  }
  _addPairAxisCandidates(xOrdinary, yOrdinary, own, otherGeoms);
  _addTextLetters(xOrdinary, yOrdinary, points, project, layer, globalFrame, own, candidates);
  _addGrid(xOrdinary, yOrdinary, own);
  // the frame's edges compete like the rest (they used to win outright
  // whenever in reach, blocking a closer snap to an object).
  _addFrameBoundary(xOrdinary, yOrdinary, own);

  var xWin = _nearestInRange(xOrdinary);
  var yWin = _nearestInRange(yOrdinary);
  const xFb = null, yFb = null;

  // a 2-D match moves both axes - unless an axis has a closer snap of
  // its own there (they add up).
  _PointCandidate? pWin;
  for (final p in points) {
    if (p.inRange && (pWin == null || p.distance < pWin.distance)) pWin = p;
  }
  if (pWin != null) {
    // a letter's middle onto a letter beats the letters' edges (a letter
    // set into the same letter would otherwise catch on its neighbour).
    final letter = pWin.category == SnapCategory.textLetter;
    if (xWin == null || pWin.dx.abs() < xWin.distance || (letter && xWin.category == SnapCategory.textLetter)) {
      xWin = _AxisCandidate(
          category: pWin.category, ownValue: pWin.own[0], targetValue: pWin.target[0], radius: pWin.radius, otherPoint: pWin.target);
    }
    if (yWin == null || pWin.dy.abs() < yWin.distance || (letter && yWin.category == SnapCategory.textLetter)) {
      yWin = _AxisCandidate(
          category: pWin.category, ownValue: pWin.own[1], targetValue: pWin.target[1], radius: pWin.radius, otherPoint: pWin.target);
    }
  }

  var deltaX = xWin != null ? xWin.targetValue - xWin.ownValue : 0.0;
  var deltaY = yWin != null ? yWin.targetValue - yWin.ownValue : 0.0;
  final guides = <SnapGuideLine>[];
  var jointWon = false;

  if (xFb == null && yFb == null) {
    final xDist = xWin?.distance ?? double.infinity;
    final yDist = yWin?.distance ?? double.infinity;
    for (final joint
        in _resolveJoint(_buildJointCandidates(otherGeoms, snapRectGridEnabled ? [for (final c in candidates) ...rectGridCrossingsFrame(project, c, globalFrame)] : const []), own.center)) {
      if (joint.distance < xDist && joint.distance < yDist) {
        deltaX = joint.snappedPoint[0] - own.center[0];
        deltaY = joint.snappedPoint[1] - own.center[1];
        jointWon = true;
        final c = joint.candidate;
        guides.add(SnapGuideLine(
            category: c.category,
            a: c.category == SnapCategory.centerExact
                ? own.center
                : c.referencePoint,
            b: joint.snappedPoint));
        break;
      }
    }
  }

  if (!jointWon) {
    if (xWin != null) {
      guides.add(_axisGuide(xWin.category, true, xWin.targetValue, own.center, xWin.otherPoint));
    }
    if (yWin != null) {
      guides.add(_axisGuide(yWin.category, false, yWin.targetValue, own.center, yWin.otherPoint));
    }
  }

  if (xWin == null && yWin == null && !jointWon) {
    return AnchorSnapResult(newLocal: newLocal, guides: const []);
  }

  final localDelta = frameDeltaToLocal(
      project, layer, globalFrame, own.center, [deltaX, deltaY]);
  return AnchorSnapResult(
      newLocal: [newLocal[0] + localDelta[0], newLocal[1] + localDelta[1]],
      guides: guides);
}

// ===== rotation (RotateDragOp only) =====

/// signed shortest delta (to - from), in (-180, 180]. Dart's `%` with a
/// positive divisor is always in [0, 360), so this can't return -0 or a
/// value outside the expected half-open range.
double _angleDeltaDeg(double from, double to) {
  final d = (to - from) % 360;
  return d > 180 ? d - 360 : d;
}

/// called from RotateDragOp.apply right before its existing `k != null ?
/// k.value = newRotation: trk.defaultValue = newRotation` write, mirroring
/// computeAnchorSnap/computeScaleSnap's own hook shape. Two independent
/// mechanisms, both s: (a) fixed- increment snapping (H: 0/180, V: 90/270,
/// Diagonal: every other multiple of the SAME snapDiagonalAngleIncrementDeg
/// position-snapping already uses - "diagonal" should mean the same angle set
/// everywhere) needs no other-layer lookup at all; (b) matching a nearby
/// object's own current rotation reads every other in-range, non- descendant
/// layer's LOCAL rotation (LayerState.rot - the same parent-relative value
/// this drag is itself writing to, so local-vs- local is exact for top-level
/// layers and for siblings under the same parent, the common cases including
/// groups; this file doesn't special-case rotated/skewed parents anywhere else
/// either, so upgrading to a world-rotation extraction is a disclosed,
/// deliberate simplification, not an oversight - see this round's own plan
/// notes). No spatial gate on the match mechanism, deliberately: equal-size
/// (the closest existing analog - comparing a non-positional numeric property
/// of nearby OTHER layers) already has the opposite shape, a spatial gate with
/// NO threshold on the size difference itself: a value threshold makes sense
/// here since without ANY threshold, every rotate drag would lock onto the
/// nearest OTHER layer's rotation regardless of how different it is. Others
/// are still sorted by center distance, purely to pick which one the guide
/// points at when multiple tie on rotation. `snapRotationToleranceDeg` needs
/// no px->frame conversion (unlike every OTHER sensitivity in this file) - an
/// angle means the same thing at any zoom level; same precedent as
/// `snapFixedGapFrame`, a core global written directly from the UI with no
/// AppState px-mirror and no _refreshSnapRadii entry.
RotationSnapResult computeRotationSnap({
  required Project project,
  required Layer layer,
  required int globalFrame,
  required double newRotation,
}) {
  if (!snapEnabled || !snapRotationEnabled) {
    return RotationSnapResult(newRotation: newRotation);
  }

  final ownGeom = computeLayerFrameGeometry(project, layer, globalFrame,
      includeVertices: false);
  double bestDelta = 0;
  var bestAbs = double.infinity;
  SnapCategory? bestCategory;
  List<double>? bestOtherCenter;

  void consider(double targetDeg, SnapCategory cat, List<double>? otherCenter) {
    final delta = _angleDeltaDeg(newRotation, targetDeg);
    if (delta.abs() <= snapRotationToleranceDeg && delta.abs() < bestAbs) {
      bestAbs = delta.abs();
      bestDelta = delta;
      bestCategory = cat;
      bestOtherCenter = otherCenter;
    }
  }

  final inc = snapDiagonalAngleIncrementDeg;
  final fixedTargets = <double>[
    if (snapRotationHorizontalEnabled) ...[0, 180],
    if (snapRotationVerticalEnabled) ...[90, 270],
    if (snapRotationDiagonalEnabled && inc > 0)
      for (var a = inc; a < 360; a += inc)
        if (a % 90 != 0) a,
  ];
  for (final t in fixedTargets) {
    consider(t, SnapCategory.rotationAngle, null);
  }

  if (snapRotationMatchNearbyEnabled) {
    final others = [
      for (final o in _snapCandidates(project, layer, globalFrame))
        (
          rot: getLayerStateAt(project, o.id, globalFrame).rot,
          center: computeLayerFrameGeometry(project, o, globalFrame,
                  includeVertices: false)
              .center
        ),
    ]..sort((x, y) => _pointDistance(ownGeom.center, x.center)
        .compareTo(_pointDistance(ownGeom.center, y.center)));
    for (final o in others) {
      consider(o.rot, SnapCategory.rotationMatch, o.center);
      // its mirror angle too (a shape beside another, turned the other way).
      if (snapRotationMirrorEnabled) consider(-o.rot, SnapCategory.rotationMatch, o.center);
    }
  }

  if (bestCategory == null) return RotationSnapResult(newRotation: newRotation);
  final snapped =
      newRotation + bestDelta; // keeps winding: 362 -> 360, not wrapped to 0

  SnapGuideLine guide;
  if (bestCategory == SnapCategory.rotationMatch) {
    guide = SnapGuideLine(
        category: SnapCategory.rotationMatch,
        a: ownGeom.center,
        b: bestOtherCenter!);
  } else {
    final rad = snapped * math.pi / 180;
    final half = math.max(ownGeom.bbox.maxX - ownGeom.bbox.minX,
                ownGeom.bbox.maxY - ownGeom.bbox.minY) /
            2 +
        24;
    final ux = math.cos(rad) * half, uy = math.sin(rad) * half;
    guide = SnapGuideLine(
        category: SnapCategory.rotationAngle,
        a: [ownGeom.center[0] - ux, ownGeom.center[1] - uy],
        b: [ownGeom.center[0] + ux, ownGeom.center[1] + uy]);
  }
  return RotationSnapResult(newRotation: snapped, guide: guide);
}

// ===== equal size (resize-drag only) =====

/// called from ScaleDragOp.apply right before its existing
/// `k != null ? k.value = newScale : trk.defaultValue = newScale`
/// write. Effective size = a layer's own LOCAL content bbox extents x
/// its OWN local scale track value only - deliberately ignoring the
/// parent scale/rotation chain, matching ScaleDragOp's own existing
/// scope (its mCanvasNoScale math is already single-layer/local, not
/// parent-chain-aware - equal-size stays consistent with that rather
/// than introducing a wider notion of "size" the drag op itself
/// doesn't use). `snapSizeMeasurement` decides which spatial distance
/// test gates a candidate's eligibility (are these two objects even
/// near each other), not the size matching itself.
///
/// Scope note, stated plainly rather than silently cut: `snapFixedGapFrame`
/// (a fixed target gap between facing edges, independent of the
/// neighbor's own size) is NOT implemented here. Getting it right in
/// the general rotated-layer case would require re-introducing exactly
/// the parent/rotation-aware frame-space edge tracking that the
/// single-layer-local scope decision above was meant to avoid for the
/// PRIMARY equal-size match; the setting/preference still exists and is
/// exposed in the settings UI (per the spec's "worth keeping... independent
/// of measurement mode" framing) for future use, but this pass only
/// implements the width/height/uniform size-matching described as the
/// category's own main behavior.
/// Resizing: the dragged edge (or corner) lands on a frame boundary when
/// it comes within snapFrameBoundaryFrameRadius of it. The handle's point
/// moves linearly with the scale, so the scale that puts it exactly on the
/// boundary is solved for directly.
SizeSnapResult? _frameBoundaryScaleSnap(
    Project project, Layer layer, int globalFrame, String handle, List<double> newScale, BoundingBox bbox) {
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvasNoScale;
  final midX = (bbox.minX + bbox.maxX) / 2, midY = (bbox.minY + bbox.maxY) / 2;
  final p = switch (handle) {
    'left' => [bbox.minX, midY],
    'right' => [bbox.maxX, midY],
    'top' => [midX, bbox.minY],
    'bottom' => [midX, bbox.maxY],
    _ => scaleCornerLocal(bbox), // scaleCorner
  };
  // world position of the handle for a scale (sx, sy).
  List<double> at(double sx, double sy) => applyAffine(m, [p[0] * sx, p[1] * sy]);
  final now = at(newScale[0], newScale[1]);
  final w = stageSize.width, h = stageSize.height;
  List<double>? best;
  var bestDist = double.infinity;
  SnapGuideLine? guide;
  for (final (axis, target) in [(0, 0.0), (0, w), (1, 0.0), (1, h)]) {
    final dist = (now[axis] - target).abs();
    if (dist > snapFrameBoundaryFrameRadius || dist >= bestDist) continue;
    List<double>? scale;
    if (handle == 'left' || handle == 'right') {
      // x scale moves it: now[axis] = base + coef * sx
      final coef = (axis == 0 ? m[0] : m[1]) * p[0];
      if (coef.abs() < 1e-9) continue;
      scale = [newScale[0] + (target - now[axis]) / coef, newScale[1]];
    } else if (handle == 'top' || handle == 'bottom') {
      final coef = (axis == 0 ? m[2] : m[3]) * p[1];
      if (coef.abs() < 1e-9) continue;
      scale = [newScale[0], newScale[1] + (target - now[axis]) / coef];
    } else {
      // the corner keeps the ratio: both scales by one factor k.
      final origin = applyAffine(m, [0, 0]);
      final offset = now[axis] - origin[axis];
      if (offset.abs() < 1e-9) continue;
      final k = (target - origin[axis]) / offset;
      scale = [newScale[0] * k, newScale[1] * k];
    }
    if (scale[0] <= 0 || scale[1] <= 0) continue;
    best = scale;
    bestDist = dist;
    guide = SnapGuideLine(
        category: SnapCategory.frameBoundary,
        a: axis == 0 ? [target, 0] : [0, target],
        b: axis == 0 ? [target, h] : [w, target]);
  }
  return best == null ? null : SizeSnapResult(newScale: best, guide: guide);
}

SizeSnapResult computeScaleSnap({
  required Project project,
  required Layer layer,
  required int globalFrame,
  required String handle, // 'scaleCorner' | 'left' | 'right' | 'top' | 'bottom'
  required List<double> newScale,
  required BoundingBox localBbox,
}) {
  if (!snapEnabled) return SizeSnapResult(newScale: newScale);
  // frame boundaries win while resizing too, like while moving.
  if (snapFrameBoundaryEnabled) {
    final b = _frameBoundaryScaleSnap(project, layer, globalFrame, handle, newScale, localBbox);
    if (b != null) return b;
  }
  if (!snapEqualSizeEnabled) {
    return SizeSnapResult(newScale: newScale);
  }

  final localWidth = localBbox.maxX - localBbox.minX;
  final localHeight = localBbox.maxY - localBbox.minY;
  final ownWidth = localWidth * newScale[0];
  final ownHeight = localHeight * newScale[1];
  final ownGeom = computeLayerFrameGeometry(project, layer, globalFrame,
      includeVertices: false);

  double? bestWidth, bestHeight;
  var bestWidthDist = double.infinity, bestHeightDist = double.infinity;
  List<double>? bestWidthCenter, bestHeightCenter;

  for (final other in _snapCandidates(project, layer, globalFrame)) {
    final otherGeom = computeLayerFrameGeometry(project, other, globalFrame,
        includeVertices: false);
    final spatialDist =
        snapSizeMeasurement == SnapSizeMeasurement.centerDistance
            ? _pointDistance(ownGeom.center, otherGeom.center)
            : _edgeGap(ownGeom.bbox, otherGeom.bbox);
    if (spatialDist > snapEqualSizeFrameRadius) continue;

    final otherLocalBbox = pieceBoundingBox(other);
    final otherScale = getLayerStateAt(project, other.id, globalFrame).scale;
    final otherWidth =
        (otherLocalBbox.maxX - otherLocalBbox.minX) * otherScale[0];
    final otherHeight =
        (otherLocalBbox.maxY - otherLocalBbox.minY) * otherScale[1];

    // only a size that is already close (the sensitivity, in px - both
    // sides move, so twice it): a shape inside another used to jump to the
    // other's size from anywhere.
    final sizeTol = 2 * snapEqualSizeFrameRadius;
    final widthDist = (ownWidth - otherWidth).abs();
    if (widthDist <= sizeTol && widthDist < bestWidthDist) {
      bestWidthDist = widthDist;
      bestWidth = otherWidth;
      bestWidthCenter = otherGeom.center;
    }
    final heightDist = (ownHeight - otherHeight).abs();
    if (heightDist <= sizeTol && heightDist < bestHeightDist) {
      bestHeightDist = heightDist;
      bestHeight = otherHeight;
      bestHeightCenter = otherGeom.center;
    }
  }

  // nested in the same centre (a cube in a cube in a cube): the next one
  // snaps to the same step as between the ones already there.
  final nest = _nestedStepSnap(project, layer, globalFrame, ownGeom.center,
      handle == 'top' || handle == 'bottom' ? ownHeight : ownWidth, handle == 'top' || handle == 'bottom');
  if (nest != null) {
    final useH = handle == 'top' || handle == 'bottom';
    final own = useH ? ownHeight : ownWidth;
    final eq = useH ? bestHeightDist : bestWidthDist;
    if ((nest - own).abs() < eq) {
      final k = nest / _orOne(own);
      final scale = switch (handle) {
        'left' || 'right' => [nest / _orOne(localWidth), newScale[1]],
        'top' || 'bottom' => [newScale[0], nest / _orOne(localHeight)],
        _ => [newScale[0] * k, newScale[1] * k],
      };
      final c = ownGeom.center;
      return SizeSnapResult(
          newScale: scale,
          guide: SnapGuideLine(
              category: SnapCategory.edgeToEdge,
              a: c,
              b: useH ? [c[0], c[1] - nest / 2] : [c[0] + nest / 2, c[1]]));
    }
  }

  List<double>? resultScale;
  SnapGuideLine? guide;
  if (handle == 'left' || handle == 'right') {
    if (bestWidth != null) {
      resultScale = [bestWidth / _orOne(localWidth), newScale[1]];
      guide = SnapGuideLine(
          category: SnapCategory.edgeToEdge,
          a: ownGeom.center,
          b: bestWidthCenter!);
    }
  } else if (handle == 'top' || handle == 'bottom') {
    if (bestHeight != null) {
      resultScale = [newScale[0], bestHeight / _orOne(localHeight)];
      guide = SnapGuideLine(
          category: SnapCategory.edgeToEdge,
          a: ownGeom.center,
          b: bestHeightCenter!);
    }
  } else {
    // scaleCorner: uniform ratio applied to both dimensions, picking
    // whichever pool's match is nearer - consistent with scaleCorner's
    // own existing ratio-keeping behavior in ScaleDragOp.
    double? chosenW, chosenH;
    List<double>? chosenCenter;
    if (bestWidth != null &&
        (bestHeight == null || bestWidthDist <= bestHeightDist)) {
      final ratio = bestWidth / _orOne(ownWidth);
      chosenW = bestWidth;
      chosenH = ownHeight * ratio;
      chosenCenter = bestWidthCenter;
    } else if (bestHeight != null) {
      final ratio = bestHeight / _orOne(ownHeight);
      chosenH = bestHeight;
      chosenW = ownWidth * ratio;
      chosenCenter = bestHeightCenter;
    }
    if (chosenW != null && chosenH != null) {
      resultScale = [
        chosenW / _orOne(localWidth),
        chosenH / _orOne(localHeight)
      ];
      guide = SnapGuideLine(
          category: SnapCategory.edgeToEdge,
          a: ownGeom.center,
          b: chosenCenter!);
    }
  }

  return SizeSnapResult(
      newScale: resultScale ?? newScale,
      guide: resultScale != null ? guide : null);
}

/// The size (width, or height with `useHeight`) that continues the even
/// steps of the layers sharing `center` - within the equal-size radius of
/// `own` - or null. Needs two of them: their step is the one to repeat.
double? _nestedStepSnap(Project project, Layer layer, int globalFrame, List<double> center, double own, bool useHeight) {
  final sizes = <double>[];
  for (final other in _snapCandidates(project, layer, globalFrame)) {
    final g = computeLayerFrameGeometry(project, other, globalFrame, includeVertices: false);
    if (_pointDistance(g.center, center) > snapCenterToCenterFrameRadius) continue;
    final b = pieceBoundingBox(other);
    final sc = getLayerStateAt(project, other.id, globalFrame).scale;
    sizes.add(useHeight ? (b.maxY - b.minY) * sc[1] : (b.maxX - b.minX) * sc[0]);
  }
  if (sizes.length < 2) return null;
  sizes.sort();
  double? best;
  var bestD = snapEqualSizeFrameRadius * 2; // both sides move
  for (var i = 0; i + 1 < sizes.length; i++) {
    final step = sizes[i + 1] - sizes[i];
    if (step < 1) continue;
    for (final t in [sizes[i + 1] + step, sizes[i] - step]) {
      if (t <= 0) continue;
      // a size another layer already has is equal-size's, not a step.
      if (sizes.any((s) => (s - t).abs() < 0.5)) continue;
      final d = (t - own).abs();
      if (d < bestD) {
        bestD = d;
        best = t;
      }
    }
  }
  return best;
}

/// Centre to centre also pulls onto the crossings of a rect's own grid.
bool snapRectGridEnabled = true;

/// A rect's own grid (Content.gridCols / gridRows): where its lines cross,
/// frame space (its edges' crossings left out - the corners and edge
/// middles have their own snapping).
List<List<double>> rectGridCrossingsFrame(Project project, Layer layer, int globalFrame) {
  final c = layer.content;
  final cols = c.gridCols, rows = c.gridRows;
  if (cols == null || rows == null || cols < 1 || rows < 1) return const [];
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final x0 = c.offset[0] - c.size[0] / 2, y0 = c.offset[1] - c.size[1] / 2;
  final k = c.gridKinds;
  return [
    // the lines' crossings (both kinds shown)...
    if (k & 3 == 3)
      for (var i = 1; i < cols; i++)
        for (var j = 1; j < rows; j++) applyAffine(m, [x0 + c.size[0] * i / cols, y0 + c.size[1] * j / rows]),
    // ...and where the diagonals cross: the cells' middles.
    if (k & 4 != 0)
      for (var i = 0; i < cols; i++)
        for (var j = 0; j < rows; j++)
          applyAffine(m, [x0 + c.size[0] * (i + 0.5) / cols, y0 + c.size[1] * (j + 0.5) / rows]),
  ];
}

/// A rect's own grid lines (frame space), for drawing.
List<(List<double>, List<double>)> rectGridLinesFrame(Project project, Layer layer, int globalFrame) {
  final c = layer.content;
  final cols = c.gridCols, rows = c.gridRows;
  if (cols == null || rows == null) return const [];
  final m = getTransformBoxHandles(project, layer, globalFrame).mCanvas;
  final x0 = c.offset[0] - c.size[0] / 2, y0 = c.offset[1] - c.size[1] / 2;
  final x1 = x0 + c.size[0], y1 = y0 + c.size[1];
  final k = c.gridKinds;
  return [
    if (k & 1 != 0)
      for (var i = 1; i < cols; i++)
        (applyAffine(m, [x0 + c.size[0] * i / cols, y0]), applyAffine(m, [x0 + c.size[0] * i / cols, y1])),
    if (k & 2 != 0)
      for (var j = 1; j < rows; j++)
        (applyAffine(m, [x0, y0 + c.size[1] * j / rows]), applyAffine(m, [x1, y0 + c.size[1] * j / rows])),
    if (k & 4 != 0)
      for (final d in gridDiagonals(x0, y0, c.size[0], c.size[1], cols, rows)) (applyAffine(m, d.a), applyAffine(m, d.b)),
  ];
}
