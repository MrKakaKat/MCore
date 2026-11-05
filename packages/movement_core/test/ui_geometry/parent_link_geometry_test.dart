import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer(String id, {String? parentId, List<double> anchor = const [0.5, 0.5]}) {
  return Layer(
    id: id,
    name: id,
    parentId: parentId,
    transform: Transform(anchor: track(anchor), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
    content: Content(shape: 'rect', offset: [0, 0], size: [46, 46]),
  );
}

void main() {
  setUp(() => setStageSize(640, 400));

  test('a 3-level chain produces 2 edges and exactly one root marker, at the true top', () {
    final project = Project(layers: [
      _layer('A', anchor: [0.1, 0.1]), // root
      _layer('B', parentId: 'A', anchor: [0.2, 0.2]), // mid: both a parent and a child
      _layer('C', parentId: 'B', anchor: [0.3, 0.3]), // leaf
    ]);

    final geo = computeParentLinkGeometry(project, 0);
    expect(geo.edges.length, equals(2));
    expect(geo.edges.map((e) => '${e.parentLayerId}->${e.childLayerId}').toSet(), equals({'A->B', 'B->C'}));

    // exactly one root - B is a parent too, but has its own parentId,
    // so it must NOT be marked as a root (that's the whole point of the
    // marker: disambiguating "root with one child" from "plain leaf",
    // both of which would otherwise show exactly one line).
    expect(geo.roots.length, equals(1));
    expect(geo.roots.single.layerId, equals('A'));
    expect(geo.roots.single.screen, equals([0.1 * 640, 0.1 * 400]));
  });

  test('an orphan leaf (no parent, no children) produces no edges and no root marker', () {
    final project = Project(layers: [_layer('lonely')]);
    final geo = computeParentLinkGeometry(project, 0);
    expect(geo.edges, isEmpty);
    expect(geo.roots, isEmpty); // never anyone's parent -> not a root either
  });

  test('a dangling parentId (parent layer missing) is skipped entirely, not drawn as a half-edge', () {
    final project = Project(layers: [_layer('child', parentId: 'ghost')]);
    final geo = computeParentLinkGeometry(project, 0);
    expect(geo.edges, isEmpty);
    expect(geo.roots, isEmpty);
  });

  test('edge endpoints are the parent/child anchor screen positions at the given frame', () {
    final project = Project(layers: [
      _layer('P', anchor: [0.25, 0.75]),
      _layer('C', parentId: 'P', anchor: [0.6, 0.4]),
    ]);
    final geo = computeParentLinkGeometry(project, 0);
    final edge = geo.edges.single;
    expect(edge.parentScreen, equals([0.25 * 640, 0.75 * 400]));
    // C's anchor is relative to its parent P's matrix (identity here
    // since P itself has no parent), so C's world position composes
    // P's translation with C's own local anchor via matFromTRS/matMul -
    // NOT simply C's raw anchor fraction times stage size.
    expect(edge.childScreen[0], isNot(equals(0.6 * 640))); // sanity: composition actually happened
  });
}
