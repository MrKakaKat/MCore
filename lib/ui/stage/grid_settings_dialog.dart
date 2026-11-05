import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/reset_button.dart';

/// (Snapping shouldn't be tied to the grid feature - separate them) - this is
/// the new, standalone home for the grid OVERLAY's own visibility + density
/// (cols/rows), fully independent of Snapping's "Snap to grid lines" toggle
/// (snapping_settings_dialog.dart, still in the Snapping tab, unchanged
/// meaning - "can a drag snap to these lines' positions"). See
/// gridOverlayEnabled's own doc comment in project.dart for the full
/// decoupling rationale. Cols/rows moved here verbatim from Snapping's old
/// "Grid" block.
Future<void> showGridSettingsDialog(BuildContext context, AppState app) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Grid'),
      content: SizedBox(width: 300, child: GridSettingsView(app: app)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}

class GridSettingsView extends StatelessWidget {
  final AppState app;
  const GridSettingsView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Show grid overlay', style: TextStyle(fontWeight: FontWeight.bold))),
                Switch(value: gridOverlayEnabled, onChanged: (_) => app.toggleGridOverlay()),
              ],
            ),
            const Hint('Purely visual - whether drags actually SNAP to these lines is a separate toggle, in the Snapping tab.'),
            ..._rectGrid(context),
            if (gridOverlayEnabled) ...[
              const SizedBox(height: 8),
              // the titles over their buttons, so both fit the window.
              Row(
                children: [
                  for (final (title, value, set) in [
                    ('Cols', snapGridCols, app.setSnapGridCols),
                    ('Rows', snapGridRows, app.setSnapGridRows),
                  ])
                    Expanded(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(title),
                        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          IconButton(
                              key: ValueKey('grid-$title-minus'),
                              icon: const Icon(Icons.remove),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => set(value - 1)),
                          Text('$value'),
                          IconButton(
                              key: ValueKey('grid-$title-plus'),
                              icon: const Icon(Icons.add),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => set(value + 1)),
                        ]),
                      ]),
                    ),
                  ResetIconButton(onPressed: () {
                    app.setSnapGridCols(4);
                    app.setSnapGridRows(4);
                  }),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// A selected rect's own grid: on / off, its columns and rows.
  List<Widget> _rectGrid(BuildContext context) {
    final l = findLayer(app.project, app.selection.selectedLayer);
    if (l == null || l.content.shape != 'rect') return const [];
    final c = l.content;
    final on = c.gridCols != null;
    void set(int? cols, int? rows) {
      app.pushUndo();
      c
        ..gridCols = cols
        ..gridRows = rows;
      app.commitEdit();
    }

    return [
      const Divider(),
      Row(children: [
        Expanded(child: Text('Grid inside "${l.name}"', style: const TextStyle(fontWeight: FontWeight.bold))),
        Switch(key: const ValueKey('rect-grid'), value: on, onChanged: (v) => v ? set(3, 3) : set(null, null)),
      ]),
      if (on)
        Row(children: [
          for (final (title, value, isCols) in [('Cols', c.gridCols!, true), ('Rows', c.gridRows!, false)])
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(title),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                      key: ValueKey('rect-grid-$title-minus'),
                      icon: const Icon(Icons.remove),
                      visualDensity: VisualDensity.compact,
                      onPressed: value <= 1
                          ? null
                          : () => isCols ? set(value - 1, c.gridRows) : set(c.gridCols, value - 1)),
                  Text('$value'),
                  IconButton(
                      key: ValueKey('rect-grid-$title-plus'),
                      icon: const Icon(Icons.add),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => isCols ? set(value + 1, c.gridRows) : set(c.gridCols, value + 1)),
                ]),
              ]),
            ),
        ]),
      if (on) const Hint('An editor guide (not in the picture). Centre to centre snaps onto its crossings.'),
    ];
  }
}
