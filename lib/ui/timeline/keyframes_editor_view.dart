import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart' hide Transform;

import '../../app_state.dart';
import '../common/no_layer.dart';
import '../common/num_field.dart';
import '../graph_editor/graph_editor_view.dart';
import 'key_mode_panel.dart';

/// A dedicated "Keyframes" tab - asked for a separate place to edit keyframe
/// animation directly, beyond the compact merged scrub+strip
/// (timeline_view.dart), which is precise for drag-to-retime but too small a
/// target for review/cleanup or for exposing per-track options like looping.
///
/// Per-track `loop` - already fully implemented in movement_core's
/// interpolation.dart (evaluateTrack wraps localFrame back into the
/// keyframe range once past the last keyframe, when trk.loop is true)
/// but never had a UI toggle anywhere in this app until now; this tab
/// is that toggle, one per animatable track (loop is a per-Track
/// property, not a single layer-wide switch, so each of the 4 movement
/// tracks gets its own checkbox rather than inventing a layer-level
/// concept the data model doesn't have).
///
/// "Moving" a keyframe here is precise numeric retiming (long-press ->
/// dialog with a frame number field) - a different, complementary way
/// to move keyframes from the strip's direct-drag, useful when you want
/// an EXACT target frame rather than whatever a finger lands on.
///
/// (the 3 keyframe-interaction features need to move to the very top of the
/// Keyframes section) - copy/paste/multiselect used to live in the
/// always-visible TimelineToolbar; they're keyframe-tab concerns, so they
/// moved here, as the first thing this tab shows.
///
/// UNVERIFIED like the rest of ui/ - needs the Flutter engine, not
/// available in this sandbox.
class KeyframesEditorView extends StatelessWidget {
  final AppState app;
  const KeyframesEditorView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) {
          return NoLayer(app: app, text: 'No layer selected');
        }
        // only the parameters that have keys (every tab's, and the
        // animation layers').
        final tracks = <String, Track>{};
        visitLayerTracksNamed(layer, (name, trk) {
          if (trk.keyframes.isNotEmpty) tracks[name] = trk;
        });
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            _keyframeActionsRow(context, layer),
            if (kfSelectedFrames.isNotEmpty) _selectedKeysRow(context, layer),
            SwitchListTile(
              key: const ValueKey('key-edit-all'),
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.only(left: 4),
              title: const Text('Edit the whole object', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                  'any change (scale, place, an effect...) goes to all its keys alike - the animation stays as it is',
                  style: TextStyle(fontSize: 11)),
              value: layer.editAll,
              onChanged: (v) {
                app.pushUndo();
                layer.editAll = v;
                app.commitEdit();
              },
            ),
            _freeMoveField(context),
            const Divider(height: 16),
            KeyModePanel(app: app, layer: layer),
            const Divider(height: 16),
            // the parameters with keys, folded away until opened (the
            // header's list button).
            if (app.showKeyParams) ...[
              if (tracks.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('No keys yet', style: TextStyle(color: Colors.grey)),
                ),
              for (final entry in tracks.entries)
                _trackSection(context, layer, entry.key, entry.value),
            ],
          ],
        );
      },
    );
  }

  /// Free move: drag the object along its way on the stage; confirmed, it
  /// becomes a key layer of two keys (the curve in their handles).
  Widget _freeMoveField(BuildContext context) {
    final rec = app.freeMoveRecording;
    return Card(
      key: const ValueKey('free-move-field'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.gesture, size: 18),
            const SizedBox(width: 6),
            const Expanded(child: Text('Free move', style: TextStyle(fontWeight: FontWeight.w600))),
            const Text('takes', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            SizedBox(
              width: 56,
              child: NumField(
                key: const ValueKey('free-move-seconds'),
                value: app.freeMoveSeconds,
                onCommit: app.setFreeMoveSeconds,
              ),
            ),
            const Text(' s', style: TextStyle(fontSize: 12)),
          ]),
          const SizedBox(height: 4),
          Text(
              rec
                  ? (app.freeMovePath.length < 2
                      ? 'Drag the object on the stage along its way.'
                      : 'Drag again to draw it anew, or confirm.')
                  : 'Move the object by hand along any curve: it becomes a key layer of two keys, from the playhead.',
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 4),
          Row(children: [
            if (!rec)
              OutlinedButton.icon(
                key: const ValueKey('free-move-start'),
                onPressed: app.startFreeMove,
                icon: const Icon(Icons.gesture, size: 16),
                label: const Text('Draw the move'),
              )
            else ...[
              FilledButton.icon(
                key: const ValueKey('free-move-confirm-tab'),
                onPressed: app.freeMovePath.length >= 2 ? app.confirmFreeMove : null,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Confirm'),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: app.cancelFreeMove, child: const Text('Cancel')),
            ],
          ]),
        ]),
      ),
    );
  }

  /// A parameter whose key at `localFrame` ends a transition (one before
  /// it), and that transition's number - the shared key's ease is edited
  /// on it (and goes to every parameter's key there).
  (Track, int)? _masterEaseTrack(Layer layer, int localFrame) {
    (Track, int)? found;
    visitActiveLayerTracks(layer, (trk) {
      if (found != null) return;
      final i = trk.keyframes.indexWhere((k) => k.frame == localFrame);
      if (i >= 1) found = (trk, i - 1);
    });
    return found;
  }

  /// copy/paste/multiselect - moved here from timeline_toolbar.dart (see
  /// this file's own top-level doc comment).
  Widget _keyframeActionsRow(BuildContext context, Layer layer) {
    final localFrame = localFrameOf(layer, app.currentFrame);
    final allKeyed = allTracksKeyedAt(layer, localFrame);
    return Row(
      children: [
        Text('Keyframes', style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        // a "master key" that records every parameter of the object at the
        // current frame at once; pressing it again on a fully keyed frame
        // removes those keys.
        IconButton(
          icon: Icon(allKeyed ? Icons.key : Icons.key_outlined, size: 18,
              color: allKeyed ? Theme.of(context).colorScheme.primary : null),
          tooltip: allKeyed
              ? 'remove the keys of all parameters at this frame'
              : 'key all parameters at this frame',
          onPressed: () {
            app.pushUndo();
            if (allKeyed) {
              unkeyAllTracks(layer, localFrame);
            } else {
              keyAllTracks(app.project, layer, localFrame);
            }
            app.commitEdit();
          },
          visualDensity: VisualDensity.compact,
        ),
        // the master key's one ease: every parameter's transition into it.
        if (allKeyed && _masterEaseTrack(layer, localFrame) != null)
          IconButton(
            key: const ValueKey('master-key-ease'),
            icon: const Icon(Icons.show_chart, size: 18),
            tooltip: 'ease of the shared key (all parameters)',
            onPressed: () {
              final (trk, seg) = _masterEaseTrack(layer, localFrame)!;
              openEase(context, app: app, track: trk, componentCount: trk.defaultValue is List ? 2 : 1, segment: seg, shared: true);
            },
            visualDensity: VisualDensity.compact,
          ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'copy selected keyframes',
          onPressed: kfSelectedFrames.isEmpty ? null : app.copySelectedKfs,
          visualDensity: VisualDensity.compact,
        ),
        // the selected key cluster, mirrored so the animation plays back the
        // other way, placed right after it.
        IconButton(
          icon: const Icon(Icons.u_turn_left, size: 18),
          tooltip: 'reverse: add a mirrored copy after the selected keys',
          onPressed: kfSelectedFrames.isEmpty ? null : app.reverseSelectedKfs,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: const Icon(Icons.paste, size: 18),
          tooltip: 'paste keyframes at current frame',
          onPressed: app.pasteKfsAtCurrentFrame,
          visualDensity: VisualDensity.compact,
        ),
        // (multiselect lives in the top toolbar) - show / fold the
        // parameters with keys.
        IconButton(
          key: const ValueKey('key-params-toggle'),
          icon: Icon(app.showKeyParams ? Icons.expand_less : Icons.list, size: 18),
          tooltip: app.showKeyParams ? 'fold the parameters with keys' : 'show the parameters with keys',
          onPressed: app.toggleShowKeyParams,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// The selected key(s) at the top, same chips as the track rows below:
  /// the frame, and which parameters have a key there.
  Future<void> _pickKeysTarget(BuildContext context, Layer layer) async {
    final id = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Move the selected keys to...'),
        children: [
          for (final l in app.project.layers)
            if (!identical(l, layer))
              SimpleDialogOption(
                key: ValueKey('keys-to-${l.id}'),
                onPressed: () => Navigator.pop(c, l.id),
                child: Text(l.name),
              ),
        ],
      ),
    );
    if (id != null) app.moveSelectedKeysToLayer(id);
  }

  Widget _selectedKeysRow(BuildContext context, Layer layer) {
    final frames = kfSelectedFrames.toList()..sort();
    final named = <String, Track>{};
    visitLayerTracksNamed(layer, (name, trk) => named[name] = trk);
    return Padding(
      key: const ValueKey('selected-keys'),
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Selected', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            IconButton(
              key: const ValueKey('delete-selected-keys'),
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'delete the selected keys',
              visualDensity: VisualDensity.compact,
              onPressed: app.deleteSelectedKfs,
            ),
            // keys can go to another layer: same parameters, same moments.
            TextButton.icon(
              key: const ValueKey('move-keys-to-layer'),
              icon: const Icon(Icons.drive_file_move_outline, size: 16),
              label: const Text('to layer...'),
              onPressed: app.project.layers.length < 2 ? null : () => _pickKeysTarget(context, layer),
            ),
          ]),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final g in frames)
                Material(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => app.setFrame(g.clamp(0, app.maxFrame)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(
                          '${g - layer.startFrame}  ·  ${[
                            for (final e in named.entries)
                              if (e.value.keyframes.any((k) => k.frame + layer.startFrame == g)) e.key
                          ].join(', ')}'),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _trackSection(
      BuildContext context, Layer layer, String label, Track track) {
    final sortedKfs = [...track.keyframes]
      ..sort((a, b) => a.frame.compareTo(b.frame));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label[0].toUpperCase() + label.substring(1), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              // a frame number, + to key the field there (its current value).
              _AddKeyAt(
                key: ValueKey('add-key-at-$label'),
                onAdd: (f) {
                  if (track.keyframes.any((k) => k.frame == f)) return;
                  app.pushUndo();
                  final v = evaluateTrack(app.project, track, f.toDouble(), layer);
                  track.keyframes
                    ..add(Keyframe(frame: f, value: v is List ? List<double>.from(v) : v))
                    ..sort((a, b) => a.frame.compareTo(b.frame));
                  if (track.spatial) autoComputeTangents(track);
                  app.commitEdit();
                },
              ),
              const Spacer(),
              // show / hide its keys on the timeline.
              IconButton(
                key: ValueKey('track-eye-$label'),
                icon: Icon(track.hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                tooltip: track.hidden ? 'show its keys on the timeline' : 'hide its keys on the timeline',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  app.pushUndo();
                  track.hidden = !track.hidden;
                  app.commitEdit();
                },
              ),
              const Text('Loop', style: TextStyle(fontSize: 12)),
              Checkbox(
                value: track.loop,
                onChanged: (_) {
                  app.pushUndo();
                  track.loop = !track.loop;
                  app.commitEdit();
                },
              ),
            ],
          ),
          if (sortedKfs.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('no keyframes',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final k in sortedKfs)
                  _keyframeRow(context, layer, track, k)
              ],
            ),
          const Divider(height: 16),
        ],
      ),
    );
  }

  Widget _keyframeRow(
      BuildContext context, Layer layer, Track track, Keyframe k) {
    final globalFrame = k.frame + layer.startFrame;
    final isCurrent = app.currentFrame == globalFrame;
    return Material(
      color: isCurrent
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => app.setFrame(globalFrame),
        onLongPress: () => _showRetimeDialog(context, layer, track, k),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${k.frame}'),
              const SizedBox(width: 6),
              InkWell(
                onTap: () {
                  app.pushUndo();
                  track.keyframes.remove(k);
                  if (track.spatial) autoComputeTangents(track);
                  app.commitEdit();
                },
                child: const Icon(Icons.close, size: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRetimeDialog(
      BuildContext context, Layer layer, Track track, Keyframe k) async {
    final controller = TextEditingController(text: '${k.frame}');
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Move keyframe to frame'),
        content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, int.tryParse(controller.text)),
              child: const Text('Move')),
        ],
      ),
    );
    if (result == null) return;
    app.pushUndo();
    k.frame = result.clamp(0, layer.durationFrames);
    track.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
    if (track.spatial) autoComputeTangents(track);
    app.commitEdit();
  }
}

class _AddKeyAt extends StatefulWidget {
  final void Function(int frame) onAdd;
  const _AddKeyAt({super.key, required this.onAdd});

  @override
  State<_AddKeyAt> createState() => _AddKeyAtState();
}

class _AddKeyAtState extends State<_AddKeyAt> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add() {
    final f = int.tryParse(_c.text.trim());
    if (f == null || f < 0) return;
    widget.onAdd(f);
    _c.clear();
  }

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 48,
          height: 28,
          child: TextField(
            key: const ValueKey('add-key-field'),
            controller: _c,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(isDense: true, hintText: 'frame', contentPadding: EdgeInsets.all(6)),
            onSubmitted: (_) => _add(),
          ),
        ),
        IconButton(
          key: const ValueKey('add-key-plus'),
          icon: const Icon(Icons.add, size: 16),
          tooltip: 'add a key at that frame',
          visualDensity: VisualDensity.compact,
          onPressed: _add,
        ),
        const SizedBox(width: 4),
      ]);
}
