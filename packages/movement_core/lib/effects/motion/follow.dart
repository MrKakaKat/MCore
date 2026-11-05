/// Follow: a layer lazily trails a target layer - while the target moves it
/// lags behind, when the target stops it catches up and settles. A damped
/// spring per followed value (position, rotation, scale), stepped forward
/// frame by frame from the layer's first frame (like the pendulum), cached
/// per frame and re-run only from the first frame whose target changed.
///
///   a = stiffness * (t - x) - damping * v;  v += a dt;  x += v dt
///   (semi-implicit Euler, 4 substeps a frame, dt = 1 / fps)
///
/// The layer's own animation stays on top: the result is its own pose
/// moved by how far the followed point has gone from where the layer
/// started (so nothing jumps at the start), blended by Amount.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../core/interpolation.dart' show evaluateTrack;
import '../../core/stage_size.dart';
import '../../core/state_cache.dart';
import '../../model/project.dart';
import '../../model/project_json.dart' show trackToJson, trackFromJson;

class FollowSettings {
  bool enabled;
  String? targetId;
  bool position, rotation, scale;

  /// Where on the target it aims, px in the target's own space; null: the
  /// follower's own offset on its first frame (no snapping onto it).
  Track? offset;

  /// Speed (stiffness 1..500) and Bounciness (0..100 %: damping ratio 1.0
  /// down to 0.1); with `advanced` the raw damping (0..60) instead.
  Track speed, bounciness, damping;
  bool advanced;

  /// 0..1: the blend between the layer's own pose and the followed one.
  Track amount;

  FollowSettings({
    this.enabled = false,
    this.targetId,
    this.position = true,
    this.rotation = false,
    this.scale = false,
    this.offset,
    Track? speed,
    Track? bounciness,
    Track? damping,
    this.advanced = false,
    Track? amount,
  })  : speed = speed ?? Track(60.0, false),
        bounciness = bounciness ?? Track(30.0, false),
        damping = damping ?? Track(14.0, false),
        amount = amount ?? Track(1.0, false);

  FollowSettings copy() => FollowSettings(
      enabled: enabled,
      targetId: targetId,
      position: position,
      rotation: rotation,
      scale: scale,
      offset: offset == null ? null : cloneTrack(offset!),
      speed: cloneTrack(speed),
      bounciness: cloneTrack(bounciness),
      damping: cloneTrack(damping),
      advanced: advanced,
      amount: cloneTrack(amount));

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'targetId': targetId,
        'position': position,
        'rotation': rotation,
        'scale': scale,
        if (offset != null) 'offset': trackToJson(offset!),
        'speed': trackToJson(speed),
        'bounciness': trackToJson(bounciness),
        'damping': trackToJson(damping),
        if (advanced) 'advanced': true,
        'amount': trackToJson(amount),
      };

  static FollowSettings fromJson(Map<String, dynamic> j) {
    Track? t(String k) => j[k] is Map ? trackFromJson(j[k] as Map<String, dynamic>) : null;
    return FollowSettings(
      enabled: j['enabled'] as bool? ?? false,
      targetId: j['targetId'] as String?,
      position: j['position'] as bool? ?? true,
      rotation: j['rotation'] as bool? ?? false,
      scale: j['scale'] as bool? ?? false,
      offset: t('offset'),
      speed: t('speed'),
      bounciness: t('bounciness'),
      damping: t('damping'),
      advanced: j['advanced'] as bool? ?? false,
      amount: t('amount'),
    );
  }
}

/// Bounciness 0..100 % as a damping ratio (1.0 .. 0.1) -> damping for
/// `stiffness`.
double followDamping(double stiffness, double bounciness) {
  final zeta = 1.0 - 0.9 * (bounciness / 100).clamp(0.0, 1.0);
  return 2 * zeta * math.sqrt(math.max(0, stiffness));
}

/// One spring step over a frame (4 substeps): (x, v) toward `t`.
(double, double) springStep(double x, double v, double t, double stiffness, double damping, double dt) {
  final h = dt / 4;
  for (var i = 0; i < 4; i++) {
    final a = stiffness * (t - x) - damping * v;
    v += a * h;
    x += v * h;
  }
  return (x, v);
}

/// A pose in frame px / degrees.
class _Pose {
  final double x, y, rot, sx, sy;
  const _Pose(this.x, this.y, this.rot, this.sx, this.sy);
  static _Pose of(List<double> m) => _Pose(m[4] * stageSize.width, m[5] * stageSize.height, math.atan2(m[1], m[0]) * 180 / math.pi,
      math.sqrt(m[0] * m[0] + m[1] * m[1]), math.sqrt(m[2] * m[2] + m[3] * m[3]));
  bool same(_Pose o) => x == o.x && y == o.y && rot == o.rot && sx == o.sx && sy == o.sy;
}

class _Cache {
  String sig = '';
  final List<_Pose> targets = [];
  // spring states per frame: x, y, rot, sx, sy and their velocities.
  final List<List<double>> states = [];
}

final Map<String, _Cache> _caches = {};
final Set<String> _busy = {};

/// Whether `layer`'s follow is being worked out right now (its own pose
/// is being read - not the followed one).
bool followBusy(Project project, Layer layer) => _busy.contains('${identityHashCode(project)}|${layer.id}');

/// Forgets every follow cache (tests; a new project).
void clearFollowCaches() => _caches.clear();

/// Whether `layer` following `targetId` would make layers follow each
/// other in a circle.
bool followWouldCycle(Project project, Layer layer, String targetId) {
  String? id = targetId;
  final seen = <String>{};
  while (id != null && seen.add(id)) {
    if (id == layer.id) return true;
    final t = findLayer(project, id);
    if (t == null || !t.follow.enabled) return false;
    id = t.follow.targetId;
  }
  return id != null && id == layer.id;
}

const followCycleMessage = 'This would make layers follow each other in a circle';

/// The follower's matrix at `globalFrame` given its own (`own`) - see the
/// library doc. Called from the state evaluation.
List<double> applyFollow(Project project, Layer layer, num globalFrame, List<double> own) {
  final f = layer.follow;
  final target = f.targetId == null ? null : findLayer(project, f.targetId);
  if (target == null || identical(target, layer)) return own;
  final key = '${identityHashCode(project)}|${layer.id}';
  // a circle (refused when picked, but a restore could bring one): skip.
  if (!_busy.add(key)) return own;
  try {
    final start = layer.startFrame;
    final frame = globalFrame.round().clamp(start, start + layer.durationFrames);
    final local = (globalFrame - start).toDouble();
    final c = _caches[key] ??= _Cache();
    final sig = jsonEncode([f.toJson(), start, layer.durationFrames, stageSize.width, stageSize.height]);
    if (sig != c.sig) {
      c
        ..sig = sig
        ..targets.clear()
        ..states.clear();
    }
    // the follower's own pose where it starts (the follow is relative to it).
    final own0 = _Pose.of(_ownAt(project, layer, start));
    final t0 = _Pose.of(getLayerStateAt(project, target.id, start).matrix);
    // re-run from the first frame whose target pose changed.
    for (var g = start; g <= frame; g++) {
      final i = g - start;
      final p = _Pose.of(getLayerStateAt(project, target.id, g).matrix);
      if (i < c.targets.length) {
        if (c.targets[i].same(p)) continue;
        c.targets.removeRange(i, c.targets.length);
        if (c.states.length > i) c.states.removeRange(i, c.states.length);
      }
      c.targets.add(p);
    }
    // the point aimed at: the target's pose plus the offset in its space.
    List<double> aim(int i) {
      final tp = c.targets[i];
      final lf = i.toDouble();
      List<double> off;
      if (f.offset != null) {
        off = [for (final v in evaluateTrack(project, f.offset!, lf, layer) as List) (v as num).toDouble()];
      } else {
        // the follower's own offset at its start, in the target's space then.
        final r0 = -t0.rot * math.pi / 180;
        final dx = own0.x - t0.x, dy = own0.y - t0.y;
        off = [dx * math.cos(r0) - dy * math.sin(r0), dx * math.sin(r0) + dy * math.cos(r0)];
      }
      final r = tp.rot * math.pi / 180;
      return [
        tp.x + off[0] * math.cos(r) - off[1] * math.sin(r),
        tp.y + off[0] * math.sin(r) + off[1] * math.cos(r),
        own0.rot + (tp.rot - t0.rot),
        own0.sx * (t0.sx == 0 ? 1 : tp.sx / t0.sx),
        own0.sy * (t0.sy == 0 ? 1 : tp.sy / t0.sy),
      ];
    }

    final dt = 1 / (fps <= 0 ? 60 : fps);
    while (c.states.length <= frame - start) {
      final i = c.states.length;
      final t = aim(i);
      if (i == 0) {
        c.states.add([...t, 0, 0, 0, 0, 0]);
        continue;
      }
      final prev = c.states[i - 1];
      final lf = i.toDouble();
      final k = (evaluateTrack(project, f.speed, lf, layer) as num).toDouble().clamp(1.0, 500.0);
      final d = f.advanced
          ? (evaluateTrack(project, f.damping, lf, layer) as num).toDouble().clamp(0.0, 60.0)
          : followDamping(k, (evaluateTrack(project, f.bounciness, lf, layer) as num).toDouble());
      // rotation: the shortest way round.
      var tr = t[2];
      while (tr - prev[2] > 180) {
        tr -= 360;
      }
      while (tr - prev[2] < -180) {
        tr += 360;
      }
      final targets = [t[0], t[1], tr, t[3], t[4]];
      final next = List<double>.filled(10, 0);
      for (var q = 0; q < 5; q++) {
        final (x, v) = springStep(prev[q], prev[q + 5], targets[q], k, d, dt);
        next[q] = x;
        next[q + 5] = v;
      }
      c.states.add(next);
    }
    final s = c.states[frame - start];
    final a = (evaluateTrack(project, f.amount, local.clamp(0, layer.durationFrames.toDouble()), layer) as num).toDouble().clamp(0.0, 1.0);
    if (a == 0) return own;
    final o = _Pose.of(own);
    // the layer's own pose, moved by how far the followed values went.
    final x = f.position ? o.x + a * (s[0] - own0.x) : o.x;
    final y = f.position ? o.y + a * (s[1] - own0.y) : o.y;
    final rot = f.rotation ? o.rot + a * (s[2] - own0.rot) : o.rot;
    final sx = f.scale ? o.sx * (1 + a * ((own0.sx == 0 ? 1 : s[3] / own0.sx) - 1)) : o.sx;
    final sy = f.scale ? o.sy * (1 + a * ((own0.sy == 0 ? 1 : s[4] / own0.sy) - 1)) : o.sy;
    if (!f.rotation && !f.scale) {
      return [own[0], own[1], own[2], own[3], x / stageSize.width, y / stageSize.height];
    }
    final r = rot * math.pi / 180;
    return [math.cos(r) * sx, math.sin(r) * sx, -math.sin(r) * sy, math.cos(r) * sy, x / stageSize.width, y / stageSize.height];
  } finally {
    _busy.remove(key);
  }
}

// the follower's pose without its follow (the state evaluation skips it
// while this layer's key is busy).
List<double> _ownAt(Project project, Layer layer, int frame) => getLayerStateAt(project, layer.id, frame).matrix;

/// Bake Follow to keys: the followed position (and rotation) become keys
/// every frame, thinned while the path stays within 0.5 px; the effect
/// goes off. Layers with a parent keep it (keys in its space are not
/// worked out) - only unparented layers are baked.
bool bakeFollowToKeys(Project project, Layer layer) {
  if (!layer.follow.enabled || layer.parentId != null) return false;
  final pos = <List<double>>[], rots = <double>[];
  for (var f = 0; f <= layer.durationFrames; f++) {
    clearStateCaches();
    final m = getLayerStateAt(project, layer.id, layer.startFrame + f).matrix;
    pos.add([m[4], m[5]]);
    rots.add(math.atan2(m[1], m[0]) * 180 / math.pi);
  }
  final keep = _thin(pos, 0.5 / math.max(1, math.max(stageSize.width, stageSize.height)));
  layer.transform.anchor.keyframes = [for (final i in keep) Keyframe(frame: i, value: [...pos[i]])];
  if (layer.follow.rotation) {
    layer.transform.rotation.keyframes = [for (final i in keep) Keyframe(frame: i, value: rots[i])];
  }
  layer.follow.enabled = false;
  clearStateCaches();
  return true;
}

// frames to keep so straight runs between them stay within `tol`.
List<int> _thin(List<List<double>> p, double tol) {
  final keep = <int>{0, p.length - 1};
  void rec(int a, int b) {
    var worst = -1.0;
    var at = -1;
    for (var i = a + 1; i < b; i++) {
      final t = (i - a) / (b - a);
      final x = p[a][0] + (p[b][0] - p[a][0]) * t, y = p[a][1] + (p[b][1] - p[a][1]) * t;
      final d = math.sqrt(math.pow(p[i][0] - x, 2) + math.pow(p[i][1] - y, 2));
      if (d > worst) {
        worst = d;
        at = i;
      }
    }
    if (worst > tol && at > 0) {
      keep.add(at);
      rec(a, at);
      rec(at, b);
    }
  }

  if (p.length > 2) rec(0, p.length - 1);
  return keep.toList()..sort();
}

/// The point `layer` is aiming at on `globalFrame` (frame px): its
/// target's position plus the Offset in the target's space. Null without
/// a target (debug line on the stage).
List<double>? followAimPoint(Project project, Layer layer, num globalFrame) {
  final f = layer.follow;
  final target = f.targetId == null ? null : findLayer(project, f.targetId);
  if (!f.enabled || target == null || identical(target, layer)) return null;
  final start = layer.startFrame;
  final tp = _Pose.of(getLayerStateAt(project, target.id, globalFrame).matrix);
  List<double> off;
  if (f.offset != null) {
    off = [for (final v in evaluateTrack(project, f.offset!, (globalFrame - start).toDouble(), layer) as List) (v as num).toDouble()];
  } else {
    final key = '${identityHashCode(project)}|${layer.id}';
    _busy.add(key);
    final own0 = _Pose.of(_ownAt(project, layer, start));
    _busy.remove(key);
    final t0 = _Pose.of(getLayerStateAt(project, target.id, start).matrix);
    final r0 = -t0.rot * math.pi / 180;
    final dx = own0.x - t0.x, dy = own0.y - t0.y;
    off = [dx * math.cos(r0) - dy * math.sin(r0), dx * math.sin(r0) + dy * math.cos(r0)];
  }
  final r = tp.rot * math.pi / 180;
  return [tp.x + off[0] * math.cos(r) - off[1] * math.sin(r), tp.y + off[0] * math.sin(r) + off[1] * math.cos(r)];
}
