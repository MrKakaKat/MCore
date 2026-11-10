import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import 'add_layer_dialog.dart';
import 'project_ref_ui.dart';

/// Ported from movement-core/src/ui/layerPanel.js - the layer list
/// (select/hide/add/delete). Group/ungroup (a multiselect + "Group (N)"
/// button in JS, per layerPanel.js:81-96 - never drag-based there
/// either) isn't wired up here yet; the underlying operations
/// (groupLayers/ungroupLayer in packages/movement_core) are already
/// ported and tested, just not yet reachable from this panel.
///
/// Reparenting itself is NOT missing: JS never did that via drag either
/// - it's a plain dropdown (paramsPanel/layerSection.js's `parentSel`),
/// ported as params_panel_view.dart's parent selector. An earlier
/// version of this comment described "drag-to-reparent" as deferred
/// gesture work, which was wrong on two counts - JS has no drag-based
/// reparenting to defer a port of, and the actual dropdown-based
/// feature was simply missing, not deferred-by-design. Corrected here.
///
/// UNVERIFIED like the rest of ui/.
class LayerPanelView extends StatelessWidget {
  final AppState app;
  const LayerPanelView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([app, _collapsed]),
      builder: (context, _) {
        final failed = app.failedImageLayerIds;
        // adding the timeline-length/move-to-frame fields pushed the
        // fixed-height header content taller than the mobile
        // DraggableScrollableSheet's own initial/squeezed size could fit - a
        // plain Column+Expanded(ListView) can't shrink the FIXED rows at all,
        // so the whole thing overflowed instead of scrolling. A single
        // ListView (header rows as leading items, followed by the layer tiles)
        // scrolls as one unit when squeezed instead, the same "tolerate a
        // squeezed viewport" philosophy layers_timeline_view.dart's own
        // vertical SingleChildScrollView already uses.
        return ReorderableListView(
          header: Column(
            children: [
              // "Go to frame" and "Timeline length" moved into the timeline
              // toolbar, next to play they took a row each here, while the
              // toolbar's "70 / 180" only showed the same two numbers).
            // the 4 separate shape/import icons collapse into one button
            // opening add_layer_dialog.dart's picker. The standalone delete
            // button that used to sit here is gone too - delete (the new
            // duplicate action) now live per-layer in each row's own trailing
            // icons below, per
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Builder(
                builder: (context) => Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add layer'),
                      onPressed: () => showAddLayerDialog(context, app),
                    ),
                  ),
                  // several selected: put them into a folder at once.
                  if (app.selectedGroup.length > 1) ...[
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      key: const ValueKey('selected-to-folder'),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      tooltip: 'Put the selected layers into a folder',
                      onPressed: () async {
                        final picked = await _pickFolder(context, 'Folder for ${app.selectedGroup.length} layers');
                        if (picked != null) app.setLayersFolder(app.selectedGroup, picked.isEmpty ? null : picked);
                      },
                    ),
                  ],
                ]),
              ),
            ),
            ],
          ),
          // (drag-to-reorder via the colored circle) - onReorder converts
          // Flutter's own display-space indices (this list is REVERSED - see
          // below) into a real project.layers target via AppState.moveLayer.
          onReorder: (oldIndex, newIndex) {
            final n = app.project.layers.length;
            final adjusted = oldIndex < newIndex ? newIndex - 1 : newIndex;
            final id = app.project.layers[n - 1 - oldIndex].id;
            app.moveLayer(id, (n - 1) - adjusted);
          },
          children: [
            // reversed: last-in-array paints on top (see
            // canvas_renderer.dart), so showing it at the top of the
            // list matches "what's visually in front" the way most
            // layer-stack UIs (and the original movement-core's own
            // layerPanel.js) present it.
            for (final layer in app.project.layers.reversed)
              _inFolder(context, layer, ListTile(
                key: ValueKey('tile-${layer.id}'),
                selected: app.selectedGroup.contains(layer.id),
                // long-press: select it together with the selected one.
                onLongPress: () => app.toggleMultiSelect(layer.id),
                dense: true,
                // in the wide/tablet layout's fixed 220px column, 3
                // default-sized (~48px tap target each) trailing IconButtons
                // left almost no width for the title, wrapping it
                // character-by-character into a tall, narrow stack that read
                // as "vertical text". ellipsis is a hard safety net regardless
                // of available width; the trailing row below is also shrunk to
                // free up real width in the first place.
                title: Row(children: [
                  Flexible(child: Text(layer.name, overflow: TextOverflow.ellipsis, maxLines: 1)),
                  RefUpdatedBadge(app: app, layer: layer),
                ]),
                // the drag handle: press-and-hold (not a plain tap) to start
                // reordering, matching the timeline's own move-in-time
                // gesture's long-press convention and the phrasing - scoped to
                // just this Icon, so row-tap-to-select and the trailing
                // buttons below are completely unaffected.
                leading: ReorderableDelayedDragStartListener(
                  index: app.project.layers.length - 1 -
                      app.project.layers.indexOf(layer),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.circle, size: 12, color: _parseColor(layer.color)),
                    // its row on the timeline (1: the bottom of the
                    // stack) - layers sharing a row share the number.
                    SizedBox(
                      width: 26,
                      child: Text('${timelineRowOf(app.project, layer.id) + 1}',
                          key: ValueKey('layer-order-${layer.id}'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ),
                  ]),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (failed.contains(layer.id))
                      _compactIconButton(
                        icon: Icons.broken_image,
                        tooltip: 'Image failed to load - tap to retry',
                        onPressed: () => app.retryImage(layer.id),
                      ),
                    // locked: a padlock (tap to unlock); locking is in the menu.
                    if (layer.locked)
                      _compactIconButton(
                        icon: Icons.lock,
                        tooltip: 'Locked on the stage (tap to unlock)',
                        onPressed: () => app.toggleLocked(layer.id),
                      ),
                    _compactIconButton(
                      icon: layer.hidden ? Icons.visibility_off : Icons.visibility,
                      tooltip: layer.hidden ? 'Show layer' : 'Hide layer',
                      onPressed: () => app.toggleHidden(layer.id),
                    ),
                    _compactIconButton(
                      icon: Icons.copy,
                      tooltip: 'Duplicate layer',
                      onPressed: () => app.duplicateLayer(layer.id),
                    ),
                    _compactIconButton(
                      icon: Icons.delete,
                      tooltip: 'Delete layer',
                      onPressed: () => app.deleteLayerById(layer.id),
                    ),
                    _layerMenu(context, layer),
                  ],
                ),
                onTap: () => app.selectLayer(layer.id),
              )),
          ],
        );
      },
    );
  }

  /// Folders the user folded (while the app runs).
  static final ValueNotifier<Set<String>> _collapsed = ValueNotifier({});

  /// A layer row in its folder: the folder's first (top) layer carries the
  /// folder's header; rows of a folded folder take no room. Every row
  /// stays in the list, so reordering is unchanged.
  Widget _inFolder(BuildContext context, Layer layer, Widget tile) {
    final f = layer.folder;
    if (f == null) return KeyedSubtree(key: ValueKey(layer.id), child: tile);
    final shown = app.project.layers.reversed.toList();
    final i = shown.indexOf(layer);
    final first = i == 0 || shown[i - 1].folder != f;
    final last = i == shown.length - 1 || shown[i + 1].folder != f;
    final open = !_collapsed.value.contains(f);
    final mates = shown.where((l) => l.folder == f).toList();
    final count = mates.length;
    final allHidden = mates.every((l) => l.hidden);
    return Column(
      key: ValueKey(layer.id),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (first)
          InkWell(
            key: ValueKey('folder-$f'),
            onTap: () => _collapsed.value = open ? {..._collapsed.value, f} : ({..._collapsed.value}..remove(f)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Row(children: [
                Icon(open ? Icons.folder_open : Icons.folder, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text('$f ($count)', style: const TextStyle(fontWeight: FontWeight.bold))),
                _compactIconButton(
                  icon: allHidden ? Icons.visibility_off : Icons.visibility,
                  tooltip: allHidden ? 'Show the folder' : 'Hide the folder',
                  onPressed: () => app.toggleFolderHidden(f),
                ),
                _compactIconButton(
                  icon: Icons.copy,
                  tooltip: 'Copy the folder',
                  onPressed: () => app.duplicateFolder(f),
                ),
                Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
              ]),
            ),
          ),
        if (open) Padding(padding: const EdgeInsets.only(left: 12), child: tile),
        // where the folder ends.
        if (last)
          Container(
            key: ValueKey('folder-end-$f'),
            margin: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            height: 1.5,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, Layer layer) async {
    final c = TextEditingController(text: layer.name);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Rename layer'),
        content: TextField(key: const ValueKey('rename-field'), controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('rename-ok'), onPressed: () => Navigator.pop(d, c.text), child: const Text('Rename')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) app.renameLayer(layer.id, name.trim());
  }

  Future<void> _moveToFolder(BuildContext context, Layer layer) async {
    final picked = await _pickFolder(context, 'Folder for ${layer.name}');
    if (picked != null) app.setLayerFolder(layer.id, picked.isEmpty ? null : picked);
  }

  /// A folder picked (or a new one named): '' no folder, null cancelled.
  Future<String?> _pickFolder(BuildContext context, String title) async {
    final folders = {for (final l in app.project.layers) if (l.folder != null) l.folder!}.toList()..sort();
    final c = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (d) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(d, ''), child: const Text('No folder')),
          for (final f in folders) SimpleDialogOption(onPressed: () => Navigator.pop(d, f), child: Text(f)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('folder-new'),
                  controller: c,
                  decoration: const InputDecoration(hintText: 'New folder'),
                ),
              ),
              IconButton(
                key: const ValueKey('folder-new-ok'),
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () => Navigator.pop(d, c.text.trim()),
              ),
            ]),
          ),
        ],
      ),
    );
    return picked;
  }

  Color _parseColor(String? hex) {
    if (hex == null) return Colors.grey;
    // (a transparent colour shows its rgb, fully: the row's dot stays seen)
    final h = hex.replaceFirst('#', '');
    final v = int.tryParse(h.length == 8 ? h.substring(0, 6) : h, radix: 16) ?? 0x888888;
    return Color(0xFF000000 | v);
  }

  /// Replace content / copy parameters / paste parameters - a compact
  /// icon (like its neighbours) that opens a popup menu.
  Widget _layerMenu(BuildContext context, Layer layer) {
    return Builder(
      builder: (buttonContext) => _compactIconButton(
        icon: Icons.more_vert,
        tooltip: 'More layer actions',
        onPressed: () async {
          final box = buttonContext.findRenderObject() as RenderBox;
          final overlay = Overlay.of(buttonContext).context.findRenderObject() as RenderBox;
          final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
          final action = await showMenu<String>(
            context: buttonContext,
            position: RelativeRect.fromLTRB(
                topLeft.dx, topLeft.dy + box.size.height, overlay.size.width - topLeft.dx - box.size.width, 0),
            items: [
              const PopupMenuItem(value: 'rename', child: Text('Rename...')),
              PopupMenuItem(value: 'lock', child: Text(layer.locked ? 'Unlock on the stage' : 'Lock on the stage')),
              const PopupMenuItem(value: 'folder', child: Text('Move to folder...')),
              const PopupMenuItem(value: 'replace', child: Text('Replace content...')),
              const PopupMenuItem(value: 'copy', child: Text('Copy parameters')),
              PopupMenuItem(
                  value: 'paste', enabled: app.copiedLayerParams != null, child: const Text('Paste parameters')),
              ...projectRefMenuItems(app, layer),
              if (layer.follow.enabled && layer.follow.targetId != null)
                const PopupMenuItem(value: 'bakeFollow', child: Text('Bake Follow to keys')),
            ],
          );
          if (context.mounted && await runProjectRefAction(context, app, layer, action)) return;
          switch (action) {
            case 'rename':
              if (context.mounted) await _rename(context, layer);
            case 'lock':
              app.toggleLocked(layer.id);
            case 'folder':
              if (context.mounted) await _moveToFolder(context, layer);
            case 'replace':
              if (context.mounted) await showAddLayerDialog(context, app, replaceId: layer.id);
            case 'copy':
              app.copyLayerParamsOf(layer.id);
            case 'paste':
              app.pasteLayerParamsInto(layer.id);
            case 'bakeFollow':
              if (!app.bakeFollowToKeys(layer.id) && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Only a layer without a parent can bake its Follow')));
              }
          }
        },
      ),
    );
  }

  Widget _compactIconButton({required IconData icon, required String tooltip, required VoidCallback onPressed}) {
    return IconButton(
      icon: Icon(icon),
      iconSize: 18,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
    );
  }
}
