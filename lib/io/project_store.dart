import 'dart:convert';
import 'dart:io';

import 'package:movement_core/movement_core.dart';

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
  ProjectMeta({
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

  /// Removes imported videos and sounds no saved project uses any more,
  /// keeping `keepVideos` / `keepAudios` too (what an open project and its
  /// undo history still use). Returns the removed video ids.
  Future<Set<String>> cleanupVideos({Set<String> keepVideos = const {}, Set<String> keepAudios = const {}}) async {
    final files = <File>[];
    if (await _dir.exists()) {
      await for (final f in _dir.list()) {
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
    if (!await _dir.exists()) return [];
    final metas = <ProjectMeta>[];
    await for (final entity in _dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final data = jsonDecode(await entity.readAsString());
        if (data is! Map<String, dynamic>) continue;
        // files saved before ids get one now (kept from then on).
        if (data['id'] is! String) {
          data['id'] = newProjectId();
          await entity.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
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
        ));
      } catch (_) {
        continue;
      }
    }
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
    await saveProjectToFile(file, Project(layers: []),
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
    for (final scene in perfReferenceScenes()) {
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
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  Future<ProjectMeta?> metaOf(String id) async {
    for (final m in await list()) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> delete(File file) async {
    if (await file.exists()) await file.delete();
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
