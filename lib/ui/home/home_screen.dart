import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../io/crash_log.dart';
import '../../i18n.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../player/player_screen.dart';
import '../../io/app_settings.dart';
import '../../io/save_load.dart';
import '../ai/ai_dialogs.dart';
import '../../io/backup.dart';
import '../../io/outside_folder.dart';
import '../../io/file_pick.dart';
import '../../io/font_store.dart';
import '../../io/preset_store.dart';
import '../../io/project_store.dart';
import '../layer_panel/project_ref_ui.dart' show showUsedInDialog;
import '../../main.dart' show EditorScreen;
import '../../io/freeze_watch.dart';
import '../../version.dart';

/// The app's start screen: "New project" plus the list of saved projects
/// (newest first). Opening one gives it its own AppState/EditorScreen,
/// autosaved to its own file; returning refreshes the list.
class HomeScreen extends StatefulWidget {
  final ProjectStore store;

  /// The last start never got going: this one was a safe one (said on
  /// top, with a backup at hand).
  final bool safeStart;
  final Directory? cacheRoot;
  const HomeScreen({super.key, required this.store, this.safeStart = false, this.cacheRoot});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<ProjectMeta>> _projects = _list();

  void _refresh() => setState(() {
        _projects = _list();
      });

  /// The projects, newest first by the chosen date (see Settings).
  /// Project id -> its folder (see ProjectStore.folders); folders open.
  Map<String, String> _folders = {};
  final Set<String> _openFolders = {};

  Future<List<ProjectMeta>> _list() async {
    final all = await widget.store.list();
    _folders = await widget.store.folders();
    // kept outside the app too: written there once something changed.
    _keepOutside(all);
    // what waited out its week in the trash goes now.
    await widget.store.purgeTrash();
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

  /// A project is being opened: further taps wait (a second tap opened
  /// it twice, on top of itself, and the app went down).
  bool _opening = false;

  Future<void> _open(ProjectMeta meta, {bool player = false}) async {
    if (_opening) return;
    _opening = true;
    try {
      await _openOnce(meta, player: player);
    } finally {
      _opening = false;
    }
  }

  Future<void> _openOnce(ProjectMeta meta, {bool player = false}) async {
    final app = AppState()
      ..presetStore = PresetStore(widget.store.root)
      ..fontStore = FontStore(widget.store.root)
      ..videoStore = widget.store.videos
      ..audioStore = widget.store.audios
      ..projectStore = widget.store
      // a reference's "Open source": that project in its own editor, on
      // top of this one.
      ..onOpenProject = _openById;
    // not read: not opened (nothing is ever saved over it).
    if (!await app.openProject(meta.file)) {
      if (!mounted) return;
      final err = '${app.openError}';
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          key: const ValueKey('open-failed'),
          title: Text('"${meta.name}" ${tr('could not be opened')}'),
          content: SingleChildScrollView(
              child: SelectableText('${tr('Its file is left as it is. Copy this and send it to get it fixed:')}\n\n$err',
                  style: const TextStyle(fontSize: 12))),
          actions: [
            TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: 'open failed: ${meta.file.path}\n$err')),
                child: Text(tr('Copy'))),
            TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('OK'))),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    // a crash in it is told where it was.
    CrashLog.instance?.onMemoryPressure = () => app.trimMemory('the system asked');
    CrashLog.instance?.status = () => {
          'project': app.projectName,
          'frame': app.currentFrame,
          'playing': app.playing,
          'layers': app.project.layers.length,
          'refs': app.project.layers.where((l) => l.content.shape == 'projectRef').length,
          'memory MB': FreezeWatch.memoryMb(),
          'version': appVersion,
        };
    final route = Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => player ? PlayerScreen(app: app) : EditorScreen(appState: app)),
    );
    // open now (its route covers the list): a reference's "Open source"
    // may open another one on top.
    _opening = false;
    await route;
    CrashLog.instance?.status = null;
    CrashLog.instance?.onMemoryPressure = null;
    // closed: drop videos no project uses any more (after the final save,
    // so a video imported in this session is still referenced).
    await app.saveNow();
    await widget.store.cleanupVideos();
    _refresh();
  }

  /// A project file that doesn't read: what it is, a copy of it saved
  /// outside the app (to be sent on and repaired), or deleted.
  Widget _unreadableTile(({File file, int size, String reason}) b) {
    final ts = int.tryParse(b.file.uri.pathSegments.last.replaceAll('.json', ''));
    final made = ts == null ? '' : _formatDate(DateTime.fromMicrosecondsSinceEpoch(ts));
    final size = b.size < 1024 ? '${b.size} B' : '${(b.size / 1024).toStringAsFixed(1)} KB';
    return ListTile(
      key: ValueKey('home-unreadable-${b.file.path}'),
      leading: const Icon(Icons.broken_image_outlined, color: Colors.orangeAccent),
      title: Text(tr('Damaged project file')),
      subtitle: hint('${made.isEmpty ? '' : '$made  ·  '}$size  ·  ${b.size == 0 ? tr('empty: nothing left in it') : b.reason}'),
      trailing: PopupMenuButton<String>(
        onSelected: (a) async {
          final messenger = ScaffoldMessenger.of(context);
          if (a == 'save') {
            final folder = await pickOutsideFolder();
            if (folder == null) return;
            try {
              await writeIntoFolder(folder.uri, 'MCore-damaged-${b.file.uri.pathSegments.last}', b.file, mime: 'application/json');
              messenger.showSnackBar(SnackBar(content: Text('${tr('Saved to')} ${folder.name}')));
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text('$e')));
            }
          } else if (a == 'delete') {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(tr('Delete the damaged file?')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
                  TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Delete'))),
                ],
              ),
            );
            if (ok == true) {
              await widget.store.delete(b.file);
              _refresh();
            }
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'save', child: Text(tr('Save a copy outside the app'))),
          PopupMenuItem(value: 'delete', child: Text(tr('Delete'))),
        ],
      ),
    );
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
        title: Text('Move ${ps.length} projects to the trash?'),
        content: Text('${ps.map((p) => p.name).join(', ')}. They are deleted for good after 7 days.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(tr('Delete'))),
        ],
      ),
    );
    if (ok != true) return;
    for (final p in ps) {
      await widget.store.moveToTrash(p.file);
    }
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

  /// The project's earlier versions kept beside its file: one picked
  /// becomes the project again.
  Future<void> _versions(ProjectMeta meta) async {
    final versions = await widget.store.versionsOf(meta.file);
    var now = 0;
    try {
      now = projectFileLayerCount(await meta.file.readAsString());
    } catch (_) {}
    if (!mounted) return;
    final picked = await showDialog<File>(
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('project-versions'),
        title: Text('"${meta.name}"'),
        content: SizedBox(
          width: 360,
          child: ListView(shrinkWrap: true, children: [
            ListTile(dense: true, title: Text(tr('Now')), subtitle: Text('$now ${tr('layers')}')),
            if (versions.isEmpty)
              Padding(padding: const EdgeInsets.all(8), child: Text(tr('No earlier versions kept.'))),
            for (final v in versions)
              ListTile(
                key: ValueKey('project-version-${v.file.path}'),
                dense: true,
                title: Text(tr(v.label)),
                subtitle: Text('${v.layers} ${tr('layers')}  ·  ${_formatDate(v.modified)}'),
                trailing: TextButton(onPressed: () => Navigator.pop(c, v.file), child: Text(tr('Restore'))),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Close')))],
      ),
    );
    if (picked == null) return;
    await widget.store.restoreVersion(meta.file, picked);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Restored (what was there is kept too)'))));
    }
    _refresh();
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
            ? 'It goes to the trash and is deleted for good after 7 days.'
            : 'Used in ${users.length} project${users.length == 1 ? '' : 's'}: '
                '${users.map((u) => u.name).join(', ')}. They will show "Project not found". '
                'It goes to the trash and is deleted for good after 7 days.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: Text(tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(tr('Delete'))),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.moveToTrash(meta.file);
    _refresh();
  }

  Future<void> _openTrash() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrashScreen(store: widget.store)));
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

  bool _keeping = false;

  @override
  void initState() {
    super.initState();
    // the app closed unexpectedly last time: where it was and what went
    // wrong, to be sent on.
    final log = CrashLog.instance;
    final crash = log?.lastCrash;
    if (log != null && crash != null) {
      log.lastCrash = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final text = log.describe(crash);
        showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            key: const ValueKey('crash-report'),
            title: Text(tr('MCore closed unexpectedly')),
            content: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontSize: 12))),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  Navigator.pop(c);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied - send it to fix the crash'))));
                },
                child: Text(tr('Copy report')),
              ),
              TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('OK'))),
            ],
          ),
        );
      });
    }
    // the last start never got going: said, with a backup at hand.
    if (widget.safeStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final m = ScaffoldMessenger.of(context);
        m.showMaterialBanner(MaterialBanner(
          key: const ValueKey('safe-start'),
          content: Text(tr('The app did not start last time: this time the cache was made afresh and your own fonts were left out. Back up your projects now to be safe.')),
          actions: [
            TextButton(
              onPressed: () {
                m.hideCurrentMaterialBanner();
                _projectsFolder();
              },
              child: Text(tr('Keep them outside')),
            ),
            TextButton(onPressed: m.hideCurrentMaterialBanner, child: Text(tr('OK'))),
          ],
        ));
      });
    }
  }

  /// Projects kept in a folder outside the app (settings
  /// 'projectsFolder'): the backup there is written over when a project
  /// changed since the last one.
  Future<void> _keepOutside(List<ProjectMeta> all) async {
    final s = AppSettings.instance;
    final folder = s?.projectsFolder;
    if (s == null || folder == null || _keeping || all.isEmpty) return;
    final newest = all.map((m) => m.modified.millisecondsSinceEpoch).reduce((a, b) => a > b ? a : b);
    if (newest <= s.projectsFolderSaved) return;
    _keeping = true;
    try {
      await backUpProjectsTo(folder, widget.store);
      await s.setValue('projectsFolderSaved', newest);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Could not keep the projects in the folder')}: $e')));
      }
    } finally {
      _keeping = false;
    }
  }

  /// Where the projects are kept outside the app: pick a folder (a copy
  /// goes there now and after every change), or stop.
  Future<void> _projectsFolder() async {
    final s = AppSettings.instance;
    if (s == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final now = s.projectsFolder;
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Projects outside the app')),
        content: Text(now == null
            ? tr('Pick a folder: every project with its media is kept there too (one file, MCore-projects.zip, written over after each change). It outlives the app - restore it with "Restore a backup".')
            : '${tr('Kept in')} ${s.projectsFolderName ?? now}'),
        actions: [
          if (now != null)
            TextButton(key: const ValueKey('projects-folder-stop'), onPressed: () => Navigator.pop(c, 'stop'), child: Text(tr('Stop'))),
          if (now != null)
            TextButton(key: const ValueKey('projects-folder-now'), onPressed: () => Navigator.pop(c, 'now'), child: Text(tr('Save now'))),
          FilledButton(
              key: const ValueKey('projects-folder-pick'),
              onPressed: () => Navigator.pop(c, 'pick'),
              child: Text(now == null ? tr('Pick a folder') : tr('Another folder'))),
        ],
      ),
    );
    if (choice == 'stop') {
      await s.setValue('projectsFolder', '');
      return;
    }
    if (choice == 'pick') {
      final f = await pickOutsideFolder(title: tr('Keep projects in'));
      if (f == null) return;
      await s.setValue('projectsFolder', f.uri);
      await s.setValue('projectsFolderName', f.name);
    } else if (choice != 'now') {
      return;
    }
    await s.setValue('projectsFolderSaved', 0);
    messenger.showSnackBar(SnackBar(content: Text(tr('Saving the projects there...'))));
    try {
      final n = await backUpProjectsTo(s.projectsFolder!, widget.store);
      await s.setValue('projectsFolderSaved', DateTime.now().millisecondsSinceEpoch);
      messenger.showSnackBar(SnackBar(content: Text('${tr('Projects kept in')} ${s.projectsFolderName} (${(n / 1048576).toStringAsFixed(1)} MB)')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${tr('Could not keep the projects in the folder')}: $e')));
    }
  }

  /// The cache (video frames, decoded sound, scratch): how big, and
  /// cleared on asking - all of it is made again when needed.
  Future<void> _cache() async {
    final messenger = ScaffoldMessenger.of(context);
    final size = await cacheSize(widget.cacheRoot);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Cache')),
        content: Text('${(size / 1048576).toStringAsFixed(1)} MB - ${tr('video frames, decoded sound and scratch files; all of it is made again when needed (a video takes a moment the first time).')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
          FilledButton(key: const ValueKey('cache-clear'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Clear'))),
        ],
      ),
    );
    if (ok != true) return;
    await clearCache(widget.cacheRoot);
    messenger.showSnackBar(SnackBar(content: Text(tr('Cache cleared'))));
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
    FreezeWatch.at('building $runtimeType');
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
          : AppBar(
              title: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(tr('Projects')),
                const SizedBox(width: 8),
                const Text('v$appVersion', key: ValueKey('home-version'), style: TextStyle(fontSize: 12, color: Colors.grey)),
              ]),
              actions: [
        IconButton(
          key: const ValueKey('home-trash'),
          icon: const Icon(Icons.delete_outline),
          tooltip: tr('Trash'),
          onPressed: _openTrash,
        ),
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
            if (v == 'folder') await _projectsFolder();
            if (v == 'cache') await _cache();
            if (v == 'aiImport') await _importFromText();
            if (v == 'restore') await _restore();
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'aiPrompt', child: Text(tr('Prompt for AI...'))),
            PopupMenuItem(value: 'aiImport', child: Text(tr('Import from text...'))),
            PopupMenuItem(value: 'backup', child: Text(tr('Back up everything...'))),
            PopupMenuItem(value: 'restore', child: Text(tr('Restore a backup...'))),
            PopupMenuItem(value: 'folder', child: Text(tr('Projects outside the app...'))),
            PopupMenuItem(value: 'cache', child: Text(tr('Cache...'))),
            PopupMenuItem(value: 'perf', child: Text(tr('Add performance test projects'))),
          ],
        ),
      ]),
      // several picked: they go into one folder from here.
      floatingActionButton: _picked.isNotEmpty
          ? FloatingActionButton.extended(
              key: const ValueKey('home-pick-folder'),
              onPressed: () async => _folderPicked(await _projects),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: Text(tr('Put into a folder')),
            )
          : FloatingActionButton.extended(
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
          // project files that don't read: shown, never hidden away.
          final bad = widget.store.unreadable;
          if (projects.isEmpty && bad.isEmpty) {
            return const Center(
              child: Text('No projects yet - tap "New project" to start.', style: TextStyle(color: Colors.grey)),
            );
          }
          // folders first (each folded or open), then the projects in none.
          final byFolder = <String, List<ProjectMeta>>{};
          final loose = <ProjectMeta>[];
          for (final p in projects) {
            final f = _folders[p.id];
            if (f == null) {
              loose.add(p);
            } else {
              (byFolder[f] ??= []).add(p);
            }
          }
          final names = byFolder.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          final rows = <Widget>[
            for (final b in bad) _unreadableTile(b),
            for (final f in names) ...[
              _folderTile(f, byFolder[f]!),
              if (_openFolders.contains(f))
                for (final p in byFolder[f]!)
                  Padding(padding: const EdgeInsets.only(left: 16), child: _projectTile(p, projects.indexOf(p))),
            ],
            for (final p in loose) _projectTile(p, projects.indexOf(p)),
          ];
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) => rows[i],
          );
        },
      ),
    );
  }

  /// A folder of projects: its name and count; tap folds / opens it.
  Widget _folderTile(String name, List<ProjectMeta> items) {
    final open = _openFolders.contains(name);
    final picked = items.isNotEmpty && items.every((p) => _picked.contains(p.file.path));
    return ListTile(
      key: ValueKey('home-folder-$name'),
      tileColor: picked ? Theme.of(context).colorScheme.primary.withOpacity(0.18) : null,
      leading: Icon(open ? Icons.folder_open : Icons.folder),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: hint('${items.length} ${tr('projects')}'),
      onTap: () => setState(() => open ? _openFolders.remove(name) : _openFolders.add(name)),
      // long press: the whole folder picked (or not).
      onLongPress: () => setState(() {
        for (final p in items) {
          picked ? _picked.remove(p.file.path) : _picked.add(p.file.path);
        }
      }),
      trailing: PopupMenuButton<String>(
        key: ValueKey('home-folder-menu-$name'),
        onSelected: (a) async {
          if (a == 'rename') {
            final to = await _askName(tr('Rename folder'), name);
            if (to == null || to.isEmpty) return;
            await widget.store.renameFolder(name, to);
            if (_openFolders.remove(name)) _openFolders.add(to);
          } else {
            await widget.store.ungroupFolder(name);
          }
          _refresh();
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'rename', child: Text(tr('Rename'))),
          PopupMenuItem(value: 'ungroup', child: Text(tr('Ungroup (projects stay)'))),
        ],
      ),
    );
  }

  Future<String?> _askName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(key: const ValueKey('folder-name'), controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('Cancel'))),
          TextButton(
              key: const ValueKey('folder-name-ok'), onPressed: () => Navigator.pop(c, controller.text.trim()), child: Text(tr('OK'))),
        ],
      ),
    );
    controller.dispose();
    return name;
  }

  /// Where the projects go: a folder there is, a new one, or out of any.
  /// Null: cancelled; '': out of any folder.
  Future<String?> _chooseFolder(int count) async {
    const newOne = '\u0000new';
    final names = {..._folders.values}.toList()..sort();
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        key: const ValueKey('folder-choose'),
        title: Text('$count: ${tr('into a folder')}'),
        children: [
          for (final n in names)
            SimpleDialogOption(key: ValueKey('folder-choose-$n'), onPressed: () => Navigator.pop(c, n), child: Text(n)),
          SimpleDialogOption(
              key: const ValueKey('folder-choose-new'), onPressed: () => Navigator.pop(c, newOne), child: Text(tr('New folder...'))),
          if (names.isNotEmpty)
            SimpleDialogOption(
                key: const ValueKey('folder-choose-none'),
                onPressed: () => Navigator.pop(c, ''),
                child: Text(tr('Out of any folder'))),
        ],
      ),
    );
    if (choice != newOne) return choice;
    final name = await _askName(tr('New folder'), '');
    return name == null || name.isEmpty ? null : name;
  }

  Future<void> _folderPicked(List<ProjectMeta> all) async {
    final ps = [for (final p in all) if (_picked.contains(p.file.path)) p];
    if (ps.isEmpty) return;
    final to = await _chooseFolder(ps.length);
    if (to == null) return;
    await widget.store.setFolder([for (final p in ps) p.id], to.isEmpty ? null : to);
    if (to.isNotEmpty) _openFolders.add(to);
    _picked.clear();
    _refresh();
  }

  Widget _projectTile(ProjectMeta p, int i) {
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
        onSelected: (action) async {
          switch (action) {
            case 'play':
              await _open(p, player: true);
            case 'rename':
              await _rename(p);
            case 'duplicate':
              await _duplicate(p);
            case 'usedIn':
              await showUsedInDialog(context, widget.store, p);
            case 'versions':
              await _versions(p);
            case 'folder':
              final to = await _chooseFolder(1);
              if (to == null) return;
              await widget.store.setFolder([p.id], to.isEmpty ? null : to);
              if (to.isNotEmpty) _openFolders.add(to);
              _refresh();
            default:
              await _delete(p);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'play', child: Text(tr('Play full screen'))),
          PopupMenuItem(value: 'rename', child: Text(tr('Rename'))),
          PopupMenuItem(value: 'duplicate', child: Text(tr('Duplicate'))),
          PopupMenuItem(value: 'folder', child: Text(tr('Into a folder...'))),
          PopupMenuItem(value: 'usedIn', child: Text(tr('Used in...'))),
          PopupMenuItem(value: 'versions', child: Text(tr('Previous versions...'))),
          PopupMenuItem(value: 'delete', child: Text(tr('Delete'))),
        ],
      ),
    );
  }
}

/// Deleted projects: each waits a week, then goes for good. Restore one,
/// delete one for good, or empty the whole trash.
class TrashScreen extends StatefulWidget {
  final ProjectStore store;
  const TrashScreen({super.key, required this.store});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late Future<List<ProjectMeta>> _items = widget.store.listTrash();

  void _refresh() => setState(() {
        _items = widget.store.listTrash();
      });

  Future<bool> _confirm(String title) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: const Text('This cannot be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
            TextButton(key: const ValueKey('trash-confirm'), onPressed: () => Navigator.pop(c, true), child: Text(tr('Delete'))),
          ],
        ),
      ) ==
      true;

  @override
  Widget build(BuildContext context) {
    FreezeWatch.at('building $runtimeType');
    return Scaffold(
      appBar: AppBar(title: Text(tr('Trash')), actions: [
        FutureBuilder<List<ProjectMeta>>(
          future: _items,
          builder: (context, snap) => TextButton(
            key: const ValueKey('trash-empty'),
            onPressed: (snap.data ?? const []).isEmpty
                ? null
                : () async {
                    if (!await _confirm('Empty the trash?')) return;
                    await widget.store.emptyTrash();
                    _refresh();
                  },
            child: Text(tr('Empty trash')),
          ),
        ),
      ]),
      body: FutureBuilder<List<ProjectMeta>>(
        future: _items,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(child: Text('The trash is empty.', style: TextStyle(color: Colors.grey)));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final p = items[i];
              final days = p.purgeAt!.difference(DateTime.now()).inHours / 24;
              final left = days <= 1 ? 'Deleted within a day' : 'Deleted in ${days.ceil()} days';
              return ListTile(
                key: ValueKey('trash-item-$i'),
                leading: _AspectThumb(width: p.frameWidth, height: p.frameHeight),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(left, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    key: ValueKey('trash-restore-$i'),
                    icon: const Icon(Icons.restore),
                    tooltip: tr('Restore'),
                    onPressed: () async {
                      await widget.store.restoreFromTrash(p.file);
                      _refresh();
                    },
                  ),
                  IconButton(
                    key: ValueKey('trash-delete-$i'),
                    icon: const Icon(Icons.delete_forever_outlined),
                    tooltip: tr('Delete for good'),
                    onPressed: () async {
                      if (!await _confirm('Delete "${p.name}" for good?')) return;
                      await widget.store.delete(p.file);
                      await widget.store.cleanupVideos();
                      _refresh();
                    },
                  ),
                ]),
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
    FreezeWatch.at('building $runtimeType');
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
    FreezeWatch.at('building $runtimeType');
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
