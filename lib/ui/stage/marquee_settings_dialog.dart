import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';

/// The selection rectangle's options: on by holding a finger, picking
/// several with taps, and the kinds of layers it leaves out.
Future<void> showMarqueeSettingsDialog(BuildContext context, AppState app) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Select with a rectangle'),
      content: SizedBox(
        width: 300,
        child: AnimatedBuilder(
          animation: app,
          builder: (context, _) => SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                key: const ValueKey('marquee-mode'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Drag draws the rectangle'),
                value: app.marqueeMode,
                onChanged: (v) => app.setAppPreference('marqueeMode', v),
              ),
              SwitchListTile(
                key: const ValueKey('marquee-on-hold'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Hold a finger, then drag'),
                subtitle: const Text('the rectangle without turning it on'),
                value: app.marqueeOnHold,
                onChanged: (v) => app.setAppPreference('marqueeOnHold', v),
              ),
              SwitchListTile(
                key: const ValueKey('marquee-multi'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Pick several with taps'),
                subtitle: const Text('a tap adds a layer (or takes it out); the rectangle adds too'),
                value: app.stageMultiSelect,
                onChanged: (v) => app.setAppPreference('stageMultiSelect', v),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 4),
                child: Text('It selects', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final e in marqueeKinds.entries)
                  FilterChip(
                    key: ValueKey('marquee-kind-${e.key}'),
                    label: Text(e.value),
                    selected: !app.marqueeSkip.contains(e.key),
                    onSelected: (on) {
                      final next = {...app.marqueeSkip};
                      on ? next.remove(e.key) : next.add(e.key);
                      app.setAppPreference('marqueeSkip', next.toList());
                    },
                  ),
              ]),
            ]),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}
