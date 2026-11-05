import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../../io/preset_store.dart';

/// Presets tab, two lists:
/// - object presets: the selected object's parameters (movement,
///   effects, masks, motion blur/wiggle/pendulum, color, crop, mirror -
///   not its shape or timing);
/// - animation presets: only its keyframed animation, applied so it
///   starts at the playhead.
/// Both are kept outside any project, so they work in every project.
class PresetsView extends StatelessWidget {
  final AppState app;
  const PresetsView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final store = app.presetStore;
    final animStore = app.animationPresetStore;
    if (store == null || animStore == null) {
      return const Center(child: Text('Presets are available for projects opened from the home screen'));
    }
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        _PresetSection(
          app: app,
          store: store,
          title: 'Object presets',
          saveLabel: 'Save current as preset',
          defaultName: 'Preset',
          snapshot: (layer) => layerParamsToJson(layer),
          apply: (layer, params) => app.applyParamsTo(layer.id, params),
        ),
        const Divider(height: 24),
        _PresetSection(
          app: app,
          store: animStore,
          title: 'Animation presets',
          saveLabel: 'Save animation (keys only)',
          defaultName: 'Animation',
          canSave: layerHasAnimation,
          snapshot: animationPresetToJson,
          apply: (layer, params) => app.applyAnimationPresetTo(layer.id, params),
        ),
      ],
    );
  }
}

class _PresetSection extends StatefulWidget {
  final AppState app;
  final PresetStore store;
  final String title;
  final String saveLabel;
  final String defaultName;
  final bool Function(Layer layer)? canSave;
  final Map<String, dynamic> Function(Layer layer) snapshot;
  final void Function(Layer layer, Map<String, dynamic> params) apply;
  const _PresetSection({
    required this.app,
    required this.store,
    required this.title,
    required this.saveLabel,
    required this.defaultName,
    this.canSave,
    required this.snapshot,
    required this.apply,
  });

  @override
  State<_PresetSection> createState() => _PresetSectionState();
}

class _PresetSectionState extends State<_PresetSection> {
  late Future<List<Preset>> _presets = widget.store.list();
  void _refresh() => setState(() => _presets = widget.store.list());

  Future<String?> _askName(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCurrent(Layer layer) async {
    final existing = await _presets;
    if (!mounted) return;
    final name = await _askName(widget.saveLabel, '${widget.defaultName} ${existing.length + 1}');
    if (name == null || name.isEmpty) return;
    await widget.store.save(name, widget.snapshot(layer));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.app,
      builder: (context, _) {
        final layer = findLayer(widget.app.project, widget.app.selection.selectedLayer);
        final saveable = layer != null && (widget.canSave?.call(layer) ?? true);
        return FutureBuilder<List<Preset>>(
          future: _presets,
          builder: (context, snap) {
            final presets = snap.data ?? const <Preset>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(widget.title, style: Theme.of(context).textTheme.titleSmall),
                ),
                OutlinedButton.icon(
                  onPressed: saveable ? () => _saveCurrent(layer) : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: Text(widget.saveLabel),
                ),
                if (snap.connectionState == ConnectionState.done && presets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('No presets yet', style: TextStyle(color: Colors.grey)),
                  ),
                for (final p in presets)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.bookmark_outline, size: 18),
                    title: Text(p.name, overflow: TextOverflow.ellipsis, maxLines: 1),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: layer == null ? null : () => widget.apply(layer, p.params),
                          child: const Text('Apply'),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'preset options',
                          onSelected: (action) async {
                            if (action == 'rename') {
                              final name = await _askName('Rename preset', p.name);
                              if (name == null || name.isEmpty) return;
                              await widget.store.rename(p, name);
                            } else {
                              await widget.store.delete(p);
                            }
                            _refresh();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'rename', child: Text('Rename')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
