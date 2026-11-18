/// Links outside their time do nothing; the stage shows, as an area,
/// where the layer would be (and how it would be sized) if they worked -
/// following its sources as they are now.
library;

import 'dart:math' as math;

import '../core/math.dart' as mm;
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../geometry/shapes.dart' show getContentOutline;
import 'project.dart';
import 'prop_links.dart';

/// The outline (frame px) `layer` would have at `globalFrame` with its
/// links working; null when they all work now (nothing to show) or it
/// would not change.
List<List<double>>? linkPreviewOutline(Project project, Layer layer, int globalFrame) {
  if (!linkOutOfRange(layer, globalFrame)) return null;
  final st = getLayerStateAt(project, layer.id, globalFrame);
  if (!st.inRange) return null;
  double d(String prop) => layer.links.any((k) => linkHits(k.to, prop)) ? linkOffsetIfWorking(project, layer, prop, globalFrame) : 0;
  final dx = d('x'), dy = d('y'), dr = d('rotation');
  final dsx = d('scaleX') + d('scale.x'), dsy = d('scaleY') + d('scale.y');
  final dL = d('scaleLeft'), dR = d('scaleRight'), dT = d('scaleTop'), dB = d('scaleBottom');
  if ([dx, dy, dr, dsx, dsy, dL, dR, dT, dB].every((v) => v.abs() < 1e-9)) return null;
  final base = getLayerBaseStateAt(project, layer.id, globalFrame);
  final rot = base.baseRot + dr;
  var anchor = [base.anchor[0] + dx / stageSize.width, base.anchor[1] + dy / stageSize.height];
  final scale = [base.scale[0] + dsx + dL + dR, base.scale[1] + dsy + dT + dB];
  if (dL != 0 || dR != 0 || dT != 0 || dB != 0) {
    // as the size-handle links do: the far sides stay.
    final c = layer.content;
    final minX = c.offset[0] - c.size[0] / 2, maxX = c.offset[0] + c.size[0] / 2;
    final minY = c.offset[1] - c.size[1] / 2, maxY = c.offset[1] + c.size[1] / 2;
    final vx = -(dR * minX + dL * maxX), vy = -(dT * minY + dB * maxY);
    final a = rot * math.pi / 180;
    anchor = [
      anchor[0] + (vx * math.cos(a) - vy * math.sin(a)) / stageSize.width,
      anchor[1] + (vx * math.sin(a) + vy * math.cos(a)) / stageSize.height,
    ];
  }
  // what wraps the layer's own pose (its parent; a swing or push on top)
  // stays as it is.
  final parent = mm.matMul(base.baseMatrix, mm.invertAffine(mm.matFromTRS(base.anchor, base.baseRot, base.scale)));
  final over = mm.matMul(st.matrix, mm.invertAffine(base.baseMatrix));
  final m = mm.matMul(over, mm.matMul(parent, mm.matFromTRS(anchor, rot, scale)));
  final f = [m[0], m[1], m[2], m[3], m[4] * stageSize.width, m[5] * stageSize.height];
  final pts = getContentOutline(layer.content, layer, globalFrame, project: project);
  if (pts.length < 2) return null;
  return [for (final p in pts) mm.applyAffine(f, p)];
}

/// The layer's outline (frame px) as it is at `globalFrame`.
List<List<double>> layerOutlineAt(Project project, Layer layer, int globalFrame) {
  final m = getLayerStateAt(project, layer.id, globalFrame).matrix;
  final f = [m[0], m[1], m[2], m[3], m[4] * stageSize.width, m[5] * stageSize.height];
  return [for (final p in getContentOutline(layer.content, layer, globalFrame, project: project)) mm.applyAffine(f, p)];
}
