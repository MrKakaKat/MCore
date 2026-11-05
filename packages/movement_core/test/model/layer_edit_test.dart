import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer({String id = 'L_a', int start = 10, int duration = 100}) => Layer(
      id: id,
      name: 'a',
      startFrame: start,
      durationFrames: duration,
      transform: Transform(
          anchor: track([0.5, 0.5], true),
          scale: track([1.0, 1.0]),
          rotation: track(0.0),
          opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [40, 20]),
    );

void main() {
  setUp(() {
    setStageSize(640, 400);
    registerBuiltinEffects();
  });

  group('splitLayer', () {
    test('cuts the layer in two at the frame, keeps the animation continuous', () {
      final a = _layer();
      a.transform.rotation.keyframes
          .addAll([Keyframe(frame: 0, value: 0.0), Keyframe(frame: 100, value: 100.0)]);
      final project = Project(layers: [a]);

      final b = splitLayer(project, a, 50, 'L_b')!; // local cut at 40

      expect(project.layers.map((l) => l.id), equals(['L_a', 'L_b']));
      expect([a.startFrame, a.durationFrames], equals([10, 40]));
      expect([b.startFrame, b.durationFrames], equals([50, 60]));
      expect(a.transform.rotation.keyframes.map((k) => (k.frame, k.value)),
          equals([(0, 0.0), (40, 40.0)]));
      expect(b.transform.rotation.keyframes.map((k) => (k.frame, k.value)),
          equals([(0, 40.0), (60, 100.0)]));
      expect(b.name, equals('A 2'));
    });

    test('static tracks stay static; a cut outside the layer does nothing', () {
      final a = _layer();
      final project = Project(layers: [a]);
      expect(splitLayer(project, a, 10, 'x'), isNull, reason: 'at the start edge');
      expect(splitLayer(project, a, 110, 'x'), isNull, reason: 'at the end edge');
      final b = splitLayer(project, a, 60, 'L_b')!;
      expect(b.transform.rotation.keyframes, isEmpty);
      expect(a.transform.rotation.keyframes, isEmpty);
    });
  });

  group('parameter snapshot', () {
    test('copies movement, effects and crop but not the shape or timing', () {
      final src = _layer(id: 'L_src', start: 0, duration: 30);
      src.transform.scale.defaultValue = [2.0, 3.0];
      src.transform.rotation.keyframes.add(Keyframe(frame: 5, value: 45.0));
      src.effectStack.add(createEffectInstance('bend_arc', 'fx_1', src));
      src.crop = [0.1, 0, 0, 0.2];
      src.mirrorX = true;
      src.color = '#ff0000';
      final dst = _layer(id: 'L_dst', start: 70, duration: 5)
        ..content = Content(shape: 'circle', offset: [0, 0], size: [10, 10]);
      final project = Project(layers: [src, dst]);

      applyLayerParamsJson(project, dst, layerParamsToJson(src));

      expect(dst.transform.scale.defaultValue, equals([2.0, 3.0]));
      expect(dst.transform.rotation.keyframes.single.value, equals(45.0));
      expect(dst.effectStack.single.effectId, equals('bend_arc'));
      expect(dst.effectStack.single.id, isNot('fx_1'), reason: 'fresh instance id');
      expect(dst.crop, equals([0.1, 0, 0, 0.2]));
      expect(dst.mirrorX, isTrue);
      expect(dst.color, equals('#ff0000'));
      expect(dst.content.shape, equals('circle'));
      expect([dst.startFrame, dst.durationFrames], equals([70, 5]));
      // independent copies
      dst.transform.rotation.keyframes.single.value = 1.0;
      expect(src.transform.rotation.keyframes.single.value, equals(45.0));
    });

    test('references to layers missing from the target project are dropped', () {
      final src = _layer(id: 'L_src');
      src.masks.add(Mask(sourceLayerId: 'L_gone'));
      final dst = _layer(id: 'L_dst');
      applyLayerParamsJson(Project(layers: [dst]), dst, layerParamsToJson(src));
      expect(dst.masks.single.sourceLayerId, isNull);
    });
  });

  test('replaceLayerContent fits the new content into the old box', () {
    final l = _layer()..content = Content(shape: 'rect', offset: [5, 5], size: [40, 20]);
    replaceLayerContent(l, Content(shape: 'circle', offset: [0, 0], size: [8, 8]));
    expect(l.content.shape, equals('circle'));
    expect(l.content.offset, equals([5.0, 5.0]));

    replaceLayerContent(
        l,
        Content(
            shape: 'image',
            offset: [0, 0],
            size: [1, 1],
            imageNaturalWidth: 100,
            imageNaturalHeight: 100));
    // the circle's box is 20x20 (radius = min(size)/2) around (5,5)
    expect(l.content.size[0], closeTo(l.content.size[1], 1e-9), reason: 'image keeps its aspect');
  });

  test('crop and mirror survive a JSON round trip, and default when absent', () {
    final l = _layer()
      ..crop = [0.1, 0.2, 0.3, 0.05]
      ..cropAspect = '16:9'
      ..mirrorY = true;
    final back = layerFromJson(layerToJson(l));
    expect(back.crop, equals([0.1, 0.2, 0.3, 0.05]));
    expect(back.cropAspect, equals('16:9'));
    expect(back.mirrorY, isTrue);
    final plain = layerFromJson(layerToJson(_layer()));
    expect(plain.crop, equals([0.0, 0.0, 0.0, 0.0]));
    expect(layerToJson(_layer()).containsKey('crop'), isFalse);
  });

  test('params taken from an image layer never change the target\'s colour', () {
    final image = _layer(id: 'L_img')
      ..content = Content(shape: 'image', offset: [0, 0], size: [10, 10])
      ..color = '#123456';
    final shape = _layer(id: 'L_shape')..color = '#ff0000';
    applyLayerParamsJson(Project(layers: [image, shape]), shape, layerParamsToJson(image));
    expect(shape.color, '#ff0000');
    expect(layerParamsToJson(image).containsKey('color'), isFalse);
  });
}
