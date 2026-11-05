import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Real, run coverage of getLayerStateAt/getLayerBaseStateAt's `num` (not
/// `int`) frame parameter - the fix for motion blur looked like a static
/// duplicate with a slight offset instead of a smooth streak, because every
/// fractional sub-frame sample time used to get `.round`ed to an integer
/// BEFORE the transform was computed, collapsing a whole shutter window's
/// worth of samples down to at most 1-2 distinct positions. JS's own
/// getLayerStateAt never rounds at all (plain floats); this proves the Dart
/// port now matches that continuous behavior.
void main() {
  Project buildProject() {
    final layer = Layer(
      id: 'L1',
      name: 'mover',
      transform: Transform(
        anchor: track([0.0, 0.0], true),
        scale: track([1.0, 1.0]),
        rotation: track(0.0),
        opacity: track(1.0),
      ),
      content: Content(shape: 'rect', offset: [0, 0], size: [10, 10]),
      durationFrames: 180,
    );
    layer.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0], temporal: easingPresets['linear']),
      Keyframe(frame: 10, value: [1.0, 0.0], temporal: easingPresets['linear']),
    ]);
    return Project(layers: [layer]);
  }

  test('a fractional globalFrame produces a genuinely different matrix than the nearest integer frame', () {
    final project = buildProject();
    final atFive = getLayerStateAt(project, 'L1', 5);
    final atFiveHalf = getLayerStateAt(project, 'L1', 5.5);

    expect(atFiveHalf.matrix[4], isNot(equals(atFive.matrix[4])), reason: 'linear motion over a full frame must move measurably within HALF a frame too - this is exactly what motion blur sampling relies on');
    // sanity: still linear interpolation, so exactly halfway between the two integer samples.
    final atSix = getLayerStateAt(project, 'L1', 6);
    expect(atFiveHalf.matrix[4], closeTo((atFive.matrix[4] + atSix.matrix[4]) / 2, 1e-9));
  });

  test('passing an int and the equal double for globalFrame produce identical results', () {
    final project = buildProject();
    final viaInt = getLayerStateAt(project, 'L1', 5);
    final viaDouble = getLayerStateAt(project, 'L1', 5.0);
    expect(viaDouble.matrix, equals(viaInt.matrix));
  });

  test('several sub-frame samples within one frame-wide window are NOT collapsed to the same matrix (the actual motion-blur bug)', () {
    final project = buildProject();
    // mirrors canvas_renderer.dart's own sample-frame math: shutterAngle
    // 360 (=1 frame width), 6 samples, centered on globalFrame=5.
    const globalFrame = 5.0;
    const samples = 6;
    final xs = <double>[];
    for (var s = 0; s < samples; s++) {
      final t = (s / (samples - 1)) - 0.5;
      final sampleFrame = globalFrame + t * 1.0;
      xs.add(getLayerStateAt(project, 'L1', sampleFrame).matrix[4]);
    }
    final distinct = xs.toSet();
    expect(distinct.length, equals(samples), reason: 'all 6 samples across a full frame-wide shutter window must land at distinct positions for a linearly-moving object - the pre-fix behavior (rounding each sample first) collapsed nearly all of them to the same 1-2 values');
  });
}
