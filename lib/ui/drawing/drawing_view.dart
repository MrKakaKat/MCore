import 'package:flutter/material.dart';

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
            const Text('Edges', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              key: const ValueKey('draw-fill-mode'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'mixed', label: Text('Mixed')),
                ButtonSegment(value: 'pixel', label: Text('Pixels')),
                ButtonSegment(value: 'vectorPixel', label: Text('Vector by pixels')),
              ],
              selected: {app.fillMode},
              onSelectionChanged: (v) => app.setFillOptions(mode: v.first),
            ),
            Hint(switch (app.fillMode) {
              'pixel' => 'Everything you see bounds it, pixel by pixel (colours, pictures, filters) - the fill is a '
                  'picture.',
              'vectorPixel' => 'A vector fill: shapes bound it by their vectors, everything else (pictures, filters, '
                  'blur...) by its pixels.',
              _ => 'A vector fill: shapes bound it by their vectors, pictures by their pixels (it goes under them, so '
                  'their soft edges blend into it).',
            }),
            if (app.fillMode == 'pixel')
              Row(children: [
                SizedBox(width: 110, child: Text('Colour range ${(app.fillTolerance * 100).round()}%')),
                Expanded(
                  child: Slider(
                    key: const ValueKey('draw-fill-tolerance'),
                    value: app.fillTolerance,
                    onChanged: (v) => app.setFillOptions(tolerance: v),
                  ),
                ),
              ]),
            SwitchListTile(
              key: const ValueKey('draw-fill-bleed'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Reach under the edges'),
              subtitle: hint('A hair of the fill (1 px) goes on under the layers bounding it - no thin gaps'),
              value: app.fillBleed,
              onChanged: (v) => app.setFillOptions(bleed: v),
            ),
            if (app.fillMode != 'pixel')
              SwitchListTile(
                key: const ValueKey('draw-fill-over'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Over the pictures'),
                subtitle: hint('Off: the fill goes under the pictures that bound it. On: over them, each picture '
                    'taking itself out of it by its alpha (100 - n)'),
                value: app.fillOverPictures,
                onChanged: (v) => app.setFillOptions(over: v),
              ),
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
          ],
        );
      },
    );
  }
}
