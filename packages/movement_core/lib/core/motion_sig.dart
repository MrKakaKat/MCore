/// One number for what the project's layers' motion depends on (keys,
/// parents, motion effects...), worked out once per state epoch: what is
/// kept from frame to frame (a swing, a follow) is used only while it is
/// unchanged.
library;

import 'dart:convert';

import '../model/project.dart';
import '../ui_geometry/keyframe_strip.dart' show visitLayerTracks;
import 'state_cache.dart' show stateEpoch;

final _sigs = Expando<(int, int)>('motionSig');
var _volatile = 0;

int projectMotionSig(Project project) {
  final c = _sigs[project];
  if (c != null && c.$1 == stateEpoch) return c.$2;
  // contour physics is worked out a little more every frame drawn (no
  // edit in between): nothing kept is trusted while any layer collides.
  if (project.layers.any((l) => l.physics.collide)) {
    final v = Object.hash(stateEpoch, identityHashCode(project), _volatile++);
    _sigs[project] = (stateEpoch, v);
    return v;
  }
  var h = 17;
  void add(Object? o) => h = Object.hash(h, o);
  void addValue(dynamic v) => v is List ? add(Object.hashAll(v)) : add(v);
  for (final l in project.layers) {
    add(l.id);
    add(l.parentId);
    add(l.startFrame);
    add(l.durationFrames);
    add(Object.hash(l.inheritPosition, l.inheritRotation, l.inheritScale, l.parentKeepDifference, l.parentFrom, l.parentUntil,
        l.parentOutside));
    add(Object.hash(l.pendulum.enabled, l.pendulum.frequency, l.pendulum.damping, l.pendulum.sensitivity, l.pendulum.freeze,
        l.pendulum.maxAngle));
    add(Object.hash(l.swing.enabled, l.swing.minAngle, l.swing.maxAngle, l.swing.frequency, l.swing.damping, l.swing.phase));
    add(Object.hash(l.wiggle.enabled, l.wiggle.speed, l.wiggle.amplitude, l.wiggle.wiggleSeed, l.scaleWiggle.enabled,
        l.scaleWiggle.amplitude, l.scaleWiggle.speed, l.scaleWiggle.axes));
    if (l.follow.enabled) add(jsonEncode(l.follow.toJson()).hashCode);
    add(Object.hash(l.follow.enabled, l.physics.collide, l.links.length, l.transform.pathFollow.enabled, l.loopEnabled, l.loopUntil));
    add(Object.hash(Object.hashAll(l.content.size), Object.hashAll(l.content.offset), l.rotateOrigin == null ? 0 : Object.hashAll(l.rotateOrigin!),
        l.scaleOrigin == null ? 0 : Object.hashAll(l.scaleOrigin!)));
    visitLayerTracks(l, (t) {
      addValue(t.defaultValue);
      add(Object.hash(t.loop, t.loopMode, t.loopFrom, t.loopEnd, t.constantSpeed, t.tension));
      for (final k in t.keyframes) {
        add(k.frame);
        addValue(k.value);
        final e = k.temporal;
        add(Object.hash(e.x1, e.y1, e.x2, e.y2, e.over, e.ant, e.amount, e.bounces, e.shaped, e.hold));
        add(Object.hash(Object.hashAll(k.spatialTangent.inTan), Object.hashAll(k.spatialTangent.outTan)));
      }
    });
  }
  _sigs[project] = (stateEpoch, h);
  return h;
}
