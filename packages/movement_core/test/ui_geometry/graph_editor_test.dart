import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Real, run coverage of ui_geometry/graph_editor.dart's state layer -
/// the counterpart to movement-core/src/ui/graphEditor.js's `graphState`
/// object plus its `getEditingTemporal`/`currentSegmentKeyframes`/
/// `drawCurvePreview` sampling loop. The Flutter widget (unverifiable in
/// this sandbox) only owns the two canvases' drawing; every state
/// transition and the curve sampling itself is provable here.
void main() {
  Track spatialTrack() {
    final t = Track([0.0, 0.0], true);
    t.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.0]),
      Keyframe(frame: 30, value: [10.0, 0.0], temporal: const Easing(0.42, 0, 0.58, 1)),
      Keyframe(frame: 60, value: [20.0, 0.0], temporal: const Easing(0, 0, 1, 1)),
    ]);
    return t;
  }

  group('per-segment mode', () {
    test('defaults to the LAST segment, matching openGraphEditor\'s own default', () {
      final trk = spatialTrack();
      final state = GraphEditorState(track: trk, componentCount: 2);
      expect(state.segmentIndex, equals(1)); // keyframes.length - 2 == 1 (segment 30->60)
    });

    test('currentSegmentKeyframes returns the pair for the active segment', () {
      final trk = spatialTrack();
      final state = GraphEditorState(track: trk, componentCount: 2, segmentIndex: 0);
      final (k0, k1) = state.currentSegmentKeyframes();
      expect(k0.frame, equals(0));
      expect(k1.frame, equals(30));
    });

    test('getEditingTemporal reads the SECOND keyframe\'s temporal (the transition INTO it)', () {
      final trk = spatialTrack();
      final state = GraphEditorState(track: trk, componentCount: 2, segmentIndex: 0);
      final t = state.getEditingTemporal();
      expect(t.x1, equals(0.42));
      expect(t.y1, equals(0));
      expect(t.x2, equals(0.58));
      expect(t.y2, equals(1));
    });

    test('setEditingTemporal replaces the second keyframe\'s temporal, leaving other keyframes untouched', () {
      final trk = spatialTrack();
      final state = GraphEditorState(track: trk, componentCount: 2, segmentIndex: 0);
      state.setEditingTemporal(const Easing(0.1, 0.2, 0.3, 0.4));

      expect(trk.keyframes[1].temporal.x1, equals(0.1));
      expect(trk.keyframes[1].temporal.y1, equals(0.2));
      expect(trk.keyframes[2].temporal.x1, equals(0), reason: 'the OTHER segment\'s easing must be untouched');
    });

    test('segmentLabels produces one "frame->frame" label per transition', () {
      final trk = spatialTrack();
      final state = GraphEditorState(track: trk, componentCount: 2);
      expect(state.segmentLabels(), equals(['0→30', '30→60']));
    });

    test('sampleCurve samples only the active segment\'s span, for the selected component', () {
      final trk = spatialTrack();
      final state = GraphEditorState(track: trk, componentCount: 2, component: 0, segmentIndex: 0);
      final samples = state.sampleCurve(steps: 4);
      expect(samples.length, equals(5));
      expect(samples.first, closeTo(0, 1e-9)); // value at frame 0
      expect(samples.last, closeTo(10, 1e-9)); // value at frame 30
    });

    test('sampleCurve on the Y component picks the other channel', () {
      final trk = Track([0.0, 0.0], true);
      trk.keyframes.addAll([
        Keyframe(frame: 0, value: [0.0, 0.0]),
        Keyframe(frame: 10, value: [0.0, 100.0]),
      ]);
      final state = GraphEditorState(track: trk, componentCount: 2, component: 1, segmentIndex: 0);
      final samples = state.sampleCurve(steps: 2);
      expect(samples.last, closeTo(100, 1e-9));
    });
  });

  group('whole-path mode', () {
    test('getEditingTemporal reads the track\'s own globalEasing', () {
      final trk = spatialTrack();
      trk.globalEasing = const Easing(0.1, 0.2, 0.3, 0.4);
      final state = GraphEditorState(track: trk, componentCount: 2, wholePath: true);
      final t = state.getEditingTemporal();
      expect(t.x1, equals(0.1));
    });

    test('setEditingTemporal replaces the track\'s globalEasing, not any keyframe\'s own temporal', () {
      final trk = spatialTrack();
      trk.globalEasing = const Easing(0.42, 0, 0.58, 1);
      final state = GraphEditorState(track: trk, componentCount: 2, wholePath: true);
      state.setEditingTemporal(const Easing(0.9, 0.8, 0.7, 0.6));

      expect(trk.globalEasing!.x1, equals(0.9));
      expect(trk.keyframes[1].temporal.x1, equals(0.42), reason: 'per-keyframe temporal must be untouched in whole-path mode');
    });

    test('sampleCurve spans the FULL track (first keyframe to last), not one segment', () {
      final trk = spatialTrack();
      trk.globalEasing = const Easing(0, 0, 1, 1); // linear, so the sampled curve is exactly a straight ramp
      final state = GraphEditorState(track: trk, componentCount: 2, component: 0, wholePath: true);
      final samples = state.sampleCurve(steps: 6);
      expect(samples.first, closeTo(0, 1e-9)); // value at frame 0 (track start)
      expect(samples.last, closeTo(20, 1e-9)); // value at frame 60 (track end), not 30
    });
  });

  group('coordinate clamping', () {
    test('clampX restricts to [0,1]', () {
      expect(GraphEditorState.clampX(-0.5), equals(0.0));
      expect(GraphEditorState.clampX(1.5), equals(1.0));
      expect(GraphEditorState.clampX(0.42), equals(0.42));
    });

    test('clampY allows the JS-documented overshoot range [-0.6,1.6]', () {
      expect(GraphEditorState.clampY(-1.0), equals(-0.6));
      expect(GraphEditorState.clampY(2.0), equals(1.6));
      expect(GraphEditorState.clampY(1.2), equals(1.2));
    });
  });
}
