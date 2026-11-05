import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Real coverage for the "image" content shape - added for image import. This
/// is the part of the export/import round that genuinely doesn't need dart:ui
/// at all: an image layer's PLACEMENT (offset/size, bounding box,
/// effect-warped outline) is pure geometry, identical to "rect" - only the
/// render backend (movement_mobile/lib/render/canvas_renderer.dart, untestable
/// in this sandbox) draws it differently.
void main() {
  group('isRectLikeShape', () {
    test('true for rect and image, false for every other shape', () {
      expect(isRectLikeShape('rect'), isTrue);
      expect(isRectLikeShape('image'), isTrue);
      expect(isRectLikeShape('circle'), isFalse);
      expect(isRectLikeShape('triangle'), isFalse);
      expect(isRectLikeShape('ngon'), isFalse);
      expect(isRectLikeShape('polygon'), isFalse);
    });
  });

  group('createImageLayer', () {
    test('a wide source image gets width=maxDimension, height scaled down to preserve aspect ratio', () {
      final layer = createImageLayer(
        imageSourceType: 'embedded',
        imageData: 'ZmFrZQ==',
        naturalWidth: 400,
        naturalHeight: 200,
        maxDimension: 200,
      );
      expect(layer.content.shape, equals('image'));
      expect(layer.content.size[0], equals(200));
      expect(layer.content.size[1], equals(100));
    });

    test('a tall source image gets height=maxDimension, width scaled down to preserve aspect ratio', () {
      final layer = createImageLayer(
        imageSourceType: 'file',
        imagePath: '/tmp/photo.png',
        naturalWidth: 150,
        naturalHeight: 300,
        maxDimension: 200,
      );
      expect(layer.content.size[1], equals(200));
      expect(layer.content.size[0], equals(100));
    });

    test('a square source image gets width=height=maxDimension', () {
      final layer = createImageLayer(
        imageSourceType: 'embedded',
        imageData: 'ZmFrZQ==',
        naturalWidth: 100,
        naturalHeight: 100,
      );
      expect(layer.content.size[0], equals(layer.content.size[1]));
    });

    test('carries the source type, data/path, and natural dimensions through onto Content', () {
      final embedded = createImageLayer(
        imageSourceType: 'embedded',
        imageData: 'ZmFrZQ==',
        naturalWidth: 64,
        naturalHeight: 32,
      );
      expect(embedded.content.imageSourceType, equals('embedded'));
      expect(embedded.content.imageData, equals('ZmFrZQ=='));
      expect(embedded.content.imagePath, isNull);
      expect(embedded.content.imageNaturalWidth, equals(64));
      expect(embedded.content.imageNaturalHeight, equals(32));

      final fileRef = createImageLayer(
        imageSourceType: 'file',
        imagePath: '/tmp/x.jpg',
        naturalWidth: 10,
        naturalHeight: 20,
      );
      expect(fileRef.content.imageSourceType, equals('file'));
      expect(fileRef.content.imagePath, equals('/tmp/x.jpg'));
      expect(fileRef.content.imageData, isNull);
    });

    test('rejects "embedded" without imageData, and "file" without imagePath', () {
      expect(
        () => createImageLayer(imageSourceType: 'embedded', naturalWidth: 10, naturalHeight: 10),
        throwsArgumentError,
      );
      expect(
        () => createImageLayer(imageSourceType: 'file', naturalWidth: 10, naturalHeight: 10),
        throwsArgumentError,
      );
    });
  });

  group('geometry treats "image" exactly like "rect"', () {
    Content imageContent({List<double> offset = const [10, 20], List<double> size = const [40, 60]}) => Content(
          shape: 'image',
          offset: offset,
          size: size,
          imageSourceType: 'embedded',
          imageData: 'ZmFrZQ==',
        );

    test('shapeBoundingBox matches a rect Content with the same offset/size', () {
      final imageBox = shapeBoundingBox(imageContent());
      final rectBox = shapeBoundingBox(Content(shape: 'rect', offset: [10, 20], size: [40, 60]));
      expect(imageBox.minX, equals(rectBox.minX));
      expect(imageBox.maxX, equals(rectBox.maxX));
      expect(imageBox.minY, equals(rectBox.minY));
      expect(imageBox.maxY, equals(rectBox.maxY));
    });

    test('getContentOutline (no effects) returns the same 4-corner rectangle as a rect layer', () {
      final imageOutline = getContentOutline(imageContent(), null, null);
      final rectOutline = getContentOutline(Content(shape: 'rect', offset: [10, 20], size: [40, 60]), null, null);
      expect(imageOutline, equals(rectOutline));
      expect(imageOutline, hasLength(4));
    });

    test('buildGrid works on image content the same as rect content (no shape switch inside it)', () {
      final grid = buildGrid(imageContent(), 3, 3);
      expect(grid, hasLength(3));
      expect(grid[0], hasLength(3));
      // corners land exactly on the bounding box.
      final box = shapeBoundingBox(imageContent());
      expect(grid[0][0][0], equals(box.minX));
      expect(grid[0][0][1], equals(box.minY));
      expect(grid[2][2][0], equals(box.maxX));
      expect(grid[2][2][1], equals(box.maxY));
    });

    test('an image layer under an active effect gets a deformed outline (same code path as rect)', () {
      final layer = createImageLayer(
        imageSourceType: 'embedded',
        imageData: 'ZmFrZQ==',
        naturalWidth: 100,
        naturalHeight: 100,
      );
      registerBuiltinEffects();
      final inst = createEffectInstance('squeeze_axis', 'e1', layer);
      inst.params['axisX'] = 0.4;
      layer.effectStack.add(inst);
      final undeformed = getContentOutline(layer.content, null, null);
      final deformed = getContentOutline(layer.content, layer, 0);
      expect(deformed, isNot(equals(undeformed)), reason: 'an active effect must actually warp an image layer\'s outline, same as it would a rect');
    });
  });
}
