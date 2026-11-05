import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => activeAnimLayer = 0);

  test('an animation layer adds its own keys on top: path A..C plus sway B..D', () {
    final l = createLayer('rect')..durationFrames = 100;
    final anchor = l.transform.anchor;
    anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.0, 0.5]),
      Keyframe(frame: 60, value: [0.6, 0.5]),
    ]);
    expect(addTransformAnimLayer(l), 1);
    final sway = anchor.animLayers.single.track;
    sway.keyframes.addAll([
      Keyframe(frame: 30, value: [0.0, 0.0]),
      Keyframe(frame: 100, value: [0.0, 0.2]),
    ]);
    final v = evaluateTrack(null, anchor, 30) as List<double>;
    expect(v[0], closeTo(0.3, 1e-9));
    expect(v[1], closeTo(0.5, 1e-9));
    final end = evaluateTrack(null, anchor, 100) as List<double>;
    expect(end, [closeTo(0.6, 1e-9), closeTo(0.7, 1e-9)]);
    setTransformAnimLayerEnabled(l, 1, false);
    expect((evaluateTrack(null, anchor, 100) as List<double>)[1], closeTo(0.5, 1e-9));
  });

  test('scale multiplies; edits with a layer active go to that layer', () {
    final l = createLayer('rect');
    addTransformAnimLayer(l);
    l.transform.scale.defaultValue = [2.0, 2.0];
    activeAnimLayer = 1;
    setTrackValueAt(l.transform.scale, 0, [3.0, 4.0]);
    expect(l.transform.scale.defaultValue, [2.0, 2.0], reason: 'own value untouched');
    expect(l.transform.scale.animLayers.single.track.defaultValue, [1.5, 2.0]);
    expect(evaluateTrack(null, l.transform.scale, 0), [3.0, 4.0]);
    setTrackValueAt(l.transform.rotation, 0, 30.0);
    expect(l.transform.rotation.defaultValue, 0.0);
    expect(evaluateTrack(null, l.transform.rotation, 0), 30.0);
    expect(trackValueToEdit(l.transform.rotation, 0), 30.0, reason: 'the total, to edit from');
    activeAnimLayer = 0;
    setTrackValueAt(l.transform.rotation, 0, 10.0);
    expect(evaluateTrack(null, l.transform.rotation, 0), 40.0);
  });

  test('master key with a layer active keys that layer; layers saved, cloned and on the timeline', () {
    final l = createLayer('rect');
    addTransformAnimLayer(l);
    activeAnimLayer = 1;
    keyAllTracks(Project(layers: [l]), l, 12);
    expect(l.transform.rotation.keyframes, isEmpty);
    expect(l.transform.rotation.animLayers.single.track.keyframes.single.frame, 12);
    activeAnimLayer = 0;
    final names = <String>[];
    visitLayerTracksNamed(l, (n, t) => names.add(n));
    expect(names, contains('rotation +1'));
    expect(keyDetailRows(l).keys, ['Layer 1'], reason: 'its own row');
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.transform.scale.animLayers.single.multiply, isTrue);
    expect(cloneLayer(l).transform.rotation.animLayers.single.track.keyframes, hasLength(1));
  });
}
