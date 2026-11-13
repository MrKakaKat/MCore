import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/color_row.dart';
import '../common/hint.dart';

/// Drawing: tools that paint new layers on the stage. Fill: a tap fills
/// the region it lands in, bounded by the edges of the other layers.
class DrawingView extends StatelessWidget {
  final AppState app;
  const DrawingView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
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
    ];
  }
}
