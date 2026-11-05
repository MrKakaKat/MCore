import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Real, run coverage of layer_track_snap.dart - the timeline's own 1D,
/// integer-frame-space edge snapping ("layers should snap to each
/// other's edges in the timeline"), deliberately separate from the 2D
/// stage-object snapping system.
void main() {
  Layer buildLayer(String id, {int startFrame = 20, int durationFrames = 30}) {
    return Layer(
      id: id,
      name: id,
      startFrame: startFrame,
      durationFrames: durationFrames,
      transform: Transform(
          anchor: track([0.5, 0.5]),
          scale: track([1.0, 1.0]),
          rotation: track(0.0),
          opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [10, 10]),
    );
  }

  group('applyLayerEdgeSnap - move', () {
    test('snaps own start to a nearby other layer\'s end, within threshold',
        () {
      final other =
          buildLayer('A', startFrame: 0, durationFrames: 50); // end = 50
      final moved = buildLayer('B',
          startFrame: 54, durationFrames: 20); // 4 frames past other's end
      applyLayerEdgeSnap(moved, [other, moved], LayerDragMode.move);
      expect(moved.startFrame, equals(50));
      expect(moved.durationFrames, equals(20),
          reason: 'move must never change duration');
    });

    test('does nothing when the nearest edge is outside the threshold', () {
      final other = buildLayer('A', startFrame: 0, durationFrames: 50);
      final moved = buildLayer('B', startFrame: 100, durationFrames: 20);
      applyLayerEdgeSnap(moved, [other, moved], LayerDragMode.move);
      expect(moved.startFrame, equals(100));
    });

    test('own end may snap to another layer\'s start', () {
      final other =
          buildLayer('A', startFrame: 80, durationFrames: 20); // start = 80
      final moved = buildLayer('B',
          startFrame: 30, durationFrames: 47); // end = 77, 3 away
      applyLayerEdgeSnap(moved, [other, moved], LayerDragMode.move);
      expect(moved.startFrame + moved.durationFrames, equals(80));
    });

    test(
        'never goes negative even if the snapped delta would push start below 0',
        () {
      final other =
          buildLayer('A', startFrame: 0, durationFrames: 1); // edges at 0 and 1
      final moved = buildLayer('B', startFrame: 3, durationFrames: 10);
      applyLayerEdgeSnap(moved, [other, moved], LayerDragMode.move);
      expect(moved.startFrame, greaterThanOrEqualTo(0));
    });

    test(
        'a single-layer list (self only) never snaps - self is excluded from candidates',
        () {
      final only = buildLayer('A', startFrame: 20, durationFrames: 30);
      applyLayerEdgeSnap(only, [only], LayerDragMode.move);
      expect(only.startFrame, equals(20));
    });
  });

  group('applyLayerEdgeSnap - trimLeft', () {
    test('snaps the new start to a nearby edge, keeping the end fixed', () {
      final other =
          buildLayer('A', startFrame: 0, durationFrames: 40); // end = 40
      final trimmed =
          buildLayer('B', startFrame: 43, durationFrames: 20); // end = 63
      applyLayerEdgeSnap(trimmed, [other, trimmed], LayerDragMode.trimLeft);
      expect(trimmed.startFrame, equals(40));
      expect(trimmed.startFrame + trimmed.durationFrames, equals(63));
    });

    test('outside the threshold, trimLeft is a no-op', () {
      final other = buildLayer('A', startFrame: 0, durationFrames: 40);
      final trimmed = buildLayer('B', startFrame: 60, durationFrames: 20);
      applyLayerEdgeSnap(trimmed, [other, trimmed], LayerDragMode.trimLeft);
      expect(trimmed.startFrame, equals(60));
    });
  });

  group('applyLayerEdgeSnap - trimRight', () {
    test('snaps the new end to a nearby edge, keeping the start fixed', () {
      final other =
          buildLayer('A', startFrame: 100, durationFrames: 0); // edges at 100
      final trimmed =
          buildLayer('B', startFrame: 20, durationFrames: 83); // end = 103
      applyLayerEdgeSnap(trimmed, [other, trimmed], LayerDragMode.trimRight);
      expect(trimmed.startFrame, equals(20));
      expect(trimmed.durationFrames, equals(80));
    });

    test('outside the threshold, trimRight is a no-op', () {
      final other = buildLayer('A', startFrame: 100, durationFrames: 0);
      final trimmed =
          buildLayer('B', startFrame: 20, durationFrames: 50); // end = 70
      applyLayerEdgeSnap(trimmed, [other, trimmed], LayerDragMode.trimRight);
      expect(trimmed.durationFrames, equals(50));
    });
  });
}
