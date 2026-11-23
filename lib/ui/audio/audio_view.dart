import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../media/media_library.dart';
import '../common/num_field.dart';
import '../../app_state.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../graph_editor/graph_editor_view.dart';
import '../../io/freeze_watch.dart';

/// Audio tab: the selected sound layer's volume (animatable) and mute, and
/// importing sound. Where the sound starts in its file and how long it
/// plays are edited on the timeline like video: trim, split, loop.
class AudioView extends StatelessWidget {
  final AppState app;
  const AudioView({super.key, required this.app});

  static String _time(double seconds) {
    final m = seconds ~/ 60;
    final s = seconds - m * 60;
    return '$m:${s.toStringAsFixed(2).padLeft(5, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    FreezeWatch.at('building $runtimeType');
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        final importButton = OutlinedButton.icon(
          key: const ValueKey('audio-import'),
          icon: const Icon(Icons.audiotrack, size: 18),
          label: const Text('Add audio'),
          // the phone's music, searchable (Files... there for the rest).
          onPressed: () => openMediaLibrary(context, app, section: 'audio'),
        );
        final error = app.audioError;
        // a video: its speed (its sound goes along).
        if (layer != null && layer.content.shape == 'video') {
          return ListView(padding: const EdgeInsets.all(8), children: [
            Row(children: [
              const Icon(Icons.movie_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(layer.name,
                      style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
            ]),
            _speedRow(layer),
          ]);
        }
        // nothing (or no sound) picked: the same centred offer as Text.
        if (layer == null || layer.content.shape != 'audio') {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Select an audio layer, or add one'),
                const SizedBox(height: 8),
                importButton,
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('Preview without sound: $error',
                        style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
                  ),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            ...[
              ..._layerControls(context, layer),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Preview without sound: $error',
                    style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
              ),
          ],
        );
      },
    );
  }

  /// How fast it plays its source: quick picks and an exact number - its
  /// length follows (twice as fast, half as long); a sound gets higher /
  /// lower with it, like a tape.
  Widget _speedRow(Layer layer) {
    final s = layer.content.mediaSpeed;
    return Padding(
      key: const ValueKey('media-speed'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // one line: the exact number, then the quick picks scrolling.
        SizedBox(
          height: 40,
          child: Row(children: [
            const Text('Speed', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 8),
            SizedBox(
              width: 64,
              child: NumField(
                key: const ValueKey('media-speed-field'),
                width: 64,
                value: s,
                onCommit: (v) => app.setMediaSpeedOf(layer.id, v),
              ),
            ),
            const Text(' ×', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 6),
            Expanded(
              child: ListView(
                key: const ValueKey('media-speed-strip'),
                scrollDirection: Axis.horizontal,
                children: [
                  for (final v in const [0.1, 0.25, 0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0, 3.0, 4.0, 8.0])
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: ChoiceChip(
                        key: ValueKey('media-speed-$v'),
                        label: Text('$v×'),
                        selected: (s - v).abs() < 1e-9,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => app.setMediaSpeedOf(layer.id, v),
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
        const Text('Its length follows (twice as fast: half as long); a sound goes higher or lower with it.',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      ]),
    );
  }

  List<Widget> _layerControls(BuildContext context, Layer layer) {
    final c = layer.content;
    final rebuilding = c.audioAssetId != null && app.audioRebuilding.contains(c.audioAssetId);
    final decoded = app.audioPeaks(c.audioAssetId) != null;
    final playing = layer.durationFrames / fps;
    return [
      Row(
        children: [
          const Icon(Icons.audiotrack, size: 18),
          const SizedBox(width: 6),
          Expanded(
              child: Text(layer.name,
                  style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
          const Text('Mute', style: TextStyle(fontSize: 12)),
          Switch(
            key: const ValueKey('audio-mute'),
            value: c.audioMuted,
            onChanged: (v) => app.setAudioMuted(layer.id, v),
          ),
        ],
      ),
      _speedRow(layer),
      Text(
        'From ${_time(c.sourceIn)} of the file, plays ${_time(playing)}'
        '${c.audioDuration != null ? ' (file ${_time(c.audioDuration!)})' : ''}',
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      if (rebuilding)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('Reading the sound again...', style: TextStyle(fontSize: 11)),
        )
      else if (!decoded)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('The sound file is missing - this layer is silent.',
              style: TextStyle(fontSize: 11, color: Colors.redAccent)),
        ),
      const SizedBox(height: 8),
      if (c.volume != null) _volumeRow(context, layer, c.volume!),
      const SizedBox(height: 4),
      const Hint('Trim, split and loop it on the timeline like a video - the waveform on its lane '
        'shows where the beats are.'),
    ];
  }

  Widget _volumeRow(BuildContext context, Layer layer, Track trk) {
    final localFrame = layerLocalFrame(layer, app.currentFrame);
    final value = (evaluateTrack(app.project, trk, localFrame, layer) as num).toDouble();
    final frame = localFrame.round();
    final keyed = trk.keyframes.any((k) => k.frame == frame);
    return ParamEditor(
      prefKey: 'audio.volume',
      label: 'volume',
      values: [value],
      scale: const ParamScale.slider(0, 2, decimals: 2),
      onEditStart: app.pushUndo,
      onChanged: (v) {
        setTrackValueAt(trk, frame, v.first);
        app.commitEdit();
      },
      onCommit: (v) {
        app.pushUndo();
        setTrackValueAt(trk, frame, v.first.clamp(0.0, 2.0));
        app.commitEdit();
      },
      trailing: [
        if (trk.keyframes.length >= 2)
          IconButton(
            icon: const Icon(Icons.show_chart, size: 16),
            tooltip: 'edit easing curve',
            onPressed: () => openEase(context, app: app, track: trk, componentCount: 1),
          ),
        ResetIconButton(onPressed: () {
          app.pushUndo();
          setTrackValueAt(trk, frame, 1.0);
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
        ),
      ],
    );
  }
}
