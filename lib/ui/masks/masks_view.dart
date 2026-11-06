import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../stage/stage_painter.dart' show regionColor, regionsPanelOpen, showFootprints, showMaskViz, showRegionTints;
import '../effects/effects_view.dart';
import '../common/num_field.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../graph_editor/graph_editor_view.dart';

/// Ported from movement-core/src/ui/paramsPanel/masksSection.js - a
/// mask is always sourced from another layer (no separate "circle vs
/// layer" type - a circle-shaped mask is just a normal circle LAYER
/// used as a mask source), so this is: enable/mode/source-layer/feather
/// per mask, reorder-free (JS's masksSection.js has no up/down - masks
/// composite in array order the same way effects do, but no UI to
/// reorder them was ever built there either), plus an "+ mask" button.
///
/// UNVERIFIED like the rest of ui/.
class MasksView extends StatelessWidget {
  final AppState app;
  const MasksView({super.key, required this.app});

  /// What each mode does to the layer, given what the masks above it
  /// already let through (a first "add" mask starts from nothing visible,
  /// a first "subtract" from everything visible).
  static const modeHints = {
    'add': 'Add: the layer shows inside this shape (and wherever earlier masks already show it).',
    'subtract': 'Subtract: this shape cuts a hole in the layer.',
    'intersect': 'Intersect: only where this shape overlaps what earlier masks show.',
    'exclude': 'Exclude (XOR): where either this shape or the earlier masks show it, but not both.',
    'implication': 'Implication: shown wherever the earlier masks hide it, and inside this shape '
        '(hidden only where the earlier masks show it and this shape is empty).',
    'equivalence': 'Equivalence: shown where the earlier masks and this shape agree - both show it or both hide it.',
  };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return const Center(child: Text('No layer selected'));
        final localFrame = layerLocalFrame(layer, app.currentFrame);
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            // the mask outlines on the stage (see stage_painter's mask view).
            SwitchListTile(
              key: const ValueKey('mask-viz'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.layers_outlined),
              title: const Text('Show how the masks work'),
              subtitle: hint('On the stage: a wide outline where a mask lets the layer through, a thin one where it '
                  'hides it, a ring around a mask that changes nothing (covered by the ones before it)'),
              value: showMaskViz,
              onChanged: (v) => app.setAppPreference('showMaskViz', v),
            ),
            // the stack (modes in order) or regions (pick what shows).
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SegmentedButton<bool>(
                key: const ValueKey('mask-kind'),
                segments: const [
                  ButtonSegment(value: false, label: Text('Stack')),
                  ButtonSegment(value: true, label: Text('Regions')),
                ],
                selected: {layer.maskRegions != null && layer.maskRegions!.enabled},
                onSelectionChanged: (v) {
                  app.pushUndo();
                  final on = v.first;
                  final stack = [for (final m in layer.masks) if (m.enabled && m.sourceLayerId != null) m];
                  if (on && layer.maskRegions == null && stack.isEmpty) {
                    // a shape of its own: it is the first of the shapes
                    // (other shapes added split its regions).
                    layer.maskRegions = MaskRegions(
                      sources: isMediaShape(layer.content.shape) ? [] : [layer.id],
                      opacity: {1: track(1.0), 0: track(1.0)},
                    );
                  } else if (on && layer.maskRegions == null) {
                    // start from what the stack does now (content masked by
                    // other shapes).
                    final srcs = stack;
                    final take = srcs.take(maxRegionSources).toList();
                    layer.maskRegions = MaskRegions(
                      sources: [for (final m in take) m.sourceLayerId!],
                      opacity: {
                        for (final e in regionPresetFromStack([for (final m in take) (mode: m.mode, invert: m.invert)]).entries)
                          e.key: track(e.value)
                      },
                    );
                  } else {
                    layer.maskRegions?.enabled = on;
                  }
                  app.commitEdit();
                },
              ),
            ),
            if (layer.maskRegions != null && layer.maskRegions!.enabled)
              _RegionsPanel(app: app, child: _regionsSection(context, layer, localFrame))
            else ...[
            // dragged by the = on the right, like the layers.
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorder: (from, to) => _reorderMask(layer, from, to),
              children: [
                for (var i = 0; i < layer.masks.length; i++)
                  _Fold(
                    key: ValueKey('mask-fold-${identityHashCode(layer.masks[i])}'),
                    id: 'mask ${identityHashCode(layer.masks[i])}',
                    title: 'Mask - ${_cap(layer.masks[i].mode)}${layer.masks[i].invert ? ' (inverted)' : ''}',
                    leading: Checkbox(
                      key: ValueKey('mask-enabled-$i'),
                      value: layer.masks[i].enabled,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) {
                        app.pushUndo();
                        layer.masks[i].enabled = v ?? true;
                        app.commitEdit();
                      },
                    ),
                    trailing: [
                      IconButton(
                        key: ValueKey('mask-delete-$i'),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'remove mask',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _deleteMask(layer, layer.masks[i]),
                      ),
                    ],
                    dragIndex: i,
                    child: _maskSection(context, layer, layer.masks[i], i, localFrame),
                  ),
              ],
            ),
            OutlinedButton(onPressed: () => _addMask(layer), child: const Text('+ mask')),
            ],
            const Divider(),
            _Fold(id: 'edge matte', title: 'Edge matte', child: _edgeMatteSection(layer)),
            const Divider(),
            _Fold(id: 'cut by layer', title: 'Cut by layer', child: EffectsView(app: app).cutsSection(context, layer, localFrame)),
            const Divider(),
            _Fold(id: 'mirror', title: 'Mirror', child: _mirrorSection(layer)),
          ],
        );
      },
    );
  }

  /// A titled block of the Regions mode (all its parts look alike).
  Widget _regionCard(BuildContext context, String title, IconData icon, List<Widget> children, {Widget? trailing}) {
    final scheme = Theme.of(context).colorScheme;
    // a Material (not a coloured box): the switches' list tiles paint on it.
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
      color: scheme.surfaceContainerHigh.withOpacity(0.5),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          if (trailing != null) trailing,
        ]),
        const SizedBox(height: 6),
        ...children,
      ]),
      ),
      ),
    );
  }

  /// "easeInOut" -> "Ease in out".
  static String _easeLabel(String key) =>
      _cap(key.replaceAllMapped(RegExp(r'[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}'));

  /// Regions mode, in plain words: the shapes that cut the stage into
  /// areas, quick set-ups, every area with how much of this layer it
  /// shows, the stage view - and the reactions.
  Widget _regionsSection(BuildContext context, Layer layer, double localFrame) {
    // regions made before a shape was one of its own shapes: it goes in
    // (nothing looks different).
    ensureRegionSelf(layer);
    final mr = layer.maskRegions!;
    final n = mr.sources.length;
    final candidates = [
      for (final l in app.project.layers)
        if (l.id != layer.id && !isAudioShape(l.content.shape) && !mr.sources.contains(l.id)) l
    ];
    final geo = maskRegionGeometry(app.project, layer, app.currentFrame);
    final bake = geo != null ? regionEpisodesReady(app.project, layer) : RegionBake.empty;
    void set(void Function() f) {
      app.pushUndo();
      f();
      app.commitEdit();
    }

    const label = TextStyle(fontSize: 13);
    const muted = TextStyle(fontSize: 12, color: Colors.grey);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Hint('Shapes cut the stage into areas: "Rect 1 + Rect 2" where both are, "Rect 1 − Rect 2" for Rect 1 '
          'without the part Rect 2 covers. Say how much of this layer each area shows.'),
      _regionCard(context, 'Shapes', Icons.category_outlined, [
        for (var i = 0; i < n; i++)
          Padding(
            key: ValueKey('region-source-$i'),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(
                  child: Text(
                      '${findLayer(app.project, mr.sources[i])?.name ?? '?'}${mr.sources[i] == layer.id ? '  (this layer)' : ''}',
                      style: label)),
              const Text('Soft edge', style: muted),
              const SizedBox(width: 6),
              SizedBox(
                width: 56,
                child: NumField(
                  key: ValueKey('region-feather-$i'),
                  value: mr.featherOf(i),
                  onCommit: (v) => set(() {
                    while (mr.feather.length <= i) {
                      mr.feather.add(0);
                    }
                    mr.feather[i] = v.clamp(0, 500).toDouble();
                  }),
                ),
              ),
              const Text(' px', style: muted),
              IconButton(
                key: ValueKey('region-source-del-$i'),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove this shape',
                onPressed: () => set(() {
                  // areas keep how they were where this shape is outside.
                  final old = mr.opacity;
                  if (i < mr.feather.length) mr.feather.removeAt(i);
                  mr.sources.removeAt(i);
                  mr.opacity = {
                    for (var sig = 0; sig < mr.signatureCount; sig++)
                      sig: old[(sig & ((1 << i) - 1)) | ((sig >> i) << (i + 1))] ?? track(0.0)
                  };
                }),
              ),
            ]),
          ),
        if (n < maxRegionSources && candidates.isNotEmpty)
          DropdownButtonFormField<String>(
            key: const ValueKey('region-add-source'),
            decoration: const InputDecoration(isDense: true, labelText: 'Add a shape'),
            value: null,
            items: [for (final l in candidates) DropdownMenuItem(value: l.id, child: Text(l.name))],
            onChanged: (id) {
              if (id == null) return;
              set(() {
                // a new shape: each area splits in two, both as it was.
                final old = mr.opacity;
                mr.sources.add(id);
                final bit = 1 << (mr.sources.length - 1);
                mr.opacity = {
                  for (var sig = 0; sig < mr.signatureCount; sig++) sig: cloneTrack(old[sig & (bit - 1)] ?? track(0.0))
                };
              });
            },
          ),
        if (geo == null && n > 0)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Hint('A shape is a picture: its areas are worked out per pixel (not listed as on screen, '
                'not numbered).'),
          ),
      ]),
      if (n >= 1)
        _regionCard(context, 'Areas', Icons.layers_outlined, trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 8, color: Colors.greenAccent.shade400),
          const Text(' On screen now', style: muted),
        ]), [
          for (final sig in ownedRegionSigs(layer)) () {
            final t = mr.opacity[sig];
            final off = sig == 0 && regionOuterEmpty(layer);
            final op = t == null ? 0.0 : (evaluateTrack(app.project, t, localFrame, layer) as num).toDouble();
            final exists = geo != null && sig < geo.length && geo[sig].exists;
            final keyed = t != null && t.keyframes.any((k) => k.frame == localFrame.round());
            final numbers = <int>{
              for (final e in bake.episodes)
                if (e.sig == sig && e.number != null) e.number!
            }.toList()
              ..sort();
            final picked = app.selectedRegionSig == sig;
            return Container(
              key: ValueKey('region-$sig'),
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: regionColor(sig), width: 4)),
                color: picked ? regionColor(sig).withOpacity(0.12) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => app.selectRegion(picked && app.selectedRegionNumber == null ? null : sig),
                      child: Row(children: [
                        Flexible(
                          child: Text(regionLabel(app.project, layer, sig),
                              style: TextStyle(
                                  fontSize: 13,
                                  color: off ? Colors.grey : null,
                                  fontWeight: picked ? FontWeight.w600 : FontWeight.normal)),
                        ),
                        if (exists) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.circle, size: 8, color: Colors.greenAccent.shade400),
                        ],
                      ]),
                    ),
                  ),
                  Text(op <= 0 ? 'Hidden' : '${(op * 100).round()}%',
                      style: TextStyle(fontSize: 12, color: op <= 0 ? Colors.grey : null)),
                  IconButton(
                    key: ValueKey('region-key-$sig'),
                    icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
                    tooltip: 'Key the shown amount here',
                    onPressed: () => set(() {
                      final trk = mr.opacity[sig] ??= track(0.0);
                      final f = localFrame.round();
                      if (trk.keyframes.any((k) => k.frame == f)) {
                        trk.keyframes.removeWhere((k) => k.frame == f);
                      } else {
                        trk.keyframes
                          ..add(Keyframe(frame: f, value: op))
                          ..sort((a, b) => a.frame.compareTo(b.frame));
                      }
                    }),
                  ),
                ]),
                if (off)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text('Works for layers whose content is larger than their shape',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  )
                else
                  Slider(
                    key: ValueKey('region-opacity-$sig'),
                    value: op.clamp(0.0, 1.0),
                    onChangeStart: (_) => app.pushUndo(),
                    onChanged: (v) {
                      setTrackValueAt(mr.opacity[sig] ??= track(0.0), localFrame.round(), v);
                      app.commitEdit();
                    },
                  ),
                // its numbered pieces (as the animation made them).
                if (numbers.isNotEmpty && mr.numbered)
                  Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    const Text('Pieces', style: muted),
                    for (final k in numbers)
                      ChoiceChip(
                        key: ValueKey('region-$sig-n$k'),
                        label: Text('#$k', style: const TextStyle(fontSize: 11)),
                        visualDensity: VisualDensity.compact,
                        selected: picked && app.selectedRegionNumber == k,
                        onSelected: (_) {
                          app.selectRegion(sig, k);
                          final ep = bake.episodes.firstWhere((e) => e.sig == sig && e.number == k);
                          app.setFrame(ep.peakFrame);
                        },
                      ),
                  ]),
              ]),
            );
          }(),
        ]),
      if (n >= 1)
        _regionCard(context, 'On the stage', Icons.visibility_outlined, [
          SwitchListTile(
            key: const ValueKey('region-show-tints'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Colour the areas', style: label),
            value: showRegionTints,
            onChanged: (v) => app.setAppPreference('showRegionTints', v),
          ),
          // numbering: vector shapes only.
          if (geo != null)
            SwitchListTile(
              key: const ValueKey('region-numbered'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Number the pieces', style: label),
              subtitle: Text(
                  mr.numbered
                      ? 'Numbered regions are not in the list in advance - they appear as the animation creates them.'
                      : 'Each separate touch of the shapes gets a number (#1, #2...); touching again in the same '
                          'place keeps it.',
                  style: TextStyle(fontSize: 11, color: mr.numbered ? Colors.orangeAccent : Colors.grey)),
              value: mr.numbered,
              onChanged: (v) => set(() => mr.numbered = v),
            ),
          if (mr.numbered)
            SwitchListTile(
              key: const ValueKey('region-show-footprints'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Show the biggest size of each piece', style: label),
              value: showFootprints,
              onChanged: (v) => app.setAppPreference('showFootprints', v),
            ),
          if (bake.renumbered.isNotEmpty && mr.numbered)
            Container(
              key: const ValueKey('region-renumbered'),
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
              child: const Text('Region numbers changed after this edit', style: TextStyle(fontSize: 12)),
            ),
        ]),
      if (n >= 1) _regionCommands(context, layer, mr, bake),
    ]);
  }

  /// Reactions:
  ///   When [Rect 1 + Rect 2] [Appears]
  ///   Make [Rect 1 + Rect 2] [Disappear]
  ///   (Gradually: over [10] frames, [Ease in out])
  /// Every area field can also be picked by tapping the area on the stage.
  /// Ones pointing at a number that changed are marked.
  Widget _regionCommands(BuildContext context, Layer layer, MaskRegions mr, RegionBake bake) {
    void set(void Function() f) {
      app.pushUndo();
      f();
      app.commitEdit();
    }

    const label = TextStyle(fontSize: 13);
    final sigs = [for (var s = mr.signatureCount - 1; s >= 0; s--) s];
    const gap = SizedBox(height: 8);
    const lead = 56.0;
    InputDecoration box() => const InputDecoration(isDense: true, border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10));

    // "When": any area (its appearing is shared by every owner); "Make":
    // this layer's own.
    final whenSigs = [for (final x in sigs) if (x != 0) x];
    final makeSigs = [
      for (final x in ownedRegionSigs(layer))
        if (!(x == 0 && regionOuterEmpty(layer))) x
    ];
    Widget areaField(String key, int value, void Function(int) on) {
      final picking = app.regionPickKey == key;
      final make = key.contains('target');
      final list = make ? makeSigs : whenSigs;
      String text(int s) => make ? regionLabel(app.project, layer, s) : regionName(app.project, mr, s);
      return Row(children: [
        Expanded(
          child: DropdownButtonFormField<int>(
            key: ValueKey(key),
            isExpanded: true,
            decoration: box(),
            value: list.contains(value) ? value : (list.isEmpty ? null : list.first),
            items: [
              for (final s in list)
                DropdownMenuItem(value: s, child: Text(text(s), style: label, overflow: TextOverflow.ellipsis))
            ],
            onChanged: (v) => v == null ? null : set(() => on(v)),
          ),
        ),
        IconButton(
          key: ValueKey('$key-pick'),
          icon: Icon(Icons.ads_click, size: 20, color: picking ? Theme.of(context).colorScheme.primary : null),
          tooltip: picking ? 'Tap an area on the stage (tap here to stop)' : 'Pick the area on the stage',
          isSelected: picking,
          onPressed: () => app.startRegionPick(key, (sig, _) => set(() => on(sig))),
        ),
      ]);
    }

    Widget pieceField(String key, int sig, int? value, void Function(int?) on) {
      final known = <int>{
        for (final e in bake.episodes)
          if (e.sig == sig && e.number != null) e.number!,
        if (value != null) value,
      }.toList()
        ..sort();
      return DropdownButtonFormField<int?>(
        key: ValueKey(key),
        isExpanded: true,
        decoration: box(),
        value: value,
        items: [
          const DropdownMenuItem<int?>(value: null, child: Text('Any piece', style: label)),
          for (final k in known) DropdownMenuItem<int?>(value: k, child: Text('Piece #$k', style: label)),
        ],
        onChanged: (v) => set(() => on(v)),
      );
    }

    // a row: the lead word (or nothing), then the field(s) filling the rest.
    Widget line(String word, List<Widget> fields) => Row(children: [
          SizedBox(width: lead, child: Text(word, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: fields[i]),
          ],
          // under the pick buttons of the area rows.
          const SizedBox(width: 48),
        ]);

    return _regionCard(context, 'Reactions', Icons.bolt_outlined,
        trailing: TextButton.icon(
          key: const ValueKey('region-command-add'),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add'),
          onPressed: () => set(() => mr.commands.add(RegionCommand(
              whenSig: mr.signatureCount - 1, targetSig: mr.signatureCount - 1, opacity: 0, ease: 'easeInOut'))),
        ),
        [
          const Hint('When an area appears or disappears, an area (the same or another) appears, disappears or '
              'changes its opacity.'),
          for (var i = 0; i < mr.commands.length; i++) () {
            final c = mr.commands[i];
            final stale = bake.renumbered.contains('${c.whenSig}:${c.whenNumber}') ||
                bake.renumbered.contains('${c.targetSig}:${c.targetNumber}');
            final action = c.opacity <= 0 ? 'disappear' : (c.opacity >= 1 ? 'appear' : 'opacity');
            return Container(
              key: ValueKey('region-command-$i'),
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 10),
              decoration: BoxDecoration(
                border: Border.all(color: stale ? Colors.orange : Colors.grey.withOpacity(0.35)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Text('Reaction ${i + 1}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Remove',
                    onPressed: () => set(() => mr.commands.removeAt(i)),
                  ),
                ]),
                Row(children: [
                  const SizedBox(width: lead, child: Text('When', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                  Expanded(child: areaField('rc-when-sig-$i', c.whenSig, (v) => c.whenSig = v)),
                ]),
                gap,
                line('', [
                  DropdownButtonFormField<String>(
                    key: ValueKey('rc-when-$i'),
                    isExpanded: true,
                    decoration: box(),
                    value: c.when,
                    items: const [
                      DropdownMenuItem(value: 'appears', child: Text('Appears', style: label)),
                      DropdownMenuItem(value: 'disappears', child: Text('Disappears', style: label)),
                    ],
                    onChanged: (v) => set(() => c.when = v ?? c.when),
                  ),
                  if (mr.numbered) pieceField('rc-when-n-$i', c.whenSig, c.whenNumber, (v) => c.whenNumber = v),
                ]),
                gap,
                Row(children: [
                  const SizedBox(width: lead, child: Text('Make', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                  Expanded(child: areaField('rc-target-sig-$i', c.targetSig, (v) => c.targetSig = v)),
                ]),
                gap,
                line('', [
                  DropdownButtonFormField<String>(
                    key: ValueKey('rc-action-$i'),
                    isExpanded: true,
                    decoration: box(),
                    value: action,
                    items: const [
                      DropdownMenuItem(value: 'disappear', child: Text('Disappear', style: label)),
                      DropdownMenuItem(value: 'appear', child: Text('Appear', style: label)),
                      DropdownMenuItem(value: 'opacity', child: Text('Opacity...', style: label)),
                    ],
                    onChanged: (v) => set(() => c.opacity = switch (v) { 'appear' => 1.0, 'opacity' => 0.5, _ => 0.0 }),
                  ),
                  if (action == 'opacity')
                    NumField(
                      key: ValueKey('rc-opacity-$i'),
                      value: c.opacity * 100,
                      onCommit: (v) => set(() => c.opacity = (v / 100).clamp(0.01, 0.99)),
                    ),
                  if (mr.numbered) pieceField('rc-target-n-$i', c.targetSig, c.targetNumber, (v) => c.targetNumber = v),
                ]),
                // how: at once (the default) or gradually.
                const Divider(height: 20),
                Row(children: [
                  const Expanded(child: Text('Gradually', style: label)),
                  Switch(
                    key: ValueKey('rc-timed-$i'),
                    value: c.timed,
                    onChanged: (v) => set(() => c.timed = v),
                  ),
                ]),
                if (c.timed)
                  Row(children: [
                    const Text('Over', style: label),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 64,
                      child: NumField(
                        key: ValueKey('rc-frames-$i'),
                        value: c.frames.toDouble(),
                        integer: true,
                        onCommit: (v) => set(() => c.frames = v.round().clamp(1, 100000)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Frames', style: label),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('rc-ease-$i'),
                        isExpanded: true,
                        decoration: box(),
                        value: easingPresets.containsKey(c.ease) ? c.ease : 'linear',
                        items: [
                          for (final e in easingPresets.keys)
                            DropdownMenuItem(value: e, child: Text(_easeLabel(e), style: label))
                        ],
                        onChanged: (v) => set(() => c.ease = v ?? c.ease),
                      ),
                    ),
                  ]),
              ]),
            );
          }(),
        ]);
  }

  void _reorderMask(Layer layer, int from, int to) {
    if (to > from) to--;
    if (to == from) return;
    app.pushUndo();
    layer.masks.insert(to, layer.masks.removeAt(from));
    app.commitEdit();
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _maskSection(BuildContext context, Layer layer, Mask mask, int idx, double localFrame) {
    final candidates = app.project.layers.where((l) => l.id != layer.id && !isAudioShape(l.content.shape)).toList();
    final source = findLayer(app.project, mask.sourceLayerId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                const SizedBox(width: 60, child: Text('Mode', style: TextStyle(fontSize: 12))),
                Expanded(
                  child: DropdownButton<String>(
                    key: ValueKey('mask-mode-$idx'),
                    isExpanded: true,
                    value: mask.mode,
                    items: const [
                      DropdownMenuItem(value: 'add', child: Text('Add')),
                      DropdownMenuItem(value: 'subtract', child: Text('Subtract')),
                      DropdownMenuItem(value: 'intersect', child: Text('Intersect')),
                      DropdownMenuItem(value: 'exclude', child: Text('Exclude')),
                      DropdownMenuItem(value: 'implication', child: Text('Implication')),
                      DropdownMenuItem(value: 'equivalence', child: Text('Equivalence')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      app.pushUndo();
                      mask.mode = v;
                      app.commitEdit();
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                const SizedBox(width: 60, child: Text('Source', style: TextStyle(fontSize: 12))),
                Expanded(
                  child: DropdownButton<String?>(
                    isExpanded: true,
                    value: mask.sourceLayerId,
                    hint: const Text('None'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      for (final l in candidates)
                        DropdownMenuItem<String?>(
                            value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) {
                      app.pushUndo();
                      mask.sourceLayerId = v;
                      app.commitEdit();
                    },
                  ),
                ),
                // more sources: the mask is all of them together.
                if (mask.sourceLayerId != null)
                  PopupMenuButton<String>(
                    key: const ValueKey('mask-add-source'),
                    tooltip: 'add another source (the mask is all of them together)',
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    itemBuilder: (_) => [
                      for (final l in candidates)
                        if (!mask.sourceIds.contains(l.id)) PopupMenuItem(value: l.id, child: Text(l.name)),
                    ],
                    onSelected: (id) {
                      app.pushUndo();
                      mask.moreSources.add(id);
                      app.commitEdit();
                    },
                  ),
              ],
            ),
          ),
          // a text source: all of it, or one of its parts.
          if (findLayer(app.project, mask.sourceLayerId)?.content.text case final st? when st.spans.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 72, bottom: 4),
              child: DropdownButton<int?>(
                key: const ValueKey('mask-source-part'),
                isDense: true,
                value: mask.sourcePart != null && mask.sourcePart! < st.spans.length ? mask.sourcePart : null,
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('the whole text')),
                  for (var i = 0; i < st.spans.length; i++)
                    DropdownMenuItem<int?>(
                        value: i, child: Text('part "${st.spans[i].name.isEmpty ? '${st.spans[i].start}-${st.spans[i].end}' : st.spans[i].name}"')),
                ],
                onChanged: (v) {
                  app.pushUndo();
                  mask.sourcePart = v;
                  app.commitEdit();
                },
              ),
            ),
          if (mask.moreSources.isNotEmpty)
            Padding(
              key: const ValueKey('mask-more-sources'),
              padding: const EdgeInsets.only(left: 72, bottom: 4),
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                for (final id in [...mask.moreSources])
                  InputChip(
                    label: Text('+ ${findLayer(app.project, id)?.name ?? '?'}', style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onDeleted: () {
                      app.pushUndo();
                      mask.moreSources.remove(id);
                      app.commitEdit();
                    },
                  ),
              ]),
            ),
          // what the mode does, right under it.
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Hint(modeHints[mask.mode] ?? ''),
          ),
          if (idx == 0 && mask.mode != 'subtract')
            const Padding(
              padding: EdgeInsets.only(left: 12, bottom: 4),
              child: Hint('First mask (except Subtract) simply shows the source shape'),
            ),
          _Fold(
            key: ValueKey('mask-params-$idx'),
            id: 'mask params ${identityHashCode(mask)}',
            title: 'Parameters',
            small: true,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CheckboxListTile(
            key: ValueKey('mask-invert-$idx'),
            dense: true,
            contentPadding: const EdgeInsets.only(left: 12),
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Invert', style: TextStyle(fontSize: 13)),
            subtitle: hint('The shape turned inside out: everything but the source counts'),
            value: mask.invert,
            onChanged: (v) {
              app.pushUndo();
              mask.invert = v ?? false;
              app.commitEdit();
            },
          ),
          // the shape lending its outline is usually not meant to be
          // seen itself (e.g. a text whose letters cut out a photo).
          if (source != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Row(children: [
                const Expanded(child: Text('Show the source layer', style: TextStyle(fontSize: 12))),
                Switch(
                  key: ValueKey('mask-source-visible-$idx'),
                  value: !source.hidden,
                  onChanged: (_) => app.toggleHidden(source.id),
                ),
              ]),
            ),
          _featherRow(context, mask, localFrame),
          // how far the soft edge may reach past the outline.
          Row(children: [
            const SizedBox(
                width: 96,
                child: Text('feather outside', style: TextStyle(fontSize: 12))),
            Expanded(
              child: Slider(
                key: ValueKey('feather-outside-${app.project.layers.indexWhere((l) => l.masks.contains(mask))}-${mask.hashCode}'),
                value: mask.featherOutside,
                onChangeStart: (_) => app.pushUndo(),
                onChanged: (v) {
                  mask.featherOutside = v;
                  app.commitEdit();
                },
              ),
            ),
            SizedBox(width: 40, child: Text('${(mask.featherOutside * 100).round()}%', style: const TextStyle(fontSize: 12))),
          ]),
          _timeRow(layer, mask, idx),
            ]),
          ),
        ],
      ),
    );
  }

  /// When the mask works: the whole layer, or from / to (layer frames).
  Widget _timeRow(Layer layer, Mask mask, int idx) {
    final r = mask.range;
    void set(List<int>? v) {
      app.pushUndo();
      mask.range = v;
      app.commitEdit();
    }

    return Row(children: [
      const SizedBox(width: 96, child: Text('time', style: TextStyle(fontSize: 12))),
      if (r == null)
        TextButton(
          key: ValueKey('mask-time-$idx'),
          onPressed: () {
            set([0, layer.durationFrames]);
            app.showMaskTimeOnTimeline(idx);
          },
          child: const Text('whole layer - limit'),
        )
      else ...[
        SizedBox(
            width: 64,
            child: NumField(
                key: ValueKey('mask-from-$idx'),
                value: r[0].toDouble(),
                integer: true,
                onCommit: (v) => set([v.round().clamp(0, r[1]), r[1]]))),
        const Text(' - '),
        SizedBox(
            width: 64,
            child: NumField(
                key: ValueKey('mask-to-$idx'),
                value: r[1].toDouble(),
                integer: true,
                onCommit: (v) => set([r[0], v.round().clamp(r[0], layer.durationFrames)]))),
        IconButton(
          key: ValueKey('mask-time-show-$idx'),
          icon: const Icon(Icons.straighten, size: 16),
          tooltip: 'its indicators on the timeline',
          onPressed: () => app.showMaskTimeOnTimeline(idx),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          tooltip: 'whole layer',
          onPressed: () => set(null),
        ),
      ],
    ]);
  }

  Widget _featherRow(BuildContext context, Mask mask, double localFrame) {
    final trk = mask.feather;
    final value = evaluateTrack(app.project, trk, localFrame) as double;
    final frame = localFrame.round();
    final keyed = trk.keyframes.any((k) => k.frame == frame);
    return ParamEditor(
      prefKey: 'mask.feather',
      label: 'feather',
      values: [value],
      scale: const ParamScale.ruler(unitsPerPixel: 0.5, minorTick: 5, majorTick: 25, min: 0, decimals: 1),
      onEditStart: app.pushUndo,
      onChanged: (v) {
        setTrackValueAt(trk, frame, v.first);
        app.commitEdit();
      },
      onCommit: (v) {
        app.pushUndo();
        setTrackValueAt(trk, frame, v.first);
        app.commitEdit();
      },
      trailing: [
        if (trk.keyframes.length >= 2)
          IconButton(
            icon: const Icon(Icons.show_chart, size: 16),
            tooltip: 'edit easing curve',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => GraphEditorView(app: app, track: trk, componentCount: 1),
            ),
          ),
        ResetIconButton(onPressed: () {
          app.pushUndo();
          setTrackValueAt(trk, frame, 0.0);
          app.commitEdit();
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
        )
      ],
    );
  }

  /// Edge matte: a picture shot on black or white (or any plain colour)
  /// gets that colour taken out - lighten (black goes see-through, light
  /// stays), darken (white goes) - so glows and soft edges sit on any
  /// background without a dark or pale fringe.
  Widget _edgeMatteSection(Layer layer) {
    void edit(void Function() change) {
      app.pushUndo();
      change();
      app.commitEdit();
    }

    final raster = chromaCapable(layer.content.shape);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('edge-matte'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Edge matte'),
          subtitle: hint(raster
              ? 'Takes a black or white background out of the picture (lighten / darken)'
              : 'For images, videos and merged shapes'),
          value: layer.edgeMatte,
          onChanged: raster ? (v) => edit(() => layer.edgeMatte = v) : null,
        ),
        if (layer.edgeMatte && raster) ...[
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final (label, hex) in const [('Lighten (black bg)', '#000000'), ('Darken (white bg)', '#ffffff')])
              ChoiceChip(
                key: ValueKey('edge-matte-$hex'),
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: layer.edgeMatteColor.toLowerCase() == hex,
                onSelected: (_) => edit(() => layer.edgeMatteColor = hex),
              ),
            // any other background colour: the chroma loupe.
            FilterChip(
              key: const ValueKey('edge-matte-pick'),
              avatar: const Icon(Icons.colorize, size: 16),
              label: const Text('Pick on stage'),
              selected: chromaTool == 'mattePick',
              onSelected: (on) => app.setChromaTool(on ? 'mattePick' : 'none'),
            ),
            Container(
              key: const ValueKey('edge-matte-swatch'),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: Color(0xFF000000 | (int.tryParse(layer.edgeMatteColor.substring(1), radix: 16) ?? 0)),
                border: Border.all(color: Colors.white38),
              ),
            ),
            Text(layer.edgeMatteColor, style: const TextStyle(fontSize: 12)),
          ]),
          if (chromaTool == 'mattePick')
            const Hint('Press on the picture and slide to the background colour; lift to take it.'),
          Row(children: [
            const SizedBox(width: 96, child: Text('strength', style: TextStyle(fontSize: 12))),
            Expanded(
              child: Slider(
                key: const ValueKey('edge-matte-strength'),
                value: layer.edgeMatteStrength.clamp(0.0, 1.0),
                onChangeStart: (_) => app.pushUndo(),
                onChanged: (v) {
                  layer.edgeMatteStrength = v;
                  app.commitEdit();
                },
              ),
            ),
            SizedBox(width: 40, child: Text('${(layer.edgeMatteStrength * 100).round()}%', style: const TextStyle(fontSize: 12))),
          ]),
        ],
      ],
    );
  }

  /// Mirror: this layer's shape shows, flipped, what another layer (the
  /// base) covers in the layers below.
  Widget _mirrorSection(Layer layer) {
    void edit(void Function() change) {
      app.pushUndo();
      change();
      app.commitEdit();
    }

    return Column(
      key: const ValueKey('mirror-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Hint('Make mirror: a copy of this shape appears beside it, drawn only as a dashed outline. '
            'This layer then shows what lies under the copy (the layers below), flipped. '
            'Move the copy: something else is reflected. Move this: the reflection goes with it.'),
        Wrap(spacing: 8, children: [
          FilledButton.tonalIcon(
            key: const ValueKey('mirror-make'),
            icon: const Icon(Icons.flip, size: 18),
            label: Text(layer.mirrorSourceId == null ? 'Make mirror' : 'New mirror copy'),
            onPressed: () => app.makeMirror(layer.id),
          ),
          if (layer.mirrorSourceId != null)
            IconButton(
              key: const ValueKey('mirror-reset'),
              icon: const Icon(Icons.restart_alt, size: 20),
              tooltip: 'put the mirror copy back beside the layer',
              onPressed: () => app.resetMirrorProbe(layer.id),
            ),
          if (layer.mirrorSourceId != null)
            TextButton(
              key: const ValueKey('mirror-remove'),
              onPressed: () => app.removeMirror(layer.id),
              child: const Text('Not a mirror'),
            ),
        ]),
        if (layer.mirrorSourceId != null)
          SwitchListTile(
            key: const ValueKey('mirror-all-layers'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Show all layers', style: TextStyle(fontSize: 13)),
            subtitle: hint('Off: only the layers below this one are reflected'),
            value: layer.mirrorAllLayers,
            onChanged: (v) => edit(() => layer.mirrorAllLayers = v),
          ),
        if (layer.mirrorSourceId != null)
          Wrap(spacing: 6, children: [
            for (final (axis, label) in const [('x', 'Left-right'), ('y', 'Upside down'), ('both', 'Both'), ('none', 'Not flipped')])
              ChoiceChip(
                key: ValueKey('mirror-axis-$axis'),
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: layer.mirrorAxis == axis,
                onSelected: (_) => edit(() => layer.mirrorAxis = axis),
              ),
          ]),
      ],
    );
  }

  void _deleteMask(Layer layer, Mask mask) {
    app.pushUndo();
    layer.masks.remove(mask);
    app.commitEdit();
  }

  void _addMask(Layer layer) {
    app.pushUndo();
    layer.masks.add(Mask());
    app.commitEdit();
  }
}


/// A folding section; open by default, remembered while the app runs.
class _Fold extends StatefulWidget {
  final String id;
  final String title;
  final Widget child;
  final Widget? leading;
  final List<Widget> trailing;

  /// In a ReorderableListView: the = handle that drags it.
  final int? dragIndex;

  /// A fold inside another one (a lighter title).
  final bool small;
  const _Fold(
      {super.key,
      required this.id,
      required this.title,
      required this.child,
      this.leading,
      this.trailing = const [],
      this.dragIndex,
      this.small = false});

  /// Open folds (all start folded).
  static final Map<String, bool> _open = {};

  @override
  State<_Fold> createState() => _FoldState();
}

class _FoldState extends State<_Fold> {
  @override
  Widget build(BuildContext context) {
    final open = _Fold._open[widget.id] ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('fold-${widget.id}'),
          onTap: () => setState(() => _Fold._open[widget.id] = !open),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: widget.leading != null || widget.trailing.isNotEmpty ? 0 : 6),
            child: Row(children: [
              if (widget.leading != null) widget.leading!,
              Expanded(
                  child: Text(widget.title,
                      style: widget.small
                          ? const TextStyle(fontSize: 13, color: Colors.grey)
                          : const TextStyle(fontWeight: FontWeight.bold))),
              Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
              ...widget.trailing,
              if (widget.dragIndex != null)
                ReorderableDragStartListener(
                  index: widget.dragIndex!,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle, size: 20),
                  ),
                ),
            ]),
          ),
        ),
        if (open) Padding(padding: EdgeInsets.only(left: widget.small ? 8 : 0), child: widget.child),
      ],
    );
  }
}

/// Marks the Regions panel as open while it is shown: the stage then shows
/// the areas and a tap picks them.
class _RegionsPanel extends StatefulWidget {
  final AppState app;
  final Widget child;
  const _RegionsPanel({required this.app, required this.child});

  @override
  State<_RegionsPanel> createState() => _RegionsPanelState();
}

class _RegionsPanelState extends State<_RegionsPanel> {
  @override
  void initState() {
    super.initState();
    regionsPanelOpen++;
  }

  @override
  void dispose() {
    regionsPanelOpen--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
