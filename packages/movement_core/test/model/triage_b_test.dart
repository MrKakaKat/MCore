import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  setUp(() {
    fps = 60;
    setStageSize(200, 200);
    clearStateCaches();
    defaultKeyEasingName = 'easeInOut';
  });

  test('undo toast names what changed', () {
    final a = createLayer('rect')
      ..id = 'a'
      ..name = 'rect_1';
    final b = cloneLayer(a)..transform.rotation.defaultValue = 30.0;
    expect(describeLayerChange([a], [b]), contains('rect_1'));
    expect(describeLayerChange([a], []), 'deleting rect_1');
    expect(describeLayerChange([], [a]), 'adding rect_1');
    expect(describeLayerChange([a], [cloneLayer(a)]), '');
  });

  test('new keys take the default ease from settings', () {
    defaultKeyEasingName = 'linear';
    expect(newKeyEasing(), same(easingPresets['linear']));
    defaultKeyEasingName = 'nonsense';
    expect(newKeyEasing(), same(easingPresets['easeInOut']));
  });

  test('a master key shares one ease across its tracks', () {
    final l = createLayer('rect');
    final p = Project(layers: [l]);
    keyAllTracks(p, l, 10);
    expect(allTracksKeyedAt(l, 10), isTrue);
    final ease = easingPresets['linear']!;
    shareEaseAtFrame(l, 10, ease);
    visitActiveLayerTracks(l, (trk) {
      for (final k in trk.keyframes.where((k) => k.frame == 10)) {
        expect(k.temporal, same(ease));
      }
    });
  });

  test('tiny boxes drop side handles, the smallest the corner rotate', () {
    TransformBoxHandles box(double w, double h) => TransformBoxHandles(
          bbox: BoundingBox(minX: 0, minY: 0, maxX: w, maxY: h),
          mCanvas: const [1, 0, 0, 1, 0, 0],
          mCanvasNoScale: const [1, 0, 0, 1, 0, 0],
          screen: {
            'tl': [0, 0],
            'tr': [w, 0],
            'bl': [0, h],
          },
        );
    expect(crowdedTransformHandles(box(200, 200), 1), isEmpty);
    expect(crowdedTransformHandles(box(30, 200), 1), {'top', 'bottom'});
    // they go later than they used to: a 40 px side still keeps its handles.
    expect(crowdedTransformHandles(box(40, 200), 1), isEmpty);
    expect(crowdedTransformHandles(box(20, 20), 1), {'top', 'bottom', 'left', 'right', 'rotateCorner'});
    // zoomed in 4x: the same box is big on screen.
    expect(crowdedTransformHandles(box(20, 20), 0.25), isEmpty);
  });

  test('edge matte and feather range survive save / load', () {
    final l = createLayer('rect')
      ..edgeMatte = true
      ..edgeMatteColor = '#ffffff'
      ..edgeMatteStrength = 0.4
      ..masks.add(Mask()..featherOutside = 0.25);
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    expect(back.edgeMatte, isTrue);
    expect(back.edgeMatteColor, '#ffffff');
    expect(back.edgeMatteStrength, 0.4);
    expect(back.masks.single.featherOutside, 0.25);
    final plain = layerFromJson(jsonDecode(jsonEncode(layerToJson(createLayer('rect')))) as Map<String, dynamic>);
    expect(plain.edgeMatte, isFalse);
    final c = cloneLayer(l);
    expect(c.edgeMatteStrength, 0.4);
    expect(c.masks.single.featherOutside, 0.25);
  });
}
