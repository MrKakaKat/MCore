/// Crop: the geometry behind the Crop tab's canvas handles. A layer's
/// crop is four insets [left, top, right, bottom] as fractions of its
/// content bounding box (see `Layer.crop`); these helpers turn it into a
/// local rect, handle positions and a drag op, with an optional aspect
/// lock.
library;

import 'dart:math' as math;

import '../core/math.dart';
import '../core/state_cache.dart';
import '../geometry/shapes.dart';
import '../core/stage_size.dart';
import '../model/project.dart';
import '../model/track_edit.dart';
import 'drag_ops.dart';
import 'handles.dart';
import 'snapping.dart';

/// While true, the selected layer shows crop handles on the stage instead
/// of its transform box (the Crop tab's "Edit crop on canvas").
bool cropEditing = false;

const cropAspectOptions = ['free', 'original', '1:1', '4:3', '16:9', '9:16'];

// the smallest a cropped side can get, as a fraction of the full box.
const double _minCropFraction = 0.05;

/// Detach a piece (Crop tab): the part to detach set like a crop - four
/// insets of the content box, with the same handles on the stage. Null:
/// the tool is off.
List<double>? pieceInsets;

/// The visible part of the content box, in content-local coordinates
/// (`insets`: another set of insets, e.g. [pieceInsets]).
BoundingBox croppedBox(Layer layer, [List<double>? insets]) {
  final b = shapeBoundingBox(layer.content);
  final w = b.maxX - b.minX, h = b.maxY - b.minY;
  final c = insets ?? layer.crop;
  return BoundingBox(
    minX: b.minX + c[0] * w,
    minY: b.minY + c[1] * h,
    maxX: b.maxX - c[2] * w,
    maxY: b.maxY - c[3] * h,
  );
}

/// The on-screen width/height ratio the aspect setting asks for, or null
/// for a free crop. `displayScale` is the layer's current |scale|, so the
/// ratio holds for what you actually see.
double? cropAspectRatio(Layer layer, List<double> displayScale) {
  switch (layer.cropAspect) {
    case 'original':
      final b = shapeBoundingBox(layer.content);
      final h = (b.maxY - b.minY) * displayScale[1];
      return h <= 0 ? null : (b.maxX - b.minX) * displayScale[0] / h;
    case '1:1':
      return 1;
    case '4:3':
      return 4 / 3;
    case '16:9':
      return 16 / 9;
    case '9:16':
      return 9 / 16;
    default:
      return null;
  }
}

void _setCropRect(Layer layer, double minX, double minY, double maxX, double maxY, {bool piece = false}) {
  final b = shapeBoundingBox(layer.content);
  final w = b.maxX - b.minX, h = b.maxY - b.minY;
  if (w <= 0 || h <= 0) return;
  final next = [
    ((minX - b.minX) / w).clamp(0.0, 1.0),
    ((minY - b.minY) / h).clamp(0.0, 1.0),
    ((b.maxX - maxX) / w).clamp(0.0, 1.0),
    ((b.maxY - maxY) / h).clamp(0.0, 1.0),
  ];
  piece ? pieceInsets = next : layer.crop = next;
}

/// The piece rect (Detach a piece), content-local, as a ring.
List<List<double>> pieceRectRing(Layer layer) {
  final c = croppedBox(layer, pieceInsets ?? const [0.25, 0.25, 0.25, 0.25]);
  return [
    [c.minX, c.minY],
    [c.maxX, c.minY],
    [c.maxX, c.maxY],
    [c.minX, c.maxY],
  ];
}

List<double> _absScale(Project project, Layer layer, int globalFrame) {
  final s = getLayerStateAt(project, layer.id, globalFrame).scale;
  return [math.max(1e-6, s[0].abs()), math.max(1e-6, s[1].abs())];
}

/// Re-fits the crop to `layer.cropAspect`: the largest rect of that ratio
/// inside the full box, centred on the current crop's centre. A free
/// aspect leaves the crop as it is.
void fitCropToAspect(Project project, Layer layer, int globalFrame) {
  final scale = _absScale(project, layer, globalFrame);
  final r = cropAspectRatio(layer, scale);
  if (r == null) return;
  final full = shapeBoundingBox(layer.content);
  final cur = croppedBox(layer);
  final rl = r * scale[1] / scale[0]; // the ratio in local units
  final fw = full.maxX - full.minX, fh = full.maxY - full.minY;
  var w = fw, h = fw / rl;
  if (h > fh) {
    h = fh;
    w = fh * rl;
  }
  final cx = ((cur.minX + cur.maxX) / 2).clamp(full.minX + w / 2, full.maxX - w / 2);
  final cy = ((cur.minY + cur.maxY) / 2).clamp(full.minY + h / 2, full.maxY - h / 2);
  _setCropRect(layer, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2);
}

class CropHandles {
  final BoundingBox full;
  final BoundingBox crop;
  final List<double> mCanvas;
  final Map<String, List<double>> screen;
  CropHandles({required this.full, required this.crop, required this.mCanvas, required this.screen});
}

CropHandles getCropHandles(Project project, Layer layer, int globalFrame, {List<double>? insets}) {
  final full = shapeBoundingBox(layer.content);
  final c = croppedBox(layer, insets);
  final mCanvas = toFrameMatrix(getLayerStateAt(project, layer.id, globalFrame).matrix);
  final midX = (c.minX + c.maxX) / 2, midY = (c.minY + c.maxY) / 2;
  final local = <String, List<double>>{
    'left': [c.minX, midY],
    'right': [c.maxX, midY],
    'top': [midX, c.minY],
    'bottom': [midX, c.maxY],
    'tl': [c.minX, c.minY],
    'tr': [c.maxX, c.minY],
    'br': [c.maxX, c.maxY],
    'bl': [c.minX, c.maxY],
  };
  return CropHandles(
    full: full,
    crop: c,
    mCanvas: mCanvas,
    screen: {for (final e in local.entries) e.key: applyAffine(mCanvas, e.value)},
  );
}

/// Drags one crop handle ('left' | 'right' | 'top' | 'bottom' | 'tl' |
/// 'tr' | 'br' | 'bl'). Corners keep the opposite corner fixed; with an
/// aspect lock, edges keep the rect centred on the other axis.
class CropDragOp implements DragOp {
  final Layer layer;
  final String handle;

  /// Moves the piece rect ([pieceInsets]) instead of the crop.
  final bool piece;
  CropDragOp({required this.layer, required this.handle, this.piece = false});

  @override
  List<SnapGuideLine> get snapGuides => const [];

  @override
  void apply(Project project, int globalFrame, List<double> framePoint) {
    final h = getCropHandles(project, layer, globalFrame, insets: piece ? pieceInsets : null);
    final p = applyAffine(invertAffine(h.mCanvas), framePoint);
    final f = h.full, c = h.crop;
    final fw = f.maxX - f.minX, fh = f.maxY - f.minY;
    final minW = fw * _minCropFraction, minH = fh * _minCropFraction;
    // the quarters (and the middle) of the full box hold the edge a moment.
    final px = snapToStops(p[0].clamp(f.minX, f.maxX).toDouble(), [for (final q in const [0.25, 0.5, 0.75]) f.minX + fw * q], fw * 0.025);
    final py = snapToStops(p[1].clamp(f.minY, f.maxY).toDouble(), [for (final q in const [0.25, 0.5, 0.75]) f.minY + fh * q], fh * 0.025);

    var minX = c.minX, minY = c.minY, maxX = c.maxX, maxY = c.maxY;
    final moveLeft = handle == 'left' || handle == 'tl' || handle == 'bl';
    final moveRight = handle == 'right' || handle == 'tr' || handle == 'br';
    final moveTop = handle == 'top' || handle == 'tl' || handle == 'tr';
    final moveBottom = handle == 'bottom' || handle == 'bl' || handle == 'br';
    if (moveLeft) minX = math.min(px, maxX - minW);
    if (moveRight) maxX = math.max(px, minX + minW);
    if (moveTop) minY = math.min(py, maxY - minH);
    if (moveBottom) maxY = math.max(py, minY + minH);

    final scale = _absScale(project, layer, globalFrame);
    final r = piece ? null : cropAspectRatio(layer, scale);
    if (r != null) {
      final rl = r * scale[1] / scale[0];
      final horizontal = moveLeft || moveRight, vertical = moveTop || moveBottom;
      var w = maxX - minX, hh = maxY - minY;
      if (horizontal && vertical) {
        // corner: the larger change wins, the opposite corner stays put.
        if (w / hh > rl) {
          hh = w / rl;
        } else {
          w = hh * rl;
        }
      } else if (horizontal) {
        hh = w / rl;
      } else {
        w = hh * rl;
      }
      // never larger than the full box.
      final k = math.min(1.0, math.min(fw / w, fh / hh));
      w *= k;
      hh *= k;
      // anchor: the fixed side(s); the free axis stays centred.
      final cx = (c.minX + c.maxX) / 2, cy = (c.minY + c.maxY) / 2;
      if (moveLeft) {
        minX = maxX - w;
      } else if (moveRight) {
        maxX = minX + w;
      } else {
        minX = cx - w / 2;
        maxX = cx + w / 2;
      }
      if (moveTop) {
        minY = maxY - hh;
      } else if (moveBottom) {
        maxY = minY + hh;
      } else {
        minY = cy - hh / 2;
        maxY = cy + hh / 2;
      }
      // slide back inside the full box.
      final dx = math.max(0.0, f.minX - minX) - math.max(0.0, maxX - f.maxX);
      final dy = math.max(0.0, f.minY - minY) - math.max(0.0, maxY - f.maxY);
      minX += dx;
      maxX += dx;
      minY += dy;
      maxY += dy;
    }
    _setCropRect(layer, minX, minY, maxX, maxY, piece: piece);
  }
}

/// How "fit to frame" sizes an object: 'fit' (all of it visible, aspect
/// kept), 'fill' (covers the frame, aspect kept, overflow cut by the
/// frame) or 'stretch' (exactly the frame, aspect may change).
const fitModes = ['fit', 'fill', 'stretch'];

/// Fits the layer's visible (cropped) box to the whole frame at
/// `globalFrame`: centred, unrotated, scaled by `mode`. Writes anchor,
/// scale and rotation through the usual keyframe rule, compensating for
/// the parent's position, scale and rotation so the result is right on
/// screen. Does nothing for an empty box.
void fitLayerToStage(Project project, Layer layer, int globalFrame, String mode) {
  final box = croppedBox(layer);
  final w = box.maxX - box.minX, h = box.maxY - box.minY;
  if (w <= 1e-9 || h <= 1e-9) return;
  final fw = stageSize.width, fh = stageSize.height;
  final kx = fw / w, ky = fh / h;
  final List<double> world = switch (mode) {
    'fill' => [math.max(kx, ky), math.max(kx, ky)],
    'stretch' => [kx, ky],
    _ => [math.min(kx, ky), math.min(kx, ky)],
  };
  // keep a mirrored scale's sign.
  final cur = getLayerStateAt(project, layer.id, globalFrame).scale;
  final sx = world[0] * (cur[0] < 0 ? -1 : 1), sy = world[1] * (cur[1] < 0 ? -1 : 1);
  final cx = (box.minX + box.maxX) / 2, cy = (box.minY + box.maxY) / 2;
  // the anchor (fractions of the frame) that puts the box centre mid-frame.
  final anchorWorld = [(fw / 2 - sx * cx) / fw, (fh / 2 - sy * cy) / fh];

  var anchor = anchorWorld;
  var scale = [sx, sy];
  var rot = 0.0;
  final parent = findLayer(project, layer.parentId);
  if (parent != null) {
    final pm = getLayerStateAt(project, parent.id, globalFrame).matrix;
    anchor = applyAffine(invertAffine(pm), anchorWorld);
    final psx = math.sqrt(pm[0] * pm[0] + pm[1] * pm[1]), psy = math.sqrt(pm[2] * pm[2] + pm[3] * pm[3]);
    if (psx > 1e-9 && psy > 1e-9) scale = [sx / psx, sy / psy];
    rot = -math.atan2(pm[1], pm[0]) * 180 / math.pi;
  }
  final lf = localFrameOf(layer, globalFrame);
  setTrackValueAt(layer.transform.anchor, lf, anchor);
  setTrackValueAt(layer.transform.scale, lf, scale);
  setTrackValueAt(layer.transform.rotation, lf, rot);
  clearStateCaches();
}
