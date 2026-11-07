import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../i18n.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../player/player_screen.dart';
import '../../io/app_settings.dart';
import '../../io/save_load.dart';
import '../ai/ai_dialogs.dart';
import '../../io/backup.dart';
import '../../io/file_pick.dart';
import '../../io/font_store.dart';
import '../../io/preset_store.dart';
import '../../io/project_store.dart';
import '../layer_panel/project_ref_ui.dart' show showUsedInDialog;
import '../../main.dart' show EditorScreen;

/// The app's start screen: "New project" plus the list of saved projects
/// (newest first). Opening one gives it its own AppState/EditorScreen,
/// autosaved to its own file; returning refreshes the list.
class HomeScreen extends StatefulWidget {
  final ProjectStore store;
  const HomeScreen({super.key, required this.store});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<ProjectMeta>> _projects = _list();

  void _refresh() => setState(() => _projects = _list());

  /// The projects, newest first by the chosen date (see Settings).
  Future<List<ProjectMeta>> _list() async {
    final all = await widget.store.list();
    if (AppSettings.instance?.projectSort == 'created') {
      all.sort((a, b) => b.created.compareTo(a.created));
    }
    return all;
  }

  /// Home settings: the projects' order, then the language.
  Future<void> _settings() async {
    final s = AppSettings.instance;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(tr('Settings')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('Sort projects by'), style: const TextStyle(fontWeight: FontWeight.bold)),
            for (final (v, label) in const [('modified', 'Date modified'), ('created', 'Date created')])
              RadioListTile<String>(
                key: ValueKey('sort-$v'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(tr(label)),
                value: v,
                groupValue: s?.projectSort ?? 'modified',
                onChanged: (x) async {
                  await s?.setValue('projectSort', x!);
                  set(() {});
                  _refresh();
                },
              ),
            const SizedBox(height: 8),
            Text(tr('Language'), style: const TextStyle(fontWeight: FontWeight.bold)),
            for (final (v, label) in const [('en', 'English'), ('ru', 'Русский')])
              RadioListTile<String>(
                key: ValueKey('lang-$v'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(label),
                value: v,
                groupValue: appLanguage,
                onChanged: (x) async {
                  appLanguage = x!;
                  await s?.setValue('language', x);
                  set(() {});
                  setState(() {});
                },
              ),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Close')))],
        ),
      ),
    );
  }

  Future<void> _open(ProjectMeta meta, {bool player = false}) async {
    final app = AppState()
      ..presetStore = PresetStore(widget.store.root)
      ..fontStore = FontStore(widget.store.root)
      ..videoStore = widget.store.videos
      ..audioStore = widget.store.audios
      ..projectStore = widget.store
      // a reference's "Open source": that project in its own editor, on
      // top of this one.
      ..onOpenProject = _openById;
    await app.openProject(meta.file);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => player ? PlayerScreen(app: app) : EditorScreen(appState: app)),
    );
    // closed: drop videos no project uses any more (after the final save,
    // so a video imported in this session is still referenced).
    await app.saveNow();
    await widget.store.cleanupVideos();
    _refresh();
  }

  Future<void> _openById(String id) async {
    final meta = await widget.store.metaOf(id);
    if (meta != null) await _open(meta);
  }

  /// Several picked (a long press starts it, taps add / take out): their
  /// files' paths, shown tinted.
  final Set<String> _picked = {};

  void _togglePick(ProjectMeta p) => setState(() => _picked.contains(p.file.path) ? _picked.remove(p.file.path) : _picked.add(p.file.path));

  Future<void> _deletePicked(List<ProjectMeta> all) async {
    final ps = [for (final p in all) if (_picked.contains(p.file.path)) p];
    if (ps.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${ps.length} projects?'),
        content: Text('${ps.map((p) => p.name).join(', ')}. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(tr('Delete'))),
        ],
      ),
    );
    if (ok != true) return;
    for (final p in ps) {
      await widget.store.delete(p.file);
    }
    await widget.store.cleanupVideos();
    _picked.clear();
    _refresh();
  }

  Future<void> _duplicatePicked(List<ProjectMeta> all) async {
    for (final p in all) {
      if (_picked.contains(p.file.path)) await widget.store.duplicate(p.file);
    }
    _picked.clear();
    _refresh();
  }

  Future<void> _duplicate(ProjectMeta meta) async {
    await widget.store.duplicate(meta.file);
    _refresh();
  }

  Future<void> _create() async {
    final existing = await _projects;
    if (!mounted) return;
    final spec = await showNewProjectDialog(context, defaultName: 'Project ${existing.length + 1}');
    if (spec == null) return;
    final file = await widget.store.create(spec.name, spec.width, spec.height, fps: spec.fps);
    if (spec.guide) await AppSettings.instance?.setTourWanted();
    final metas = await widget.store.list();
    _refresh();
    await _open(metas.firstWhere((m) => m.file.path == file.path));
  }

  Future<void> _rename(ProjectMeta meta) async {
    final controller = TextEditingController(text: meta.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename project'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(tr('Rename')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await widget.store.rename(meta.file, name);
    _refresh();
  }

  Future<void> _delete(ProjectMeta meta) async {
    // other projects that show this one lose it.
    final users = await widget.store.usedIn(meta.id);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${meta.name}"?'),
        content: Text(users.isEmpty
            ? 'This cannot be undone.'
            : 'Used in ${users.length} project${users.length == 1 ? '' : 's'}: '
                '${users.map((u) => u.name).join(', ')}. They will show "Project not found". '
                'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(tr('Delete'))),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.delete(meta.file);
    await widget.store.cleanupVideos();
    _refresh();
  }

  /// A chatbot's reply (MCJ) as a new project, after its report.
  Future<void> _importFromText() async {
    final r = await showAiImportDialog(context);
    if (r == null || !mounted) return;
    final existing = await _projects;
    final name = 'AI project ${existing.length + 1}';
    final file = await widget.store.create(name, r.width, r.height, fps: r.fps);
    await saveProjectToFile(file, r.project,
        maxFrame: r.duration,
        playbackSpeed: 1,
        name: name,
        frameWidth: r.width,
        frameHeight: r.height,
        backgroundRgb: r.background == null ? null : int.parse(r.background!.substring(1), radix: 16),
        projectFps: r.fps,
        projectId: newProjectId());
    final metas = await widget.store.list();
    _refresh();
    if (!mounted) return;
    await _open(metas.firstWhere((m) => m.file.path == file.path));
  }

  /// Every project with its media, fonts, presets and settings, saved as
  /// one zip where the user picks.
  Future<void> _backup() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = makeBackup(widget.store.root);
      final d = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save the backup',
        fileName: 'MCore-backup-${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}.zip',
        bytes: bytes,
      );
      if (path == null) return;
      // desktop: saveFile only names the file.
      if (!Platform.isAndroid && !Platform.isIOS) await File(path).writeAsBytes(bytes);
      messenger
          .showSnackBar(SnackBar(content: Text('Backup saved (${(bytes.length / 1048576).toStringAsFixed(1)} MB)')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> _restore() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await pickOriginalFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final path = picked?.files.single.path;
    if (path == null) return;
    try {
      final n = restoreBackup(await File(path).readAsBytes(), widget.store.root);
      await FontStore(widget.store.root).registerAll();
      _refresh();
      messenger.showSnackBar(SnackBar(content: Text('Restored $n files. Restart the app for its settings.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _picked.isNotEmpty
          ? AppBar(
              leading: IconButton(
                key: const ValueKey('home-pick-clear'),
                icon: const Icon(Icons.close),
                onPressed: () => setState(_picked.clear),
              ),
              title: Text('${_picked.length} selected'),
              actions: [
                IconButton(
                  key: const ValueKey('home-pick-duplicate'),
                  icon: const Icon(Icons.copy_all_outlined),
                  tooltip: tr('Duplicate'),
                  onPressed: () async => _duplicatePicked(await _projects),
                ),
                IconButton(
                  key: const ValueKey('home-pick-delete'),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: tr('Delete'),
                  onPressed: () async => _deletePicked(await _projects),
                ),
              ],
            )
          : AppBar(title: Text(tr('Projects')), actions: [
        IconButton(
          key: const ValueKey('home-settings'),
          icon: const Icon(Icons.settings_outlined),
          tooltip: tr('Settings'),
          onPressed: _settings,
        ),
        PopupMenuButton<String>(
          key: const ValueKey('home-menu'),
          onSelected: (v) async {
            if (v == 'aiPrompt') {
              await showAiPromptDialog(context);
              return;
            }
            if (v == 'perf') {
              await widget.store.addPerfScenes();
              _refresh();
            }
            if (v == 'backup') await _backup();
            if (v == 'aiImport') await _importFromText();
            if (v == 'restore') await _restore();
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'aiPrompt', child: Text(tr('Prompt for AI...'))),
            PopupMenuItem(value: 'aiImport', child: Text(tr('Import from text...'))),
            PopupMenuItem(value: 'backup', child: Text(tr('Back up everything...'))),
            PopupMenuItem(value: 'restore', child: Text(tr('Restore a backup...'))),
            PopupMenuItem(value: 'perf', child: Text(tr('Add performance test projects'))),
          ],
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(tr('New project')),
      ),
      body: FutureBuilder<List<ProjectMeta>>(
        future: _projects,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final projects = snapshot.data!;
          if (projects.isEmpty) {
            return const Center(
              child: Text('No projects yet - tap "New project" to start.', style: TextStyle(color: Colors.grey)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: projects.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final p = projects[i];
              final picked = _picked.contains(p.file.path);
              return ListTile(
                key: ValueKey('home-project-$i'),
                // picked: tinted half-see-through.
                tileColor: picked ? Theme.of(context).colorScheme.primary.withOpacity(0.18) : null,
                onLongPress: () => _togglePick(p),
                leading: _AspectThumb(width: p.frameWidth, height: p.frameHeight),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: hint('${p.frameWidth.round()} × ${p.frameHeight.round()}  ·  ${_formatDate(p.modified)}'),
                onTap: () => _picked.isNotEmpty ? _togglePick(p) : _open(p),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) => switch (action) {
                    'play' => _open(p, player: true),
                    'rename' => _rename(p),
                    'duplicate' => _duplicate(p),
                    'usedIn' => showUsedInDialog(context, widget.store, p),
                    _ => _delete(p),
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'play', child: Text(tr('Play full screen'))),
                    PopupMenuItem(value: 'rename', child: Text(tr('Rename'))),
                    PopupMenuItem(value: 'duplicate', child: Text(tr('Duplicate'))),
                    PopupMenuItem(value: 'usedIn', child: Text(tr('Used in...'))),
                    PopupMenuItem(value: 'delete', child: Text(tr('Delete'))),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

String _formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// A small outline of the project's frame shape.
class _AspectThumb extends StatelessWidget {
  final double width;
  final double height;
  const _AspectThumb({required this.width, required this.height});

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

class NewProjectSpec {
  final String name;
  final double width;
  final double height;
  final int fps;

  /// Show the tool fields' guides in this project.
  final bool guide;
  const NewProjectSpec(this.name, this.width, this.height, {this.fps = 60, this.guide = false});
}

class _Aspect {
  final String label;
  final int w;
  final int h;
  const _Aspect(this.label, this.w, this.h);
}

const _aspects = [
  _Aspect('1:1', 1, 1),
  _Aspect('4:3', 4, 3),
  _Aspect('16:9', 16, 9),
  _Aspect('3:4', 3, 4),
  _Aspect('4:5', 4, 5),
  _Aspect('9:16', 9, 16),
];

/// short-side pixel counts, biggest first
const _resolutions = [2160, 1620, 1440, 1080, 720, 480];

const _fpsChoices = [60, 50, 30, 25, 24];

int _even(double v) => (v / 2).round() * 2;

/// Frame size for an aspect ratio at a given short-side resolution,
/// rounded to even numbers (video encoders expect even dimensions).
(int, int) frameSizeFor(int aspectW, int aspectH, int shortSide) {
  if (aspectW >= aspectH) {
    return (_even(shortSide * aspectW / aspectH), shortSide);
  }
  return (shortSide, _even(shortSide * aspectH / aspectW));
}

/// Name, aspect ratio and resolution (or a custom width/height).
Future<NewProjectSpec?> showNewProjectDialog(BuildContext context, {String defaultName = 'Untitled'}) {
  return showDialog<NewProjectSpec>(
    context: context,
    builder: (_) => _NewProjectDialog(defaultName: defaultName),
  );
}

class _NewProjectDialog extends StatefulWidget {
  final String defaultName;
  const _NewProjectDialog({required this.defaultName});

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  late final _name = TextEditingController(text: widget.defaultName);
  final _customW = TextEditingController(text: '1080');
  final _customH = TextEditingController(text: '1080');
  _Aspect _aspect = _aspects[0];
  int? _resolution = 1080; // null = custom
  int _fps = 60;
  bool _guide = false;

  @override
  void dispose() {
    _name.dispose();
    _customW.dispose();
    _customH.dispose();
    super.dispose();
  }

  (int, int)? get _size {
    final res = _resolution;
    if (res != null) return frameSizeFor(_aspect.w, _aspect.h, res);
    final w = int.tryParse(_customW.text), h = int.tryParse(_customH.text);
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return (w, h);
  }

  /// A row of chips that scrolls sideways.
  Widget _chipRow(List<Widget> chips) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final c in chips) Padding(padding: const EdgeInsets.only(right: 6), child: c),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final size = _size;
    return AlertDialog(
      title: Text(tr('New project')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 16),
            // the choices in one field (each row scrolls sideways).
            Container(
              key: const ValueKey('new-project-formats'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Aspect ratio', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  _chipRow([
                    for (final a in _aspects)
                      ChoiceChip(
                        label: Text(a.label),
                        selected: _resolution != null && _aspect == a,
                        onSelected: _resolution == null ? null : (_) => setState(() => _aspect = a),
                      ),
                  ]),
                  const SizedBox(height: 12),
                  const Text('Resolution', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  _chipRow([
                    for (final r in _resolutions)
                      ChoiceChip(
                        label: Text(switch (r) { 2160 => '4K', 1620 => '3K', 1440 => '2K', _ => '${r}p' }),
                        selected: _resolution == r,
                        onSelected: (_) => setState(() => _resolution = r),
                      ),
                    ChoiceChip(
                      label: const Text('Custom'),
                      selected: _resolution == null,
                      onSelected: (_) => setState(() => _resolution = null),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  const Text('Frame rate', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  _chipRow([
                    for (final f in _fpsChoices)
                      ChoiceChip(
                        key: ValueKey('new-project-fps-$f'),
                        label: Text('$f fps'),
                        selected: _fps == f,
                        onSelected: (_) => setState(() => _fps = f),
                      ),
                  ]),
                ],
              ),
            ),
            if (_resolution == null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customW,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Width'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _customH,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Height'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(size == null ? 'Enter a valid size' : '${size.$1} × ${size.$2} px, $_fps fps',
                style: const TextStyle(color: Colors.grey)),
            // right above Create: the tool fields' tour.
            CheckboxListTile(
              key: const ValueKey('new-project-guide'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Show the tool guide'),
              subtitle: const Text('A tour of the tool fields when they appear', style: TextStyle(fontSize: 11)),
              value: _guide,
              onChanged: (v) => setState(() => _guide = v ?? false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: size == null
              ? null
              : () {
                  final name = _name.text.trim();
                  Navigator.pop(
                    context,
                    NewProjectSpec(name.isEmpty ? widget.defaultName : name, size.$1.toDouble(), size.$2.toDouble(),
                        fps: _fps, guide: _guide),
                  );
                },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
