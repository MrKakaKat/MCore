/// Snapping, text letters: a text dragged near another text snaps letter
/// to letter by their real outlines (not the text boxes) - a letter's
/// middle onto a letter's middle (a "T" lands exactly in the "T" of
/// "Text"), and a letter's edge onto the edge of a letter beside it (one
/// touching the other's top, bottom or side).
library;

import 'dart:math' as math;

import '../core/state_cache.dart';
import '../core/math.dart' show applyAffine;
import '../geometry/shapes.dart' show BoundingBox;
import '../model/project.dart';
import '../text/open_type_font.dart' show PathCmd;
import '../text/text_layout.dart';
import 'handles.dart' show toFrameMatrix;

/// Snapping settings: letter middles / letter edges of texts.
bool snapTextCentersEnabled = true;
bool snapTextEdgesEnabled = true;

/// The outline box of each visible letter of text layer `l` at
/// `globalFrame`, frame px (null: not a text).
List<BoundingBox>? textLetterFrameBoxes(Project project, Layer l, int globalFrame) {
  final spec = l.content.text;
  if (l.content.shape != 'text' || spec == null) return null;
  final shown = spec.atFrame(layerLocalFrame(l, globalFrame));
  final layout = layoutText(shown, l.content.offset, l.content.size);
  final m = toFrameMatrix(getLayerStateAt(project, l.id, globalFrame).matrix);
  final out = <BoundingBox>[];
  for (final g in layout.glyphs) {
    if (g.cmdEnd <= g.cmdStart) continue; // a space
    final b = _inkBox(layout.path.sublist(g.cmdStart, g.cmdEnd));
    if (b == null) continue;
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final c in [
      [b.minX, b.minY],
      [b.maxX, b.minY],
      [b.maxX, b.maxY],
      [b.minX, b.maxY],
    ]) {
      final p = applyAffine(m, c);
      x0 = math.min(x0, p[0]);
      x1 = math.max(x1, p[0]);
      y0 = math.min(y0, p[1]);
      y1 = math.max(y1, p[1]);
    }
    out.add(BoundingBox(minX: x0, maxX: x1, minY: y0, maxY: y1));
  }
  return out;
}

/// The box of an outline: its points and its curves (sampled - a curve's
/// control points lie outside the ink).
BoundingBox? _inkBox(List<PathCmd> cmds) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  void add(double x, double y) {
    x0 = math.min(x0, x);
    x1 = math.max(x1, x);
    y0 = math.min(y0, y);
    y1 = math.max(y1, y);
  }

  var cx = 0.0, cy = 0.0;
  for (final c in cmds) {
    final p = c.p;
    if (p.length == 2) {
      add(p[0], p[1]);
    } else if (p.length == 4) {
      // quadratic: (cx, cy) -> control -> end
      for (var i = 1; i <= 8; i++) {
        final t = i / 8, u = 1 - t;
        add(u * u * cx + 2 * u * t * p[0] + t * t * p[2], u * u * cy + 2 * u * t * p[1] + t * t * p[3]);
      }
    } else if (p.length == 6) {
      for (var i = 1; i <= 8; i++) {
        final t = i / 8, u = 1 - t;
        add(u * u * u * cx + 3 * u * u * t * p[0] + 3 * u * t * t * p[2] + t * t * t * p[4],
            u * u * u * cy + 3 * u * u * t * p[1] + 3 * u * t * t * p[3] + t * t * t * p[5]);
      }
    }
    if (p.length >= 2) {
      cx = p[p.length - 2];
      cy = p[p.length - 1];
    }
  }
  if (x0 == double.infinity) return null;
  return BoundingBox(minX: x0, maxX: x1, minY: y0, maxY: y1);
}

/// One letter snap: `own` (a point / a value of the dragged text) onto
/// `target`. Middles move both axes; an edge one axis (`axis` 0: x, 1: y).
class TextLetterSnap {
  final bool middle;
  final int axis;
  final List<double> own, target;
  TextLetterSnap.middle(this.own, this.target)
      : middle = true,
        axis = -1;
  TextLetterSnap.edge(this.axis, double ownValue, double targetValue, List<double> at)
      : middle = false,
        own = axis == 0 ? [ownValue, at[1]] : [at[0], ownValue],
        target = axis == 0 ? [targetValue, at[1]] : [at[0], targetValue];
}

/// What the dragged text's letters (`own`, already where the drag puts
/// them) can snap onto among `others`' letters: middles onto middles,
/// edges against the facing edges of letters beside them (overlapping on
/// the other axis).
List<TextLetterSnap> textLetterSnaps(List<BoundingBox> own, List<List<BoundingBox>> others, double reach) {
  final out = <TextLetterSnap>[];
  for (final o in own) {
    final oc = [(o.minX + o.maxX) / 2, (o.minY + o.maxY) / 2];
    for (final boxes in others) {
      for (final t in boxes) {
        final tc = [(t.minX + t.maxX) / 2, (t.minY + t.maxY) / 2];
        if (snapTextCentersEnabled) out.add(TextLetterSnap.middle(oc, tc));
        if (!snapTextEdgesEnabled) continue;
        final overlapY = o.minY <= t.maxY + reach && t.minY <= o.maxY + reach;
        final overlapX = o.minX <= t.maxX + reach && t.minX <= o.maxX + reach;
        if (overlapY) {
          // side by side: one's right edge on the other's left.
          out
            ..add(TextLetterSnap.edge(0, o.maxX, t.minX, oc))
            ..add(TextLetterSnap.edge(0, o.minX, t.maxX, oc));
        }
        if (overlapX) {
          // one on top of the other: bottom on top, top on bottom.
          out
            ..add(TextLetterSnap.edge(1, o.maxY, t.minY, oc))
            ..add(TextLetterSnap.edge(1, o.minY, t.maxY, oc));
        }
      }
    }
  }
  return out;
}
