/// Contour physics, stage 1: collision push without inertia.
///
/// Layers with Collide on in the same group can't overlap: animating one
/// into another pushes it. A pushed layer's final position is its keyed
/// pose plus an induced offset that persists (once pushed, it stays
/// pushed); the user's keys stay as they are. The result depends on the
/// frame before, so it is baked frame by frame and cached; an edit
/// re-bakes from the first frame it changes.
///
/// Solver, per frame and group:
/// 1. candidates = keyed pose(f) + induced(f-1);
/// 2. every armed, overlapping pair (SAT on the convex hulls of the layers'
///    contours) is separated along the contact normal by the depth + gap,
///    split by inverse weight (Immovable takes none);
/// 3. step 2 repeats a fixed number of times (8) - chains (A pushes B
///    pushes C) settle without recursion;
/// 4. a layer moving more than half its smallest size in one frame splits
///    the frame into substeps (keyed position interpolated), so fast
///    pushers don't pass through;
/// 5. induced(f) = resolved - keyed(f).
///
/// Choices made here (stage 1):
/// - Collision uses each layer's CONVEX HULL of its contour (exact for
///   convex shapes; a concave silhouette collides as its hull). Raster
///   contours come from the app's extraction (the same rings Outline
///   draws), not a distance field.
/// - Substeps interpolate the keyed TRANSLATION; rotation / scale are the
///   frame's own (a pendulum's swing between two frames isn't
///   interpolated).
/// - Only positions change; rotation never does.
/// - A pair that overlaps when it becomes active is not armed (they pass
///   through each other) until the first frame they are apart.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/interpolation.dart' show evaluateTrack;
import '../core/math.dart' as mm;
import '../core/stage_size.dart';
import 'convex_decomp.dart';
import '../effects/builtins/bend_arc.dart' show bendCollisionLookup;
import '../model/line_path.dart' show isNodeLine, lineCollisionRings;
import '../core/state_cache.dart';
import '../geometry/contour_layer.dart' show layerVectorRings;
import '../model/project.dart';
import '../model/project_json.dart' show trackToJson, pendulumToJson, swingToJson, wiggleToJson, effectInstanceToJson;
import '../ui_geometry/handles.dart' show toFrameMatrix;
import '../ui_geometry/keyframe_strip.dart' show visitLayerTracks;

/// A layer's contour rings in its content-local space (outer rings are
/// what collide), or null while not known (e.g. a picture's contour still
/// being extracted).
typedef ContourRingsProvider = List<List<List<double>>>? Function(Project project, Layer layer, int globalFrame);

/// One contact of a frame (debug view): where, which way B was pushed
/// from A, and whether it was against an Immovable that a pendulum
/// swings into (the swing passes through).
class PhysicsContact {
  final String a, b;
  final List<double> point, normal;
  final bool blocked;
  const PhysicsContact(this.a, this.b, this.point, this.normal, {this.blocked = false});
}

class _Frame {
  final Map<String, List<double>> induced;
  final Map<String, List<double>> keyed; // keyed translations (frame px)
  final Set<String> armed; // pair keys
  final Set<String> touching; // layers in contact this frame
  final List<PhysicsContact> contacts;
  // contact normals kept per touching pair (from the pair's first id to
  // its second), so a corner contact doesn't flip faces frame to frame.
  final Map<String, List<double>> normals;
  final String sig;

  /// How the push moved each object this frame (inertia carries it on).
  final Map<String, List<double>> velocity;

  /// Bends that give under a push (bend's `react`): angle (degrees) and
  /// its speed (degrees per frame), springing back to 0.
  final Map<String, List<double>> bend;
  _Frame(this.induced, this.keyed, this.armed, this.touching, this.contacts, this.normals, this.sig,
      [this.velocity = const {}, this.bend = const {}]);
}

class PhysicsWorld {
  PhysicsWorld(this.project);
  final Project project;

  /// Where contours come from (the app gives the extracted ones for
  /// pictures); defaults to vector geometry.
  ContourRingsProvider rings = (p, l, f) =>
      isNodeLine(l.content) ? lineCollisionRings(l.content, frame: layerLocalFrame(l, f)) : layerVectorRings(p, l, f);

  /// Solver iterations per (sub)step.
  int iterations = 8;

  final List<_Frame> _frames = [];
  // the previous bake's frames, shown past the re-baked ones until they
  // are re-baked too (an edit doesn't flash the unpushed state).
  List<_Frame> _stale = const [];
  // the last bake that reached the end of every colliding layer: the
  // timeline markers and the pushed path come from it (never a mix of an
  // old and a new bake).
  List<_Frame>? _complete;
  String? _projectSig;

  /// The frame every colliding layer has ended by.
  int get endFrame => [for (final l in _colliders) l.startFrame + l.durationFrames].fold(0, math.max);

  /// Whether the bake has reached [endFrame].
  bool get complete => _frames.length > endFrame;

  _Frame? _shown(int f) {
    if (f < 0) return null;
    if (f < _frames.length) return _frames[f];
    if (f < _stale.length) return _stale[f];
    return null;
  }

  int get _shownLength => math.max(_frames.length, _stale.length);

  /// Frames baked so far: 0..bakedUntil (-1 when none).
  int get bakedUntil => _frames.length - 1;

  /// Frames baked in the last second (HUD).
  final List<int> _bakeTimes = [];
  int get framesPerSecond {
    final now = DateTime.now().millisecondsSinceEpoch;
    _bakeTimes.removeWhere((t) => now - t > 1000);
    return _bakeTimes.length;
  }

  /// Whether any layer has Collide on.
  bool get active => project.layers.any((l) => l.physics.collide);

  /// The induced offset (frame px) of a colliding layer at `frame`; a
  /// frame not baked yet holds the last baked one.
  List<double>? offsetAt(String layerId, int frame) {
    final n = _shownLength;
    if (n == 0) return null;
    return _shown(frame.clamp(0, n - 1))!.induced[layerId];
  }

  List<PhysicsContact> contactsAt(int frame) => _shown(frame)?.contacts ?? const [];

  /// The extra bend angle (degrees) a push gave `layerId` at `frame`; a
  /// frame not baked yet holds the last baked one.
  double bendAt(String layerId, int frame) {
    final n = _shownLength;
    if (n == 0) return 0;
    return _shown(frame.clamp(0, n - 1))!.bend[layerId]?[0] ?? 0;
  }

  // the layer's bend that gives under pushes, with its react 0..1.
  static (EffectInstance, double)? _reactBend(Layer l, int localFrame) {
    for (final i in l.effectStack) {
      if (!i.enabled || i.effectId != 'bend_arc' || !i.params.containsKey('axisAngle')) continue;
      final r = i.params['react'];
      final v = r is Track ? (evaluateTrack(null, r, localFrame.toDouble()) as num).toDouble() : 0.0;
      if (v > 0) return (i, (v / 100).clamp(0.0, 1.0));
    }
    return null;
  }

  /// Frames where `layerId` starts or stops touching another (timeline
  /// markers), inside the layer's own range only; a contact still going
  /// at the end of what is baked gets its end marker only once the bake
  /// has reached the layer's end.
  List<int> contactMarkers(String layerId) {
    final layer = findLayer(project, layerId);
    if (layer == null) return const [];
    final first = math.max(0, layer.startFrame);
    // past the last key of any layer nothing moves: a touch still going
    // then ends with the animation, not with the layer.
    final last = math.min(layer.startFrame + layer.durationFrames, _animationEnd ?? 1 << 30);
    final frames = _complete ?? _frames;
    final out = <int>[];
    var was = false;
    final n = math.min(frames.length - 1, last);
    for (var f = first; f <= n; f++) {
      final now = frames[f].touching.contains(layerId);
      if (now != was) out.add(now ? f : f - 1);
      was = now;
    }
    if (was && n >= last) out.add(last);
    return out;
  }

  // the last keyed frame (project time) of any layer; null without keys.
  int? get _animationEnd {
    int? end;
    for (final l in project.layers) {
      visitLayerTracks(l, (t) {
        for (final k in t.keyframes) {
          final f = l.startFrame + k.frame;
          if (end == null || f > end!) end = f;
        }
      });
    }
    return end;
  }

  /// Inertia (timeline): where the layer slides on after a push - from
  /// the frame contact ended to the frame it comes to rest - inside its
  /// own range, from the last complete bake.
  List<(int, int)> inertiaSpans(String layerId) {
    final layer = findLayer(project, layerId);
    if (layer == null || layer.physics.inertia <= 0) return const [];
    final frames = _complete ?? _frames;
    final first = math.max(0, layer.startFrame);
    final last = math.min(frames.length - 1, layer.startFrame + layer.durationFrames);
    final out = <(int, int)>[];
    int? start;
    for (var f = first; f <= last; f++) {
      final fr = frames[f];
      final v = fr.velocity[layerId];
      final sliding = !fr.touching.contains(layerId) && v != null && (v[0].abs() + v[1].abs()) > 0.05;
      if (sliding && start == null) start = f - 1;
      if (!sliding && start != null) {
        out.add((start, f - 1));
        start = null;
      }
    }
    if (start != null && last > start) out.add((start, last));
    return out;
  }

  /// The push at `frame` from the last complete bake (the pushed path),
  /// else what is shown.
  List<double>? completeOffsetAt(String layerId, int frame) {
    final frames = _complete;
    if (frames == null || frames.isEmpty) return offsetAt(layerId, frame);
    return frames[frame.clamp(0, frames.length - 1)].induced[layerId];
  }

  /// Re-bakes from `frame` on (an edit there); until then the old frames
  /// are still shown.
  void invalidateFrom(int frame) {
    if (frame >= _frames.length) return;
    // the marks never show a layout that's gone: until the new bake is
    // through they come from the frames already re-baked.
    _complete = null;
    if (_frames.length >= _stale.length) _stale = [..._frames];
    _frames.removeRange(math.max(0, frame), _frames.length);
  }

  /// Forgets everything (old frames too).
  void reset() {
    _frames.clear();
    _stale = const [];
    _complete = null;
    _projectSig = null;
  }

  /// Bakes up to `frame`; with a `budget`, stops when it runs out.
  /// Returns whether `frame` is baked.
  bool bakeTo(int frame, {Duration? budget}) {
    final sw = Stopwatch()..start();
    _suspend(() {
      _checkEdits(frame, sw, budget);
      while (_frames.length <= frame) {
        _frames.add(_solveFrame(_frames.length));
        _bakeTimes.add(DateTime.now().millisecondsSinceEpoch);
        if (budget != null && sw.elapsed > budget) break;
      }
      // fully re-baked: the old frames are no longer needed.
      if (_frames.length >= _stale.length) _stale = const [];
      if (complete) _complete = List.of(_frames);
    });
    return _frames.length > frame;
  }

  // keyed poses are read with the physics offsets off.
  void _suspend(void Function() f) {
    final was = physicsSuspended;
    physicsSuspended = true;
    clearStateCaches();
    try {
      f();
    } finally {
      physicsSuspended = was;
      clearStateCaches();
    }
  }

  /// Something changed: re-bake from the first frame whose inputs differ
  /// (frames before stay bit-identical).
  void _checkEdits(int upTo, Stopwatch sw, Duration? budget) {
    final sig = _wholeSig();
    if (sig == _projectSig) return;
    _projectSig = sig;
    final n = math.min(_frames.length, upTo + 1);
    for (var f = 0; f < n; f++) {
      // out of time: what isn't checked yet is re-baked.
      if (_frames[f].sig != _frameSig(f) || (budget != null && sw.elapsed > budget)) {
        invalidateFrom(f);
        return;
      }
    }
    // frames past upTo weren't checked: drop them.
    invalidateFrom(n);
  }

  // what physics depends on, cheap enough to compare every render.
  String _wholeSig() => jsonEncode([
        project.stageWalls,
        for (final l in project.layers)
          [
            l.id, l.parentId, l.startFrame, l.durationFrames, l.physics.toJson(),
            trackToJson(l.transform.anchor), trackToJson(l.transform.rotation), trackToJson(l.transform.scale),
            pendulumToJson(l.pendulum), swingToJson(l.swing), wiggleToJson(l.wiggle),
            l.content.shape, l.content.size, l.content.offset, l.content.text?.text,
            // effect params too: a bend / fold changes the contour.
            [for (final i in l.effectStack) effectInstanceToJson(i)],
          ]
      ]);

  List<Layer> get _colliders => [for (final l in project.layers) if (l.physics.collide) l];

  String _frameSig(int f) {
    final b = StringBuffer();
    for (final l in _colliders) {
      final s = getLayerStateAt(project, l.id, f);
      final r = rings(project, l, f);
      b
        ..write(l.id)
        ..write(s.inRange)
        ..write(s.matrix.join(','))
        ..write(jsonEncode(l.physics.toJson()))
        ..write(r == null ? 'none' : '${r.length}:${r.isEmpty ? '' : r.first.length}:${_ringHash(r)}');
    }
    return b.toString();
  }

  _Frame _solveFrame(int f) {
    final prev = f > 0 ? _frames[f - 1] : null;
    final induced = <String, List<double>>{
      if (prev != null) for (final e in prev.induced.entries) e.key: [...e.value],
    };
    final keyedT = <String, List<double>>{};
    final armed = <String>{};
    final touching = <String>{};
    final contacts = <PhysicsContact>[];
    // layers held by an Immovable this frame (rotate logic: else they
    // go back to how they were).
    final againstFixed = <String>{};
    final normals = <String, List<double>>{if (prev != null) ...prev.normals};
    final groups = <String, List<_Body>>{};
    // bends giving under pushes: last frame's angle springs back toward 0.
    final bend = <String, List<double>>{};
    // per layer: its react, the bend's normal (frame space, unit) and arm.
    final reacts = <String, (double, List<double>, double)>{};
    for (final l in _colliders) {
      final rb = _reactBend(l, layerLocalFrame(l, f).round());
      if (rb == null) continue;
      final (inst, react) = rb;
      final was = prev?.bend[l.id] ?? const [0.0, 0.0];
      double at(String k, double d) {
        final v = inst.params[k];
        return v is Track ? (evaluateTrack(null, v, layerLocalFrame(l, f).toDouble()) as num).toDouble() : d;
      }

      final freq = at('frequency', 2).clamp(0.05, 30.0);
      final zeta = 0.03 + 0.97 * at('damping', 30).clamp(0.0, 100.0) / 100;
      final w = 2 * math.pi * freq / fps; // per frame
      var vel = was[1] + (-w * w * was[0] - 2 * zeta * w * was[1]);
      final ang = was[0] + vel;
      bend[l.id] = [ang, vel];
      // the bend's normal in the frame and the free part's length.
      final s0 = getLayerStateAt(project, l.id, f);
      final m = toFrameMatrix(s0.matrix);
      final a = at('axisAngle', -90) * math.pi / 180;
      final ux = math.cos(a), uy = math.sin(a);
      final nx = -uy, ny = ux;
      final wx = m[0] * nx + m[2] * ny, wy = m[1] * nx + m[3] * ny;
      final wl = math.sqrt(wx * wx + wy * wy);
      final box = l.content.size;
      final k = math.sqrt((m[0] * m[3] - m[1] * m[2]).abs());
      final reach = ((box[0] / 2 * ux).abs() + (box[1] / 2 * uy).abs()) * 2 * k;
      final arm = math.max(1.0, reach * (1 - at('start', 0.25).clamp(0.0, 1.0)));
      reacts[l.id] = (react, wl < 1e-9 ? [0.0, 0.0] : [wx / wl, wy / wl], arm);
    }
    // a push on such a layer: partly into its bend (the static side stays).
    void push(String id, List<double> off, double dx, double dy) {
      final r = reacts[id];
      if (r == null) {
        off[0] += dx;
        off[1] += dy;
        return;
      }
      final (react, nrm, arm) = r;
      off[0] += dx * (1 - react);
      off[1] += dy * (1 - react);
      final along = (dx * nrm[0] + dy * nrm[1]) * react;
      final dAng = along / arm * 180 / math.pi;
      final b = bend[id]!;
      b[0] += dAng;
      b[1] += dAng;
    }
    for (final l in _colliders) {
      induced[l.id] ??= [0, 0];
      final s = getLayerStateAt(project, l.id, f);
      final m = toFrameMatrix(s.matrix);
      keyedT[l.id] = [m[4], m[5]];
      if (!s.inRange) continue;
      final r = rings(project, l, f);
      if (r == null || r.isEmpty) continue;
      final hull = _hullOf(l.id, r);
      if (hull.length < 3) continue;
      // shrunk to keep turning (rotate logic 'size'): the size it had.
      final was = prev?.induced[l.id];
      final sc = was != null && was.length > 2 ? was[2] : 1.0;
      if (l.physics.rotateLogic == 'size' && induced[l.id]!.length < 3) induced[l.id]!.add(sc);
      final body = _Body(l, [m[0] * sc, m[1] * sc, m[2] * sc, m[3] * sc], hull, prev?.keyed[l.id] ?? [m[4], m[5]], [m[4], m[5]],
          prevOffset: prev?.induced[l.id] ?? const [0.0, 0.0], parts: _partsOf(l.id, r));
      // inertia: last frame's push carries on, a little slower.
      final k = l.physics.immovable ? 0.0 : l.physics.inertia.clamp(0.0, 0.99);
      final v = prev?.velocity[l.id];
      if (k > 0 && v != null) {
        induced[l.id]![0] += v[0] * k;
        induced[l.id]![1] += v[1] * k;
      }
      // leash: pulled toward its point once past the leash's length (a
      // spring: with inertia it swings back and settles).
      final ph = l.physics;
      if (ph.leash && !ph.immovable) {
        final off = induced[l.id]!;
        final px = m[4] + off[0], py = m[5] + off[1];
        final dx = ph.leashPoint[0] - px, dy = ph.leashPoint[1] - py;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > ph.leashLength && d > 1e-9) {
          final pull = (d - ph.leashLength) * ph.leashStrength.clamp(0.0, 1.0);
          off[0] += dx / d * pull;
          off[1] += dy / d * pull;
        }
      }
      (groups[l.physics.group] ??= []).add(body);
    }
    for (final bodies in groups.values) {
      // substeps: no step moves anything more than half the smallest body
      // of the group (a fast pusher can't jump over a thin target).
      var steps = 1;
      final smallest = bodies.map((b) => b.minSize).fold(double.infinity, math.min);
      for (final b in bodies) {
        final dx = b.t1[0] - b.t0[0], dy = b.t1[1] - b.t0[1];
        final move = math.sqrt(dx * dx + dy * dy);
        final half = smallest / 2;
        if (half > 0 && move > half) steps = math.max(steps, (move / half).ceil());
      }
      steps = steps.clamp(1, 256);
      for (var s = 1; s <= steps; s++) {
        final a = s / steps;
        for (final b in bodies) {
          b.place([b.t0[0] + (b.t1[0] - b.t0[0]) * a, b.t0[1] + (b.t1[1] - b.t0[1]) * a]);
        }
        // arming: a pair that is apart arms; a pair already armed stays.
        for (var i = 0; i < bodies.length; i++) {
          for (var j = i + 1; j < bodies.length; j++) {
            final key = _pairKey(bodies[i].layer.id, bodies[j].layer.id);
            if (armed.contains(key)) continue;
            if (prev != null && prev.armed.contains(key)) {
              armed.add(key);
              continue;
            }
            final inner = _innerPair(bodies[i], induced[bodies[i].layer.id]!, bodies[j], induced[bodies[j].layer.id]!);
            if (inner != null) {
              // inside a hollow one: armed once wholly inside.
              final (h, oh, o, oo) = inner;
              if (_inner(h, oh, o, oo, 0) == null) armed.add(key);
              continue;
            }
            final hit = _sat(bodies[i], induced[bodies[i].layer.id]!, bodies[j], induced[bodies[j].layer.id]!, 0);
            if (hit == null) armed.add(key);
          }
        }
        for (var it = 0; it < iterations; it++) {
          var moved = false;
          for (var i = 0; i < bodies.length; i++) {
            for (var j = i + 1; j < bodies.length; j++) {
              final A = bodies[i], B = bodies[j];
              if (!armed.contains(_pairKey(A.layer.id, B.layer.id))) continue;
              final gap = math.max(A.layer.physics.gap, B.layer.physics.gap);
              final offA = induced[A.layer.id]!, offB = induced[B.layer.id]!;
              final key = _pairKey(A.layer.id, B.layer.id);
              // one inside a hollow one: it hits the walls from within.
              final inner = _innerPair(A, offA, B, offB);
              if (inner != null) {
                final (h, oh, o, oo) = inner;
                final hit = _inner(h, oh, o, oo, gap);
                if (hit == null) continue;
                final wH = h.layer.physics.immovable ? double.infinity : h.layer.physics.weight;
                final wO = o.layer.physics.immovable ? double.infinity : o.layer.physics.weight;
                if (wH.isInfinite && wO.isInfinite) continue;
                final shareH = wH.isInfinite ? 0.0 : (wO.isInfinite ? 1.0 : wO / (wH + wO));
                final n = hit.$1, d = hit.$2;
                // the wall is pushed outward, the one inside back in.
                push(h.layer.id, oh, n[0] * d * shareH, n[1] * d * shareH);
                push(o.layer.id, oo, -n[0] * d * (1 - shareH), -n[1] * d * (1 - shareH));
                moved = true;
                if (s == steps) {
                  touching
                    ..add(A.layer.id)
                    ..add(B.layer.id);
                  if (h.layer.physics.immovable) againstFixed.add(o.layer.id);
                  if (o.layer.physics.immovable) againstFixed.add(h.layer.id);
                  contacts.add(PhysicsContact(h.layer.id, o.layer.id, o.support(n, oo), n));
                }
                continue;
              }
              final hit = _contact(A, offA, B, offB, gap, normals[key], A.layer.id.compareTo(B.layer.id) < 0);
              if (hit == null) continue;
              // turning into an Immovable with rotate logic 'size': it
              // shrinks instead of being pushed off.
              final shrinkB = A.layer.physics.immovable && B.layer.physics.rotateLogic == 'size' && !B.layer.physics.immovable;
              final shrinkA = B.layer.physics.immovable && A.layer.physics.rotateLogic == 'size' && !A.layer.physics.immovable;
              if (shrinkA || shrinkB) {
                final body = shrinkB ? B : A, off = shrinkB ? offB : offA;
                // toward the Immovable: -n for B, +n for A.
                final dir = shrinkB ? [-hit.$1[0], -hit.$1[1]] : hit.$1;
                final reach = body.reach(dir);
                if (reach > 1e-6) {
                  final k = ((reach - hit.$2) / reach).clamp(0.2, 1.0);
                  body.rescale(k);
                  off[2] = (off.length > 2 ? off[2] : 1.0) * k;
                  moved = true;
                  if (s == steps) {
                    touching
                      ..add(A.layer.id)
                      ..add(B.layer.id);
                    againstFixed.add(body.layer.id);
                    contacts.add(PhysicsContact(A.layer.id, B.layer.id, A.support(hit.$1, offA), hit.$1));
                  }
                  continue;
                }
              }
              // soft: a part of the depth each frame (deeper: more), once.
              final soft = math.max(A.layer.physics.softness, B.layer.physics.softness).clamp(0.0, 0.95);
              if (soft > 0 && it > 0) continue;
              // kept for the next steps / frames, from the pair's first id.
              normals[key] = A.layer.id.compareTo(B.layer.id) < 0 ? hit.$1 : [-hit.$1[0], -hit.$1[1]];
              final wA = A.layer.physics.immovable ? double.infinity : A.layer.physics.weight;
              final wB = B.layer.physics.immovable ? double.infinity : B.layer.physics.weight;
              if (wA.isInfinite && wB.isInfinite) continue;
              // A moves by B's share, B by A's (inverse weight).
              final shareA = wA.isInfinite ? 0.0 : (wB.isInfinite ? 1.0 : wB / (wA + wB));
              final shareB = 1 - shareA;
              final n = hit.$1;
              var d = hit.$2 * (1 - soft);
              // soft never lets them pass through: at most a third of the
              // smaller one stays sunk in.
              if (soft > 0) {
                final maxSink = math.min(A.minSize, B.minSize) / 3;
                if (hit.$2 - d > maxSink) d = hit.$2 - maxSink;
              }
              push(A.layer.id, offA, -n[0] * d * shareA, -n[1] * d * shareA);
              push(B.layer.id, offB, n[0] * d * shareB, n[1] * d * shareB);
              moved = true;
              if (s == steps) {
                touching
                  ..add(A.layer.id)
                  ..add(B.layer.id);
                if (A.layer.physics.immovable) againstFixed.add(B.layer.id);
                if (B.layer.physics.immovable) againstFixed.add(A.layer.id);
                final blocked = (A.layer.pendulum.enabled && B.layer.physics.immovable) ||
                    (B.layer.pendulum.enabled && A.layer.physics.immovable);
                contacts.add(PhysicsContact(A.layer.id, B.layer.id, A.support(n, offA), n, blocked: blocked));
              }
            }
          }
          if (project.stageWalls && _walls(bodies, induced)) moved = true;
          if (!moved) break;
        }
      }
      // touching at rest (gap reached, nothing to push): still a contact.
      for (var i = 0; i < bodies.length; i++) {
        for (var j = i + 1; j < bodies.length; j++) {
          final A = bodies[i], B = bodies[j];
          if (!armed.contains(_pairKey(A.layer.id, B.layer.id))) continue;
          final gap = math.max(A.layer.physics.gap, B.layer.physics.gap) + 0.5;
          final inner = _innerPair(A, induced[A.layer.id]!, B, induced[B.layer.id]!);
          final touches = inner != null
              ? _inner(inner.$1, inner.$2, inner.$3, inner.$4, gap) != null
              : _sat(A, induced[A.layer.id]!, B, induced[B.layer.id]!, gap) != null;
          if (touches) {
            touching
              ..add(A.layer.id)
              ..add(B.layer.id);
          }
        }
      }
    }
    // rotate logic, free again: back to its size / place, a little each
    // frame.
    for (final l in _colliders) {
      final ph = l.physics;
      if (ph.rotateLogic == 'none' || !ph.rotateReturn || againstFixed.contains(l.id)) continue;
      final off = induced[l.id];
      if (off == null) continue;
      if (ph.rotateLogic == 'size' && off.length > 2) {
        off[2] += (1 - off[2]) * 0.2;
        if ((1 - off[2]).abs() < 1e-3) off[2] = 1;
      } else if (ph.rotateLogic == 'position') {
        off[0] *= 0.8;
        off[1] *= 0.8;
        if (off[0].abs() < 0.05) off[0] = 0;
        if (off[1].abs() < 0.05) off[1] = 0;
      }
    }
    // a pair that came apart forgets its normal.
    normals.removeWhere((key, _) {
      final ids = key.split('|');
      return !(touching.contains(ids[0]) && touching.contains(ids[1]) && armed.contains(key));
    });
    // pairs stay armed while both exist (the ones not checked this frame
    // - a layer out of range - drop).
    final velocity = <String, List<double>>{
      for (final e in induced.entries)
        e.key: [e.value[0] - (prev?.induced[e.key]?[0] ?? 0), e.value[1] - (prev?.induced[e.key]?[1] ?? 0)]
    };
    return _Frame(induced, keyedT, armed, touching, contacts, normals, _frameSig(f), velocity, bend);
  }

  /// A pair where one is hollow and the other's middle is inside it:
  /// (hollow, its offset, the other, its offset); else null.
  static (_Body, List<double>, _Body, List<double>)? _innerPair(_Body a, List<double> offA, _Body b, List<double> offB) {
    if (a.layer.physics.hollow == b.layer.physics.hollow) return null;
    final (h, oh, o, oo) = a.layer.physics.hollow ? (a, offA, b, offB) : (b, offB, a, offA);
    final c = o.centre(oo);
    if (!_insideHull(h.world, oh, c)) return null;
    return (h, oh, o, oo);
  }

  static bool _insideHull(List<List<double>> hull, List<double> off, List<double> p) {
    var inside = false;
    for (var i = 0, j = hull.length - 1; i < hull.length; j = i++) {
      final a = [hull[i][0] + off[0], hull[i][1] + off[1]], b = [hull[j][0] + off[0], hull[j][1] + off[1]];
      if ((a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
    }
    return inside;
  }

  /// The one inside `o` against the hollow `h`'s walls from within: the
  /// deepest wall it reaches past (its outward normal, how far + gap);
  /// null while wholly inside.
  static (List<double>, double)? _inner(_Body h, List<double> oh, _Body o, List<double> oo, double gap) {
    final w = h.world;
    final n = w.length;
    if (n < 3) return null;
    var cx = 0.0, cy = 0.0;
    for (final p in w) {
      cx += p[0];
      cy += p[1];
    }
    cx /= n;
    cy /= n;
    (List<double>, double)? best;
    for (var i = 0; i < n; i++) {
      final p = w[i], q = w[(i + 1) % n];
      var nx = q[1] - p[1], ny = -(q[0] - p[0]);
      final l = math.sqrt(nx * nx + ny * ny);
      if (l < 1e-9) continue;
      nx /= l;
      ny /= l;
      // outward: away from the middle.
      if ((cx - p[0]) * nx + (cy - p[1]) * ny > 0) {
        nx = -nx;
        ny = -ny;
      }
      final wall = (p[0] + oh[0]) * nx + (p[1] + oh[1]) * ny;
      var reach = -double.infinity;
      for (final r in o.world) {
        reach = math.max(reach, (r[0] + oo[0]) * nx + (r[1] + oo[1]) * ny);
      }
      final pen = reach - wall + gap;
      if (pen > 1e-9 && (best == null || pen > best.$2)) best = ([nx, ny], pen);
    }
    return best;
  }

  /// The frame's edges as walls: a pushable object past one is pushed
  /// back inside. Returns whether anything moved.
  bool _walls(List<_Body> bodies, Map<String, List<double>> induced) {
    var moved = false;
    final w = stageSize.width, h = stageSize.height;
    for (final b in bodies) {
      if (b.layer.physics.immovable) continue;
      final off = induced[b.layer.id]!;
      var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
      for (final p in b.world) {
        x0 = math.min(x0, p[0] + off[0]);
        x1 = math.max(x1, p[0] + off[0]);
        y0 = math.min(y0, p[1] + off[1]);
        y1 = math.max(y1, p[1] + off[1]);
      }
      double fix(double lo, double hi, double max) => hi - lo > max ? 0 : (lo < 0 ? -lo : (hi > max ? max - hi : 0));
      final dx = fix(x0, x1, w), dy = fix(y0, y1, h);
      if (dx.abs() > 1e-9 || dy.abs() > 1e-9) {
        off[0] += dx;
        off[1] += dy;
        moved = true;
      }
    }
    return moved;
  }

  /// The contact of a pair: null when apart; else the normal (A to B) and
  /// depth. A touching pair keeps its normal (`stored`, from the pair's
  /// first id; `aFirst`: A is that one) unless another face is clearly
  /// shallower (below 0.8x - hysteresis); a first contact takes the face
  /// the pair was still apart on a frame before, the latest to close
  /// (the face actually hit); exact ties go to the axis closest to the
  /// relative motion, then to x.
  (List<double>, double)? _contact(
      _Body a, List<double> offA, _Body b, List<double> offB, double gap, List<double>? stored, bool aFirst) {
    if (a.multi || b.multi) return _contactParts(a, offA, b, offB, gap, stored, aFirst);
    final axes = _overlaps(a.world, offA, b.world, offB, gap);
    if (axes == null) return null;
    final ca = a.centre(offA), cb = b.centre(offB);
    List<double> orient(List<double> n) =>
        (cb[0] - ca[0]) * n[0] + (cb[1] - ca[1]) * n[1] < 0 ? [-n[0], -n[1]] : n;
    // the axis of least penetration.
    var least = axes.first;
    for (final x in axes) {
      if (x.$2 < least.$2 - 1e-9) least = x;
    }
    if (stored != null) {
      final n = aFirst ? stored : [-stored[0], -stored[1]];
      final pa = _project(a.world, n[0], n[1], offA), pb = _project(b.world, n[0], n[1], offB);
      final keep = math.min(pa.$2, pb.$2) - math.max(pa.$1, pb.$1) + gap;
      if (keep > 1e-9 && !(least.$2 < 0.8 * keep)) return (n, keep);
      if (keep <= 1e-9) return null;
      return (orient(least.$1), least.$2);
    }
    // first contact: which faces were apart a frame before.
    final prevA = a.placedAt(a.t0), prevB = b.placedAt(b.t0);
    final before = _overlaps(prevA, a.prevOffset, prevB, b.prevOffset, gap, all: true)!;
    (List<double>, double)? hit;
    var latest = -double.infinity;
    for (var k = 0; k < axes.length; k++) {
      final was = before[k].$2, now = axes[k].$2;
      if (was > 1e-9 || now <= was) continue;
      final t = -was / (now - was); // when this face closed
      if (t > latest + 1e-12) {
        latest = t;
        hit = axes[k];
      } else if ((t - latest).abs() <= 1e-12 && hit != null) {
        hit = _tieBreak(hit, axes[k], a, b);
      }
    }
    if (hit == null) {
      // already overlapping: least penetration, ties by motion.
      hit = least;
      for (final x in axes) {
        if ((x.$2 - least.$2).abs() <= 1e-9) hit = _tieBreak(hit!, x, a, b);
      }
    }
    return (orient(hit!.$1), hit.$2);
  }

  static (List<double>, double) _tieBreak((List<double>, double) p, (List<double>, double) q, _Body a, _Body b) {
    // relative motion of B against A over the frame.
    final rx = (b.t1[0] - b.t0[0]) - (a.t1[0] - a.t0[0]), ry = (b.t1[1] - b.t0[1]) - (a.t1[1] - a.t0[1]);
    final dp = (p.$1[0] * rx + p.$1[1] * ry).abs(), dq = (q.$1[0] * rx + q.$1[1] * ry).abs();
    if ((dp - dq).abs() > 1e-9) return dp > dq ? p : q;
    return p.$1[0].abs() >= q.$1[0].abs() ? p : q;
  }

  /// Every separating-axis candidate (edge normals of both hulls) with
  /// its overlap (+ gap); null as soon as one separates them, unless
  /// `all` (then separated axes come back with their negative overlap).
  static List<(List<double>, double)>? _overlaps(
      List<List<double>> pa, List<double> offA, List<List<double>> pb, List<double> offB, double gap,
      {bool all = false}) {
    final out = <(List<double>, double)>[];
    for (final poly in [pa, pb]) {
      for (var i = 0; i < poly.length; i++) {
        final p = poly[i], q = poly[(i + 1) % poly.length];
        var nx = q[1] - p[1], ny = -(q[0] - p[0]);
        final len = math.sqrt(nx * nx + ny * ny);
        if (len < 1e-12) continue;
        nx /= len;
        ny /= len;
        final x = _project(pa, nx, ny, offA), y = _project(pb, nx, ny, offB);
        final overlap = math.min(x.$2, y.$2) - math.max(x.$1, y.$1) + gap;
        if (overlap <= 1e-9 && !all) return null;
        out.add(([nx, ny], overlap));
      }
    }
    return out;
  }

  // hulls per layer, kept while its rings are the same object (the
  // contour cache hands back the same rings for the same contour).
  final Map<String, (Object, List<List<double>>)> _hulls = {};
  // a cheap fingerprint of the rings (a bend moves points in the middle,
  // not just the first one).
  static String _ringHash(List<List<List<double>>> r) {
    var h = 0.0;
    var k = 1;
    for (final ring in r) {
      for (final p in ring) {
        h += (p[0] * 31.7 + p[1] * 17.3) * k;
        k = k % 97 + 1;
      }
    }
    return h.toStringAsFixed(3);
  }

  List<List<double>> _hullOf(String id, List<List<List<double>>> rings) {
    final have = _hulls[id];
    if (have != null && identical(have.$1, rings)) return have.$2;
    final hull = convexHull([for (final ring in rings) ...ring]);
    _hulls[id] = (rings, hull);
    return hull;
  }

  // convex parts per layer, kept while its rings are the same object.
  final Map<String, (Object, List<ConvexPart>?)> _parts = {};
  List<ConvexPart>? _partsOf(String id, List<List<List<double>>> rings) {
    final have = _parts[id];
    if (have != null && identical(have.$1, rings)) return have.$2;
    final parts = convexParts(rings);
    // one part: the hull itself (exactly as before).
    final out = parts.length <= 1 ? null : parts;
    _parts[id] = (rings, out);
    return out;
  }

  /// Concave layers: the deepest contact over their convex parts' pairs
  /// (only where the parts' boxes meet). The face normal prefers the
  /// outline's own edges (never a seam between two parts); a touching
  /// pair keeps its stored normal unless another face is clearly
  /// shallower, as for whole hulls.
  static (List<double>, double)? _contactParts(
      _Body a, List<double> offA, _Body b, List<double> offB, double gap, List<double>? stored, bool aFirst) {
    (List<double>, double)? best;
    for (final pa in a.worldParts) {
      for (final pb in b.worldParts) {
        if (!_boxesMeet(pa.points, offA, pb.points, offB, gap)) continue;
        final hit = _partContact(pa, offA, pb, offB, gap, stored == null ? null : (aFirst ? stored : [-stored[0], -stored[1]]));
        if (hit != null && (best == null || hit.$2 > best.$2)) best = hit;
      }
    }
    return best;
  }

  static (List<double>, double)? _satParts(_Body a, List<double> offA, _Body b, List<double> offB, double gap) {
    (List<double>, double)? best;
    for (final pa in a.worldParts) {
      for (final pb in b.worldParts) {
        if (!_boxesMeet(pa.points, offA, pb.points, offB, gap)) continue;
        final hit = _partContact(pa, offA, pb, offB, gap, null);
        if (hit != null && (best == null || hit.$2 > best.$2)) best = hit;
      }
    }
    return best;
  }

  static bool _boxesMeet(List<List<double>> a, List<double> offA, List<List<double>> b, List<double> offB, double gap) {
    final xa = _project(a, 1, 0, offA), xb = _project(b, 1, 0, offB);
    if (math.min(xa.$2, xb.$2) - math.max(xa.$1, xb.$1) + gap <= 1e-9) return false;
    final ya = _project(a, 0, 1, offA), yb = _project(b, 0, 1, offB);
    return math.min(ya.$2, yb.$2) - math.max(ya.$1, yb.$1) + gap > 1e-9;
  }

  /// SAT between two convex parts: null when apart, else the normal
  /// (A to B) and depth - least penetration over the outline's edges
  /// (seams only if nothing else), or the stored normal while it holds.
  static (List<double>, double)? _partContact(
      ConvexPart pa, List<double> offA, ConvexPart pb, List<double> offB, double gap, List<double>? stored) {
    (List<double>, double)? least, leastAny;
    for (final (poly, edges) in [(pa.points, pa.boundary), (pb.points, pb.boundary)]) {
      for (var i = 0; i < poly.length; i++) {
        final p = poly[i], q = poly[(i + 1) % poly.length];
        var nx = q[1] - p[1], ny = -(q[0] - p[0]);
        final len = math.sqrt(nx * nx + ny * ny);
        if (len < 1e-12) continue;
        nx /= len;
        ny /= len;
        final x = _project(pa.points, nx, ny, offA), y = _project(pb.points, nx, ny, offB);
        final overlap = math.min(x.$2, y.$2) - math.max(x.$1, y.$1) + gap;
        if (overlap <= 1e-9) return null;
        if (leastAny == null || overlap < leastAny.$2 - 1e-9) leastAny = ([nx, ny], overlap);
        if (edges[i] && (least == null || overlap < least.$2 - 1e-9)) least = ([nx, ny], overlap);
      }
    }
    var hit = least ?? leastAny!;
    if (stored != null) {
      final x = _project(pa.points, stored[0], stored[1], offA), y = _project(pb.points, stored[0], stored[1], offB);
      final keep = math.min(x.$2, y.$2) - math.max(x.$1, y.$1) + gap;
      if (keep > 1e-9 && !(hit.$2 < 0.8 * keep)) return (stored, keep);
    }
    // from A's part toward B's.
    double cx(List<List<double>> poly, int k) => poly.map((p) => p[k]).reduce((a, b) => a + b) / poly.length;
    final dx = cx(pb.points, 0) + offB[0] - cx(pa.points, 0) - offA[0], dy = cx(pb.points, 1) + offB[1] - cx(pa.points, 1) - offA[1];
    if (dx * hit.$1[0] + dy * hit.$1[1] < 0) hit = ([-hit.$1[0], -hit.$1[1]], hit.$2);
    return hit;
  }

  static String _pairKey(String a, String b) => a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  /// SAT between two placed hulls shifted by their offsets, with `gap`:
  /// null when apart, else the normal (from A to B) and the depth.
  static (List<double>, double)? _sat(_Body a, List<double> offA, _Body b, List<double> offB, double gap) {
    if (a.multi || b.multi) return _satParts(a, offA, b, offB, gap);
    var best = double.infinity;
    List<double>? axis;
    for (final poly in [a.world, b.world]) {
      for (var i = 0; i < poly.length; i++) {
        final p = poly[i], q = poly[(i + 1) % poly.length];
        var nx = q[1] - p[1], ny = -(q[0] - p[0]);
        final len = math.sqrt(nx * nx + ny * ny);
        if (len < 1e-12) continue;
        nx /= len;
        ny /= len;
        final pa = _project(a.world, nx, ny, offA), pb = _project(b.world, nx, ny, offB);
        final overlap = math.min(pa.$2, pb.$2) - math.max(pa.$1, pb.$1) + gap;
        if (overlap <= 1e-9) return null;
        if (overlap < best) {
          best = overlap;
          axis = [nx, ny];
        }
      }
    }
    if (axis == null) return null;
    final ca = a.centre(offA), cb = b.centre(offB);
    if ((cb[0] - ca[0]) * axis[0] + (cb[1] - ca[1]) * axis[1] < 0) axis = [-axis[0], -axis[1]];
    return (axis, best);
  }

  static (double, double) _project(List<List<double>> poly, double nx, double ny, List<double> off) {
    var lo = double.infinity, hi = -double.infinity;
    final shift = off[0] * nx + off[1] * ny;
    for (final p in poly) {
      final v = p[0] * nx + p[1] * ny + shift;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    return (lo, hi);
  }
}

class _Body {
  _Body(this.layer, this.linear, this.hull, this.t0, this.t1, {this.prevOffset = const [0.0, 0.0], this.parts}) {
    place(t1);
    var lo = double.infinity;
    for (final ax in [
      [1.0, 0.0],
      [0.0, 1.0]
    ]) {
      final pr = PhysicsWorld._project(world, ax[0], ax[1], const [0, 0]);
      lo = math.min(lo, pr.$2 - pr.$1);
    }
    minSize = lo;
  }
  final Layer layer;
  final List<double> linear; // the keyed pose without translation
  final List<List<double>> hull; // content-local
  final List<double> t0, t1; // keyed translation at the previous / this frame
  final List<double> prevOffset; // the induced offset a frame before
  List<List<double>> world = const [];
  double minSize = 0;

  /// A concave layer's convex parts (content-local; null: one part, the
  /// hull) and where they are now.
  final List<ConvexPart>? parts;
  List<ConvexPart> worldParts = const [];
  bool get multi => parts != null;

  List<double> _t = const [0.0, 0.0];

  /// Shrinks (or grows) it about its own pivot by `k`.
  void rescale(double k) {
    for (var i = 0; i < 4; i++) {
      linear[i] *= k;
    }
    place(_t);
  }

  /// How far it reaches from its pivot along `n` (unit).
  double reach(List<double> n) {
    var best = 0.0;
    for (final p in world) {
      best = math.max(best, (p[0] - _t[0]) * n[0] + (p[1] - _t[1]) * n[1]);
    }
    return best;
  }

  void place(List<double> t) {
    _t = t;
    world = placedAt(t);
    final ps = parts;
    if (ps == null) {
      // one part: the hull (against a concave layer's parts).
      worldParts = [ConvexPart(world, List.filled(world.length, true))];
    } else {
      worldParts = [
        for (final p in ps)
          ConvexPart([
            for (final q in p.points)
              [linear[0] * q[0] + linear[2] * q[1] + t[0], linear[1] * q[0] + linear[3] * q[1] + t[1]]
          ], p.boundary)
      ];
    }
  }

  List<List<double>> placedAt(List<double> t) => [
        for (final p in hull)
          [linear[0] * p[0] + linear[2] * p[1] + t[0], linear[1] * p[0] + linear[3] * p[1] + t[1]]
      ];

  List<double> centre(List<double> off) {
    var x = 0.0, y = 0.0;
    for (final p in world) {
      x += p[0];
      y += p[1];
    }
    return [x / world.length + off[0], y / world.length + off[1]];
  }

  /// The hull's farthest point along `n` (a contact point for the debug
  /// view).
  List<double> support(List<double> n, List<double> off) {
    var best = world.first;
    var bv = -double.infinity;
    for (final p in world) {
      final v = p[0] * n[0] + p[1] * n[1];
      if (v > bv) {
        bv = v;
        best = p;
      }
    }
    return [best[0] + off[0], best[1] + off[1]];
  }
}

/// Convex hull (monotone chain), counter-clockwise.
List<List<double>> convexHull(List<List<double>> points) {
  final pts = [...points]..sort((a, b) => a[0] != b[0] ? a[0].compareTo(b[0]) : a[1].compareTo(b[1]));
  if (pts.length < 3) return pts;
  double cross(List<double> o, List<double> a, List<double> b) =>
      (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  final lower = <List<double>>[], upper = <List<double>>[];
  for (final p in pts) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in pts.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  return [...lower.sublist(0, lower.length - 1), ...upper.sublist(0, upper.length - 1)];
}

final Expando<PhysicsWorld> _worlds = Expando('physics');

/// The project's physics world (made on first use).
PhysicsWorld physicsWorldOf(Project project) => _worlds[project] ??= PhysicsWorld(project);

/// Wires the state evaluation to the physics offsets (once).
void enablePhysicsOffsets() {
  bendCollisionLookup ??= (project, layer, frame) =>
      layer.physics.collide ? (_worlds[project]?.bendAt(layer.id, frame) ?? 0) : 0;
  physicsOffsetLookup ??= (project, layerId, frame) {
    final layer = findLayer(project, layerId);
    if (layer == null || !layer.physics.collide) return null;
    final w = _worlds[project];
    return w?.offsetAt(layerId, frame);
  };
}

/// "Bake push to keys": the push of every layer of `layer`'s group
/// becomes normal position keys (one per frame where needed, then thinned
/// while the path stays within 0.5 px), and Collide goes off for all of
/// them - baking one alone would let the others, no longer pushed back by
/// it, walk into it. Call inside an undo step. Returns the layers baked.
List<Layer> bakePushToKeys(Project project, PhysicsWorld world, Layer layer) {
  final group = [
    for (final l in project.layers)
      if (l.physics.collide && l.physics.group == layer.physics.group) l
  ];
  final end = group.map((l) => l.startFrame + l.durationFrames).fold(0, math.max);
  world.bakeTo(end);
  // every layer's path first, while all of them still collide.
  final paths = {for (final l in group) l: _pushedPath(project, world, l)};
  paths.forEach((l, samples) {
    l.transform.anchor.keyframes
      ..clear()
      ..addAll([for (final f in _thin(samples)) Keyframe(frame: f, value: samples[f]!)]);
    l.physics.collide = false;
  });
  world.reset();
  return group;
}

/// The layer's anchor value per local frame with its push added (in the
/// parent's space; anchor units are fractions of the stage).
Map<int, List<double>> _pushedPath(Project project, PhysicsWorld world, Layer layer) {
  final samples = <int, List<double>>{};
  physicsSuspended = true;
  clearStateCaches();
  try {
    for (var f = layer.startFrame; f <= layer.startFrame + layer.durationFrames; f++) {
      final off = world.offsetAt(layer.id, f) ?? const [0.0, 0.0];
      final local = f - layer.startFrame;
      final keyed = evaluateTrack(project, layer.transform.anchor, local.toDouble(), layer) as List<double>;
      final pm = parentMatrixFor(project, layer, f);
      final inv = mm.invertAffine([pm[0], pm[1], pm[2], pm[3], 0, 0]);
      final d = mm.applyAffine(inv, [off[0] / stageSize.width, off[1] / stageSize.height]);
      samples[local] = [keyed[0] + d[0], keyed[1] + d[1]];
    }
  } finally {
    physicsSuspended = false;
    clearStateCaches();
  }
  return samples;
}

/// The frames to keep: one only where a straight line between its kept
/// neighbours would miss by more than 0.5 px.
List<int> _thin(Map<int, List<double>> samples) {
  final frames = samples.keys.toList()..sort();
  final keep = <int>[frames.first];
  var i = 0;
  while (i < frames.length - 1) {
    var j = frames.length - 1;
    for (; j > i + 1; j--) {
      final a = samples[frames[i]]!, b = samples[frames[j]]!;
      var ok = true;
      for (var k = i + 1; k < j && ok; k++) {
        final t = (frames[k] - frames[i]) / (frames[j] - frames[i]);
        final p = samples[frames[k]]!;
        final ex = (a[0] + (b[0] - a[0]) * t - p[0]) * stageSize.width;
        final ey = (a[1] + (b[1] - a[1]) * t - p[1]) * stageSize.height;
        ok = ex * ex + ey * ey <= 0.25;
      }
      if (ok) break;
    }
    keep.add(frames[j]);
    i = j;
  }
  return keep;
}
