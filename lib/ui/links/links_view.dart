import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/num_field.dart';
import '../stage/stage_painter.dart' show showPropLinks;

const _propNames = {
  'x': 'X', 'y': 'Y', 'rotation': 'Rotation', 'scaleX': 'Scale X', 'scaleY': 'Scale Y', 'opacity': 'Opacity',
  'scaleLeft': 'left size handle', 'scaleRight': 'right size handle',
  'scaleTop': 'top size handle', 'scaleBottom': 'bottom size handle',
  'round': 'rounding (all corners)', 'round0': 'rounding: top left', 'round1': 'rounding: top right',
  'round2': 'rounding: bottom right', 'round3': 'rounding: bottom left',
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
            for (var i = 0; i < layer.links.length; i++)
              if (!layer.links[i].fromSound) () {
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
                          for (final p in linkTargets) DropdownMenuItem(value: p, child: Text('my ${_propNames[p]}')),
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
            const Divider(height: 24),
            _soundSection(context, layer, set),
          ],
        );
      },
    );
  }

  /// Sound: a property of this layer follows how loud an audio layer is.
  Widget _soundSection(BuildContext context, Layer layer, void Function(void Function()) set) {
    final sounds = [for (final l in app.project.layers) if (isAudioShape(l.content.shape)) l];
    const defaults = {
      'x': (0.0, 30.0), 'y': (0.0, -30.0), 'rotation': (0.0, 15.0),
      'scaleX': (0.0, 0.3), 'scaleY': (0.0, 0.3), 'opacity': (-0.6, 0.0),
      'scaleLeft': (0.0, 0.3), 'scaleRight': (0.0, 0.3), 'scaleTop': (0.0, 0.3), 'scaleBottom': (0.0, 0.3),
      'round': (0.0, 30.0), 'round0': (0.0, 30.0), 'round1': (0.0, 30.0), 'round2': (0.0, 30.0), 'round3': (0.0, 30.0),
    };
    Widget num(String key, String label, double v, void Function(double) on) => Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          SizedBox(width: 64, child: NumField(key: ValueKey(key), value: v, onCommit: (x) => set(() => on(x)))),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Driven by sound', style: TextStyle(fontWeight: FontWeight.bold))),
        TextButton.icon(
          key: const ValueKey('sound-link-add'),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add'),
          onPressed: sounds.isEmpty
              ? null
              : () => set(() => layer.links.add(PropLink(
                  from: 'sound', to: 'scaleX', sourceId: sounds.first.id, min: defaults['scaleX']!.$1, max: defaults['scaleX']!.$2))),
        ),
      ]),
      Hint(sounds.isEmpty
          ? 'Add a sound to the project first.'
          : 'How loud the sound is moves a property: silent gives "quiet", loudest gives "loud" (added to its own value).'),
      for (var i = 0; i < layer.links.length; i++)
        if (layer.links[i].fromSound) () {
          final k = layer.links[i];
          return Card(
            key: ValueKey('sound-link-$i'),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Checkbox(value: k.enabled, onChanged: (v) => set(() => k.enabled = v ?? true)),
                  const Icon(Icons.music_note, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: DropdownButton<String?>(
                      key: ValueKey('sound-link-source-$i'),
                      isExpanded: true,
                      value: sounds.any((l) => l.id == k.sourceId) ? k.sourceId : null,
                      items: [for (final l in sounds) DropdownMenuItem<String?>(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis))],
                      onChanged: (id) => set(() => k.sourceId = id),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'remove',
                    onPressed: () => set(() => layer.links.removeAt(i)),
                  ),
                ]),
                Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  DropdownButton<String>(
                    key: ValueKey('sound-link-to-$i'),
                    value: k.to,
                    items: [for (final p in linkTargets) DropdownMenuItem(value: p, child: Text('changes ${_propNames[p]}'))],
                    onChanged: (v) => set(() {
                      if (v == null || v == k.to) return;
                      k.to = v;
                      k.min = defaults[v]!.$1;
                      k.max = defaults[v]!.$2;
                    }),
                  ),
                  num('sound-link-min-$i', 'quiet', k.min, (x) => k.min = x),
                  num('sound-link-max-$i', 'loud', k.max, (x) => k.max = x),
                ]),
                Row(children: [
                  const Text('Smoothing', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      key: ValueKey('sound-link-smooth-$i'),
                      value: k.smooth.clamp(0.0, 1.0),
                      onChangeStart: (_) => app.pushUndo(),
                      onChanged: (v) {
                        k.smooth = v;
                        app.commitEdit();
                      },
                    ),
                  ),
                  Text('${(k.smooth * 100).round()}%', style: const TextStyle(fontSize: 12)),
                ]),
                const Hint('More smoothing: it follows the music\'s swell instead of every beat and noise.'),
              ]),
            ),
          );
        }(),
    ]);
  }
}
