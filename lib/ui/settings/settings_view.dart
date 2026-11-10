import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../stage/stage_camera.dart' show stageRotateEnabled;
import '../stage/stage_painter.dart' show showBoxOverEffectGrid;

import '../common/param_editor.dart' show rulerLengthScale;

import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../ai/ai_dialogs.dart';
import '../common/hint.dart';
import '../../perf/perf_monitor.dart';
import '../perf/perf_hud.dart';

/// Settings tab: app-wide view options.
class SettingsView extends StatelessWidget {
  final AppState app;
  const SettingsView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(8),
        children: [
          ListTile(
            dense: true,
            title: const Text('Frame rate'),
            subtitle: hint('Frames per second of the timeline, playback and export. Changing it re-times '
                'the layers and keys so the animation keeps its speed (clears undo). Only these rates: '
                'the ones video encoders, GIF timing (1/100 s) and phones play back evenly - others '
                'would stutter or drift.'),
            trailing: DropdownButton<int>(
              value: projectFpsOptions.contains(fps) ? fps : null,
              hint: Text('$fps'),
              items: [for (final f in projectFpsOptions) DropdownMenuItem(value: f, child: Text('$f fps'))],
              onChanged: (v) {
                if (v != null) app.setProjectFps(v);
              },
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Hide top icons'),
            subtitle: hint('The buttons over the top of the stage (handles, visual aids, grid, export)'),
            value: app.hideStageIcons,
            onChanged: (_) => app.toggleHideStageIcons(),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Timeline', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          SwitchListTile(
            key: const ValueKey('pref-stageZoomLock'),
            dense: true,
            title: const Text('Stage zoom lock'),
            subtitle: hint('The canvas\'s side edges stay on the screen\'s sides: it always fills the width '
                '(zoom in and move up / down freely)'),
            value: app.stageZoomLock,
            onChanged: (v) => app.setAppPreference('stageZoomLock', v),
          ),
          SwitchListTile(
            key: const ValueKey('pref-showBoxOverEffectGrid'),
            dense: true,
            title: const Text('Box outline over effect grids'),
            subtitle: hint('Squeeze, bend, 3D...: the handles\' box line also shows over the effect\'s grid. '
                'Off: the grid alone outlines the shape'),
            value: showBoxOverEffectGrid,
            onChanged: (v) => app.setAppPreference('showBoxOverEffectGrid', v),
          ),
          SwitchListTile(
            key: const ValueKey('pref-stageRotate'),
            dense: true,
            title: const Text('Turn the stage'),
            subtitle: hint('Twist two fingers to turn the view, like the pinch zoom (it sticks to straight angles). '
                'Only the view turns, not the picture. Off: straight again'),
            value: stageRotateEnabled,
            onChanged: (v) => app.setAppPreference('stageRotate', v),
          ),
          for (final (name, title, subtitle) in const [
            ('timelineLayerColors', 'Layer colours', 'Off: every lane in one colour that follows the light / dark theme'),
            ('timelineFrameCounts', 'Frame counts', 'The length at the end of each layer and the frames between keys, in small print'),
            ('keysMayLeaveLayer', 'Keys can leave their layer',
                'Dragging keys past the layer\'s start or end keeps them there (dimmed, cut off). Off: they stop at the edges'),
            ('rangeAsSelection', 'Range lights up its layers',
                'The range highlights the layers in it like selected ones, instead of a blue band down the whole timeline'),
          ])
            SwitchListTile(
              key: ValueKey('pref-$name'),
              dense: true,
              title: Text(title),
              subtitle: hint(subtitle),
              value: app.appPreference(name),
              onChanged: (v) => app.setAppPreference(name, v),
            ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('Keys', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            dense: true,
            title: const Text('Ease of new keys'),
            trailing: DropdownButton<String>(
              key: const ValueKey('pref-defaultKeyEase'),
              value: defaultKeyEasingName,
              items: [
                for (final (name, label) in const [
                  ('easeInOut', 'Ease in-out'),
                  ('easeIn', 'Ease in'),
                  ('easeOut', 'Ease out'),
                  ('linear', 'Linear'),
                ])
                  DropdownMenuItem(value: name, child: Text(label)),
              ],
              onChanged: (v) {
                if (v != null) app.setDefaultKeyEase(v);
              },
            ),
          ),
          ListTile(
            dense: true,
            title: Text('Ruler length ×${rulerLengthScale.toStringAsFixed(2)}'),
            subtitle: hint('How much of a value one ruler width covers in the parameters (longer: coarser, faster).'),
            trailing: SizedBox(
              width: 160,
              child: Slider(
                key: const ValueKey('pref-rulerLength'),
                value: math.log(rulerLengthScale) / math.ln2,
                min: -2,
                max: 2,
                divisions: 8,
                onChanged: (v) => app.setAppPreference('rulerLength', math.pow(2, v).toDouble()),
              ),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('pref-masterKeysShareEase'),
            dense: true,
            title: const Text('Master keys share one ease'),
            subtitle: hint('Editing the curve of a key where every parameter is keyed changes it for all of them'),
            value: masterKeysShareEase,
            onChanged: (v) => app.setAppPreference('masterKeysShareEase', v),
          ),
          const Divider(),
          SwitchListTile(
            key: const ValueKey('recenter-pieces-switch'),
            dense: true,
            title: const Text('Recenter detached pieces'),
            subtitle: hint('A detached piece moves, turns and swings (pendulum) about its own centre. '
                'Off: about the centre of the object it came from. Nothing on screen changes either way.'),
            value: recenterDetachedPieces,
            onChanged: (_) => app.toggleRecenterDetachedPieces(),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: PerfMonitor.instance.visible,
            builder: (context, on, _) => SwitchListTile(
              key: const ValueKey('perf-hud-switch'),
              dense: true,
              title: const Text('Performance HUD'),
              subtitle: hint('Frame time, render cost, video decoding and memory over the stage '
                  '(for all projects; never part of an export)'),
              value: on,
              onChanged: (_) => togglePerfHud(),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('pref-showDescriptions'),
            dense: true,
            title: const Text('Show descriptions'),
            subtitle: hint('The small grey explanations under the settings and tools'),
            value: descriptionsVisible.value,
            onChanged: (v) => app.setAppPreference('showDescriptions', v),
          ),
          ListTile(
            key: const ValueKey('export-ai-guide'),
            dense: true,
            title: const Text('Export AI guide'),
            subtitle: hint('MCORE_AGENT_GUIDE.md: give it to any chatbot and it can write MCore projects '
                '(Import from text brings them in)'),
            trailing: const Icon(Icons.description_outlined),
            onTap: () async {
              final path = await exportAgentGuide();
              if (path != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $path')));
              }
            },
          ),
          ListTile(
            key: const ValueKey('pref-tool-guides'),
            dense: true,
            title: const Text('Show the tool guides again'),
            subtitle: hint('The tours of the bottom tool field and the field above it, next time each appears'),
            trailing: const Icon(Icons.tour_outlined),
            onTap: () {
              app.showToolGuidesAgain();
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('The guides show next time the fields appear')));
            },
          ),
          SwitchListTile(
            key: const ValueKey('pref-handlesRightHanded'),
            dense: true,
            title: const Text('Handles for the right hand'),
            subtitle: hint('On: move bottom right, size top right, turn top left. Off: mirrored for the left hand'),
            value: handlesRightHanded,
            onChanged: (v) => app.setAppPreference('handlesRightHanded', v),
          ),
          SwitchListTile(
            key: const ValueKey('pref-eyedropperAlpha'),
            dense: true,
            title: const Text('Eyedropper takes the alpha'),
            subtitle: hint('The picked colour keeps how see-through it is on the stage (its opacity too). Off: always solid'),
            value: app.eyedropperAlpha,
            onChanged: (v) => app.setAppPreference('eyedropperAlpha', v),
          ),
          SwitchListTile(
            key: const ValueKey('pref-playOnPlayheadTap'),
            dense: true,
            title: const Text('Tap the playhead to play'),
            subtitle: hint('With the timeline pinned to the playhead: its head starts and stops playback'),
            value: app.playOnPlayheadTap,
            onChanged: (v) => app.setAppPreference('playOnPlayheadTap', v),
          ),
          SwitchListTile(
            key: const ValueKey('pref-rulerTapSteps'),
            dense: true,
            title: const Text('Tap the ruler to step'),
            subtitle: hint('A tap on the timeline\'s top ruler moves the playhead: right of it forward, left of it back'),
            value: app.rulerTapSteps,
            onChanged: (v) => app.setAppPreference('rulerTapSteps', v),
          ),
          if (app.rulerTapSteps)
            ListTile(
              dense: true,
              title: const Text('Step (frames)'),
              trailing: SizedBox(
                width: 64,
                child: TextFormField(
                  key: const ValueKey('pref-rulerStepFrames'),
                  initialValue: '${app.rulerStepFrames}',
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null && n >= 1) app.setAppPreference('rulerStepFrames', n.clamp(1, 10000));
                  },
                ),
              ),
            ),
          SwitchListTile(
            key: const ValueKey('pref-rulerInFrames'),
            dense: true,
            title: const Text('Ruler in frames'),
            subtitle: hint('Frame numbers instead of seconds: every 10th, every 100th when zoomed out'),
            value: app.rulerInFrames,
            onChanged: (v) => app.setAppPreference('rulerInFrames', v),
          ),
          SwitchListTile(
            key: const ValueKey('loop-playback-switch'),
            dense: true,
            title: const Text('Loop playback'),
            subtitle: hint('Off: playback stops at the end'),
            value: app.loopPlayback,
            onChanged: (_) => app.toggleLoopPlayback(),
          ),
          const Divider(),
          _StorageSection(app: app),
        ],
      ),
    );
  }
}

/// Storage: how much imported media and its caches take, what the undo
/// history alone keeps, and the two actions that free it.
class _StorageSection extends StatefulWidget {
  final AppState app;
  const _StorageSection({required this.app});

  @override
  State<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends State<_StorageSection> {
  late Future<StorageOverview> _overview = widget.app.storageOverview();
  bool _busy = false;

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _overview = widget.app.storageOverview();
    });
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(key: const ValueKey('storage-confirm'), onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _clearUndo(StorageOverview o) async {
    final ok = await _confirm(
        'Clear undo cache?',
        'Forgets the undo / redo history (${o.undoSteps} steps) and deletes the media only it keeps '
            '(${_mb(o.undoMediaBytes)} on disk, ${_mb(o.undoDecodedBytes)} of decoded frames). '
            'Deleted layers can no longer be brought back.',
        'Clear');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await widget.app.clearUndoCache();
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _trim() async {
    setState(() => _busy = true);
    final preview = await widget.app.previewMediaTrim();
    if (!mounted) return;
    setState(() => _busy = false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (preview.isEmpty) {
      messenger?.showSnackBar(const SnackBar(content: Text('Nothing to trim: the layers use their media whole.')));
      return;
    }
    final ok = await _confirm(
        'Trim unused media?',
        'Keeps only the parts of videos and sounds the layers play (plus 1 s on each side) and '
            'rewrites them - frees about ${_mb(preview.freedBytes)}. The undo / redo history is '
            'cleared: the parts cut away no longer exist.',
        'Trim');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final failed = await widget.app.trimUnusedMedia(preview);
      if (failed.isNotEmpty) {
        messenger?.showSnackBar(SnackBar(content: Text('Not trimmed (left as they were): ${failed.join(', ')}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StorageOverview>(
      future: _overview,
      builder: (context, snap) {
        final o = snap.data;
        return Column(
          key: const ValueKey('storage-overview'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              dense: true,
              title: const Text('Storage'),
              subtitle: Text(o == null
                  ? '...'
                  : 'Media copies ${_mb(o.mediaCopyBytes)} · frame & sound caches ${_mb(o.cacheBytes)}\n'
                      'Undo: ${o.undoSteps} steps, keeping ${_mb(o.undoMediaBytes)} of media no layer uses '
                      '(${_mb(o.undoDecodedBytes)} decoded)'),
              trailing: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(icon: const Icon(Icons.refresh), tooltip: 'refresh', onPressed: _refresh),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  key: const ValueKey('clear-undo-cache'),
                  onPressed: o == null || _busy ? null : () => _clearUndo(o),
                  child: const Text('Clear undo cache'),
                ),
                OutlinedButton(
                  key: const ValueKey('trim-media'),
                  onPressed: _busy ? null : _trim,
                  child: const Text('Trim unused media'),
                ),
              ],
            ),
            if (o != null && o.files.isNotEmpty)
              ExpansionTile(
                key: const ValueKey('storage-files'),
                dense: true,
                title: Text('Files (${o.files.length})'),
                children: [
                  for (final (name, bytes) in o.files)
                    ListTile(dense: true, title: Text(name, style: const TextStyle(fontSize: 12)), trailing: Text(_mb(bytes))),
                ],
              ),
          ],
        );
      },
    );
  }
}
