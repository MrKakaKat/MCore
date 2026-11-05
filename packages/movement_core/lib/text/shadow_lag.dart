/// Lagging text shadow: the shadow trails its text on a damped spring
/// (the Follow spring) - one for the whole text, or one per animated unit
/// ("Per letter"). Springs step forward frame by frame from the layer's
/// first frame in world px, kept in flat arrays per frame and re-run only
/// from the first frame whose targets changed.
///
/// The result is how far each spring hangs behind its unit, content-local
/// px: zero at rest, so a still text has its shadow in its usual place.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../core/math.dart' show applyAffine;
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../effects/motion/follow.dart' show followDamping, springStep;
import '../model/project.dart';
import '../model/project_json.dart' show textSpecToJson;
import '../ui_geometry/handles.dart' show toFrameMatrix;
import 'text_animators.dart' show animatedTextUnits;

class _LagCache {
  String sig = '';
  // per local frame: unit centres (content-local, x y ...), world targets
  // (x y ...) and spring states (x y vx vy ...).
  final List<Float64List> centres = [], targets = [], states = [];
}

final Map<String, _LagCache> _lagCaches = {};

/// Forgets every shadow lag (tests; a new project).
void clearShadowLagCaches() => _lagCaches.clear();

/// The unit centres the shadow springs aim at, content-local: one for the
/// whole text, or each animated unit's middle with Per letter.
Float64List _centresAt(Layer layer, TextSpec t, double lf) {
  final c = layer.content;
  if (t.shadow.perLetter) {
    final units = animatedTextUnits(t.atFrame(lf), c.offset, c.size, lf);
    if (units != null) {
      final out = Float64List(units.length * 2);
      for (var i = 0; i < units.length; i++) {
        out[2 * i] = units[i].centre[0];
        out[2 * i + 1] = units[i].centre[1];
      }
      return out;
    }
  }
  return Float64List.fromList([c.offset[0], c.offset[1]]);
}

/// The shadow lag of `layer`'s text at `globalFrame`: x y per unit (one
/// unit unless Per letter), content-local px; null when Lag is off.
Float64List? textShadowLag(Project project, Layer layer, num globalFrame) {
  final t = layer.content.text;
  if (t == null || !t.shadow.enabled || !t.shadow.lag) return null;
  return _shadowLag(project, layer, globalFrame, t.shadow, 'text', jsonEncode(textSpecToJson(t)),
      (lf) => _centresAt(layer, t, lf));
}

/// A shape's shadow lag (Figures tab): one spring at the shape's middle;
/// x y content-local px, null when Lag is off.
Float64List? shapeShadowLag(Project project, Layer layer, num globalFrame) {
  final sh = layer.fill.shadow;
  if (!sh.enabled || !sh.lag) return null;
  final o = layer.content.offset;
  return _shadowLag(project, layer, globalFrame, sh, 'shape', jsonEncode([sh.lagSpeed, sh.lagBounciness, o]),
      (_) => Float64List.fromList([o[0], o[1]]));
}

Float64List _shadowLag(Project project, Layer layer, num globalFrame, TextShadowSpec sh, String kind, String specSig,
    Float64List Function(double localFrame) centresAt) {
  final start = layer.startFrame;
  final frame = globalFrame.round().clamp(start, start + layer.durationFrames);
  final key = '${identityHashCode(project)}|${layer.id}|$kind';
  final c = _lagCaches[key] ??= _LagCache();
  final sig = jsonEncode([specSig, start, layer.durationFrames, stageSize.width, stageSize.height, fps]);
  if (sig != c.sig) {
    c
      ..sig = sig
      ..centres.clear()
      ..targets.clear()
      ..states.clear();
  }
  final n = frame - start;
  for (var i = c.centres.length; i <= n; i++) {
    c.centres.add(centresAt(i.toDouble()));
  }
  // world targets; re-run from the first frame that moved.
  for (var i = 0; i <= n; i++) {
    final m = toFrameMatrix(getLayerStateAt(project, layer.id, start + i).matrix);
    final ce = c.centres[i];
    final w = Float64List(ce.length);
    for (var u = 0; u < ce.length; u += 2) {
      final p = applyAffine(m, [ce[u], ce[u + 1]]);
      w[u] = p[0];
      w[u + 1] = p[1];
    }
    if (i < c.targets.length) {
      final old = c.targets[i];
      var same = old.length == w.length;
      for (var j = 0; same && j < w.length; j++) {
        same = old[j] == w[j];
      }
      if (same) continue;
      c.targets.removeRange(i, c.targets.length);
      if (c.states.length > i) c.states.removeRange(i, c.states.length);
    }
    c.targets.add(w);
  }
  final k = sh.lagSpeed.clamp(1.0, 500.0).toDouble();
  final d = followDamping(k, sh.lagBounciness);
  final dt = 1 / (fps <= 0 ? 60 : fps);
  while (c.states.length <= n) {
    final i = c.states.length;
    final w = c.targets[i];
    final units = w.length ~/ 2;
    final s = Float64List(units * 4);
    final prev = i == 0 ? null : c.states[i - 1];
    for (var u = 0; u < units; u++) {
      // a fresh unit (or the first frame) starts on its target, still.
      if (prev == null || prev.length != s.length) {
        s[4 * u] = w[2 * u];
        s[4 * u + 1] = w[2 * u + 1];
        continue;
      }
      final (x, vx) = springStep(prev[4 * u], prev[4 * u + 2], w[2 * u], k, d, dt);
      final (y, vy) = springStep(prev[4 * u + 1], prev[4 * u + 3], w[2 * u + 1], k, d, dt);
      s[4 * u] = x;
      s[4 * u + 1] = y;
      s[4 * u + 2] = vx;
      s[4 * u + 3] = vy;
    }
    c.states.add(s);
  }
  // spring - target, world -> content-local (the linear part's inverse).
  final m = toFrameMatrix(getLayerStateAt(project, layer.id, frame).matrix);
  final det = m[0] * m[3] - m[1] * m[2];
  final s = c.states[n], w = c.targets[n];
  final out = Float64List(w.length);
  for (var u = 0; u < w.length; u += 2) {
    final ex = s[2 * u] - w[u], ey = s[2 * u + 1] - w[u + 1];
    if (det.abs() < 1e-12) continue;
    out[u] = (m[3] * ex - m[2] * ey) / det;
    out[u + 1] = (-m[1] * ex + m[0] * ey) / det;
  }
  return out;
}
