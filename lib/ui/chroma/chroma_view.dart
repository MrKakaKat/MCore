import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../stage/stage_settings_dialog.dart' show parseHexColor;

/// Chroma tab: chroma key for image layers - the key colour (eyedropper on
/// the stage, or typed), strength and edge softness, and whether it keys
/// the whole picture or only the inside of a region you draw on it.
///
/// The stage tools (pick / draw region) switch off when you leave the tab,
/// so the stage never keeps ignoring handles for a tool you can't see.
class ChromaView extends StatefulWidget {
  final AppState app;
  const ChromaView({super.key, required this.app});

  @override
  State<ChromaView> createState() => _ChromaViewState();
}

class _ChromaViewState extends State<ChromaView> {
  AppState get app => widget.app;

  @override
  void dispose() {
    chromaTool = 'none';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null || !chromaCapable(layer.content.shape)) {
          return const Center(child: Text('Chroma key works on images, videos and merged shapes - select one'));
        }
        final ck = layer.chromaKey;
        final keyColor = parseHexColor(ck.color) ?? Colors.green;
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Chroma key', style: TextStyle(fontWeight: FontWeight.bold)),
              value: ck.enabled,
              onChanged: (v) => app.editChromaKey(layer.id, (c) => c.enabled = v),
            ),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const SizedBox(width: 72, child: Text('Key colour', style: TextStyle(fontSize: 12))),
                InkWell(
                  onTap: () => _typeColor(context, layer.id, ck.color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: keyColor, border: Border.all(color: Colors.white38)),
                  ),
                ),
                FilterChip(
                  avatar: const Icon(Icons.colorize, size: 16),
                  label: const Text('Pick on stage'),
                  selected: chromaTool == 'pick',
                  onSelected: (on) => app.setChromaTool(on ? 'pick' : 'none'),
                ),
              ],
            ),
            if (chromaTool == 'pick')
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Hint('Press on the picture and slide: the loupe above your finger shows the colour. Lift to take it.'),
              ),
            const SizedBox(height: 8),
            _slider(layer, 'strength', ck.strength, ChromaKey().strength, (c, v) => c.strength = v),
            _slider(layer, 'softness', ck.softness, ChromaKey().softness, (c, v) => c.softness = v),
            // the edge: grow the keyed area (eats a leftover fringe), then
            // soften the cut.
            _pxSlider(layer, 'grow edge', ck.expand, (c, v) => c.expand = v),
            _pxSlider(layer, 'feather', ck.feather, (c, v) => c.feather = v),
            SwitchListTile(
              key: const ValueKey('chroma-contiguous'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Connected only'),
              subtitle: hint('Only the colour joined to the picked point - the same colour cut off '
                  'by other colours (e.g. inside an object) stays'),
              value: ck.contiguous,
              onChanged: (v) => app.editChromaKey(layer.id, (c) => c.contiguous = v),
            ),
            if (ck.contiguous && ck.seed == null)
              const Hint('Pick the colour on the stage to set where it starts.'),
            SwitchListTile(
              key: const ValueKey('chroma-invert'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Invert'),
              subtitle: hint('Keep only the key colour'),
              value: ck.invert,
              onChanged: (v) => app.editChromaKey(layer.id, (c) => c.invert = v),
            ),
            SwitchListTile(
              key: const ValueKey('chroma-matte'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Contrast view'),
              subtitle: hint('White: what stays. Black: what is removed'),
              value: app.renderer.chromaMatteLayerId == layer.id,
              onChanged: (v) => app.setChromaMatteView(v ? layer.id : null),
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('chroma-submit'),
              onPressed: ck.enabled ? () => app.submitChromaKeyOf(layer.id) : null,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Submit colour'),
            ),
            const Hint('Submit keeps this colour removed and frees the key for another colour.'),
            if (ck.applied.isNotEmpty) ...[
              const Divider(height: 20),
              const Text('Removed colours', style: TextStyle(fontWeight: FontWeight.bold)),
              for (var i = 0; i < ck.applied.length; i++) _appliedRow(layer, i, ck.applied[i]),
            ],
          ],
        );
      },
    );
  }

  Widget _appliedRow(Layer layer, int index, ChromaKey k) {
    final shown = k.enabled;
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
              color: (parseHexColor(k.color) ?? Colors.green).withOpacity(shown ? 1 : 0.35),
              border: Border.all(color: Colors.white38)),
        ),
        Expanded(
          child: Text(
            '${k.color}  ·  strength ${(k.strength * 100).round()}%'
            '',
            style: TextStyle(fontSize: 12, color: shown ? null : Colors.grey),
          ),
        ),
        IconButton(
          icon: Icon(shown ? Icons.visibility : Icons.visibility_off, size: 18),
          tooltip: shown ? 'hide this colour' : 'show this colour',
          onPressed: () => app.toggleAppliedChromaKey(layer.id, index),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: 'delete this colour',
          onPressed: () => app.deleteAppliedChromaKey(layer.id, index),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  /// 0..20 pixels of the source picture.
  Widget _pxSlider(Layer layer, String label, double value, void Function(ChromaKey c, double v) set) {
    return Row(children: [
      SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 12))),
      Expanded(
        child: Slider(
          key: ValueKey('chroma-$label'),
          value: value.clamp(0.0, 20.0),
          max: 20,
          divisions: 20,
          label: '${value.round()} px',
          onChangeStart: (_) => app.pushUndo(),
          onChanged: (v) {
            set(layer.chromaKey, v);
            app.commitEdit();
          },
        ),
      ),
      SizedBox(width: 40, child: Text('${value.round()} px', style: const TextStyle(fontSize: 12))),
    ]);
  }

  Widget _slider(
      Layer layer, String label, double value, double defaultValue, void Function(ChromaKey c, double v) set) {
    return ParamEditor(
      prefKey: 'chroma.$label',
      label: label,
      values: [value],
      scale: const ParamScale.slider(0, 1),
      onEditStart: app.pushUndo,
      onChanged: (v) {
        set(layer.chromaKey, v.first.clamp(0.0, 1.0));
        app.commitEdit();
      },
      onCommit: (v) => app.editChromaKey(layer.id, (c) => set(c, v.first.clamp(0.0, 1.0))),
      trailing: [ResetIconButton(onPressed: () => app.editChromaKey(layer.id, (c) => set(c, defaultValue)))],
    );
  }

  Future<void> _typeColor(BuildContext context, String layerId, String current) async {
    final controller = TextEditingController(text: current.replaceFirst('#', ''));
    final color = await showDialog<Color>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Key colour'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(prefixText: '#', hintText: 'RRGGBB'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, parseHexColor(controller.text)),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (color == null) return;
    final v = color.value & 0xFFFFFF;
    app.editChromaKey(layerId, (c) => c.color = rgbHex((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF));
  }
}
