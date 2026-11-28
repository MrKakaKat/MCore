import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => keysJoinOnDrop = true);

  Layer layer() {
    final l = createLayer('rect')..durationFrames = 100;
    l.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 20, value: 90.0)]);
    l.transform.scale.keyframes.addAll([Keyframe(frame: 0, value: [1.0, 1.0]), Keyframe(frame: 40, value: [2.0, 2.0])]);
    return l;
  }

  test('joined (as before): the rotation key let go on the scale key frame shares its mark', () {
    final l = layer();
    final op = KeyframeGroupDragOp.grab(l, {20}, 20);
    op.apply(l, 40);
    op.finish(l);
    expect(l.transform.rotation.keyframes.map((k) => k.frame), [0, 40]);
  });

  test('apart: it steps aside to the nearest free frame; nothing joins', () {
    keysJoinOnDrop = false;
    final l = layer();
    final op = KeyframeGroupDragOp.grab(l, {20}, 20);
    op.apply(l, 40);
    op.finish(l);
    expect(l.transform.rotation.keyframes.map((k) => k.frame), [0, 41]);
    expect(l.transform.scale.keyframes.map((k) => k.frame), [0, 40]);
    expect(op.frames(l), {41});
  });

  test('apart, the same track: no key is lost either', () {
    keysJoinOnDrop = false;
    final l = layer();
    final op = KeyframeGroupDragOp.grab(l, {20}, 20);
    op.apply(l, 0);
    op.finish(l);
    expect(l.transform.rotation.keyframes.map((k) => k.frame), [0, 1]);
  });
}
