import 'dart:convert';
import 'dart:io';

import 'package:movement_core/movement_core.dart';

import 'json_repair.dart';
import 'save_load.dart';
import 'audio_asset_store.dart';
import 'video_asset_store.dart';

/// One row of the home screen's project list.
class ProjectMeta {
  final File file;
  final String name;
  final double frameWidth;
  final double frameHeight;
  final DateTime modified;

  /// When it was made: its file name is that moment (microseconds), or
  /// the last change for files named otherwise.
  DateTime get created {
    final n = int.tryParse(file.uri.pathSegments.last.replaceAll('.json', ''));
    return n == null ? modified : DateTime.fromMicrosecondsSinceEpoch(n);
  }

  /// Stable id (project references find a project by it), save count.
  final String id;
  final int revision;

  /// The projects it refers to directly.
  final Set<String> refs;

  /// In the trash since then (null: a live project).
  final DateTime? trashedAt;

  /// In the trash: when it goes for good.
  DateTime? get purgeAt => trashedAt?.add(ProjectStore.trashKeep);
  ProjectMeta({
    this.trashedAt,
    required this.id,
    this.revision = 0,
    this.refs = const {},
    required this.file,
    required this.name,
    required this.frameWidth,
    required this.frameHeight,
    required this.modified,
  });
}

/// Projects live as one save_load.dart file each under
/// `<root>/projects/<id>.json`. `root` is the app documents directory in
/// the app (path_provider), a temp dir in tests.
/// Layers in a project file's text (0 when it can't be read).
int projectFileLayerCount(String text) {
  try {
    final j = jsonDecode(text);
    final layers = j is Map ? (j['project'] is Map ? (j['project'] as Map)['layers'] : null) : null;
    return layers is List ? layers.length : 0;
  } catch (_) {
    return 0;
  }
}

/// A project file's earlier versions kept beside it: the save before the
/// last (`.bak`), one put aside before it was saved empty (`.keep`), one
/// that couldn't be read (`.damaged`), the one replaced by a restore
/// (`.before-restore`).
const projectVersionKinds = <(String, String)>[
  ('.bak', 'The save before the last'),
  ('.keep', 'Before it was saved empty'),
  ('.before-restore', 'Before the last restore'),
  ('.damaged', 'A damaged copy (as it was)'),
];

class ProjectStore {
  final Directory root;

  /// Imported videos (see video_asset_store.dart). Frames go to `cacheRoot`
  /// (the app cache directory), or `<root>/cache` when none is given.
  final VideoAssetStore videos;

  /// Imported sounds (see audio_asset_store.dart), same split.
  final AudioAssetStore audios;

  ProjectStore(this.root, {Directory? cacheRoot})
      : videos = VideoAssetStore(documents: root, cache: cacheRoot ?? Directory('${root.path}/cache')),
        audios = AudioAssetStore(documents: root, cache: cacheRoot ?? Directory('${root.path}/cache'));

  Directory get _dir => Directory('${root.path}/projects');

  /// Deleted projects wait here a week before they go for good.
  Directory get _trash => Directory('${root.path}/trash');
  static const trashKeep = Duration(days: 7);

  /// Removes imported videos and sounds no saved project uses any more,
  /// keeping `keepVideos` / `keepAudios` too (what an open project and its
  /// undo history still use). Returns the removed video ids.
  Future<Set<String>> cleanupVideos({Set<String> keepVideos = const {}, Set<String> keepAudios = const {}}) async {
    // (projects in the trash keep their media: they can come back.)
    final files = <File>[];
    for (final d in [_dir, _trash]) {
      if (!await d.exists()) continue;
      await for (final f in d.list()) {
        if (f is File && f.path.endsWith('.json')) files.add(f);
      }
    }
    await audios.cleanup(files, keep: keepAudios);
    return videos.cleanup(files, keep: keepVideos);
  }

  /// Newest first. Unreadable files are skipped rather than failing the
  /// whole list.
  Future<List<ProjectMeta>> list() async {
    await _migrateLegacyAutosave();
    return _metasIn(_dir);
  }

  /// The trash, newest deletion first - after dropping what has waited
  /// out its week.
  Future<List<ProjectMeta>> listTrash({DateTime? now}) async {
    await purgeTrash(now: now);
    final metas = await _metasIn(_trash);
    metas.sort((a, b) => b.trashedAt!.compareTo(a.trashedAt!));
    return metas;
  }

  /// Project files that could not be read at the last listing (never
  /// hidden away: shown, to be saved outside or repaired).
  List<({File file, int size, String reason})> unreadable = [];

  Future<List<ProjectMeta>> _metasIn(Directory dir) async {
    if (!await dir.exists()) return [];
    final metas = <ProjectMeta>[];
    final bad = <({File file, int size, String reason})>[];
    // a save the app closed in the middle of: the whole one it was
    // writing, or the one before it, back in place.
    if (dir.path == _dir.path) await _recoverOrphans(dir);
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      if (entity.uri.pathSegments.last == 'folders.json') continue;
      try {
        final data = await _readOrRecover(entity);
        if (data is! Map<String, dynamic>) {
          final size = await entity.length();
          bad.add((file: entity, size: size, reason: size == 0 ? 'empty' : 'cannot be read'));
          continue;
        }
        // files saved before ids get one now (kept from then on).
        if (data['id'] is! String) {
          data['id'] = newProjectId();
          await writeFileSafely(entity, const JsonEncoder.withIndent('  ').convert(data));
        }
        metas.add(ProjectMeta(
          id: data['id'] as String,
          revision: (data['revision'] as num?)?.toInt() ?? 0,
          refs: refsInFileJson(data),
          file: entity,
          name: (data['name'] as String?) ?? 'Untitled',
          frameWidth: (data['frameWidth'] as num?)?.toDouble() ?? defaultFrameWidth,
          frameHeight: (data['frameHeight'] as num?)?.toDouble() ?? defaultFrameHeight,
          modified: await entity.lastModified(),
          trashedAt: dir.path == _trash.path
              ? DateTime.tryParse(data['trashedAt'] as String? ?? '') ?? await entity.lastModified()
              : null,
        ));
      } catch (e) {
        try {
          bad.add((file: entity, size: await entity.length(), reason: '$e'));
        } catch (_) {}
        continue;
      }
    }
    if (dir.path == _dir.path) unreadable = bad;
    // file names are creation timestamps - the tiebreak for mtimes that
    // land in the same second.
    metas.sort((a, b) {
      final byTime = b.modified.compareTo(a.modified);
      return byTime != 0 ? byTime : b.file.path.compareTo(a.file.path);
    });
    return metas;
  }

  /// A new, empty project of the given frame size, written to disk
  /// immediately so it shows up in the list even if never edited.
  Future<File> create(String name, double width, double height, {int fps = 60}) async {
    await _dir.create(recursive: true);
    final file = File('${_dir.path}/${DateTime.now().microsecondsSinceEpoch}.json');
    // (a timeline 3 s long: with nothing on it, it fit to nothing - a
    // frame or two - and the layers added after were cut to that.)
    await saveProjectToFile(file, Project(layers: []),
        timelineLength: 3 * fps,
        maxFrame: 3 * fps,
        playbackSpeed: 1,
        name: name,
        frameWidth: width,
        frameHeight: height,
        projectFps: fps,
        projectId: newProjectId());
    return file;
  }

  /// A copy as a new project ("<name> copy"): a new id, revision 0.
  Future<File> duplicate(File file) async {
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    data['id'] = newProjectId();
    data['revision'] = 0;
    data['name'] = '${data['name'] ?? 'Untitled'} copy';
    final copy = File('${_dir.path}/${DateTime.now().microsecondsSinceEpoch}.json');
    await copy.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return copy;
  }

  /// The saved file of project `id` (its latest saved state), or null.
  Future<Map<String, dynamic>?> fileJsonOf(String id) async {
    for (final m in await list()) {
      if (m.id != id) continue;
      try {
        return jsonDecode(await m.file.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Loads the projects `ids` refer to, and theirs (as deep as nesting
  /// may go), as last saved. Missing ones are left out.
  Future<RefSources> loadSources(Iterable<String> ids) async {
    final metas = {for (final m in await list()) m.id: m};
    final out = <String, RefSource>{};
    var level = ids.toSet();
    for (var depth = 0; depth <= maxRefDepth && level.isNotEmpty; depth++) {
      final next = <String>{};
      for (final id in level) {
        if (out.containsKey(id)) continue;
        final m = metas[id];
        if (m == null) continue;
        try {
          final s = RefSource.fromFileJson(jsonDecode(await m.file.readAsString()) as Map<String, dynamic>);
          if (s == null) continue;
          out[id] = s;
          next.addAll(m.refs);
        } catch (_) {
          continue;
        }
      }
      level = next;
    }
    return out;
  }

  /// Who refers to whom (project id -> ids it refers to directly).
  Future<Map<String, Set<String>>> graph() async => {for (final m in await list()) m.id: m.refs};

  /// The projects that refer to `id` directly.
  Future<List<ProjectMeta>> usedIn(String id) async => [for (final m in await list()) if (m.refs.contains(id)) m];

  /// Adds the performance reference projects (perfReferenceScenes) to the
  /// list - for measuring a baseline with the performance HUD.
  Future<void> addPerfScenes() async {
    await _dir.create(recursive: true);
    var n = 0;
    // the timing-only scenes (static shapes, pendulum chain, motion blur,
    // mesh warp) stay for the benchmarks, not the project list.
    for (final scene in perfReferenceScenes().where((s) => !s.name.startsWith('Perf:'))) {
      final file = File('${_dir.path}/${DateTime.now().microsecondsSinceEpoch}_${n++}.json');
      await saveProjectToFile(file, scene.project,
          maxFrame: scene.maxFrame,
          playbackSpeed: 1,
          name: scene.name,
          frameWidth: 480,
          frameHeight: 480,
          timelineLength: scene.maxFrame);
    }
  }

  Future<void> rename(File file, String name) async {
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    data['name'] = name;
    await writeFileSafely(file, const JsonEncoder.withIndent('  ').convert(data));
  }

  /// A project file that doesn't read (cut short when the app closed while
  /// saving): its last whole version (`.bak`), the one being written
  /// (`.tmp`), or what can be read of it - put back in its place, the
  /// damaged one kept beside (`.damaged`). Null: nothing to be had.
  Future<Object?> _readOrRecover(File f) async {
    final text = await f.readAsString();
    try {
      return jsonDecode(text);
    } catch (_) {}
    Map<String, dynamic>? ok(Object? v) => v is Map<String, dynamic> && v['project'] is Map ? v : null;
    Map<String, dynamic>? found;
    var repaired = false;
    for (final side in ['${f.path}.tmp', '${f.path}.bak']) {
      try {
        final s = File(side);
        if (await s.exists()) found ??= ok(jsonDecode(await s.readAsString()));
      } catch (_) {}
    }
    if (found == null) {
      found = ok(repairTruncatedJson(text));
      repaired = found != null;
    }
    if (found == null) return null;
    try {
      await f.copy('${f.path}.damaged');
    } catch (_) {}
    if (repaired) found['name'] = '${found['name'] ?? 'Untitled'} (restored)';
    await writeFileSafely(f, const JsonEncoder.withIndent('  ').convert(found), keepBackup: false);
    return found;
  }

  // ---- folders of projects (the projects list) ----

  // (not .json: the projects list reads every .json beside them as a
  // project - it took the folders for one, "repaired" it, and they went)
  File get _foldersFile => File('${_dir.path}/project_folders.idx');

  /// Project id -> its folder's name (projects not in one: absent).
  Future<Map<String, String>> folders() async {
    try {
      final f = _foldersFile;
      // the earlier file: what is left of it taken over.
      final old = File('${_dir.path}/folders.json');
      if (!await f.exists() && await old.exists()) {
        try {
          final j = jsonDecode(await old.readAsString());
          if (j is Map) {
            await _saveFolders({
              for (final e in j.entries)
                if (e.value is String && e.key != 'id') '${e.key}': e.value as String
            });
          }
        } catch (_) {}
        await old.delete();
      }
      if (!await f.exists()) return {};
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return {};
      return {for (final e in j.entries) if (e.value is String) '${e.key}': e.value as String};
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveFolders(Map<String, String> m) async {
    await _dir.create(recursive: true);
    await writeFileSafely(_foldersFile, jsonEncode(m), keepBackup: false);
  }

  /// Puts the projects `ids` into folder `name` (null or empty: out of any).
  Future<void> setFolder(Iterable<String> ids, String? name) async {
    final m = await folders();
    for (final id in ids) {
      if (name == null || name.trim().isEmpty) {
        m.remove(id);
      } else {
        m[id] = name.trim();
      }
    }
    await _saveFolders(m);
  }

  /// A folder renamed (its projects go along).
  Future<void> renameFolder(String from, String to) async {
    if (to.trim().isEmpty) return;
    final m = await folders();
    m.updateAll((_, v) => v == from ? to.trim() : v);
    await _saveFolders(m);
  }

  /// A folder taken apart (its projects stay, out of any folder).
  Future<void> ungroupFolder(String name) async {
    final m = await folders()
      ..removeWhere((_, v) => v == name);
    await _saveFolders(m);
  }

  /// The earlier versions of `f` there are: their kind's name, file,
  /// layers in it, when written.
  Future<List<({String label, File file, int layers, DateTime modified})>> versionsOf(File f) async {
    final out = <({String label, File file, int layers, DateTime modified})>[];
    for (final (ext, label) in projectVersionKinds) {
      final v = File('${f.path}$ext');
      try {
        if (!await v.exists()) continue;
        out.add((label: label, file: v, layers: projectFileLayerCount(await v.readAsString()), modified: await v.lastModified()));
      } catch (_) {}
    }
    return out;
  }

  /// `f` becomes the earlier version `v` (what it was is kept as
  /// `.before-restore`).
  Future<void> restoreVersion(File f, File v) async {
    final text = await v.readAsString();
    if (await f.exists()) await f.copy('${f.path}.before-restore');
    await writeFileSafely(f, text, keepBackup: false);
  }

  /// A save cut off between its steps: only its side files there - the
  /// whole one taken back as the project.
  Future<void> _recoverOrphans(Directory dir) async {
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final p = e.path;
        final base = p.endsWith('.json.tmp') ? p.substring(0, p.length - 4) : p.endsWith('.json.bak') ? p.substring(0, p.length - 4) : null;
        if (base == null || await File(base).exists()) continue;
        try {
          final v = jsonDecode(await e.readAsString());
          if (v is Map && v['project'] is Map) await e.copy(base);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// A project file's side files (its last version, a save under way).
  Future<void> _dropSideFiles(File file) async {
    for (final s in ['.tmp', '.bak', '.damaged']) {
      try {
        final f = File('${file.path}$s');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<ProjectMeta?> metaOf(String id) async {
    for (final m in await list()) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// For good (no trash).
  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
    await _dropSideFiles(file);
  }

  /// Into the trash: it stays there a week (restorable), then goes.
  Future<void> moveToTrash(File file, {DateTime? now}) async {
    if (!await file.exists()) return;
    await _trash.create(recursive: true);
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    data['trashedAt'] = (now ?? DateTime.now()).toUtc().toIso8601String();
    await File('${_trash.path}/${file.uri.pathSegments.last}')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await file.delete();
    await _dropSideFiles(file);
  }

  /// Back out of the trash into the project list.
  Future<File?> restoreFromTrash(File file) async {
    if (!await file.exists()) return null;
    await _dir.create(recursive: true);
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    data.remove('trashedAt');
    final back = File('${_dir.path}/${file.uri.pathSegments.last}');
    await back.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    await file.delete();
    return back;
  }

  /// Everything in the trash, for good.
  Future<void> emptyTrash() async {
    if (await _trash.exists()) await _trash.delete(recursive: true);
    await cleanupVideos();
  }

  /// Drops trashed projects older than a week.
  Future<void> purgeTrash({DateTime? now}) async {
    final t = now ?? DateTime.now();
    var gone = false;
    for (final m in await _metasIn(_trash)) {
      if (!m.purgeAt!.isAfter(t)) {
        await m.file.delete();
        gone = true;
      }
    }
    if (gone) await cleanupVideos();
  }

  /// The app used to keep exactly one project, in `<root>/autosave.json`.
  /// On first run of the multi-project version it becomes a regular
  /// project so nothing is lost.
  Future<void> _migrateLegacyAutosave() async {
    final legacy = File('${root.path}/autosave.json');
    if (!await legacy.exists()) return;
    await _dir.create(recursive: true);
    final data = jsonDecode(await legacy.readAsString());
    if (data is Map<String, dynamic>) {
      data['name'] ??= 'Untitled';
      final target = File('${_dir.path}/${DateTime.now().microsecondsSinceEpoch}.json');
      await target.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    }
    await legacy.delete();
  }
}

/// The ids a project file refers to directly (its live references).
Set<String> refsInFileJson(Map<String, dynamic> data) {
  final p = data['project'];
  if (p is! Map || p['layers'] is! List) return const {};
  return {
    for (final l in p['layers'] as List)
      if (l is Map && l['content'] is Map)
        if ((l['content'] as Map)['shape'] == 'projectRef' &&
            (l['content'] as Map)['embedded'] == null &&
            (l['content'] as Map)['projectId'] is String)
          (l['content'] as Map)['projectId'] as String
  };
}
