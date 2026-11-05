import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/num_field.dart';
import '../stage/stage_painter.dart' show showPropLinks;

const _propNames = {
  'x': 'X', 'y': 'Y', 'rotation': 'Rotation', 'scaleX': 'Scale X', 'scaleY': 'Scale Y', 'opacity': 'Opacity',
};

/// Links: dependencies - one property of this layer follows one property
/// of another (like parenting, but just that one), and they chain.
class LinksView extends StatelessWidget {
  final AppState app;
  const LinksView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return const Center(child: Text('Select a layer'));
        void set(void Function() change) {
          app.pushUndo();
          change();
          app.commitEdit();
        }

        final others = [
          for (final l in app.project.layers)
            if (l.id != layer.id && !isAudioShape(l.content.shape)) l
        ];
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            SwitchListTile(
              key: const ValueKey('links-visible'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.visibility_outlined, color: Color(0xFFB065F0)),
              title: const Text('Show links on the stage'),
              value: showPropLinks,
              onChanged: (v) => app.setAppPreference('showPropLinks', v),
            ),
            Row(children: [
              const Expanded(child: Text('Dependencies', style: TextStyle(fontWeight: FontWeight.bold))),
              TextButton.icon(
                key: const ValueKey('link-add'),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
                onPressed: () => set(() => layer.links.add(PropLink())),
              ),
            ]),
            const Hint('One property of this layer moves with one property of another layer - its change since '
                'this layer starts, times the factor. A linked layer can drive the next one: a chain.'),
            for (var i = 0; i < layer.links.length; i++) () {
              final k = layer.links[i];
              return Card(
                key: ValueKey('link-$i'),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Checkbox(value: k.enabled, onChanged: (v) => set(() => k.enabled = v ?? true)),
                      const SizedBox(width: 56, child: Text('From')),
                      Expanded(
                        child: DropdownButton<String?>(
                          key: ValueKey('link-source-$i'),
                          isExpanded: true,
                          value: others.any((l) => l.id == k.sourceId) ? k.sourceId : null,
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('None')),
                            for (final l in others)
                              DropdownMenuItem<String?>(
                                value: l.id,
                                enabled: !linkWouldCycle(app.project, layer, l.id),
                                child: Text(
                                    linkWouldCycle(app.project, layer, l.id) ? '${l.name} (circle)' : l.name,
                                    overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: (id) {
                            if (id != null && linkWouldCycle(app.project, layer, id)) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('This would make layers depend on each other in a circle')));
                              return;
                            }
                            set(() {
                              k.sourceId = id;
                              pinLinkBase(app.project, k, app.currentFrame);
                            });
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: 'remove',
                        onPressed: () => set(() => layer.links.removeAt(i)),
                      ),
                    ]),
                    Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      DropdownButton<String>(
                        key: ValueKey('link-from-$i'),
                        value: k.from,
                        items: [
                          for (final p in linkProps) DropdownMenuItem(value: p, child: Text('its ${_propNames[p]}')),
                        ],
                        onChanged: (v) => set(() {
                          k.from = v ?? k.from;
                          pinLinkBase(app.project, k, app.currentFrame);
                        }),
                      ),
                      const Icon(Icons.arrow_forward, size: 16),
                      DropdownButton<String>(
                        key: ValueKey('link-to-$i'),
                        value: k.to,
                        items: [
                          for (final p in linkProps) DropdownMenuItem(value: p, child: Text('my ${_propNames[p]}')),
                        ],
                        onChanged: (v) => set(() => k.to = v ?? k.to),
                      ),
                      const Text('×'),
                      SizedBox(
                        width: 64,
                        child: NumField(
                          key: ValueKey('link-factor-$i'),
                          value: k.factor,
                          onCommit: (v) => set(() => k.factor = v),
                        ),
                      ),
                    ]),
                  ]),
                ),
              );
            }(),
          ],
        );
      },
    );
  }
}
