import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _makePendulumLayer(String id) {
  return Layer(
    id: id,
    name: id,
    parentId: null,
    durationFrames: 300,
    transform: Transform(anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
    content: Content(shape: 'rect', offset: [0, 0], size: [46, 46]),
    pendulum: Pendulum(enabled: true, frequency: 50, damping: 30, sensitivity: 50, maxAngle: 40, freeze: 60, rotateWithLine: true),
  );
}

void main() {
  late Project project;
  setUp(() => project = Project());

  group('evaluatePendulumOffset', () {
    test('stays at zero with no real motion, however many frames have passed (no phantom swing)', () {
      // a completely static anchor (no keyframes at all) never exceeds
      // the excitation gate's speed threshold, so `everExcited` must
      // stay false for the whole evaluation - a layer sitting still for
      // 200 frames should never start swinging on its own.
      final layer = _makePendulumLayer('L_static');
      project.layers.add(layer);
      expect(evaluatePendulumOffset(project, layer, 200), equals(0));
    });

    test("produces zero offset before the anchor track's own first keyframe", () {
      final layer = _makePendulumLayer('L_before_start');
      layer.transform.anchor.keyframes.addAll([
        Keyframe(frame: 30, value: [0.3, 0.5]),
        Keyframe(frame: 60, value: [0.7, 0.5]),
      ]);
      project.layers.add(layer);
      // endLocalFrame (10) <= startLocalFrame (30) -> the function's own
      // early-return, before any swing math runs at all.
      expect(evaluatePendulumOffset(project, layer, 10), equals(0));
    });

    test('flips sign between rightward and leftward travel, pinning the current sign convention', () {
      // the exact sign is an implementation convention (interacting
      // with the canvas's flipped y-axis and the rotation matrix's own
      // sign), not something to re-derive from physics intuition - this
      // pins whatever the shipped, already-verified behavior is. what
      // DOES matter is that the two directions of travel produce
      // opposite signs - confirming this is genuinely direction-derived
      // rather than a constant.
      final rightward = _makePendulumLayer('L_rightward');
      rightward.transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.2, 0.5]),
        Keyframe(frame: 60, value: [0.8, 0.5]),
      ]);
      project.layers.add(rightward);
      final offsetRight = evaluatePendulumOffset(project, rightward, 6);
      expect(offsetRight, greaterThan(0));

      project.layers.clear();
      final leftward = _makePendulumLayer('L_leftward');
      leftward.transform.anchor.keyframes.addAll([
        Keyframe(frame: 0, value: [0.8, 0.5]),
        Keyframe(frame: 60, value: [0.2, 0.5]),
      ]);
      project.layers.add(leftward);
      final offsetLeft = evaluatePendulumOffset(project, leftward, 6);
      expect(offsetLeft, lessThan(0));
    });
  });

  group('pendulum: onset', () {
    test('an eased start swings from its first frames, smoothly - no motionless stretch, then a kick', () {
      // the layer stayed still for the first frames of an eased move, then got
      // "pushed" - visible as a kink in its path. The old model only started
      // once the speed crossed a threshold (frame 22 here) and switched the
      // full swing on at once.
      final c = createLayer('rect');
      project.layers.add(c);
      addKeyframe(project, c.id, 'anchor', 0, [0.1, 0.5], 'easeInOut');
      addKeyframe(project, c.id, 'anchor', 90, [0.7, 0.55], 'easeInOut');
      autoComputeTangents(c.transform.anchor);
      c.pendulum.enabled = true;
      final values = [for (var f = 0; f <= 45; f++) evaluatePendulumOffset(project, c, f)];
      expect(values[0], 0, reason: 'at rest before the motion');
      expect(values[4].abs(), greaterThan(0.05), reason: 'already reacting in the first frames');
      var maxStep = 0.0, maxSecond = 0.0;
      for (var i = 1; i < values.length; i++) {
        maxStep = (values[i] - values[i - 1]).abs() > maxStep ? (values[i] - values[i - 1]).abs() : maxStep;
        if (i > 1) {
          final second = (values[i] - 2 * values[i - 1] + values[i - 2]).abs();
          if (second > maxSecond) maxSecond = second;
        }
      }
      expect(maxStep, lessThan(1.0), reason: 'no jump from one frame to the next');
      expect(maxSecond, lessThan(0.1), reason: 'no sudden change of swing speed (a kick)');
      expect(values.reduce((a, b) => a.abs() > b.abs() ? a : b).abs(), greaterThan(5), reason: 'it does swing');
    });

    test('a grip point at the top swings the layer the other way from one at the bottom', () {
      Layer make(List<double> pivot) {
        final l = createLayer('rect');
        project.layers.add(l);
        addKeyframe(project, l.id, 'anchor', 0, [0.2, 0.5], 'easeInOut');
        addKeyframe(project, l.id, 'anchor', 60, [0.8, 0.5], 'easeInOut');
        autoComputeTangents(l.transform.anchor);
        l.pendulum
          ..enabled = true
          ..pivotOffset.defaultValue = pivot;
        return l;
      }

      final hanging = make([0.0, -40.0]); // grip above the centre: hangs below it
      final standing = make([0.0, 40.0]); // grip below: stands above it
      final a = evaluatePendulumOffset(project, hanging, 15), b = evaluatePendulumOffset(project, standing, 15);
      expect(a.abs(), greaterThan(0.5));
      expect(a.sign, -b.sign, reason: 'the body lags behind the motion either way');
    });
  });

  group('pendulum: ringing continues after motion stops', () {
    test('keeps oscillating for many frames after the driving keyframes end, not freezing instantly', () {
      final c = createLayer('rect');
      project.layers.add(c); // evaluatePendulumOffset resolves layers via findLayer() against project.layers
      addKeyframe(project, c.id, 'anchor', 30, [0.2, 0.5], 'linear');
      addKeyframe(project, c.id, 'anchor', 50, [0.7, 0.5], 'linear');
      autoComputeTangents(c.transform.anchor);
      c.pendulum
        ..enabled = true
        ..frequency = 40
        ..damping = 20
        ..sensitivity = 50
        ..maxAngle = 60
        ..freeze = 50;

      // motion's last keyframe is at frame 50 - the swing should still
      // be very much alive at 90, not clamped to 0 the instant the
      // driving velocity stops. empirically verified sequence (not a
      // guess): f50 -39.5, f55 -41.1, f60 0.2, f65 36.9, f70 30.8,
      // f75 -7.1, f80 -33.5, f85 -21.8, f90 11.6 - a real damped
      // oscillation, sign flipping as it rings down, never pinned to
      // exactly 0 after a stop.
      final values = [50, 55, 60, 65, 70, 75, 80, 85, 90].map((f) => evaluatePendulumOffset(project, c, f)).toList();

      // the regression this guards against: an earlier "fix" for
      // phantom oscillation used a non-sticky gate that dropped
      // straight to 0 the moment driving speed hit 0 - i.e. everything
      // from f55 onward would have been exactly 0. assert it
      // demonstrably isn't.
      final nonZeroAfterStop = values.sublist(1).where((v) => v.abs() > 1);
      expect(nonZeroAfterStop.length, greaterThan(4));

      // and it should still be SIGNED (oscillating), not just decaying
      // toward some nonzero constant - both polarities should appear.
      expect(values.any((v) => v > 5), isTrue);
      expect(values.any((v) => v < -5), isTrue);
    });
  });

  group('pendulum: freeze holds near maxAngle during sustained fast motion', () {
    test("doesn't complete a full sine cycle while driving speed stays high", () {
      final c = createLayer('rect');
      project.layers.add(c);
      addKeyframe(project, c.id, 'anchor', 0, [0.1, 0.5], 'linear');
      addKeyframe(project, c.id, 'anchor', 100, [30.0, 0.5], 'linear'); // sustained fast, single direction
      autoComputeTangents(c.transform.anchor);
      c.pendulum
        ..enabled = true
        ..frequency = 40
        ..damping = 20
        ..sensitivity = 90
        ..maxAngle = 50
        ..freeze = 95; // strong freeze

      // empirically verified: ~45.89 at frame 50, mid-motion - freeze
      // should be holding it near maxAngle (50), not letting it swing
      // through zero and back the way an unfrozen sine would.
      final midMotion = evaluatePendulumOffset(project, c, 50);
      expect(midMotion.abs(), greaterThan(40));
      expect(midMotion.abs(), lessThanOrEqualTo(50.5)); // never exceeds maxAngle by more than rounding
    });
  });

  group('pendulum: rig chain cascades motion through parenting alone', () {
    test('link1 (no own keyframes) inherits root\'s swing with a lag, not identically', () {
      final root = createLayer('rect');
      project.layers.add(root);
      addKeyframe(project, root.id, 'anchor', 0, [0.2, 0.5], 'linear');
      addKeyframe(project, root.id, 'anchor', 20, [0.6, 0.5], 'linear');
      autoComputeTangents(root.transform.anchor);
      root.pendulum
        ..enabled = true
        ..frequency = 40
        ..damping = 25
        ..sensitivity = 60
        ..maxAngle = 40
        ..freeze = 40;

      final link1 = createLayer('rect');
      project.layers.add(link1);
      link1.parentId = root.id;
      link1.transform.anchor.defaultValue = [0.08, 0.0]; // offset from root, like a segment length
      // deliberately NO keyframes on link1 - purely parent-driven
      link1.pendulum
        ..enabled = true
        ..frequency = 35
        ..damping = 20
        ..sensitivity = 60
        ..maxAngle = 40
        ..freeze = 40;

      // pinned for the driven-oscillator model (the earlier fixed-sine
      // model gave -9.6783 / -25.6927 here).
      final rootSwing = evaluatePendulumOffset(project, root, 28);
      final link1Swing = evaluatePendulumOffset(project, link1, 28);

      expect(rootSwing, closeTo(-36.7094, 1e-3));
      expect(link1Swing, closeTo(-38.5867, 1e-3));

      // the actual behavioral claim, independent of the exact pinned
      // numbers above: link1 reacts (nonzero) but LAGS root (not
      // equal) - this is what "cascading secondary motion" means
      // mechanically.
      expect(link1Swing.abs(), greaterThan(1));
      expect((link1Swing - rootSwing).abs(), greaterThan(0.1));

      expect(link1.transform.anchor.keyframes, isEmpty); // confirms it's purely inherited, not separately keyed
    });

    test('does not hang or stack-overflow on a multi-link chain (regression: this used to be either infinite recursion or O(depth^frames))', () {
      var prev = createLayer('rect');
      project.layers.add(prev);
      addKeyframe(project, prev.id, 'anchor', 0, [0.2, 0.5], 'linear');
      addKeyframe(project, prev.id, 'anchor', 20, [0.6, 0.5], 'linear');
      autoComputeTangents(prev.transform.anchor);
      prev.pendulum
        ..enabled = true
        ..frequency = 40
        ..damping = 25
        ..sensitivity = 60
        ..maxAngle = 40
        ..freeze = 40;

      for (var i = 0; i < 5; i++) {
        final l = createLayer('rect');
        project.layers.add(l);
        l.parentId = prev.id;
        l.transform.anchor.defaultValue = [0.05, 0.0];
        l.pendulum
          ..enabled = true
          ..frequency = 35.0 - i
          ..damping = 20
          ..sensitivity = 60
          ..maxAngle = 40
          ..freeze = 40;
        prev = l;
      }

      // if the frame-scoped state cache regressed (e.g. stopped being
      // used, or got cleared too aggressively), this either hangs (the
      // test runner will time it out) or throws a stack overflow -
      // simply completing and returning a finite number IS the test.
      final value = evaluatePendulumOffset(project, prev, 300);
      expect(value.isFinite, isTrue);
    });
  });
}
