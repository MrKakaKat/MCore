/// Stage rectangle selection: what kind a layer counts as (for the
/// rectangle's "leave out" filters) and the box it covers in the frame.
library;

import 'dart:math' as math;

import '../core/math.dart' show applyAffine;
import '../geometry/shapes.dart' show getContentOutline;
import '../model/line_path.dart' show isNodeLine, lineFramePoints;
import '../model/project.dart';
import 'handles.dart' show getTransformBoxHandles;

/// The kinds the rectangle can leave out, with their names.
const marqueeKinds = <String, String>{
  'rect': 'Rectangles',
  'circle': 'Circles',
  'triangle': 'Triangles',
  'ngon': 'Polygons',
  'polygon': 'SVG shapes',
  'compound': 'Merged shapes',
  'line': 'Lines',
  'text': 'Text',
  'image': 'Photos',
  'video': 'Videos',
  'projectRef': 'Projects',
};

/// The kind `l` counts as for the rectangle's filters.
String marqueeKind(Layer l) {
  final s = l.content.shape;
  if (s == 'textGroup') return 'text';
  return s;
}

/// `l`'s box in the frame (minX, minY, maxX, maxY) at `globalFrame`, or
/// null when it has nothing to cover.
(double, double, double, double)? layerFrameBounds(Project project, Layer l, int globalFrame) {
  List<List<double>> pts;
  if (isNodeLine(l.content)) {
    pts = lineFramePoints(project, l, globalFrame);
  } else {
    final m = getTransformBoxHandles(project, l, globalFrame).mCanvas;
    pts = [for (final p in getContentOutline(l.content, l, globalFrame, project: project)) applyAffine(m, p)];
  }
  if (pts.isEmpty) return null;
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final p in pts) {
    x0 = math.min(x0, p[0]);
    y0 = math.min(y0, p[1]);
    x1 = math.max(x1, p[0]);
    y1 = math.max(y1, p[1]);
  }
  return (x0, y0, x1, y1);
}
