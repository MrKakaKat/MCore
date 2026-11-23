import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/num_field.dart';
import '../stage/stage_painter.dart' show showPropLinks;
import '../common/no_layer.dart';
import '../../io/freeze_watch.dart';

const _propNames = {
  'x': 'X', 'y': 'Y', 'rotation': 'Rotation', 'scaleX': 'Scale X', 'scaleY': 'Scale Y', 'opacity': 'Opacity',
  'scale': 'whole size (both scales)', 'position': 'position',
  'scaleLeft': 'left size handle', 'scaleRight': 'right size handle',
  'scaleTop': 'top size handle', 'scaleBottom': 'bottom size handle',
  'growLeft': 'grow left (lengthened)', 'growTop': 'grow top (lengthened)',
  'growRight': 'grow right (lengthened)', 'growBottom': 'grow bottom (lengthened)',
  'round': 'rounding (all corners)', 'round0': 'rounding: top left', 'round1': 'rounding: top right',
  'round2': 'rounding: bottom right', 'round3': 'rounding: bottom left',
};

/// A size-handle target, said as what moves (and what stays).
const _targetNames = {
  'scaleLeft': 'left side (right held)', 'scaleRight': 'right side (left held)',
  'scaleTop': 'bottom side (top held)', 'scaleBottom': 'top side (bottom held)',
};
String _target(String p) => _targetNames[p] ?? _propNames[p] ?? p;

/// Links: dependencies - one property of this layer follows one property
/// of another (like parenting, but just that one), and they chain.
class LinksView extends StatelessWidget {
  final AppState app;
  const LinksView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    FreezeWatch.at('building $runtimeType');
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return NoLayer(app: app, text: 'Select a layer');
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
                onPressed: () => set(() {
                  final k = PropLink();
                  _LinkCard.open[k] = true;
                  layer.links.add(k);
                }),
              ),
              // a copied link: onto this layer.
              if (app.copiedLink != null && !app.copiedLink!.fromSound)
                IconButton(
                  key: const ValueKey('link-paste'),
                  icon: const Icon(Icons.content_paste, size: 18),
                  tooltip: 'paste the copied link',
                  onPressed: () {
                    if (!app.pasteLink(layer.id)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('This would make layers depend on each other in a circle')));
                    }
                  },
                ),
            ]),
            const Hint('One property of this layer moves with one property of another layer - its change since '
                'this layer starts, times the factor. A linked layer can drive the next one: a chain. '
                '"Follows it": like parenting for one property - it moves as far as the other object does, '
                'along its own axis only. Handle to handle: "Follows it", its size handle -> my side - each '
                'handle is a point of its own, no keys needed. "Works": the time it works in.'),
            // the newest first.
            for (var i = layer.links.length - 1; i >= 0; i--)
              if (!layer.links[i].fromSound) () {
              final k = layer.links[i];
              final srcName = others.where((l) => l.id == k.sourceId).firstOrNull?.name;
              final what = k.follows
                  ? 'follows its ${_propNames[k.from] ?? k.from}'
                  : 'its ${_propNames[k.from] ?? k.from}';
              return _LinkCard(
                key: ValueKey('link-$i'),
                link: k,
                headKey: ValueKey('link-head-$i'),
                header: Row(children: [
                  Checkbox(value: k.enabled, onChanged: (v) => set(() => k.enabled = v ?? true)),
                  Expanded(
                    child: Text(
                      '${srcName ?? 'no source'} · $what → my ${_target(k.to)}'
                      '${k.factor != 1 ? ' ×${k.factor}' : ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: k.enabled ? null : Colors.white38),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('link-copy-$i'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy, size: 16),
                    tooltip: 'copy this link',
                    onPressed: () => app.copyLink(k),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'remove',
                    onPressed: () => set(() => layer.links.removeAt(i)),
                  ),
                ]),
                body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
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
                    ]),
                    // the kind: adds the source's change, or follows the
                    // source object as a parent would (one axis only).
                    Wrap(spacing: 6, children: [
                      for (final (mode, label) in const [('add', 'Adds its change'), ('follow', 'Follows it (like parenting)')])
                        ChoiceChip(
                          key: ValueKey('link-mode-$i-$mode'),
                          label: Text(label, style: const TextStyle(fontSize: 12)),
                          selected: k.mode == mode,
                          // one kind at a time; each keeps its own settings.
                          onSelected: (_) => set(() {
                            k.switchMode(mode);
                            pinLinkBase(app.project, k, app.currentFrame);
                          }),
                        ),
                    ]),
                    Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (k.follows)
                        // its place, or one of its size handles to chase.
                        DropdownButton<String>(
                          key: ValueKey('link-follow-from-$i'),
                          value: followSources.contains(k.from) ? k.from : 'position',
                          items: [
                            for (final p in followSources) DropdownMenuItem(value: p, child: Text('its ${_propNames[p]}')),
                          ],
                          onChanged: (v) => set(() {
                            k.from = v ?? k.from;
                            pinLinkBase(app.project, k, app.currentFrame);
                          }),
                        )
                      else
                        DropdownButton<String>(
                          key: ValueKey('link-from-$i'),
                          value: linkSources.contains(k.from) ? k.from : 'x',
                          items: [
                            for (final p in linkSources) DropdownMenuItem(value: p, child: Text('its ${_propNames[p]}')),
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
                          for (final p in k.follows ? followTargets : linkTargets)
                            DropdownMenuItem(value: p, child: Text('my ${_target(p)}')),
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
                    _rangeRow(layer, k, 'link-$i', set),
                  ]),
              );
            }(),
            const Divider(height: 24),
            _soundSection(context, layer, set),
          ],
        );
      },
    );
  }

  /// When the link works: from / until a frame (empty: the layer's start /
  /// end); the playhead's frame with one tap.
  Widget _rangeRow(Layer layer, PropLink k, String key, void Function(void Function()) set) {
    Widget end(String label, int? value, int whole, void Function(int?) on) => Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          NumField(
              key: ValueKey('$key-$label'),
              width: 56,
              integer: true,
              value: (value ?? whole).toDouble(),
              onCommit: (v) => set(() => on(v.round()))),
          IconButton(
            key: ValueKey('$key-$label-now'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.vertical_align_center, size: 16),
            tooltip: 'the playhead',
            onPressed: () => set(() => on(app.currentFrame)),
          ),
          if (value != null)
            IconButton(
              key: ValueKey('$key-$label-clear'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 14),
              tooltip: label == 'from' ? "from the layer's start" : "to the layer's end",
              onPressed: () => set(() => on(null)),
            ),
        ]);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
      const Text('Works', style: TextStyle(fontSize: 12)),
      end('from', k.fromFrame, layer.startFrame, (v) {
        k.fromFrame = v;
        final b = k.untilFrame;
        if (v != null && b != null && b < v) k.untilFrame = v;
      }),
      end('until', k.untilFrame, layer.startFrame + layer.durationFrames, (v) {
        k.untilFrame = v;
        final a = k.fromFrame;
        if (v != null && a != null && a > v) k.fromFrame = v;
      }),
    ]);
  }

  /// Sound: a property of this layer follows how loud an audio layer is.
  Widget _soundSection(BuildContext context, Layer layer, void Function(void Function()) set) {
    final sounds = [for (final l in app.project.layers) if (isAudioShape(l.content.shape)) l];
    const defaults = {
      'x': (0.0, 30.0), 'y': (0.0, -30.0), 'rotation': (0.0, 15.0),
      'scaleX': (0.0, 0.3), 'scaleY': (0.0, 0.3), 'scale': (0.0, 0.3), 'opacity': (-0.6, 0.0),
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
              : () => set(() {
                  final k = PropLink(
                      from: 'sound', to: 'scaleX', sourceId: sounds.first.id, min: defaults['scaleX']!.$1, max: defaults['scaleX']!.$2);
                  _LinkCard.open[k] = true;
                  layer.links.add(k);
                }),
        ),
        if (app.copiedLink != null && app.copiedLink!.fromSound)
          IconButton(
            key: const ValueKey('sound-link-paste'),
            icon: const Icon(Icons.content_paste, size: 18),
            tooltip: 'paste the copied link',
            onPressed: () => app.pasteLink(layer.id),
          ),
      ]),
      Hint(sounds.isEmpty
          ? 'Add a sound to the project first.'
          : 'How loud the sound is moves a property: silent gives "quiet", loudest gives "loud" (added to its own value).'),
      for (var i = layer.links.length - 1; i >= 0; i--)
        if (layer.links[i].fromSound) () {
          final k = layer.links[i];
          final soundName = sounds.where((l) => l.id == k.sourceId).firstOrNull?.name;
          return _LinkCard(
            key: ValueKey('sound-link-$i'),
            link: k,
            headKey: ValueKey('sound-link-head-$i'),
            header: Row(children: [
              Checkbox(value: k.enabled, onChanged: (v) => set(() => k.enabled = v ?? true)),
              const Icon(Icons.music_note, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text('${soundName ?? 'no sound'} → changes ${_target(k.to)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: k.enabled ? null : Colors.white38)),
              ),
              IconButton(
                key: ValueKey('sound-link-copy-$i'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'copy this link',
                onPressed: () => app.copyLink(k),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'remove',
                onPressed: () => set(() => layer.links.removeAt(i)),
              ),
            ]),
            body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DropdownButton<String?>(
                  key: ValueKey('sound-link-source-$i'),
                  isExpanded: true,
                  value: sounds.any((l) => l.id == k.sourceId) ? k.sourceId : null,
                  items: [for (final l in sounds) DropdownMenuItem<String?>(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis))],
                  onChanged: (id) => set(() => k.sourceId = id),
                ),
                Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  DropdownButton<String>(
                    key: ValueKey('sound-link-to-$i'),
                    value: k.to,
                    items: [for (final p in linkTargets) DropdownMenuItem(value: p, child: Text('changes ${_target(p)}'))],
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
                _rangeRow(layer, k, 'sound-link-$i', set),
              ]),
          );
        }(),
    ]);
  }
}

/// A link's card: its summary line (on / off, copy, remove) always, its
/// settings folded away until opened (a new link opens).
class _LinkCard extends StatefulWidget {
  final PropLink link;
  final Key headKey;
  final Widget header, body;
  const _LinkCard({super.key, required this.link, required this.headKey, required this.header, required this.body});

  /// Which links are open (kept while the tab is rebuilt).
  static final Expando<bool> open = Expando();

  @override
  State<_LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends State<_LinkCard> {
  @override
  Widget build(BuildContext context) {
    FreezeWatch.at('building $runtimeType');
    final open = _LinkCard.open[widget.link] ?? widget.link.sourceId == null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          key: widget.headKey,
          onTap: () => setState(() => _LinkCard.open[widget.link] = !open),
          child: Row(children: [
            Expanded(child: widget.header),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(open ? Icons.expand_less : Icons.expand_more, size: 20),
            ),
          ]),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
            child: widget.body,
          ),
      ]),
    );
  }
}
