import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';

/// Filters: colour filters over the selected layer (more to come).
class FiltersView extends StatelessWidget {
  final AppState app;
  const FiltersView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return const Center(child: Text('Select a layer'));
        final trk = layer.filters.negative;
        final lf = layerLocalFrame(layer, app.currentFrame);
        final frame = lf.round();
        final v = (evaluateTrack(app.project, trk, lf, layer) as num).toDouble();
        final keyed = trk.keyframes.any((k) => k.frame == frame);
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            ParamEditor(
              key: const ValueKey('filter-negative'),
              prefKey: 'filters.negative',
              label: 'Negative',
              values: [v * 100],
              scale: const ParamScale.slider(0, 100, decimals: 0, suffix: '%'),
              onEditStart: app.pushUndo,
              onChanged: (x) {
                setTrackValueAt(trk, frame, (x.first / 100).clamp(0.0, 1.0));
                app.commitEdit();
              },
              onCommit: (x) {
                app.pushUndo();
                setTrackValueAt(trk, frame, (x.first / 100).clamp(0.0, 1.0));
                app.commitEdit();
              },
              trailing: [
                ResetIconButton(onPressed: () {
                  app.pushUndo();
                  setTrackValueAt(trk, frame, 0.0);
                  app.commitEdit();
                }),
                IconButton(
                  icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
                  tooltip: 'toggle keyframe at current frame',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    app.pushUndo();
                    if (keyed) {
                      trk.keyframes.removeWhere((k) => k.frame == frame);
                    } else {
                      trk.keyframes.add(Keyframe(frame: frame, value: v, temporal: newKeyEasing()));
                      trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
                    }
                    app.commitEdit();
                  },
                ),
              ],
            ),
            const Hint('Negative: the layer\'s colours inverted (100 %), or part way.'),
          ],
        );
      },
    );
  }
}
