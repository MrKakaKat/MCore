import 'dart:convert';
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 1000);
    clearStateCaches();
  });

  group('media speed', () {
    test('twice as fast: twice as far into the source a frame, half as long; saved', () {
      final a = createAudioLayer(path: 'x', assetId: 'A', durationSeconds: 4);
      final before = a.durationFrames;
      expect(mediaSourceTime(a.content, fps), closeTo(1, 1e-9));
      setMediaSpeed(a, 2);
      expect(a.durationFrames, (before / 2).round());
      expect(mediaSourceTime(a.content, fps), closeTo(2, 1e-9));
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(a))) as Map<String, dynamic>);
      expect(back.content.mediaSpeed, 2);
      expect(cloneLayer(a).content.mediaSpeed, 2);
    });

    test('the sound mix plays the source faster (between samples)', () {
      const rate = 1000;
      // a ramp: sample i holds i (both channels).
      final pcm = Int16List(2 * 2000);
      for (var i = 0; i < 2000; i++) {
        pcm[2 * i] = i;
        pcm[2 * i + 1] = i;
      }
      final a = createAudioLayer(path: 'x', assetId: 'A', durationSeconds: 2);
      setMediaSpeed(a, 1.5);
      final out = mixTimeline(Project(layers: [a]), {'A': pcm}, seconds: 0.5, sampleRate: rate);
      // at 0.2 s it is at 0.3 s of the source: sample 300.
      expect(out[2 * 200], closeTo(300, 1));
      expect(out[2 * 100], closeTo(150, 1));
    });
  });

  group('corners and parents', () {
    test('a child taking its parent\'s rounding gets it; off by default', () {
      final p = createLayer('rect')..id = 'P';
      p.fill
        ..cornerRadius = 12
        ..cornerShape = 0.7;
      final c = createLayer('rect')
        ..id = 'C'
        ..parentId = 'P';
      final project = Project(layers: [p, c]);
      expect(c.inheritRounding, isFalse);
      expect(syncInheritedRounding(project), isFalse);
      expect(c.fill.cornerRadius, 0);
      c.inheritRounding = true;
      expect(syncInheritedRounding(project), isTrue);
      expect([c.fill.cornerRadius, c.fill.cornerShape], [12, 0.7]);
      expect(syncInheritedRounding(project), isFalse);
      final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(c))) as Map<String, dynamic>);
      expect(back.inheritRounding, isTrue);
    });

    test('kept round under a scaled parent (not oval)', () {
      final p = createLayer('rect')
        ..id = 'P'
        ..transform.scale.defaultValue = [2.0, 1.0];
      final c = createLayer('rect')
        ..id = 'C'
        ..parentId = 'P'
        ..content.size = [100, 100];
      c.fill
        ..cornerRadius = 10
        ..cornersKeepRound = true;
      final project = Project(layers: [p, c]);
      final (rx, ry) = cornerRadii(c, 0, project: project);
      // drawn: rx * 2 wide, ry * 1 tall - the same on the screen.
      expect(rx * 2, closeTo(ry * 1, 1e-6));
    });
  });

  group('key layers', () {
    test('a key layer holds its first key before it (as the parameters\' own keys do)', () {
      final l = createLayer('rect')..durationFrames = 60;
      l.transform.anchor.defaultValue = [0.5, 0.5];
      final n = addTransformAnimLayer(l);
      l.transform.anchor.animLayers[n - 1].track.keyframes = [Keyframe(frame: 30, value: [0.1, 0.0])];
      List<double> at(double f) => evaluateTrack(null, l.transform.anchor, f, l) as List<double>;
      expect(at(10)[0], closeTo(0.6, 1e-9));
      expect(at(30)[0], closeTo(0.6, 1e-9));
      expect(at(50)[0], closeTo(0.6, 1e-9));
    });

    test('merging two ranges keeps the movement', () {
      final l = createLayer('rect')..durationFrames = 60;
      final a = addTransformAnimLayer(l), b = addTransformAnimLayer(l);
      final al = l.transform.anchor.animLayers;
      al[a - 1].track.keyframes = [
        Keyframe(frame: 0, value: [0.0, 0.0]),
        Keyframe(frame: 10, value: [0.2, 0.0]),
      ];
      al[b - 1].track.keyframes = [
        Keyframe(frame: 20, value: [0.0, 0.0]),
        Keyframe(frame: 30, value: [0.0, 0.3]),
      ];
      List<double> at(double f) => evaluateTrack(null, l.transform.anchor, f, l) as List<double>;
      final before = [for (final f in [0.0, 5.0, 15.0, 25.0, 40.0]) at(f)];
      mergeAnimLayerInto(l, a, b);
      expect(l.transform.anchor.animLayers, hasLength(1));
      final after = [for (final f in [0.0, 5.0, 15.0, 25.0, 40.0]) at(f)];
      for (var i = 0; i < before.length; i++) {
        expect(after[i][0], closeTo(before[i][0], 1e-9));
        expect(after[i][1], closeTo(before[i][1], 1e-9));
      }
    });
  });
}
