import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// The one keyframe-edit rule (track_edit.dart), the "master key"
/// (keyAllTracks) and the timeline's keyframe group drag.
Layer _layer({int startFrame = 0, int durationFrames = 100}) {
  return Layer(
    id: 'L_test',
    name: 'test',
    startFrame: startFrame,
    durationFrames: durationFrames,
    parentId: null,
    transform: Transform(
        anchor: track([0.5, 0.5], true),
        scale: track([1.0, 1.0]),
        rotation: track(0.0),
        opacity: track(1.0)),
    content: Content(shape: 'rect', offset: [0, 0], size: [46, 46]),
  );
}

void main() {
  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
  });

  group('keyframeToEdit / setTrackValueAt', () {
    late Track trk;
    setUp(() {
      trk = track(0.0)
        ..keyframes.addAll([Keyframe(frame: 10, value: 1.0), Keyframe(frame: 30, value: 3.0)]);
    });

    test('exact frame edits that key', () {
      setTrackValueAt(trk, 10, 5.0);
      expect(trk.keyframes.map((k) => k.value), equals([5.0, 3.0]));
    });

    test('before the first key edits the first key (what you see there)', () {
      setTrackValueAt(trk, 2, 7.0);
      expect(trk.keyframes.map((k) => k.value), equals([7.0, 3.0]));
    });

    test('after the last key edits the last key', () {
      setTrackValueAt(trk, 90, 9.0);
      expect(trk.keyframes.map((k) => k.value), equals([1.0, 9.0]));
    });

    test('between keys with no exact match edits nothing visible (same as the move tool)', () {
      setTrackValueAt(trk, 20, 4.0);
      expect(trk.keyframes.map((k) => k.value), equals([1.0, 3.0]));
    });

    test('no keys: the static value', () {
      final plain = track(0.0);
      setTrackValueAt(plain, 50, 2.0);
      expect(plain.defaultValue, equals(2.0));
    });
  });

  test('RotateDragOp outside the keyed span edits the boundary key, like the move tool', () {
    final project = Project(layers: [_layer()]);
    final layer = project.layers.single;
    layer.transform.rotation.keyframes
        .addAll([Keyframe(frame: 10, value: 0.0), Keyframe(frame: 30, value: 45.0)]);
    final op = RotateDragOp(
        layer: layer, anchorScreen: [0, 0], startAngle: 0, startRotation: 45);
    op.apply(project, 60, [0, 100]); // +90deg from the start angle
    expect(layer.transform.rotation.keyframes.last.value, closeTo(135, 1e-6));
    expect(layer.transform.rotation.keyframes.first.value, equals(0.0));
  });

  group('master key', () {
    test('keyAllTracks keys every active parameter at the frame with its current value', () {
      final project = Project(layers: [_layer()]);
      final layer = project.layers.single;
      layer.transform.rotation.defaultValue = 30.0;
      layer.masks.add(Mask());

      keyAllTracks(project, layer, 12);

      expect(allTracksKeyedAt(layer, 12), isTrue);
      expect(layer.transform.rotation.keyframes.single.value, equals(30.0));
      expect(layer.masks.single.feather.keyframes.single.frame, equals(12));
      expect(layer.transform.pathFollow.t.keyframes, isEmpty,
          reason: 'path-follow is off - its progress track is not keyed');
    });

    test('unkeyAllTracks removes exactly those keys', () {
      final project = Project(layers: [_layer()]);
      final layer = project.layers.single;
      layer.transform.rotation.keyframes.add(Keyframe(frame: 40, value: 5.0));
      keyAllTracks(project, layer, 12);
      unkeyAllTracks(layer, 12);
      expect(allTracksKeyedAt(layer, 12), isFalse);
      expect(layer.transform.rotation.keyframes.map((k) => k.frame), equals([40]));
    });
  });

  group('KeyframeGroupDragOp', () {
    test('clamps to the layer range, keeping the group spacing', () {
      final layer = _layer(startFrame: 100, durationFrames: 50);
      layer.transform.rotation.keyframes
          .addAll([Keyframe(frame: 10, value: 0.0), Keyframe(frame: 20, value: 1.0)]);
      final op = KeyframeGroupDragOp.grab(layer, {110, 120}, 110);
      op.apply(layer, 500); // far past the end
      expect(layer.transform.rotation.keyframes.map((k) => k.frame), equals([40, 50]));
      op.apply(layer, 0); // far before the start
      expect(layer.transform.rotation.keyframes.map((k) => k.frame), equals([0, 10]));
    });

    test('a key dropped onto another key of the same track replaces it', () {
      final layer = _layer();
      layer.transform.rotation.keyframes
          .addAll([Keyframe(frame: 10, value: 0.0), Keyframe(frame: 20, value: 1.0)]);
      final op = KeyframeGroupDragOp.grab(layer, {10}, 10);
      op.apply(layer, 20);
      op.finish();
      expect(layer.transform.rotation.keyframes.map((k) => (k.frame, k.value)),
          equals([(20, 0.0)]));
    });
  });
}
