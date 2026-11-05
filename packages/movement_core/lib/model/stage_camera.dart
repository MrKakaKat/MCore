/// Stage camera: a frame the size of the stage that is moved, turned and
/// resized like any layer (keys, parenting - "link the stage to an
/// object" - timed parenting, animation layers, undo all come with it).
/// What is inside it is what the picture shows: moving the camera right
/// moves the whole scene left, making it bigger zooms out.
library;

import '../core/math.dart';
import '../core/state_cache.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;
import 'project.dart';

/// A new camera covering the whole stage (nothing changes until it moves).
Layer createCameraLayer(double width, double height, {int durationFrames = 180}) => createLayer('rect')
  ..id = 'L_camera_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
  ..name = 'Camera'
  ..color = '#ffc107'
  ..durationFrames = durationFrames
  ..content = Content(shape: 'camera', offset: [0, 0], size: [width, height])
  ..transform.anchor.defaultValue = [0.5, 0.5];

/// The camera the picture is seen through: the first one not hidden.
Layer? activeCamera(Project project) {
  for (final l in project.layers) {
    if (l.content.shape == 'camera' && !l.hidden) return l;
  }
  return null;
}

/// The stage-pixel transform that shows what is inside the camera's frame
/// on the whole picture (null: no camera).
List<double>? cameraViewMatrix(Project project, num globalFrame, double width, double height) {
  final cam = activeCamera(project);
  if (cam == null) return null;
  final m = toFrameMatrix(getLayerStateAt(project, cam.id, globalFrame).matrix);
  // the frame's own content box, centred on its content offset.
  final o = cam.content.offset, s = cam.content.size;
  // output pixel -> camera content-local -> world: m . box(p); invert.
  final toBox = <double>[s[0] / width, 0, 0, s[1] / height, o[0] - s[0] / 2, o[1] - s[1] / 2];
  final world = matMul(m, toBox);
  return invertAffine(world);
}

/// Mirror: the transform (stage px) that carries what the base covers
/// onto the mirror, flipped about the base's own middle - null when the
/// mirror has no (existing) base.
List<double>? mirrorTransform(Project project, Layer mirror, num globalFrame) {
  final base = mirror.mirrorSourceId == null ? null : findLayer(project, mirror.mirrorSourceId);
  if (base == null || identical(base, mirror)) return null;
  final m = toFrameMatrix(getLayerStateAt(project, mirror.id, globalFrame).matrix);
  final b = toFrameMatrix(getLayerStateAt(project, base.id, globalFrame).matrix);
  final c = base.content.offset;
  final sx = mirror.mirrorAxis == 'x' || mirror.mirrorAxis == 'both' ? -1.0 : 1.0;
  final sy = mirror.mirrorAxis == 'y' || mirror.mirrorAxis == 'both' ? -1.0 : 1.0;
  final flip = <double>[sx, 0, 0, sy, c[0] - sx * c[0], c[1] - sy * c[1]];
  return matMul(m, matMul(flip, invertAffine(b)));
}

/// The camera frame's corners on the stage (for drawing its outline).
List<List<double>> cameraFrameCorners(Project project, Layer cam, num globalFrame) {
  final m = toFrameMatrix(getLayerStateAt(project, cam.id, globalFrame).matrix);
  final o = cam.content.offset, s = cam.content.size;
  return [
    for (final (dx, dy) in const [(-1, -1), (1, -1), (1, 1), (-1, 1)]) applyAffine(m, [o[0] + dx * s[0] / 2, o[1] + dy * s[1] / 2])
  ];
}
