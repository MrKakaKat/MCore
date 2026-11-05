import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart' show colorHarmonies, harmonyColors;

import '../../app_state.dart';
import '../common/color_row.dart';
import '../common/hint.dart';
import '../stage/stage_settings_dialog.dart' show parseHexColor;

/// Palettes: named colour lists. Copy one and paste it into any colour
/// field (its palette menu); a field's palette copied back pastes here as
/// a new one.
class PalettesView extends StatelessWidget {
  final AppState app;
  const PalettesView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([app, copiedPalette]),
      builder: (context, _) {
        final pals = app.palettes;
        void save(List<({String name, List<String> colors})> p) => app.setPalettes(p);
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            Row(children: [
              const Expanded(child: Text('Palettes', style: TextStyle(fontWeight: FontWeight.bold))),
              TextButton.icon(
                key: const ValueKey('palette-paste-new'),
                icon: const Icon(Icons.content_paste, size: 16),
                label: const Text('Paste as new'),
                onPressed: copiedPalette.value == null
                    ? null
                    : () => save([...pals, (name: 'Palette ${pals.length + 1}', colors: [...copiedPalette.value!])]),
              ),
              IconButton(
                key: const ValueKey('palette-add'),
                icon: const Icon(Icons.add),
                tooltip: 'new palette',
                onPressed: () => save([...pals, (name: 'Palette ${pals.length + 1}', colors: <String>['#ffffff'])]),
              ),
            ]),
            const Hint('Copy a palette, then in any colour field open its palette menu and paste it - its colours '
                'show first there. A field\'s palette copied there pastes here as a new palette.'),
            for (var i = 0; i < pals.length; i++)
              Card(
                key: ValueKey('palette-$i'),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: TextFormField(
                          key: ValueKey('palette-name-$i-${pals[i].name}'),
                          initialValue: pals[i].name,
                          decoration: const InputDecoration(isDense: true, border: InputBorder.none),
                          onFieldSubmitted: (v) =>
                              save([for (var j = 0; j < pals.length; j++) j == i ? (name: v, colors: pals[j].colors) : pals[j]]),
                        ),
                      ),
                      // a new palette in harmony with this one's first colour.
                      PopupMenuButton<String>(
                        key: ValueKey('palette-harmony-$i'),
                        tooltip: 'new palette in harmony with its first colour',
                        icon: const Icon(Icons.palette_outlined, size: 18),
                        itemBuilder: (_) => [
                          for (final e in colorHarmonies.entries) PopupMenuItem(value: e.key, child: Text(e.value)),
                        ],
                        onSelected: (kind) {
                          final base = pals[i].colors.isEmpty ? '#ff0000' : pals[i].colors.first;
                          save([
                            ...pals,
                            (name: '${pals[i].name} · ${colorHarmonies[kind]}', colors: harmonyColors(base, kind)),
                          ]);
                        },
                      ),
                      IconButton(
                        key: ValueKey('palette-copy-$i'),
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'copy (paste it into a colour field)',
                        onPressed: () {
                          copiedPalette.value = [...pals[i].colors];
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('${pals[i].name} copied - paste it from a colour field\'s palette menu')));
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: 'delete',
                        onPressed: () => save([...pals]..removeAt(i)),
                      ),
                    ]),
                    // its colours: tap one to drop it; the last field edits.
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        for (var c = 0; c < pals[i].colors.length; c++)
                          InkWell(
                            onTap: () => save([
                              for (var j = 0; j < pals.length; j++)
                                j == i ? (name: pals[j].name, colors: [...pals[j].colors]..removeAt(c)) : pals[j]
                            ]),
                            child: Container(
                              width: 28,
                              height: 28,
                              margin: const EdgeInsets.only(right: 4),
                              decoration: BoxDecoration(
                                  color: parseHexColor(pals[i].colors[c]), border: Border.all(color: Colors.white24)),
                            ),
                          ),
                      ]),
                    ),
                    ColorRow(
                      label: 'Add',
                      hex: pals[i].colors.isEmpty ? '#ffffff' : pals[i].colors.last,
                      onPick: (h) => save([
                        for (var j = 0; j < pals.length; j++)
                          j == i ? (name: pals[j].name, colors: [...pals[j].colors, h]) : pals[j]
                      ]),
                    ),
                  ]),
                ),
              ),
          ],
        );
      },
    );
  }
}
