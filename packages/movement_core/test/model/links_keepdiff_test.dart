import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double width(Project p, String id, int f) {
  clearStateCaches();
  final m = toFrameMatrix(getLayerStateAt(p, id, f).matrix);
  final l = findLayer(p, id)!;
  return l.content.size[0] * m[0];
}

void main() {
  setUp(() => setStageSize(1000, 1000));

  test('parenting keeps the difference: the child grows by as many px as the parent', () {
    final parent = createLayer('rect')
      ..id = 'p'
      ..content.size = [200, 200]
      ..transform.anchor.defaultValue = [0.5, 0.5];
    parent.transform.scale.keyframes = [
      Keyframe(frame: 0, value: [1.0, 1.0], temporal: const Easing(0, 0, 1, 1)),
      Keyframe(frame: 10, value: [2.0, 2.0]),
    ];
    final child = createLayer('rect')
      ..id = 'c'
      ..parentId = 'p'
      ..content.size = [50, 50]
      ..transform.anchor.defaultValue = [0.1, 0.0];
    final p = Project(layers: [parent, child]);
    expect(width(p, 'c', 10), closeTo(100, 1e-6), reason: 'normal: the same factor');
    child.parentKeepDifference = true;
    expect(width(p, 'c', 0), closeTo(50, 1e-6));
    expect(width(p, 'c', 10), closeTo(250, 1e-6), reason: 'the parent grew 200 px: so does the child');
    expect(width(p, 'p', 10) - width(p, 'c', 10), closeTo(400 - 250, 1e-6));
    // its distance from the parent isn't stretched.
    clearStateCaches();
    final cx = toFrameMatrix(getLayerStateAt(p, 'c', 10).matrix)[4];
    expect(cx - 500, closeTo(100, 1e-6));
  });

  test('a dependency passes one property; chains add up; a circle is refused', () {
    final a = createLayer('rect')
      ..id = 'a'
      ..transform.anchor.defaultValue = [0.5, 0.5];
    a.transform.rotation.keyframes = [Keyframe(frame: 0, value: 0.0), Keyframe(frame: 10, value: 90.0)];
    final b = createLayer('rect')
      ..id = 'b'
      ..transform.anchor.defaultValue = [0.2, 0.2]
      ..links.add(PropLink(sourceId: 'a', from: 'rotation', to: 'x', factor: 2));
    final c = createLayer('rect')
      ..id = 'c'
      ..transform.anchor.defaultValue = [0.2, 0.8]
      ..links.add(PropLink(sourceId: 'b', from: 'x', to: 'rotation', factor: 0.5));
    final p = Project(layers: [a, b, c]);
    clearStateCaches();
    final bx = toFrameMatrix(getLayerStateAt(p, 'b', 10).matrix)[4];
    expect(bx, closeTo(200 + 180, 1e-6), reason: 'b.x moves 2 px per degree of a');
    expect(getLayerStateAt(p, 'c', 10).rot, closeTo(90, 1e-6), reason: 'c turns half of b\'s 180 px');
    expect(getLayerStateAt(p, 'b', 0).rot, 0, reason: 'only the one property');
    expect(linkWouldCycle(p, a, 'c'), isTrue);
    expect(linkWouldCycle(p, c, 'a'), isFalse);
    final back = layerFromJson(layerToJson(b));
    expect(back.links.single.from, 'rotation');
    expect(back.links.single.factor, 2);
  });

  test('a pinned link: moving an unkeyed source moves the follower at once', () {
    final a = createLayer('rect')
      ..id = 'a'
      ..transform.anchor.defaultValue = [0.5, 0.5];
    final b = createLayer('rect')
      ..id = 'b'
      ..transform.anchor.defaultValue = [0.2, 0.2];
    final k = PropLink(sourceId: 'a', from: 'x', to: 'x');
    b.links.add(k);
    final p = Project(layers: [a, b]);
    pinLinkBase(p, k, 0);
    clearStateCaches();
    expect(toFrameMatrix(getLayerStateAt(p, 'b', 0).matrix)[4], closeTo(200, 1e-6), reason: 'no jump when made');
    a.transform.anchor.defaultValue = [0.6, 0.5];
    clearStateCaches();
    expect(toFrameMatrix(getLayerStateAt(p, 'b', 0).matrix)[4], closeTo(300, 1e-6));
    expect(layerFromJson(layerToJson(b)).links.single.base, k.base);
  });
}
