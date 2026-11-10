import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/no_layer.dart';

/// Reverse: a video played backwards, and the selected layer's keys
/// mirrored in time per params tab (each a single undo step).
class ReverseView extends StatelessWidget {
  final AppState app;
  const ReverseView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return NoLayer(app: app, text: 'No layer selected');
        final rows = keyDetailRows(layer);
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            if (layer.content.shape == 'video')
              SwitchListTile(
                key: const ValueKey('reverse-video'),
                dense: true,
                title: const Text('Play the video backwards'),
                value: layer.content.playReversed,
                onChanged: (v) {
                  app.pushUndo();
                  layer.content.playReversed = v;
                  app.commitEdit();
                },
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Text('Reverse keys: the animation plays backwards over the layer',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.all(8), child: Text('This layer has no keys.')),
            for (final tab in rows.keys)
              ListTile(
                dense: true,
                title: Text(tab == 'Effects' ? 'Effects (and their time ranges)' : tab),
                subtitle: hint('${rows[tab]!.length} key frames'),
                trailing: OutlinedButton(
                  key: ValueKey('reverse-$tab'),
                  onPressed: () => _reverse(layer, {tab}),
                  child: const Text('Reverse'),
                ),
              ),
            if (rows.length > 1)
              Padding(
                padding: const EdgeInsets.all(8),
                child: FilledButton(
                  key: const ValueKey('reverse-all'),
                  onPressed: () => _reverse(layer, rows.keys.toSet()),
                  child: const Text('Reverse all keys'),
                ),
              ),
          ],
        );
      },
    );
  }

  void _reverse(Layer layer, Set<String> tabs) {
    app.pushUndo();
    reverseLayerKeys(layer, tabs);
    app.commitEdit();
  }
}
