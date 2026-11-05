import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('round-trips a default project through JSON with no data loss', () {
    final project = createDefaultProject();
    final json = projectLayersToJson(project);
    final restored = projectLayersFromJson(jsonDecode(jsonEncode(json)) as List<dynamic>);

    expect(restored.length, equals(project.layers.length));
    for (var i = 0; i < project.layers.length; i++) {
      expect(restored[i].id, equals(project.layers[i].id));
      expect(restored[i].name, equals(project.layers[i].name));
      expect(restored[i].parentId, equals(project.layers[i].parentId));
      expect(restored[i].content.shape, equals(project.layers[i].content.shape));
      expect(restored[i].transform.anchor.defaultValue, equals(project.layers[i].transform.anchor.defaultValue));
    }
  });

  test('round-trips keyframes, easing, and spatial tangents', () {
    final layer = createLayer('rect');
    addKeyframe(Project(layers: [layer]), layer.id, 'anchor', 0, [0.1, 0.2], 'easeInOut');
    addKeyframe(Project(layers: [layer]), layer.id, 'anchor', 30, [0.5, 0.6], 'linear');
    autoComputeTangents(layer.transform.anchor);

    final json = layerToJson(layer);
    final restored = layerFromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);

    expect(restored.transform.anchor.keyframes.length, equals(2));
    expect(restored.transform.anchor.keyframes[0].frame, equals(0));
    expect(restored.transform.anchor.keyframes[0].value, equals([0.1, 0.2]));
    expect(restored.transform.anchor.keyframes[0].temporal.x1, closeTo(0.42, 1e-9)); // easeInOut
    expect(restored.transform.anchor.keyframes[1].spatialTangent.outTan, equals(layer.transform.anchor.keyframes[1].spatialTangent.outTan));
  });

  test('uses the exact JS key names for cross-platform file compatibility (not the Dart field names)', () {
    final layer = createLayer('rect');
    final json = layerToJson(layer);
    // Track serializes under "default", NOT "defaultValue" (the Dart
    // field is named around `default` being a reserved word - the wire
    // format must not leak that detail).
    expect((json['transform'] as Map)['anchor'], contains('default'));
    expect((json['transform'] as Map)['anchor'], isNot(contains('defaultValue')));
    // top-level layer keys match movement-core/src/model/project.js's
    // own createLayer() object shape exactly.
    for (final key in ['id', 'name', 'parentId', 'startFrame', 'durationFrames', 'transform', 'content', 'masks', 'effectStack', 'color', 'renderMode', 'hidden', 'motionBlur', 'wiggle', 'pendulum']) {
      expect(json.containsKey(key), isTrue, reason: 'missing expected key "$key"');
    }
  });

  test('round-trips an effect instance with mixed Track and plain-value params (mesh_warp-style)', () {
    registerBuiltinEffects();
    final layer = createLayer('rect');
    final inst = createEffectInstance('mesh_warp', 'fx_1', layer);
    layer.effectStack.add(inst);

    final json = layerToJson(layer);
    final restored = layerFromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);

    final restoredInst = restored.effectStack.single;
    expect(restoredInst.effectId, equals('mesh_warp'));
    expect(restoredInst.params['rows'], equals(4)); // plain int, not a Track
    expect(restoredInst.params['r0c0'], isA<Track>()); // pin offsets ARE tracks
  });

  test('round-trips an embedded image layer\'s content through JSON with no data loss', () {
    final layer = createImageLayer(
      imageSourceType: 'embedded',
      imageData: 'ZmFrZS1pbWFnZS1ieXRlcw==',
      naturalWidth: 800,
      naturalHeight: 600,
    );
    final json = layerToJson(layer);
    final restored = layerFromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);

    expect(restored.content.shape, equals('image'));
    expect(restored.content.imageSourceType, equals('embedded'));
    expect(restored.content.imageData, equals('ZmFrZS1pbWFnZS1ieXRlcw=='));
    expect(restored.content.imagePath, isNull);
    expect(restored.content.imageNaturalWidth, equals(800));
    expect(restored.content.imageNaturalHeight, equals(600));
    expect(restored.content.size, equals(layer.content.size));
  });

  test('round-trips a file-referenced image layer\'s content through JSON with no data loss', () {
    final layer = createImageLayer(
      imageSourceType: 'file',
      imagePath: '/storage/emulated/0/DCIM/photo.jpg',
      naturalWidth: 1920,
      naturalHeight: 1080,
    );
    final json = layerToJson(layer);
    final restored = layerFromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);

    expect(restored.content.imageSourceType, equals('file'));
    expect(restored.content.imagePath, equals('/storage/emulated/0/DCIM/photo.jpg'));
    expect(restored.content.imageData, isNull);
  });

  test('a plain rect layer\'s JSON carries no image-related keys at all (no wire-format bloat)', () {
    final layer = createLayer('rect');
    final json = layerToJson(layer);
    final contentJson = json['content'] as Map<String, dynamic>;
    for (final key in ['imageSourceType', 'imageData', 'imagePath', 'imageNaturalWidth', 'imageNaturalHeight']) {
      expect(contentJson.containsKey(key), isFalse, reason: 'a non-image layer should not serialize "$key"');
    }
  });

  test('cloneLayer (used by undo snapshots) preserves every image field', () {
    final layer = createImageLayer(
      imageSourceType: 'embedded',
      imageData: 'ZmFrZQ==',
      naturalWidth: 50,
      naturalHeight: 25,
    );
    final clone = cloneLayer(layer);
    expect(clone.content.shape, equals('image'));
    expect(clone.content.imageSourceType, equals('embedded'));
    expect(clone.content.imageData, equals('ZmFrZQ=='));
    expect(clone.content.imageNaturalWidth, equals(50));
    expect(clone.content.imageNaturalHeight, equals(25));
  });
}
