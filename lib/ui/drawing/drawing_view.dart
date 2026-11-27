import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/color_row.dart';
import '../common/hint.dart';
import '../filters/filters_view.dart' show FilterTrackRow;
import '../../io/freeze_watch.dart';

/// Drawing: tools that paint new layers on the stage. Fill: a tap fills
/// the region it lands in, bounded by the edges of the other layers.
class DrawingView extends StatelessWidget {
  final AppState app;
  const DrawingView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    FreezeWatch.at('building $runtimeType');
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final on = app.drawTool == 'fill';
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            SwitchListTile(
              key: const ValueKey('draw-fill'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.format_color_fill),
              title: const Text('Fill', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: hint('Tap the stage: the region there - bounded only by the edges of the layers - becomes '
                  'a new layer of its own'),
              value: on,
              onChanged: (v) => app.setDrawTool(v ? 'fill' : 'none'),
            ),
            const SizedBox(height: 4),
            const Hint('The region is bounded by the layers\' own outlines as they show - crop, cuts, masks, '
                'flips and deformations included. The fill is a shape and always goes on top.'),
            const SizedBox(height: 4),
            const Text('Bounded by', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              key: const ValueKey('draw-fill-bounds'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('All layers')),
                ButtonSegment(value: true, label: Text('Only the selected')),
              ],
              selected: {app.fillOnlySelected},
              onSelectionChanged: (v) => app.setFillOptions(onlySelected: v.first),
            ),
            const Hint('Only the selected: every other layer is as if it were not there.'),
            ColorRow(label: 'Colour', hex: app.fillColor, onPick: (c) => app.setFillOptions(color: c)),
            SwitchListTile(
              key: const ValueKey('draw-fill-dig'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('A hole through all layers under it'),
              subtitle: hint('The fill cuts its region out of everything under it, down to the background'),
              value: app.fillDig,
              onChanged: (v) => app.setFillOptions(dig: v),
            ),
            const Divider(height: 24),
            // a point that leaves a trail behind it as it moves.
            Row(children: [
              const Expanded(child: Text('Trail point', style: TextStyle(fontWeight: FontWeight.bold))),
              OutlinedButton.icon(
                key: const ValueKey('draw-add-trail'),
                onPressed: app.addTrailPoint,
                icon: const Icon(Icons.gesture, size: 18),
                label: const Text('Add'),
              ),
            ]),
            const Hint('A point that draws a line behind it wherever it goes - by its own keys (Movement), or '
                'carried by a parent it is attached to.'),
            if (findLayer(app.project, app.selection.selectedLayer) case final t? when isTrailShape(t.content.shape))
              ..._trailRows(context, t),
            const Divider(height: 24),
            // a card: how see-through it is and how its edges fade -
            // the selected layer itself, or a new layer of its own.
            Row(children: [
              const Expanded(child: Text('Card', style: TextStyle(fontWeight: FontWeight.bold))),
              OutlinedButton.icon(
                key: const ValueKey('draw-add-card'),
                onPressed: app.addCard,
                icon: const Icon(Icons.crop_portrait, size: 18),
                label: const Text('As its own layer'),
              ),
            ]),
            const Hint('Opacity over all and edges fading out - for the selected layer within its own bounds, or '
                'as a layer of its own (the fill colour, over the whole frame).'),
            if (findLayer(app.project, app.selection.selectedLayer) case final l?
                when !isAudioShape(l.content.shape) && !isCameraShape(l.content.shape)) ...[
              FilterTrackRow(
                  app: app,
                  layer: l,
                  track: l.transform.opacity,
                  keyName: 'card-opacity',
                  label: 'Opacity',
                  min: 0,
                  max: 100,
                  factor: 100,
                  suffix: ' %',
                  resetTo: 1),
              FilterTrackRow(
                  app: app, layer: l, track: l.filters.edgeFade, keyName: 'card-edge-fade', label: 'Edge fade', min: 0, max: 200, suffix: ' px'),
            ],
          ],
        );
      },
    );
  }

  /// The selected trail point: drawing now (a keyed switch), colour,
  /// width, opacity.
  List<Widget> _trailRows(BuildContext context, Layer t) {
    final c = t.content;
    final track = c.trailOn ??= Track(1.0, false);
    final lf = layerLocalFrame(t, app.currentFrame);
    final frame = lf.round();
    final on = trailDrawingAt(c, lf);
    final keyed = track.keyframes.any((k) => k.frame == frame);
    void edit(VoidCallback change) {
      app.pushUndo();
      change();
      app.commitEdit();
    }

    void setOn(bool v) => edit(() {
          // with keys: a key here (the switch is stepped); without: the
          // whole trail.
          if (track.keyframes.isEmpty) {
            track.defaultValue = v ? 1.0 : 0.0;
          } else {
            track.keyframes.removeWhere((k) => k.frame == frame);
            track.keyframes.add(Keyframe(frame: frame, value: v ? 1.0 : 0.0));
            track.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
          }
        });
    final opacity = (evaluateTrack(app.project, t.transform.opacity, lf, t) as num).toDouble();
    return [
      Row(children: [
        Expanded(
          child: SwitchListTile(
            key: const ValueKey('trail-on'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(on ? 'Drawing now' : 'Not drawing now'),
            subtitle: hint('Key it to stop and start the trail in time - what is drawn stays'),
            value: on,
            onChanged: setOn,
          ),
        ),
        IconButton(
          key: const ValueKey('trail-on-key'),
          icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
          tooltip: 'key the switch at this frame',
          onPressed: () => edit(() {
            if (keyed) {
              track.keyframes.removeWhere((k) => k.frame == frame);
            } else {
              track.keyframes.add(Keyframe(frame: frame, value: on ? 1.0 : 0.0));
              track.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
            }
          }),
        ),
      ]),
      ColorRow(label: 'Colour', hex: t.color ?? '#ffffff', onPick: (v) => edit(() => t.color = v)),
      Row(children: [
        SizedBox(width: 110, child: Text('Width ${c.lineWidth.toStringAsFixed(1)}')),
        Expanded(
          child: Slider(
            key: const ValueKey('trail-width'),
            value: c.lineWidth.clamp(0.5, 200),
            min: 0.5,
            max: 200,
            onChangeStart: (_) => app.pushUndo(),
            onChanged: (v) {
              c.lineWidth = v;
              app.commitEdit();
            },
          ),
        ),
      ]),
      Row(children: [
        SizedBox(width: 110, child: Text('Opacity ${(opacity * 100).round()}%')),
        Expanded(
          child: Slider(
            key: const ValueKey('trail-opacity'),
            value: opacity.clamp(0.0, 1.0),
            onChangeStart: (_) => app.pushUndo(),
            onChanged: (v) {
              setTrackValueAt(t.transform.opacity, frame, v);
              app.commitEdit();
            },
          ),
        ),
      ]),
      // how long the line may get: past it the oldest part goes - cut off,
      // or fading out along the way.
      Row(children: [
        SizedBox(width: 110, child: Text(c.trailLength <= 0 ? 'Length: no limit' : 'Length ${c.trailLength.round()} px')),
        Expanded(
          child: Slider(
            key: const ValueKey('trail-length'),
            value: c.trailLength.clamp(0.0, 3000.0),
            max: 3000,
            onChangeStart: (_) => app.pushUndo(),
            onChanged: (v) {
              c.trailLength = v < 10 ? 0 : v.roundToDouble();
              app.commitEdit();
            },
          ),
        ),
      ]),
      if (c.trailLength > 0)
        SwitchListTile(
          key: const ValueKey('trail-fade'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Fade the end'),
          subtitle: hint(c.trailFade
              ? 'More see-through the further back, gone at the length.'
              : 'The end is cut off at the length.'),
          value: c.trailFade,
          onChanged: (v) => edit(() => c.trailFade = v),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('trail-to-line'),
          onPressed: () {
            if (!app.trailToLine(t.id)) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('No line drawn yet at this frame')));
            }
          },
          icon: const Icon(Icons.timeline, size: 18),
          label: const Text('Make it a line object'),
        ),
      ),
      hint('The line as it is now, as a line layer: edit its points, or let other layers move along it.') ??
          const SizedBox.shrink(),
    ];
  }
}
