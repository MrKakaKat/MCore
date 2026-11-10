import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';

/// Objects: the layer as a thing with two sides - turn it over, put
/// another picture on its back (within its bounds), give it a contour.
class ObjectsView extends StatelessWidget {
  final AppState app;
  const ObjectsView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return const Center(child: Text('Select a layer'));
        void edit(VoidCallback change) {
          app.pushUndo();
          change();
          app.commitEdit();
        }

        // what can go on the back: any other picture / shape (not a back
        // side already, not this layer's own parts).
        final candidates = [
          for (final l in app.project.layers)
            if (l.id != layer.id &&
                !isAudioShape(l.content.shape) &&
                !isCameraShape(l.content.shape) &&
                !app.project.layers.any((o) => o.id != layer.id && o.backSourceId == l.id))
              l
        ];
        final back = layer.backSourceId != null
            ? 'layer:${layer.backSourceId}'
            : layer.backSame
                ? 'same'
                : 'through';
        final outline = layer.effectStack.where((i) => i.effectId == 'outline').firstOrNull;
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            SwitchListTile(
              key: const ValueKey('objects-turn-over'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.flip),
              title: const Text('Turned over'),
              subtitle: hint('The layer flipped about its vertical middle: its back side shows. Turn it over to '
                  'place a picture on the back, then back again'),
              value: layer.showBack,
              onChanged: (v) => edit(() => layer.showBack = v),
            ),
            const Divider(),
            const Text('Back side', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            DropdownButton<String>(
              key: const ValueKey('objects-back'),
              isExpanded: true,
              value: back,
              items: [
                const DropdownMenuItem(value: 'through', child: Text('The front, seen from behind')),
                const DropdownMenuItem(value: 'same', child: Text('The same as the front')),
                for (final l in candidates)
                  DropdownMenuItem(
                      value: 'layer:${l.id}', child: Text('Picture: ${l.name}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) {
                if (v == null) return;
                edit(() {
                  layer.backSourceId = v.startsWith('layer:') ? v.substring(6) : null;
                  layer.backSame = v == 'same';
                  // placing it: shown turned over, so the picture is put
                  // where it will be seen.
                  if (v.startsWith('layer:')) layer.showBack = true;
                });
              },
            ),
            const Hint('A picture on the back is drawn only there - within this layer\'s shape, where it lies '
                'over the turned-over layer (move it while turned over to place it). Folded origami flaps show '
                'the back too.'),
            if (layer.backSourceId != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('objects-back-select'),
                  onPressed: () => app.selectLayer(layer.backSourceId),
                  icon: const Icon(Icons.open_with, size: 18),
                  label: const Text('Select the back picture to place it'),
                ),
              ),
            const Divider(),
            const Text('Contour', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Row(children: [
              if (outline == null)
                FilledButton.tonalIcon(
                  key: const ValueKey('objects-add-contour'),
                  onPressed: () => edit(() {
                    layer.effectStack.add(createEffectInstance(
                        'outline', 'fx_${DateTime.now().microsecondsSinceEpoch}', layer));
                  }),
                  icon: const Icon(Icons.border_outer, size: 18),
                  label: const Text('Add contour'),
                )
              else ...[
                const Icon(Icons.check, size: 18),
                const SizedBox(width: 6),
                const Expanded(child: Text('It has a contour - its settings are in Effects')),
                TextButton(
                  key: const ValueKey('objects-contour-open'),
                  onPressed: () => app.showTab('Effects'),
                  child: const Text('Open'),
                ),
              ],
            ]),
          ],
        );
      },
    );
  }
}
