import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';

/// Keyframes tab: where keys go.
/// - Base keys: the parameters' own keys.
/// - Order keys (the easy way): every key you place opens a range that
///   follows the playhead until you place the next key - that pair is a
///   movement of its own, added on top of everything else.
/// - Layer keys: the layers of movement as a list - tap one to put keys
///   and edits into it, switch it off, or delete it.
class KeyModePanel extends StatelessWidget {
  final AppState app;
  final Layer layer;
  const KeyModePanel({super.key, required this.app, required this.layer});

  String _range(int n) {
    final f = animLayerKeyFrames(layer, n).toList()..sort();
    if (f.isEmpty) return 'no keys yet';
    if (f.length == 1) return 'from frame ${f.first + layer.startFrame} - open';
    return 'frames ${f.first + layer.startFrame} - ${f.last + layer.startFrame}';
  }

  @override
  Widget build(BuildContext context) {
    final n = layer.transform.anchor.animLayers.length;
    final open = openOrderLayer(layer);
    return Column(
      key: const ValueKey('key-modes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'base', label: Text('Base keys')),
            ButtonSegment(value: 'order', label: Text('Order keys')),
            ButtonSegment(value: 'layers', label: Text('Layer keys')),
          ],
          selected: {keyMode},
          onSelectionChanged: (s) => app.setKeyMode(s.first, layerId: layer.id),
        ),
        const SizedBox(height: 6),
        if (keyMode == 'base')
          const Hint('Keys go into the parameters themselves - one movement from key to key.'),
        if (keyMode == 'order') ...[
          const Hint('Place a key: a range follows the playhead until you place the next one. '
              'Each pair is a movement of its own, added on top of the rest.'),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              open == null ? 'Place a key to start a range' : 'Range open ${_range(open).replaceFirst(' - open', '')}: place the second key',
              key: const ValueKey('order-status'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
        if (keyMode == 'layers') ...[
          const Hint('Each layer is a movement of its own; they add up. Tap one: new keys and edits go into it.'),
          for (var i = 1; i <= n; i++) _layerRow(context, i),
          TextButton.icon(
            key: const ValueKey('anim-layer-add'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a layer'),
            onPressed: () => app.addAnimLayer(layer.id),
          ),
        ],
      ],
    );
  }

  Widget _layerRow(BuildContext context, int i) {
    final on = layer.transform.anchor.animLayers[i - 1].enabled;
    final selected = activeAnimLayer == i;
    return Material(
      key: ValueKey('anim-layer-row-$i'),
      color: selected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => app.setActiveAnimLayer(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(children: [
            Expanded(
              child: Text('${_range(i)}${selected ? '  ·  editing' : ''}',
                  style: TextStyle(fontSize: 13, color: on ? null : Colors.grey)),
            ),
            IconButton(
              key: ValueKey('anim-layer-eye-$i'),
              icon: Icon(on ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
              tooltip: on ? 'switch this movement off' : 'switch this movement on',
              visualDensity: VisualDensity.compact,
              onPressed: () => app.setAnimLayerEnabled(layer.id, i, !on),
            ),
            IconButton(
              key: ValueKey('anim-layer-delete-$i'),
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'delete this movement and its keys',
              visualDensity: VisualDensity.compact,
              onPressed: () => app.removeAnimLayer(layer.id, i),
            ),
          ]),
        ),
      ),
    );
  }
}
