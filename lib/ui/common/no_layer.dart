import 'package:flutter/material.dart';

import '../../app_state.dart';

/// A tab with nothing to show until a layer is picked: what it wants,
/// and under it the way to the Layers tab.
class NoLayer extends StatelessWidget {
  final AppState app;
  final String text;
  const NoLayer({super.key, required this.app, this.text = 'Select a layer'});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text),
          const SizedBox(height: 6),
          LayersButton(app: app),
        ]),
      );
}

/// To the Layers tab.
class LayersButton extends StatelessWidget {
  final AppState app;
  const LayersButton({super.key, required this.app});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        key: const ValueKey('go-layers'),
        onPressed: () => app.showTab('Layers'),
        icon: const Icon(Icons.layers_outlined, size: 18),
        label: const Text('Layers'),
      );
}
