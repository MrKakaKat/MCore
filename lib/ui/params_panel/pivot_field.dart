import 'package:flutter/material.dart';

import '../../app_state.dart';

/// Movement tab: the object's centre - the point its position stands for
/// and it turns and scales round. A point of its box, or tapped on the
/// stage; the object stays where it is.
class PivotField extends StatelessWidget {
  final AppState app;
  const PivotField({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    Widget dot(double fx, double fy) => SizedBox(
          width: 22,
          height: 22,
          child: IconButton(
            key: ValueKey('pivot-$fx-$fy'),
            padding: EdgeInsets.zero,
            iconSize: fx == 0.5 && fy == 0.5 ? 12 : 9,
            tooltip: 'centre here',
            icon: const Icon(Icons.circle_outlined),
            onPressed: () => app.setPivotToBox(fx, fy),
          ),
        );
    return Padding(
      key: const ValueKey('pivot-field'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        const Text('Centre', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 8),
        // its box's corners, edges' middles and middle.
        DecoratedBox(
          decoration: BoxDecoration(border: Border.all(color: Colors.grey.withOpacity(0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final fy in const [0.0, 0.5, 1.0])
              Row(mainAxisSize: MainAxisSize.min, children: [for (final fx in const [0.0, 0.5, 1.0]) dot(fx, fy)]),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: app.pivotPick
              ? TextButton(
                  key: const ValueKey('pivot-pick-cancel'),
                  onPressed: () => app.setPivotPick(false),
                  child: const Text('Tap the stage... (cancel)'))
              : OutlinedButton.icon(
                  key: const ValueKey('pivot-pick'),
                  onPressed: () => app.setPivotPick(true),
                  icon: const Icon(Icons.ads_click, size: 16),
                  label: const Text('Tap on the stage'),
                ),
        ),
      ]),
    );
  }
}
