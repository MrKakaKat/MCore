import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/num_field.dart';
import '../common/no_layer.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';

/// Timeline tab: the selected layer's place on the timeline - which row
/// it's in (several layers can share a row when they don't overlap in
/// time), moving it into a neighbour row or its own, and "fill the gaps":
/// cut the layer down to the empty stretches of another row and put the
/// parts there ("–..–..–": it fills the dots, the rest is removed).
class TimelineRowsView extends StatefulWidget {
  final AppState app;
  const TimelineRowsView({super.key, required this.app});

  @override
  State<TimelineRowsView> createState() => _TimelineRowsViewState();
}

class _TimelineRowsViewState extends State<TimelineRowsView> {
  // the gap-fill target, by one of its layers (row indexes shift).
  String? _targetLayerId;

  AppState get app => widget.app;

  String _rowLabel(List<Layer> row) => row.map((l) => l.name).join(', ');

  /// Snapping of layer edges on the timeline: on/off and how near (frames)
  /// an edge has to come before it snaps.
  /// Range selection: a stretch of the timeline (dimmed outside on the
  /// timeline) and actions on every layer it touches.
  Widget _rangeSection() {
    final r = app.timeRange;
    return Column(
      key: const ValueKey('time-range'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('range-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Range', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: hint('Two indicators on the timeline; what is outside dims. '
              'The actions below work on every layer in it'),
          value: r != null,
          onChanged: app.setTimeRangeEnabled,
        ),
        if (r != null)
        Row(children: [
          Expanded(child: Text('${r.a} - ${r.b}')),
          IconButton(
            key: const ValueKey('range-start'),
            icon: const Icon(Icons.first_page, size: 18),
            tooltip: 'range starts at the playhead',
            onPressed: () => app.setTimeRangeEdge(start: true),
          ),
          IconButton(
            key: const ValueKey('range-end'),
            icon: const Icon(Icons.last_page, size: 18),
            tooltip: 'range ends at the playhead',
            onPressed: () => app.setTimeRangeEdge(start: false),
          ),
        ]),
        if (r != null) ...[
          Text('${layersInRange(app.project, r.a, r.b).length} layers in it', style: const TextStyle(fontSize: 11)),
          Wrap(spacing: 6, children: [
            OutlinedButton(
              key: const ValueKey('range-trim'),
              onPressed: () => app.rangeEdit((a, b) => trimLayersToRange(app.project, a, b)),
              child: const Text('Trim layers to it'),
            ),
            OutlinedButton(
              key: const ValueKey('range-delete-keys'),
              onPressed: () => app.rangeEdit((a, b) => deleteKeysInRange(app.project, a, b)),
              child: const Text('Delete keys in it'),
            ),
          ]),
          const Hint('Hold the range on the timeline and drag it to move it with its layers'),
          Wrap(spacing: 6, children: [
            OutlinedButton.icon(
              key: const ValueKey('range-add-effect'),
              icon: const Icon(Icons.auto_awesome, size: 16),
              onPressed: () => _pickEffect(context),
              label: const Text('Effect on all'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('range-add-mask'),
              icon: const Icon(Icons.layers_clear, size: 16),
              onPressed: () => _pickMask(context),
              label: const Text('Mask all by...'),
            ),
          ]),
        ],
        const Divider(),
      ],
    );
  }

  /// Path: the selected layer's position path (or the selected key
  /// line's) as a whole - moved, turned round its middle and sized, by
  /// parameters of its own; the keys keep their times and eases.
  Widget _pathSection() {
    final t = app.pathTarget;
    final layer = findLayer(app.project, app.selection.selectedLayer)!;
    Widget param(String key, String label, List<double> values, ParamScale scale, void Function(List<double>) set,
            List<double> reset) =>
        ParamEditor(
          key: ValueKey('path-$key'),
          prefKey: 'timeline.path $key',
          label: label,
          values: values,
          componentLabels: values.length == 2 ? const ['x', 'y'] : null,
          scale: scale,
          onEditStart: app.pushUndo,
          onChanged: set,
          onCommit: (v) {
            app.pushUndo();
            set(v);
          },
          trailing: [
            ResetIconButton(onPressed: () {
              app.pushUndo();
              set(reset);
            }),
          ],
        );
    return Column(
      key: const ValueKey('path-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.route, size: 18),
          const SizedBox(width: 6),
          const Text('Path', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t == null
                  ? ''
                  : '${t.line ? 'the selected key line' : 'the whole path'}: frames ${t.a + layer.startFrame} - ${t.b + layer.startFrame}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        if (t == null)
          const Hint('Two position keys or more make a path - then it can be moved, turned and sized here as a whole')
        else ...[
          param('move', 'move px', [...layer.pathOffset],
              const ParamScale.ruler(unitsPerPixel: 0.5, minorTick: 10, majorTick: 50, decimals: 1), app.movePathTo, [0, 0]),
          param('turn', 'turn', [layer.pathTurn], ParamScale.degrees, (v) => app.turnPathTo(v.first), [0]),
          param('size', 'size ×', [layer.pathScale], const ParamScale.slider(0.1, 4, decimals: 2),
              (v) => app.scalePathTo(v.first.clamp(0.05, 100).toDouble()), [1]),
          const Hint('Turn and size go round the path\'s middle. A key line selected in the expanded keys: only its stretch'),
        ],
      ],
    );
  }

  Future<void> _pickEffect(BuildContext context) async {
    final ids = effectRegistry.values.toList()..sort((x, y) => x.name.compareTo(y.name));
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => ListView(children: [
        for (final d in ids) ListTile(dense: true, title: Text(d.name), onTap: () => Navigator.pop(context, d.id)),
      ]),
    );
    if (id != null) app.rangeAddEffect(id);
  }

  Future<void> _pickMask(BuildContext context) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => ListView(children: [
        for (final l in app.project.layers)
          ListTile(dense: true, title: Text(l.name), onTap: () => Navigator.pop(context, l.id)),
      ]),
    );
    if (id != null) app.rangeAddMask(id);
  }

  /// The tab's settings for the whole timeline, shown with or without a
  /// selected layer.
  List<Widget> _general() => [
            // the selected layer's start (any frame) and the whole clip's
            // length.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Move layer to frame:', style: TextStyle(fontSize: 12)),
                SizedBox(
                  width: 72,
                  child: NumField(
                    key: const ValueKey('move-layer-to-frame'),
                    value: (findLayer(app.project, app.selection.selectedLayer)?.startFrame ?? 0).toDouble(),
                    integer: true,
                    onCommit: (v) => app.moveSelectedLayerToFrame(v.round()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Clip length:', style: TextStyle(fontSize: 12)),
                SizedBox(
                  width: 72,
                  child: NumField(
                    key: const ValueKey('clip-length'),
                    value: app.maxFrame.toDouble(),
                    onCommit: (v) => app.setMaxFrame(v.round()),
                    integer: true,
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            _rangeSection(),
            SwitchListTile(
              key: const ValueKey('keep-keys-across-layers'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep selected keys when leaving a layer'),
              subtitle: hint('They stay lit, so keys of several layers can be moved together'),
              value: app.keepKeysAcrossLayers,
              onChanged: (v) => app.setAppPreference('keepKeysAcrossLayers', v),
            ),
            _snapSection(),
            SwitchListTile(
              key: const ValueKey('loop-extended-videos'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Loop videos made longer than their clip'),
              subtitle: hint('Off: the last frame stays'),
              value: loopExtendedVideos,
              onChanged: (v) => app.setAppPreference('loopExtendedVideos', v),
            ),
      ];

  Widget _snapSection() => Column(
        key: const ValueKey('timeline-snap'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(child: Text('Snap layer edges', style: TextStyle(fontWeight: FontWeight.bold))),
            Switch(value: app.snapTimelineLayersEnabled, onChanged: (_) => app.toggleSnapTimelineLayers()),
          ]),
          Row(children: [
            const SizedBox(width: 90, child: Hint('sensitivity (frames)')),
            Expanded(
              child: Slider(
                key: const ValueKey('timeline-snap-frames'),
                value: app.timelineSnapFrames.toDouble(),
                min: 1,
                max: 30,
                divisions: 29,
                onChanged: app.snapTimelineLayersEnabled ? (v) => app.setTimelineSnapFrames(v.round()) : null,
              ),
            ),
            SizedBox(width: 24, child: Text('${app.timelineSnapFrames}')),
          ]),
        ],
      );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) {
          return ListView(padding: const EdgeInsets.all(8), children: [
            ..._general(),
            const Divider(height: 16),
            const Text('Select a layer on the timeline or in Layers'),
            Align(alignment: Alignment.centerLeft, child: LayersButton(app: app)),
          ]);
        }
        final rows = timelineRows(app.project);
        final own = rows.indexWhere((r) => r.contains(layer));
        final mates = rows[own].where((l) => !identical(l, layer)).toList();
        bool fits(int r) => r >= 0 && r < rows.length && r != own && fitsInTimelineRow(rows[r], layer);

        final end = layer.startFrame + layer.durationFrames;
        final candidates = <int>[
          for (var r = 0; r < rows.length; r++)
            if (r != own &&
                timelineRowGaps(rows[r]).any((g) => g.$1 < end && g.$2 > layer.startFrame))
              r
        ];
        // lay over: any other row with layers where this layer is.
        final overlayRows = <int>[
          for (var r = 0; r < rows.length; r++)
            if (r != own && timelineRowSpans(rows[r]).any((g) => g.$1 < end && g.$2 > layer.startFrame)) r
        ];
        final choices = {...candidates, ...overlayRows}.toList()..sort();
        var picked = choices.where((r) => rows[r].any((l) => l.id == _targetLayerId)).firstOrNull;
        picked ??= choices.firstOrNull;
        final target = candidates.contains(picked) ? picked : null;
        final overlayTarget = overlayRows.contains(picked) ? picked : null;

        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            // range, kept keys, snapping, video loop: always here.
            ..._general(),
            _pathSection(),
            const Divider(height: 16),
            Text(layer.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Row ${own + 1} of ${rows.length}'
              '${mates.isEmpty ? '' : ' - shared with ${mates.map((l) => l.name).join(', ')}'}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: fits(own - 1) ? () => app.joinNeighbourRow(layer.id, up: true) : null,
                  icon: const Icon(Icons.vertical_align_top, size: 18),
                  label: const Text('Into row above'),
                ),
                OutlinedButton.icon(
                  onPressed: fits(own + 1) ? () => app.joinNeighbourRow(layer.id, up: false) : null,
                  icon: const Icon(Icons.vertical_align_bottom, size: 18),
                  label: const Text('Into row below'),
                ),
                OutlinedButton.icon(
                  onPressed: mates.isEmpty ? null : () => app.takeOwnRow(layer.id),
                  icon: const Icon(Icons.call_split, size: 18),
                  label: const Text('Own row'),
                ),
              ],
            ),
            const Hint('A row takes a layer only where it has free time. On the timeline, drag the '
              'handle on the right onto the middle of another row to put the layer into it, '
              'or between rows to give it a row of its own. In a shared row a layer stops at '
              'its neighbours when moved or trimmed.'),
            const Divider(height: 24),
            SwitchListTile(
              key: const ValueKey('loop-switch'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Loop', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: hint('Repeat this layer after its end'),
              value: layer.loopEnabled,
              onChanged: (v) => app.setLayerLoop(layer.id, enabled: v, until: layer.loopUntil),
            ),
            if (layer.loopEnabled)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('To the end'),
                    selected: layer.loopUntil == null,
                    onSelected: (_) => app.setLayerLoop(layer.id, enabled: true),
                  ),
                  ChoiceChip(
                    label: const Text('Until frame'),
                    selected: layer.loopUntil != null,
                    onSelected: (_) => app.setLayerLoop(layer.id,
                        enabled: true,
                        until: layer.loopUntil ??
                            (app.currentFrame > end ? app.currentFrame : end + layer.durationFrames)),
                  ),
                  if (layer.loopUntil != null)
                    NumField(
                      key: const ValueKey('loop-until'),
                      value: layer.loopUntil!.toDouble(),
                      integer: true,
                      onCommit: (v) => app.setLayerLoop(layer.id, enabled: true, until: math.max(end, v.round())),
                    ),
                ],
              ),
            const Divider(height: 24),
            const Text('Fill the gaps / lay over a row', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            if (candidates.isEmpty && overlayRows.isEmpty)
              const Text('No other row has layers or gaps where this layer is.', style: TextStyle(fontSize: 12))
            else ...[
              DropdownButton<int>(
                isExpanded: true,
                value: picked,
                items: [
                  for (final r in choices)
                    DropdownMenuItem(
                      value: r,
                      child: Text('Row ${r + 1}: ${_rowLabel(rows[r])}', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (r) {
                  if (r != null) setState(() => _targetLayerId = rows[r].first.id);
                },
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: target == null ? null : () => app.fillRowGapsWith(layer.id, target),
                icon: const Icon(Icons.format_indent_increase, size: 18),
                label: const Text('Fill gaps with this layer'),
              ),
            ],
            const SizedBox(height: 4),
            OutlinedButton.icon(
              key: const ValueKey('overlay-row'),
              onPressed: overlayTarget == null ? null : () => app.overlayRowWith(layer.id, overlayTarget),
              icon: const Icon(Icons.layers, size: 18),
              label: Text(overlayTarget == null ? 'Lay over a row' : 'Lay over row ${overlayTarget + 1}'),
            ),
            const Hint('Lay over: the layer keeps only its parts where that row has layers (the row\'s '
              'gaps become its gaps) and goes into a new row drawn over it.'),
            const SizedBox(height: 4),
            const Hint('The layer is cut to the empty stretches between the layers of that row and '
              'moves into it; its parts outside the gaps are removed. It keeps its timing - '
              'each part shows what the layer showed at that time.'),
          ],
        );
      },
    );
  }
}
