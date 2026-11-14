import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../common/num_field.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';

/// Movement tab: free move - see AppState.startFreeMove.
class FreeMoveField extends StatelessWidget {
  final AppState app;
  const FreeMoveField({super.key, required this.app});

  /// Free move: drag the object along its way on the stage; confirmed, it
  /// becomes a key layer of two keys (the curve in their handles).
  @override
  Widget build(BuildContext context) {
    final rec = app.freeMoveRecording;
    return Card(
      key: const ValueKey('free-move-field'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.gesture, size: 18),
            const SizedBox(width: 6),
            const Expanded(child: Text('Free move', style: TextStyle(fontWeight: FontWeight.w600))),
            const Text('takes', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            SizedBox(
              width: 56,
              child: NumField(
                width: 56,
                key: const ValueKey('free-move-seconds'),
                value: app.freeMoveSeconds,
                onCommit: app.setFreeMoveSeconds,
              ),
            ),
            const Text(' s', style: TextStyle(fontSize: 12)),
          ]),
          ParamEditor(
            key: const ValueKey('free-move-smoothing'),
            prefKey: 'keys.free move smoothing',
            label: 'smoothing',
            values: [app.freeMoveSmoothing],
            scale: const ParamScale.slider(0, 1, decimals: 2),
            onEditStart: () {},
            onChanged: (v) => app.setAppPreference('freeMoveSmoothing', v.first.clamp(0.0, 1.0).toDouble()),
            onCommit: (v) => app.setAppPreference('freeMoveSmoothing', v.first.clamp(0.0, 1.0).toDouble()),
            trailing: [ResetIconButton(onPressed: () => app.setAppPreference('freeMoveSmoothing', 0.0))],
          ),
          Text(
              app.freeMoveSmoothing >= 0.999
                  ? 'One smooth curve: two keys.'
                  : app.freeMoveSmoothing == 0
                      ? 'Off: it follows the way as drawn (a key where it takes one, at most one a frame).'
                      : 'The more, the smoother (fewer keys).',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(
              rec
                  ? (app.freeMovePath.length < 2
                      ? 'Drag the object on the stage along its way.'
                      : 'Drag again to draw it anew, or confirm.')
                  : 'Move the object by hand along any curve: it becomes a key layer of two keys, from the playhead.',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 4),
          Row(children: [
            if (!rec)
              OutlinedButton.icon(
                key: const ValueKey('free-move-start'),
                onPressed: app.startFreeMove,
                icon: const Icon(Icons.gesture, size: 16),
                label: const Text('Draw the move'),
              )
            else ...[
              FilledButton.icon(
                key: const ValueKey('free-move-confirm-tab'),
                onPressed: app.freeMovePath.length >= 2 ? app.confirmFreeMove : null,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Confirm'),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: app.cancelFreeMove, child: const Text('Cancel')),
            ],
          ]),
        ]),
      ),
    );
  }

}
