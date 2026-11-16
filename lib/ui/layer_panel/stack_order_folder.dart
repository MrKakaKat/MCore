import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/num_field.dart';

/// Layers tab, "Order on stage": keys that put a layer above or below
/// others from a frame on (a jump). Lists only the layers that change
/// their order this way: "from 1 to 4, now at 1".
class StackOrderFolder extends StatefulWidget {
  final AppState app;
  const StackOrderFolder({super.key, required this.app});

  @override
  State<StackOrderFolder> createState() => _StackOrderFolderState();
}

class _StackOrderFolderState extends State<StackOrderFolder> {
  int? _place;

  /// "from 5 to 2, now at 2" (places as the Layers list numbers them, 1:
  /// the bottom; from: its own place, before its first border), or "now
  /// absent" while the layer isn't there.
  static String summary(Project project, Layer l, int globalFrame) {
    final keys = [...l.stackKeys]..sort((a, b) => a.frame.compareTo(b.frame));
    final from = listPlaceOf(project, l), to = keys.last.position;
    final here = getLayerStateAt(project, l.id, globalFrame).inRange;
    final now = here ? 'now at ${stackPlaceOf(project, l, globalFrame)}' : 'now absent';
    return 'from $from to $to, $now';
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final layer = findLayer(app.project, app.selection.selectedLayer);
    final keyed = [for (final l in app.project.layers.reversed) if (l.stackKeys.isNotEmpty) l];
    final place = layer == null ? 1 : (_place ?? stackPlaceOf(app.project, layer, app.currentFrame));
    return ExpansionTile(
      key: const ValueKey('stack-order-folder'),
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: const Icon(Icons.swap_vert, size: 20),
      title: Text(keyed.isEmpty ? 'Order on stage' : 'Order on stage (${keyed.length})'),
      childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (layer != null)
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
            Text('From here "${layer.name}" stands at', style: const TextStyle(fontSize: 12)),
            NumField(
              key: const ValueKey('stack-place'),
              width: 44,
              integer: true,
              value: place.toDouble(),
              onCommit: (v) => setState(() => _place = v.round().clamp(1, timelineRows(app.project).length)),
            ),
            Text('(now ${stackPlaceOf(app.project, layer, app.currentFrame)}; the list\'s numbers, 1: the bottom)',
                style: const TextStyle(fontSize: 12)),
            OutlinedButton.icon(
              key: const ValueKey('stack-key-add'),
              icon: const Icon(Icons.diamond_outlined, size: 14),
              label: const Text('Border here'),
              onPressed: () {
                app.addStackKey(layer.id, place);
                setState(() => _place = null);
              },
            ),
          ]),
        if (layer != null && layer.stackKeys.isNotEmpty)
          Wrap(spacing: 4, children: [
            for (final k in layer.stackKeys)
              InputChip(
                key: ValueKey('stack-key-${k.frame}'),
                label: Text('${layer.startFrame + k.frame}: ${k.position}', style: const TextStyle(fontSize: 12)),
                onPressed: () => app.setFrame(layer.startFrame + k.frame),
                onDeleted: () => app.removeStackKey(layer.id, k.frame),
              ),
          ]),
        if (keyed.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('No layer changes its order yet: type the place (the number the Layers list shows) and set '
                'a border at the playhead - from that frame the layer jumps there: from 5 to 2 it goes behind the '
                'layers at 2, 3 and 4.',
                style: TextStyle(fontSize: 12, color: Colors.white60)),
          ),
        for (final l in keyed)
          ListTile(
            key: ValueKey('stack-layer-${l.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            selected: l.id == layer?.id,
            title: Text(l.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(summary(app.project, l, app.currentFrame), key: ValueKey('stack-summary-${l.id}')),
            onTap: () => app.selectLayer(l.id),
          ),
      ],
    );
  }
}
