import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Real, pinned-value coverage for snapping.dart - the candidate-
/// generation, per-axis-independence, mesh-warp/corner-pin branching,
/// joint-vs-axis priority, equal-size, and grid-geometry claims made in
/// movement-mobile-snapping-spec.md's own plan section. Same
/// `setStageSize`/`Project()`/pinned-`closeTo` convention as
/// drag_ops_test.dart.
///
/// Every snap* global is reset to its default in tearDown - these are
/// plain top-level mutable globals (same category as hideHandles/
/// kfMultiselectMode elsewhere in this package), so a test that flips
/// one for a specific assertion must not leak it into the next test.
void main() {
  late Project project;
  int idCounter = 0;

  Layer rect(List<double> anchor,
      {double w = 100,
      double h = 60,
      String shape = 'rect',
      int? sides,
      List<List<double>>? points}) {
    final id = 'L${idCounter++}';
    return Layer(
      id: id,
      name: id,
      parentId: null,
      transform: Transform(
          anchor: track(anchor),
          scale: track([1.0, 1.0]),
          rotation: track(0.0),
          opacity: track(1.0)),
      content: Content(
          shape: shape,
          offset: [0, 0],
          size: [w, h],
          sides: sides,
          points: points),
    );
  }

  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
    project = Project();
    idCounter = 0;
    snapEnabled = true;
    // these tests place objects far apart on purpose: snap across the
    // whole stage (the reach by size has its own test below).
    snapReachBySize = 0;
  });

  tearDown(() {
    snapEnabled = false;
    snapEdgeToEdgeEnabled = true;
    snapCenterToCenterEnabled = true;
    snapCenterHorizontalEnabled = true;
    snapCenterVerticalEnabled = true;
    snapCenterDiagonalEnabled = true;
    snapCenterLineEnabled = true;
    snapEqualSpacingEnabled = true;
    snapCornerToCornerEnabled = true;
    snapEqualSizeEnabled = true;
    snapGridEnabled = true;
    snapFrameBoundaryEnabled = true;
    snapGuidesVisible = true;
    snapEdgeToEdgeFrameRadius = 8;
    snapCenterToCenterFrameRadius = 8;
    snapCornerToCornerFrameRadius = 8;
    snapEqualSizeFrameRadius = 8;
    snapGridFrameRadius = 8;
    snapFrameBoundaryFrameRadius = 10;
    snapSizeMeasurement = SnapSizeMeasurement.edgeGap;
    snapFixedGapFrame = 40;
    snapDiagonalAngleIncrementDeg = 45;
    snapGridCols = 4;
    snapGridRows = 4;
    snapRotationEnabled = true;
    snapRotationHorizontalEnabled = true;
    snapRotationVerticalEnabled = true;
    snapRotationDiagonalEnabled = true;
    snapRotationMatchNearbyEnabled = true;
    snapRotationToleranceDeg = 5;
  });

  test('master toggle off: newLocal passes through completely unchanged', () {
    snapEnabled = false;
    final m = rect([0.5, 0.5]);
    final a = rect([0.6, 0.5]);
    project.layers.addAll([m, a]);
    final result = computeAnchorSnap(
        project: project, layer: m, globalFrame: 0, newLocal: [0.501, 0.501]);
    expect(result.newLocal, equals([0.501, 0.501]));
    expect(result.guides, isEmpty);
  });

  test('single category toggle off: that category no longer contributes a snap',
      () {
    snapEdgeToEdgeEnabled = false;
    snapCenterToCenterEnabled = false;
    snapCornerToCornerEnabled = false;
    snapGridEnabled = false;
    snapFrameBoundaryEnabled = false;
    final m = rect([0.5, 0.5]);
    final a = rect([
      0.501,
      0.501
    ]); // extremely close - would snap if anything were enabled
    project.layers.addAll([m, a]);
    final result = computeAnchorSnap(
        project: project, layer: m, globalFrame: 0, newLocal: [0.501, 0.501]);
    expect(result.newLocal, equals([0.501, 0.501]));
  });

  test(
      'edge-to-edge: X and Y axes resolve INDEPENDENTLY - snaps X to one neighbor, Y to a completely different one',
      () {
    // m dragged to an unsnapped frame center of (376,225) -> bbox
    // [326,426]x[195,255] (100x60 rect, offset 0).
    final m = rect([376 / 640, 225 / 400]);
    // a's left edge sits at 430 (4px from m's right edge 426, within
    // the default 8px radius) - a's own Y band is far from m's.
    final a = rect([480 / 640, 100 / 400]);
    // b's top edge sits at 260 (5px from m's bottom edge 255, within
    // radius) - b's own X band is far from m's.
    final b = rect([64 / 640, 290 / 400]);
    project.layers.addAll([m, a, b]);

    final result = computeAnchorSnap(
        project: project,
        layer: m,
        globalFrame: 0,
        newLocal: [376 / 640, 225 / 400]);

    // expected: X snaps m's right edge (426) to a's left edge (430) ->
    // +4; Y snaps m's bottom edge (255) to b's top edge (260) -> +5.
    // resulting center (380,230) -> fraction (380/640, 230/400).
    expect(result.newLocal[0], closeTo(380 / 640, 1e-9));
    expect(result.newLocal[1], closeTo(230 / 400, 1e-9));
  });

  test(
      'corner-to-corner: a triangle snaps by its REAL vertex, not its bounding-box corner',
      () {
    // isolate corner-to-corner: with two congruent, purely-translated
    // triangles, edge-to-edge's own bbox extrema coincide numerically
    // with two of the triangle's three real vertices (the ones that
    // define the bbox's own width) - leaving edge-to-edge enabled would
    // let it tie/win the same distance for the wrong reason, masking
    // whether corner-to-corner's real-vertex sourcing is what actually
    // produced the result.
    snapEdgeToEdgeEnabled = false;
    snapCenterToCenterEnabled = false;
    snapGridEnabled = false;
    snapFrameBoundaryEnabled = false;
    // an equilateral-ish triangle (movement_core's own shapePoints
    // triangle) - its own top vertex is NOT at the bbox's own top-left
    // corner, so a bbox-based snap would land at the wrong offset.
    final m = rect([0.5, 0.5], shape: 'triangle', w: 100, h: 100);
    final other = rect([0.9, 0.9], shape: 'triangle', w: 100, h: 100);
    project.layers.addAll([m, other]);

    final otherGeom =
        computeLayerFrameGeometry(project, other, 0, includeVertices: true);
    final targetVertex = otherGeom
        .vertices.first; // any of the triangle's own real vertices/midpoints

    // place m's hypothetical anchor so its OWN matching vertex (same
    // relative position, since m and other are congruent triangles)
    // sits 3px away from that target vertex - well within range. Built
    // from the ANCHOR's own default frame position (0.5*640, 0.5*400) -
    // NOT the bbox center (computeLayerFrameGeometry.center), which for
    // a triangle sits at a different offset from the anchor than any
    // single vertex does (an apex-up triangle's bbox center and its own
    // apex vertex are ~37.5 local units apart) - mixing the two
    // reference points here would silently reintroduce exactly the
    // bbox/vertex discrepancy this test exists to rule out.
    final mVertexAtDefault =
        computeLayerFrameGeometry(project, m, 0, includeVertices: true)
            .vertices
            .first;
    final deltaToNear = [
      targetVertex[0] - mVertexAtDefault[0] + 3,
      targetVertex[1] - mVertexAtDefault[1] + 3
    ];
    const defaultAnchorFrame = [0.5 * 640, 0.5 * 400];
    final hypotheticalCenterFrac = [
      (defaultAnchorFrame[0] + deltaToNear[0]) / 640,
      (defaultAnchorFrame[1] + deltaToNear[1]) / 400,
    ];

    final result = computeAnchorSnap(
        project: project,
        layer: m,
        globalFrame: 0,
        newLocal: hypotheticalCenterFrac);
    final snappedGeom = computeLayerFrameGeometry(project, m, 0,
        anchorOverride: result.newLocal, includeVertices: true);
    // the same vertex (first in the list, by construction) must now sit
    // EXACTLY on the target's real vertex, not offset by a bbox-corner
    // discrepancy.
    final snappedVertex = snappedGeom.vertices.first;
    expect(snappedVertex[0], closeTo(targetVertex[0], 1e-6));
    expect(snappedVertex[1], closeTo(targetVertex[1], 1e-6));
  });

  test(
      'mesh-warp exclusion: an active mesh-warp layer contributes ONLY its pin-grid points, no midpoints',
      () {
    final m = rect([0.5, 0.5]);
    final other = rect([0.9, 0.5]);
    final inst = createEffectInstance('mesh_warp', 'fx1', other);
    other.effectStack.add(inst);
    project.layers.addAll([m, other]);

    final geom =
        computeLayerFrameGeometry(project, other, 0, includeVertices: true);
    final expectedPinCount =
        getMeshWarpHandles(project, other, inst, 0).handles.length;
    expect(geom.vertices.length, equals(expectedPinCount));
    // sanity: this is strictly fewer than getContentOutline's own dense
    // 10x10-subdivision perimeter (37 points for one such rect) would
    // have produced - confirms the dense contour is NOT what's used.
    expect(geom.vertices.length, lessThan(37));
  });

  test(
      'corner-pin: 4 mapped corners PLUS their 4 midpoints are present (still a small, well-defined set)',
      () {
    final m = rect([0.5, 0.5]);
    final other = rect([0.9, 0.5]);
    final inst = createEffectInstance('corner_pin', 'fx1', other);
    other.effectStack.add(inst);
    project.layers.addAll([m, other]);

    final geom =
        computeLayerFrameGeometry(project, other, 0, includeVertices: true);
    expect(geom.vertices.length, equals(8)); // 4 corners + 4 midpoints
  });

  test(
      'frame boundary competes like the rest: a numerically NEARER neighbor wins over the canvas edge',
      () {
    // m's left edge sits 3px from the frame's own left boundary (x=0,
    // well within the 10px frameBoundary radius).
    final m = rect([53 / 640, 0.5]); // bbox minX = 53-50 = 3
    // an ordinary neighbor whose edge is only 1px from m's own edge -
    // numerically nearer than the frame boundary, but must still lose.
    final other = rect(
        [104 / 640, 0.5]); // bbox minX = 104-50=54, m.maxX=53+50=103 -> gap 1px
    project.layers.addAll([m, other]);

    final result = computeAnchorSnap(
        project: project, layer: m, globalFrame: 0, newLocal: [53 / 640, 0.5]);
    final snappedGeom = computeLayerFrameGeometry(project, m, 0,
        anchorOverride: result.newLocal, includeVertices: false);
    // the neighbour's line 1 px away wins over the frame's edge 3 px away.
    expect(snappedGeom.bbox.minX, closeTo(4, 1e-6));
  });

  test('reach by size: only objects near the dragged one pull it', () {
    snapReachBySize = 1.5;
    snapGridEnabled = false; // its middle sits on a grid line (it pulls middles too)
    final m = rect([0.5, 0.501]);
    final far = rect([0.95, 0.503]); // far away: out of reach
    project.layers.addAll([m, far]);
    snapCenterVerticalEnabled = false;
    final r = computeAnchorSnap(project: project, layer: m, globalFrame: 0, newLocal: [0.5, 0.501]);
    expect(r.newLocal[1], closeTo(0.501, 1e-9));
    snapReachBySize = 0;
    final r2 = computeAnchorSnap(project: project, layer: m, globalFrame: 0, newLocal: [0.5, 0.501]);
    expect(r2.newLocal[1], closeTo(0.503, 1e-9));
  });

  test('a corner snaps only as a real corner (both axes close), and adds to edge to edge', () {
    snapCenterToCenterEnabled = false;
    snapEdgeMidpointsEnabled = false;
    snapFrameBoundaryEnabled = false;
    snapGridEnabled = false;
    // other's corner at (300, 100); m's corner 5 px off in x, 30 px in y:
    // not a corner match - no x pull from the corner category.
    final other = rect([250 / 640, 150 / 400]); // bbox 200..300 x 100..200
    final m = rect([(355) / 640, (80) / 400]); // bbox 305..405 x 30..130
    project.layers.addAll([other, m]);
    snapEdgeToEdgeEnabled = false;
    final r = computeAnchorSnap(project: project, layer: m, globalFrame: 0, newLocal: [355 / 640, 80 / 400]);
    expect(r.newLocal[0] * 640, closeTo(355, 1e-6), reason: 'a corner far in y does not pull x');
    // near in both: snaps both.
    final r2 = computeAnchorSnap(project: project, layer: m, globalFrame: 0, newLocal: [355 / 640, 153 / 400]);
    expect(r2.newLocal[0] * 640, closeTo(350, 1e-6));
    expect(r2.newLocal[1] * 400, closeTo(150, 1e-6));
    snapEdgeToEdgeEnabled = true;
    snapEdgeMidpointsEnabled = true;
    snapFrameBoundaryEnabled = true;
    snapGridEnabled = true;
    snapCenterToCenterEnabled = true;
  });

  test('center horizontal/vertical: axis-only, no cross-axis side effect', () {
    snapGridEnabled = false; // its middle sits on a grid line (it pulls middles too)
    final m = rect([0.5, 0.501]); // center frame y = 200.4, x=320
    final other = rect(
        [0.9, 0.503]); // same-ish Y (horizontal alignment), very different X
    project.layers.addAll([m, other]);
    snapCenterVerticalEnabled = false; // isolate horizontal only

    final result = computeAnchorSnap(
        project: project, layer: m, globalFrame: 0, newLocal: [0.5, 0.501]);
    // Y should have snapped toward other's center Y; X must be untouched.
    expect(result.newLocal[0], equals(0.5));
    expect(result.newLocal[1], closeTo(0.503, 1e-9));
  });

  test(
      'center-to-center exact match: works even with H/V/diagonal ALL off, isolated on both axes at once',
      () {
    // isolate the joint pool exactly like the diagonal/continue-line
    // tests above do - two same-size rects offset by a pure translation
    // also tie on edge-to-edge/corner-to-corner at the same distance
    // (aligning edges of congruent rects IS aligning centers), which
    // would mask whether centerExact itself is what produced the result.
    snapEdgeToEdgeEnabled = false;
    snapCornerToCornerEnabled = false;
    snapGridEnabled = false;
    snapFrameBoundaryEnabled = false;
    snapCenterHorizontalEnabled = false;
    snapCenterVerticalEnabled = false;
    snapCenterDiagonalEnabled = false;
    // m starts 3px away from other's center on EACH axis - if the old
    // H/V-only gating were still in effect, neither axis alone could
    // pull m fully onto other's center (that needed both H AND V on
    // together, coincidentally); the always-on exact-match candidate
    // must snap BOTH axes at once regardless.
    final other = rect([200 / 640, 150 / 400]); // center (200,150)
    final m = rect([(203) / 640, (153) / 400]); // center (203,153)
    project.layers.addAll([other, m]);

    final result = computeAnchorSnap(
        project: project,
        layer: m,
        globalFrame: 0,
        newLocal: [203 / 640, 153 / 400]);
    final snappedGeom = computeLayerFrameGeometry(project, m, 0,
        anchorOverride: result.newLocal, includeVertices: false);
    expect(snappedGeom.center[0], closeTo(200, 1e-6));
    expect(snappedGeom.center[1], closeTo(150, 1e-6));
  });

  test(
      'diagonal fixed-angle: perpendicular-projection snap, unclamped distance from the reference point',
      () {
    // isolate the joint pool: two 100x60 rects placed near a 45-degree
    // offset from each other also happen to have SOME bbox edge or
    // corner/midpoint pairing much closer than the intended 3px
    // perpendicular nudge (a rect's own geometry is dense/wide enough
    // that this is easy to hit by accident) - disabling every other
    // category keeps this test about the diagonal mechanism only.
    snapEdgeToEdgeEnabled = false;
    snapCornerToCornerEnabled = false;
    snapGridEnabled = false;
    snapFrameBoundaryEnabled = false;
    snapCenterHorizontalEnabled = false;
    snapCenterVerticalEnabled = false;
    final a = rect([0.5, 0.5]); // center (320,200)
    // m starts near the 45-degree line through a's center, but at an
    // arbitrary distance along it (not matching any prior segment).
    final m = rect([
      (320 + 100) / 640,
      (200 + 100) / 400
    ]); // exactly on the 45 line, offset slightly for the test below
    project.layers.addAll([a, m]);

    // nudge m 3px perpendicular to the 45-degree line (within the 8px
    // center-to-center radius) so a real snap is exercised, not a no-op.
    final nudgedCenter = [
      320.0 + 100 + 3 / 1.41421356,
      200.0 + 100 - 3 / 1.41421356
    ];
    final result = computeAnchorSnap(
        project: project,
        layer: m,
        globalFrame: 0,
        newLocal: [nudgedCenter[0] / 640, nudgedCenter[1] / 400]);
    final snappedGeom = computeLayerFrameGeometry(project, m, 0,
        anchorOverride: result.newLocal, includeVertices: false);
    // projected back onto the exact 45-degree line through (320,200):
    // dx == dy (allowing for float slack), and NOT snapped to distance 100*sqrt(2) specifically (no equal-spacing pull with only one other object).
    final dx = snappedGeom.center[0] - 320.0,
        dy = snappedGeom.center[1] - 200.0;
    expect(dx, closeTo(dy, 1e-6));
  });

  test(
      'continue-line / equal-spacing: C snaps to exactly B + (B-A), matching |AB|',
      () {
    // NOTE: this pair is horizontally ALIGNED (a and b share the same
    // Y), so per the aligned-pair redesign below, this specific
    // assertion is actually satisfied via edge-to-edge (X: c's own
    // 100-wide bbox left edge lands 4px from b's right edge) + center-
    // horizontal (Y), not via the continue-line mechanism at all -
    // confirmed by running with snapCenterLineEnabled left at its
    // tearDown-reset `true` but STILL passing when it's forced false.
    // The isolated tests below (with edge-to-edge/center-H off) are
    // what actually exercises continue-line/any-angle-line specifically.
    final a = rect([100 / 640, 100 / 400]); // center (100,100)
    final b = rect([200 / 640, 100 / 400]); // center (200,100), |AB| = 100
    // c starts near the extension of A->B, at roughly the right spot
    // but not exactly on it.
    final c = rect([(300 + 4) / 640, (100 - 2) / 400]);
    project.layers.addAll([a, b, c]);

    final result = computeAnchorSnap(
        project: project,
        layer: c,
        globalFrame: 0,
        newLocal: [(300 + 4) / 640, (100 - 2) / 400]);
    final snappedGeom = computeLayerFrameGeometry(project, c, 0,
        anchorOverride: result.newLocal, includeVertices: false);
    expect(snappedGeom.center[0],
        closeTo(300, 1e-6)); // B(200,100) + (B-A)=(100,0) = (300,100)
    expect(snappedGeom.center[1], closeTo(100, 1e-6));
  });

  test(
      'continue-line disabled but diagonal still on: falls back to the plain angle-only projection (no distance match)',
      () {
    final a = rect([100 / 640, 100 / 400]);
    final b = rect([200 / 640, 100 / 400]);
    final c = rect([
      (260 + 3) / 640,
      (100 - 2) / 400
    ]); // near the line, but NOT near the equal-spacing point (300,100)
    project.layers.addAll([a, b, c]);
    snapEqualSpacingEnabled = false;

    final result = computeAnchorSnap(
        project: project,
        layer: c,
        globalFrame: 0,
        newLocal: [(260 + 3) / 640, (100 - 2) / 400]);
    final snappedGeom = computeLayerFrameGeometry(project, c, 0,
        anchorOverride: result.newLocal, includeVertices: false);
    // free-slides along the horizontal line (y snapped to 100), x stays
    // wherever it was (no distance pull toward 300).
    expect(snappedGeom.center[1], closeTo(100, 1e-6));
    expect(snappedGeom.center[0], isNot(closeTo(300, 1)));
  });

  test(
      'joint-vs-axis priority: a joint candidate nearer than BOTH axis winners overrides both',
      () {
    // isolate to centerToCenter only (edge-to-edge/corner-to-corner's
    // own bbox/vertex geometry on a plain rect easily produces an
    // accidental, much-nearer axis candidate that would win before the
    // joint ever gets compared - see the diagonal-fixed-angle test's
    // own note). centerHorizontal/Vertical stay ON here deliberately -
    // they're the axis "winners" this test needs to exist (from the
    // SAME reference object `a`) so the joint can be shown beating them,
    // not just winning by default because nothing else was in range.
    snapEdgeToEdgeEnabled = false;
    snapCornerToCornerEnabled = false;
    snapGridEnabled = false;
    snapFrameBoundaryEnabled = false;

    final a = rect([100 / 640, 100 / 400]); // center (100,100)
    // offset (px,py) = (6, 3.171572875...) from a's center: perpendicular
    // distance to the 45-degree line through a is exactly 2 (|px-py|*
    // cos45 = 2.828427.../1.41421356*... = 2), while the axis-only
    // distances (|px|=6, |py|=3.17) are BOTH larger than 2 yet still
    // within the default 8px center-to-center radius - i.e. real,
    // in-range axis winners that the joint must still beat.
    const px = 6.0, py = 6.0 - 2 * 1.4142135623730951;
    final m = rect([(100 + px) / 640, (100 + py) / 400]);
    project.layers.addAll([a, m]);

    final result = computeAnchorSnap(
        project: project,
        layer: m,
        globalFrame: 0,
        newLocal: [(100 + px) / 640, (100 + py) / 400]);
    final snappedGeom = computeLayerFrameGeometry(project, m, 0,
        anchorOverride: result.newLocal, includeVertices: false);
    final dx = snappedGeom.center[0] - 100.0,
        dy = snappedGeom.center[1] - 100.0;
    expect(
        dx,
        closeTo(dy,
            1e-6)); // landed exactly on the diagonal line, not on either axis-only snap
  });

  group('any-angle center-line + equal-spacing fixes', () {
    void isolateToCenterLine() {
      snapEdgeToEdgeEnabled = false;
      snapCornerToCornerEnabled = false;
      snapGridEnabled = false;
      snapFrameBoundaryEnabled = false;
      snapCenterHorizontalEnabled = false;
      snapCenterVerticalEnabled = false;
      snapCenterDiagonalEnabled = false;
    }

    test(
        'bug A: equal spacing works even with Diagonal off (used to be gated behind it)',
        () {
      isolateToCenterLine();
      final a = rect([100 / 640, 100 / 400]); // center (100,100)
      final b = rect([180 / 640, 100 / 400]); // center (180,100), |AB| = 80
      final c =
          rect([263 / 640, 102 / 400]); // near the extension, not exactly on it
      project.layers.addAll([a, b, c]);

      final result = computeAnchorSnap(
          project: project,
          layer: c,
          globalFrame: 0,
          newLocal: [263 / 640, 102 / 400]);
      final snapped = computeLayerFrameGeometry(project, c, 0,
          anchorOverride: result.newLocal, includeVertices: false);
      expect(snapped.center[0],
          closeTo(260, 1e-6)); // B(180,100) + (B-A)=(80,0) = (260,100)
      expect(snapped.center[1], closeTo(100, 1e-6));
    });

    test(
        'bug B: an aligned row\'s equal-spacing X snap is not lost just because Y also has a nearer axis winner',
        () {
      // H/V ON this time (unlike bug A's test) - the OLD design's joint
      // pool required beating BOTH axis winners at once, so a tiny Y
      // distance (from center-horizontal) made the joint's own full 2D
      // distance lose, leaving X unsnapped. The new axis-pool form for
      // aligned pairs resolves X and Y independently, so this must not
      // happen anymore.
      snapEdgeToEdgeEnabled = false;
      snapCornerToCornerEnabled = false;
      snapGridEnabled = false;
      snapFrameBoundaryEnabled = false;
      snapCenterDiagonalEnabled = false;
      final a = rect([100 / 640, 100 / 400]);
      final b = rect([180 / 640, 100 / 400]);
      final c = rect([263 / 640, 102 / 400]);
      project.layers.addAll([a, b, c]);

      final result = computeAnchorSnap(
          project: project,
          layer: c,
          globalFrame: 0,
          newLocal: [263 / 640, 102 / 400]);
      final snapped = computeLayerFrameGeometry(project, c, 0,
          anchorOverride: result.newLocal, includeVertices: false);
      expect(
          snapped.center[0],
          closeTo(260,
              1e-6)); // must still snap - this is exactly what used to fail
      expect(snapped.center[1], closeTo(100, 1e-6));
    });

    test(
        'equal spacing works even with the Any-angle line toggle off (decoupled - it has its own switch)',
        () {
      // equal spacing must not require Any-angle line.
      isolateToCenterLine();
      snapCenterLineEnabled = false;
      final a = rect([100 / 640, 100 / 400]);
      final b = rect([180 / 640, 100 / 400]);
      final c = rect([263 / 640, 102 / 400]);
      project.layers.addAll([a, b, c]);

      final result = computeAnchorSnap(
          project: project,
          layer: c,
          globalFrame: 0,
          newLocal: [263 / 640, 102 / 400]);
      final snapped = computeLayerFrameGeometry(project, c, 0,
          anchorOverride: result.newLocal, includeVertices: false);
      // X still snaps via equal spacing's own along-axis candidate,
      // independent of the any-angle line. Y stays untouched here - the
      // aligned pair's PERPENDICULAR snap (what would pull Y to 100) is
      // the any-angle line's own candidate, a separate mechanism, still
      // correctly off (see the next test).
      expect(snapped.center[0], closeTo(260, 1e-6));
      expect(snapped.center[1], closeTo(102, 1e-6));
    });

    test(
        'the any-angle line itself stays independently gated on snapCenterLineEnabled',
        () {
      // the split in _addPairAxisCandidates (item (1) gated on
      // snapCenterLineEnabled, item (2) on _equalSpacingActive) must not
      // regress into "always on" once the shared early return no longer
      // requires snapCenterLineEnabled.
      isolateToCenterLine();
      snapCenterLineEnabled = false;
      snapEqualSpacingEnabled = false; // isolate the free-slide LINE only
      final a = rect([100 / 640, 100 / 400]);
      final b = rect([180 / 640, 100 / 400]);
      // near the free-slide line's own perpendicular projection point
      // (100,100)+t*(80,0) at own's along-coordinate - i.e. near
      // (own.x, 100) - but NOT near the equal-spacing point (260,100).
      final start = [150.0 / 640, 103.0 / 400];
      final c = rect(start);
      project.layers.addAll([a, b, c]);

      final result = computeAnchorSnap(
          project: project, layer: c, globalFrame: 0, newLocal: start);
      expect(result.newLocal, equals(start)); // untouched - line itself is off
    });

    test(
        'non-aligned pair: the equal-spacing POINT still wins over its own collinear any-angle LINE',
        () {
      // points are tried before lines (see _resolveJoint) - otherwise a
      // line through the same pair, at the same angle, would always be
      // at least as close (a point IS a point on that line) and would
      // silently swallow the point candidate every time.
      isolateToCenterLine();
      final a = rect([100 / 640, 100 / 400]);
      final b = rect([
        180 / 640,
        140 / 400
      ]); // non-aligned: dx=80,dy=40, angle atan(40/80)=26.57deg
      // equal-spacing point: B + (B-A) = (260,180). Place c 3px away
      // from THAT point, well inside the 8px radius, and check it lands
      // exactly there (not merely projected onto the line, which would
      // leave it off by the along-line component).
      final c = rect([263 / 640, 183 / 400]);
      project.layers.addAll([a, b, c]);

      final result = computeAnchorSnap(
          project: project,
          layer: c,
          globalFrame: 0,
          newLocal: [263 / 640, 183 / 400]);
      final snapped = computeLayerFrameGeometry(project, c, 0,
          anchorOverride: result.newLocal, includeVertices: false);
      expect(snapped.center[0], closeTo(260, 1e-6));
      expect(snapped.center[1], closeTo(180, 1e-6));
    });

    test(
        'any-angle line free-slides onto a genuinely arbitrary-angle P-Q line (not just 45-degree multiples)',
        () {
      isolateToCenterLine();
      snapEqualSpacingEnabled =
          false; // isolate the free-slide LINE only, no distance match
      final a = rect([100 / 640, 100 / 400]);
      final b = rect([
        180 / 640,
        140 / 400
      ]); // direction (80,40), angle atan(40/80) = 26.565..deg - not a 45-multiple
      // a point ON the line at t=1.5 (a + 1.5*(b-a)): (100+120, 100+60) = (220,160).
      // perpendicular unit vector to (80,40) is (-40,80)/|(80,40)| = (-0.4472136, 0.8944272).
      // c sits exactly 3px off that point, along the perpendicular - well inside the 8px radius.
      final c =
          rect([(220 - 3 * 0.4472136) / 640, (160 + 3 * 0.8944272) / 400]);
      project.layers.addAll([a, b, c]);

      final result = computeAnchorSnap(
          project: project,
          layer: c,
          globalFrame: 0,
          newLocal: c.transform.anchor.defaultValue as List<double>);
      final snapped = computeLayerFrameGeometry(project, c, 0,
          anchorOverride: result.newLocal, includeVertices: false);
      // projected exactly onto the line through (100,100)-(180,140):
      // (y-100)/(x-100) == 40/80 == 0.5
      final dx = snapped.center[0] - 100.0, dy = snapped.center[1] - 100.0;
      expect(dy / dx, closeTo(0.5, 1e-6));
      // and NOT pulled to the equal-spacing distance-matched point (260,180) specifically
      expect((snapped.center[0] - 260).abs() + (snapped.center[1] - 180).abs(),
          greaterThan(1));
    });

    test(
        'Diagonal alone does not cover a non-45-multiple pair (needs Any-angle line specifically)',
        () {
      snapEdgeToEdgeEnabled = false;
      snapCornerToCornerEnabled = false;
      snapGridEnabled = false;
      snapFrameBoundaryEnabled = false;
      snapCenterHorizontalEnabled = false;
      snapCenterVerticalEnabled = false;
      snapCenterLineEnabled = false; // Diagonal only
      snapEqualSpacingEnabled = false;
      final a = rect([100 / 640, 100 / 400]);
      final b = rect([
        180 / 640,
        140 / 400
      ]); // 26.57 degrees - more than 8px (radius) from the nearest 45-multiple line
      final start = [223.0 / 640, 122.0 / 400];
      final c = rect(start);
      project.layers.addAll([a, b, c]);

      final result = computeAnchorSnap(
          project: project, layer: c, globalFrame: 0, newLocal: start);
      expect(result.newLocal, equals(start)); // untouched - nothing in range
    });
  });

  test('equal-size: left/right handle matches width independent of height', () {
    final other = rect([0.5, 0.5], w: 200, h: 60);
    final m = rect([0.7, 0.5],
        w: 196, h: 30); // width close to other's 200, height very different
    project.layers.addAll([other, m]);

    final localBbox = shapeBoundingBox(m.content);
    final result = computeScaleSnap(
        project: project,
        layer: m,
        globalFrame: 0,
        handle: 'right',
        newScale: [1.0, 1.0],
        localBbox: localBbox);
    final newWidth = (localBbox.maxX - localBbox.minX) * result.newScale[0];
    expect(newWidth, closeTo(200, 1e-6));
    expect(result.newScale[1], equals(1.0)); // height untouched
  });

  test(
      'equal-size: scaleCorner applies the nearer pool\'s ratio uniformly to both dimensions',
      () {
    // same 2:1 aspect ratio as `other` - a uniform ratio that matches
    // width exactly will ALSO land height exactly (198x99 -> 200x100),
    // which is the only way to observe "applied uniformly" as a clean
    // pinned assertion; a mismatched aspect ratio would make the two
    // dimensions land at different, not-hand-verifiable values by design.
    final other = rect([0.5, 0.5], w: 200, h: 100);
    final m = rect([0.7, 0.5],
        w: 198,
        h: 99); // width nearer to 200 than height is to 100, same aspect ratio
    project.layers.addAll([other, m]);

    final localBbox = shapeBoundingBox(m.content);
    final result = computeScaleSnap(
        project: project,
        layer: m,
        globalFrame: 0,
        handle: 'scaleCorner',
        newScale: [1.0, 1.0],
        localBbox: localBbox);
    final newWidth = (localBbox.maxX - localBbox.minX) * result.newScale[0];
    final newHeight = (localBbox.maxY - localBbox.minY) * result.newScale[1];
    expect(newWidth, closeTo(200, 1e-6));
    expect(newHeight,
        closeTo(100, 1e-6)); // uniform ratio carries height along too
  });

  test(
      'computeSnapGridLines: pinned line positions, even auto-fit, never beyond the canvas boundary',
      () {
    final lines = computeSnapGridLines(640, 400, 4, 2);
    final verticalXs =
        lines.where((l) => l.a[0] == l.b[0]).map((l) => l.a[0]).toList();
    final horizontalYs =
        lines.where((l) => l.a[1] == l.b[1]).map((l) => l.a[1]).toList();
    expect(
        verticalXs,
        equals([
          160.0,
          320.0,
          480.0
        ])); // 4 cols -> 3 internal lines, boundary (0/cols, cols/cols) excluded
    expect(horizontalYs, equals([200.0])); // 2 rows -> 1 internal line
    for (final l in lines) {
      expect(l.a[0], inInclusiveRange(0, 640));
      expect(l.b[0], inInclusiveRange(0, 640));
      expect(l.a[1], inInclusiveRange(0, 400));
      expect(l.b[1], inInclusiveRange(0, 400));
    }
  });

  group('computeRotationSnap', () {
    test('master or category off passes through unchanged, no guide', () {
      final m = rect([0.5, 0.5]);
      project.layers.add(m);
      snapEnabled = false;
      var result = computeRotationSnap(
          project: project, layer: m, globalFrame: 0, newRotation: 177);
      expect(result.newRotation, equals(177));
      expect(result.guide, isNull);

      snapEnabled = true;
      snapRotationEnabled = false;
      result = computeRotationSnap(
          project: project, layer: m, globalFrame: 0, newRotation: 177);
      expect(result.newRotation, equals(177));
    });

    test('horizontal only: snaps to 0/180, other sub-toggles have no effect',
        () {
      final m = rect([0.5, 0.5]);
      project.layers.add(m);
      snapRotationVerticalEnabled = false;
      snapRotationDiagonalEnabled = false;
      snapRotationMatchNearbyEnabled = false;

      var result = computeRotationSnap(
          project: project, layer: m, globalFrame: 0, newRotation: 177);
      expect(result.newRotation, equals(180));
      expect(result.guide?.category, equals(SnapCategory.rotationAngle));

      result = computeRotationSnap(
          project: project, layer: m, globalFrame: 0, newRotation: 3);
      expect(result.newRotation, equals(0));
    });

    test(
        'winding is preserved - snaps by the shortest delta, not wrapped into [0,360)',
        () {
      final m = rect([0.5, 0.5]);
      project.layers.add(m);
      snapRotationVerticalEnabled = false;
      snapRotationDiagonalEnabled = false;
      snapRotationMatchNearbyEnabled = false;

      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 362)
              .newRotation,
          equals(360));
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: -178)
              .newRotation,
          equals(-180));
    });

    test('vertical gated independently by its own sub-toggle', () {
      final m = rect([0.5, 0.5]);
      project.layers.add(m);
      snapRotationHorizontalEnabled = false;
      snapRotationDiagonalEnabled = false;
      snapRotationMatchNearbyEnabled = false;
      snapRotationVerticalEnabled = false;

      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 88)
              .newRotation,
          equals(88)); // untouched

      snapRotationVerticalEnabled = true;
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 88)
              .newRotation,
          equals(90));
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: -87)
              .newRotation,
          equals(-90));
    });

    test('diagonal set excludes multiples of 90 (those are H/V\'s own job)',
        () {
      final m = rect([0.5, 0.5]);
      project.layers.add(m);
      snapRotationHorizontalEnabled = false;
      snapRotationVerticalEnabled = false;
      snapRotationMatchNearbyEnabled = false;

      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 47)
              .newRotation,
          equals(45));
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 222)
              .newRotation,
          equals(225));
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 88)
              .newRotation,
          equals(
              88)); // 90 excluded from the diagonal set, and out of its own tolerance from 45/135
    });

    test(
        'tolerance boundary: outside it, nothing snaps; widening it lets a larger delta through',
        () {
      final m = rect([0.5, 0.5]);
      project.layers.add(m);
      snapRotationVerticalEnabled = false;
      snapRotationDiagonalEnabled = false;
      snapRotationMatchNearbyEnabled = false;
      snapRotationToleranceDeg = 5;

      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 172)
              .newRotation,
          equals(172)); // 8deg away, outside tolerance

      snapRotationToleranceDeg = 10;
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 172)
              .newRotation,
          equals(180));
    });

    test(
        'match nearby: copies another in-range layer\'s own rotation, guide points at it',
        () {
      final other = rect([0.7, 0.5]);
      other.transform.rotation.defaultValue = 30.0;
      final m = rect([0.5, 0.5]);
      project.layers.addAll([other, m]);
      snapRotationHorizontalEnabled = false;
      snapRotationVerticalEnabled = false;
      snapRotationDiagonalEnabled = false;

      final result = computeRotationSnap(
          project: project, layer: m, globalFrame: 0, newRotation: 33);
      expect(result.newRotation, equals(30));
      expect(result.guide?.category, equals(SnapCategory.rotationMatch));

      final result2 = computeRotationSnap(
          project: project,
          layer: m,
          globalFrame: 0,
          newRotation: 393); // 393 = 33+360
      expect(result2.newRotation, equals(390)); // 30 + 360, winding preserved
    });

    test(
        'match nearby excludes descendants (their rotation is a function of the dragged layer\'s own)',
        () {
      final m = rect([0.5, 0.5]);
      final child = rect([0.5, 0.5]);
      child.parentId = m.id;
      child.transform.rotation.defaultValue = 30.0;
      project.layers.addAll([m, child]);
      snapRotationHorizontalEnabled = false;
      snapRotationVerticalEnabled = false;
      snapRotationDiagonalEnabled = false;

      final result = computeRotationSnap(
          project: project, layer: m, globalFrame: 0, newRotation: 33);
      expect(result.newRotation,
          equals(33)); // untouched - child's rotation isn't a valid candidate
    });

    test(
        'nearest wins between a fixed angle and a matched rotation when both are in range',
        () {
      final other = rect([0.7, 0.5]);
      other.transform.rotation.defaultValue =
          42.0; // within tolerance of BOTH itself and the 45-degree diagonal target
      final m = rect([0.5, 0.5]);
      project.layers.addAll([other, m]);
      snapRotationHorizontalEnabled = false;
      snapRotationVerticalEnabled = false;

      // 43: delta to diagonal-45 is 2, delta to match-42 is -1 - match is nearer.
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 43)
              .newRotation,
          equals(42));
      // 44: delta to diagonal-45 is 1, delta to match-42 is -2 - the fixed angle is nearer.
      expect(
          computeRotationSnap(
                  project: project, layer: m, globalFrame: 0, newRotation: 44)
              .newRotation,
          equals(45));
    });

    test(
        'picks the nearest ROTATION value among several other layers, guide points at that one',
        () {
      final near = rect([0.6, 0.5]);
      near.transform.rotation.defaultValue = 27.0;
      final far = rect([0.8, 0.5]);
      far.transform.rotation.defaultValue = 20.0;
      final m = rect([0.5, 0.5]);
      project.layers.addAll([near, far, m]);
      snapRotationHorizontalEnabled = false;
      snapRotationVerticalEnabled = false;
      snapRotationDiagonalEnabled = false;

      final result = computeRotationSnap(
          project: project, layer: m, globalFrame: 0, newRotation: 25);
      expect(result.newRotation, equals(27));
    });
  });

  group('frame boundaries while resizing', () {
    setUp(() {
      setStageSize(200, 200);
      clearStateCaches();
      snapEnabled = true;
      snapFrameBoundaryEnabled = true;
      snapEqualSizeEnabled = false;
      snapFrameBoundaryFrameRadius = 10;
    });
    tearDown(() {
      snapEnabled = false;
      snapFrameBoundaryEnabled = false;
    });

    test('a right edge dragged near the frame edge lands on it', () {
      final l = createLayer('rect')
        ..content.offset = [0, 0]
        ..content.size = [100, 100]
        ..transform.anchor.defaultValue = [0.5, 0.5];
      final p = Project(layers: [l]);
      final box = shapeBoundingBox(l.content);
      final r = computeScaleSnap(project: p, layer: l, globalFrame: 0, handle: 'right', newScale: [1.92, 1.0], localBbox: box);
      expect(r.newScale[0], closeTo(2.0, 1e-9), reason: 'right edge at x = 100 + 50 * 2 = 200');
      expect(r.newScale[1], 1.0);
      expect(r.guide?.category, SnapCategory.frameBoundary);
      // too far away: unchanged.
      final far = computeScaleSnap(project: p, layer: l, globalFrame: 0, handle: 'right', newScale: [1.6, 1.0], localBbox: box);
      expect(far.newScale, [1.6, 1.0]);
    });

    test('the corner keeps its ratio and lands on the frame', () {
      final l = createLayer('rect')
        ..content.offset = [0, 0]
        ..content.size = [100, 50]
        ..transform.anchor.defaultValue = [0.5, 0.5];
      final p = Project(layers: [l]);
      final box = shapeBoundingBox(l.content);
      // the top-left corner: x = 100 - 50k; near 0 at k = 1.95.
      final r = computeScaleSnap(project: p, layer: l, globalFrame: 0, handle: 'scaleCorner', newScale: [1.95, 1.95], localBbox: box);
      expect(r.newScale[0], closeTo(2.0, 1e-9));
      expect(r.newScale[1], closeTo(2.0, 1e-9));
    });
  });
}
