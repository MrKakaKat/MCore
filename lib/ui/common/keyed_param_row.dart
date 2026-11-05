import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import 'param_editor.dart';
import 'reset_button.dart';

/// A keyable number on `trk`: its editor at the playhead, reset, and a
/// key toggle at the current frame.
Widget keyedParamRow({
  required AppState app,
  required String prefKey,
  required String label,
  required Track trk,
  required double localFrame,
  required double defaultValue,
  required ParamScale scale,
  Layer? layer,
}) {
  final value = (evaluateTrack(app.project, trk, localFrame, layer) as num).toDouble();
  final frame = localFrame.round();
  final keyed = trk.keyframes.any((k) => k.frame == frame);
  void set(double v) {
    setTrackValueAt(trk, frame, v.clamp(scale.min, scale.max).toDouble());
    app.commitEdit();
  }

  return ParamEditor(
    key: ValueKey('keyed-$prefKey'),
    prefKey: prefKey,
    label: label,
    values: [value],
    scale: scale,
    onEditStart: app.pushUndo,
    onChanged: (v) => set(v.first),
    onCommit: (v) {
      app.pushUndo();
      set(v.first);
    },
    trailing: [
      ResetIconButton(onPressed: () {
        app.pushUndo();
        set(defaultValue);
      }),
      IconButton(
        icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
        tooltip: 'toggle keyframe at current frame',
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        onPressed: () {
          app.pushUndo();
          if (keyed) {
            trk.keyframes.removeWhere((k) => k.frame == frame);
          } else {
            trk.keyframes.add(Keyframe(frame: frame, value: value, temporal: newKeyEasing()));
            trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
          }
          app.commitEdit();
        },
      ),
    ],
  );
}
