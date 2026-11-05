import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Real, run coverage of layer_track.dart - the multi-layer timeline
/// panel's move/trim mechanics, ported from movement-core/src/ui/
/// timeline/timelinePanel.js's onDown/onMove/onUp handlers.
void main() {
  Layer buildLayer({int startFrame = 20, int durationFrames = 30}) {
    return Layer(
      id: 'L1',
      name: 'test',
      startFrame: startFrame,
      durationFrames: durationFrames,
      transform: Transform(anchor: track([0.5, 0.5]), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [10, 10]),
    );
  }

  group('LayerDragMode.move', () {
    test('shifts startFrame by the cumulative delta, duration untouched', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.move);
      op.apply(15);
      expect(layer.startFrame, equals(35));
      expect(layer.durationFrames, equals(30));
    });

    test('clamps startFrame at 0, never goes negative', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.move);
      op.apply(-100);
      expect(layer.startFrame, equals(0));
    });

    test('apply is idempotent against the ORIGINAL grab point, not incremental', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.move);
      op.apply(10);
      op.apply(15); // cumulative total from the grab point, not +15 on top of the +10
      expect(layer.startFrame, equals(35));
    });
  });

  group('LayerDragMode.trimLeft', () {
    test('shrinking from the left moves startFrame forward and shortens duration, end stays fixed', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30); // end = 50
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.trimLeft);
      op.apply(10);
      expect(layer.startFrame, equals(30));
      expect(layer.durationFrames, equals(20));
      expect(layer.startFrame + layer.durationFrames, equals(50), reason: 'the END must stay fixed under a left-edge trim');
    });

    test('growing from the left (negative delta) moves startFrame backward and lengthens duration', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.trimLeft);
      op.apply(-10);
      expect(layer.startFrame, equals(10));
      expect(layer.durationFrames, equals(40));
      expect(layer.startFrame + layer.durationFrames, equals(50));
    });

    test('the animation stays where it was in time: keys shift back, end trim leaves them', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 60);
      layer.transform.rotation.keyframes.addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 40, value: 90.0)]);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.trimLeft);
      op.apply(10);
      expect([for (final k in layer.transform.rotation.keyframes) k.frame + layer.startFrame], [20, 60],
          reason: 'the same global frames as before');
      op.apply(-5);
      expect([for (final k in layer.transform.rotation.keyframes) k.frame + layer.startFrame], [20, 60]);
      // a snap that moved the start afterwards is followed too.
      layer.startFrame = 27;
      layer.durationFrames = 53;
      op.followLeader();
      expect([for (final k in layer.transform.rotation.keyframes) k.frame + layer.startFrame], [20, 60]);

      final right = LayerTrackDragOp.grab(layer, LayerDragMode.trimRight);
      right.apply(-10);
      expect([for (final k in layer.transform.rotation.keyframes) k.frame], [-7, 33], reason: 'end trim moves no key');
    });

    test('clamps startFrame at 0', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.trimLeft);
      op.apply(-100);
      expect(layer.startFrame, equals(0));
      expect(layer.durationFrames, equals(50));
    });

    test('never shrinks duration below 1 (clamps startFrame just short of the fixed end)', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30); // end = 50
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.trimLeft);
      op.apply(1000); // absurdly far right
      expect(layer.startFrame, equals(49));
      expect(layer.durationFrames, equals(1));
    });
  });

  group('LayerDragMode.trimRight', () {
    test('extends duration by the delta, startFrame untouched', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.trimRight);
      op.apply(10);
      expect(layer.startFrame, equals(20));
      expect(layer.durationFrames, equals(40));
    });

    test('shrinks duration by a negative delta, floored at 1', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30);
      final op = LayerTrackDragOp.grab(layer, LayerDragMode.trimRight);
      op.apply(-1000);
      expect(layer.durationFrames, equals(1));
    });
  });

  group('extendedMaxFrameForLayer', () {
    test('returns null when the layer already fits within currentMax', () {
      final layer = buildLayer(startFrame: 20, durationFrames: 30); // end = 50
      expect(extendedMaxFrameForLayer(layer, 180), isNull);
    });

    test('returns end (flush, no headroom) once the layer exceeds currentMax', () {
      final layer = buildLayer(startFrame: 100, durationFrames: 200); // end = 300
      expect(extendedMaxFrameForLayer(layer, 180), equals(300));
    });

    test('exactly AT currentMax does not trigger growth (only strictly past it does)', () {
      final layer = buildLayer(startFrame: 80, durationFrames: 100); // end = 180
      expect(extendedMaxFrameForLayer(layer, 180), isNull);
    });
  });

  group('recomputeMaxFrameToFit', () {
    test('shrinks to the furthest layer end (flush, no headroom) when layers no longer need the current length', () {
      final layers = [
        buildLayer(startFrame: 0, durationFrames: 30), // end = 30
        buildLayer(startFrame: 10, durationFrames: 20), // end = 30
      ];
      expect(recomputeMaxFrameToFit(layers, 1), equals(30));
    });

    test('never shrinks below the given floor, even when every layer fits well inside it', () {
      final layers = [buildLayer(startFrame: 0, durationFrames: 10)]; // end = 10
      expect(recomputeMaxFrameToFit(layers, 180), equals(180));
    });

    test('still grows to fit a layer that extends past the floor', () {
      final layers = [buildLayer(startFrame: 100, durationFrames: 200)]; // end = 300
      expect(recomputeMaxFrameToFit(layers, 180), equals(300));
    });

    test('an empty layer list falls back to the floor', () {
      expect(recomputeMaxFrameToFit(<Layer>[], 180), equals(180));
    });

    test('takes the MAX across every layer, not just the last one in the list', () {
      final layers = [
        buildLayer(startFrame: 0, durationFrames: 500), // end = 500, furthest
        buildLayer(startFrame: 0, durationFrames: 10), // end = 10
      ];
      expect(recomputeMaxFrameToFit(layers, 1), equals(500));
    });
  });
}
