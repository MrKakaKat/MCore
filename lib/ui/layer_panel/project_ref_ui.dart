import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../../io/project_store.dart';

/// Project references (model/project_ref.dart): picking a project to place
/// or relink, the reference's own actions, "Used in..." and "Show in
/// context".

/// A saved project to refer to: never this one, nor one that would make
/// projects contain each other. Null when cancelled.
Future<String?> pickProjectForRef(BuildContext context, AppState app, {String title = 'Add project'}) async {
  final store = app.projectStore;
  if (store == null) return null;
  final metas = await store.list();
  final graph = await store.graph();
  graph[app.projectId] = directRefs(app.project);
  final choices = [
    for (final m in metas)
      if (!refWouldCycle(app.projectId, m.id, graph)) m
  ];
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(title),
      children: [
        if (choices.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No other projects to place here.', style: TextStyle(color: Colors.grey)),
          ),
        for (final m in choices)
          SimpleDialogOption(
            key: ValueKey('ref-pick-${m.id}'),
            onPressed: () => Navigator.pop(dialogContext, m.id),
            child: Row(children: [
              ProjectThumb(width: m.frameWidth, height: m.frameHeight),
              const SizedBox(width: 12),
              Expanded(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
    ),
  );
}

/// Add -> Project...
Future<void> addProjectRefFlow(BuildContext context, AppState app) async {
  final id = await pickProjectForRef(context, app);
  if (id == null) return;
  final error = await app.addProjectRef(id);
  if (error != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }
}

/// The layer menu's entries for a reference.
List<PopupMenuEntry<String>> projectRefMenuItems(AppState app, Layer layer) {
  if (layer.content.shape != 'projectRef') return const [];
  final linked = layer.content.refEmbedded == null;
  return [
    const PopupMenuDivider(),
    if (linked) PopupMenuItem(value: 'ref-open', enabled: app.onOpenProject != null, child: const Text('Open source')),
    const PopupMenuItem(value: 'ref-relink', child: Text('Relink...')),
    if (linked) const PopupMenuItem(value: 'ref-unlink', child: Text('Unlink (embed copy)')),
  ];
}

/// Runs one of [projectRefMenuItems]' actions; false when `action` isn't
/// one of them.
Future<bool> runProjectRefAction(BuildContext context, AppState app, Layer layer, String? action) async {
  switch (action) {
    case 'ref-open':
      final id = layer.content.refProjectId;
      if (id != null) {
        await app.saveNow();
        await app.onOpenProject?.call(id);
        // back here: the source may have changed.
        await app.loadReferences();
      }
      return true;
    case 'ref-relink':
      final id = await pickProjectForRef(context, app, title: 'Relink to');
      if (id == null) return true;
      final error = await app.relinkProjectRefLayer(layer.id, id);
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      }
      return true;
    case 'ref-unlink':
      await app.unlinkProjectRefLayer(layer.id);
      return true;
  }
  return false;
}

/// "Used in...": the projects that refer to `meta`.
Future<void> showUsedInDialog(BuildContext context, ProjectStore store, ProjectMeta meta) async {
  final users = await store.usedIn(meta.id);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('"${meta.name}" is used in'),
      content: users.isEmpty
          ? const Text('No other project uses it.')
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final u in users) Text('• ${u.name}'),
            ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK'))],
    ),
  );
}

/// The small "updated" mark on a reference whose source was saved since;
/// tapping it acknowledges.
class RefUpdatedBadge extends StatelessWidget {
  final AppState app;
  final Layer layer;
  const RefUpdatedBadge({super.key, required this.app, required this.layer});

  @override
  Widget build(BuildContext context) {
    if (!app.refUpdatedLayer(layer)) return const SizedBox.shrink();
    return GestureDetector(
      key: ValueKey('ref-updated-${layer.id}'),
      onTap: () => app.acknowledgeRefUpdate(layer.id),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: const Color(0xFF2F7DD1), borderRadius: BorderRadius.circular(8)),
        child: const Text('updated', style: TextStyle(fontSize: 10, color: Colors.white)),
      ),
    );
  }
}

/// Show in context: pick a project that uses this one (and which of its
/// references), or - while shown - its look and the way off.
Future<void> showContextDialog(BuildContext context, AppState app) async {
  final store = app.projectStore;
  if (store == null) return;
  final users = await store.usedIn(app.projectId);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final host = app.contextHost;
        final instances = app.contextInstances;
        return AlertDialog(
          title: const Text('Show in context'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (users.isEmpty) const Text('No saved project uses this one yet.', style: TextStyle(color: Colors.grey)),
              for (final u in users)
                RadioListTile<String>(
                  key: ValueKey('context-host-${u.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: u.id,
                  groupValue: host?.id,
                  title: Text(u.name),
                  onChanged: (id) => app.showInContext(id!),
                ),
              if (host != null) ...[
                if (instances.length > 1)
                  DropdownButton<int>(
                    value: app.contextInstance.clamp(0, instances.length - 1),
                    items: [
                      for (var i = 0; i < instances.length; i++)
                        DropdownMenuItem(value: i, child: Text('${instances[i].name} (${i + 1})')),
                    ],
                    onChanged: (i) => app.showInContext(host.id, instance: i ?? 0),
                  ),
                const Text('Opacity'),
                Slider(value: app.contextOpacity, onChanged: (v) => app.setContextLook(opacity: v)),
                const Text('Resolution'),
                Slider(
                  value: app.contextResolution,
                  min: 0.25,
                  max: 1,
                  divisions: 3,
                  label: '${(app.contextResolution * 100).round()}%',
                  onChanged: (v) => app.setContextLook(resolution: v),
                ),
              ],
            ]),
          ),
          actions: [
            if (host != null)
              TextButton(
                onPressed: () {
                  app.hideContext();
                  Navigator.pop(dialogContext);
                },
                child: const Text('Turn off'),
              ),
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Done')),
          ],
        );
      },
    ),
  );
}

/// A small outline of a project's frame shape.
class ProjectThumb extends StatelessWidget {
  final double width;
  final double height;
  const ProjectThumb({super.key, required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    const box = 36.0;
    final scale = box / (width > height ? width : height);
    return SizedBox(
      width: box,
      height: box,
      child: Center(
        child: Container(
          width: width * scale,
          height: height * scale,
          decoration: BoxDecoration(border: Border.all(color: Colors.white54)),
        ),
      ),
    );
  }
}
