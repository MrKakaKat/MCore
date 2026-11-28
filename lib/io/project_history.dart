import 'dart:convert';
import 'dart:io';

import 'project_store.dart' show projectFileLayerCount;
import 'json_repair.dart' show writeFileSafely;

/// One kept version of a project.
class HistoryEntry {
  final String id;
  final DateTime time;
  final int layers;

  /// The branch it is in (null: the main line).
  final String? branch;
  HistoryEntry({required this.id, required this.time, required this.layers, this.branch});

  Map<String, dynamic> toJson() => {'id': id, 'time': time.toIso8601String(), 'layers': layers, if (branch != null) 'branch': branch};
  static HistoryEntry fromJson(Map j) => HistoryEntry(
        id: j['id'] as String,
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        layers: (j['layers'] as num?)?.toInt() ?? 0,
        branch: j['branch'] as String?,
      );
}

/// A branch: new versions made after going back to an older one (`from`:
/// that version's id - it may be gone since).
class HistoryBranch {
  final String id;
  final String? from;
  final DateTime fromTime;
  HistoryBranch({required this.id, required this.from, required this.fromTime});
  Map<String, dynamic> toJson() => {'id': id, if (from != null) 'from': from, 'fromTime': fromTime.toIso8601String()};
  static HistoryBranch fromJson(Map j) => HistoryBranch(
        id: j['id'] as String,
        from: j['from'] as String?,
        fromTime: DateTime.tryParse(j['fromTime'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// A project's earlier versions, kept with the projects (not in the
/// cache): one each time it is left after editing - the newest
/// `keepMain` on the main line. Going back to one never loses the later
/// ones: what it was is kept, and the versions after that go into a
/// branch of its own (the newest `keepBranch` of it).
class ProjectHistory {
  final Directory dir;
  final List<HistoryEntry> entries;
  final List<HistoryBranch> branches;

  /// Where new versions go now (null: the main line).
  String? active;
  ProjectHistory._(this.dir, this.entries, this.branches, this.active);

  static Directory dirOf(Directory root, String projectId) => Directory('${root.path}/history/$projectId');

  static Future<ProjectHistory> of(Directory root, String projectId) async {
    final dir = dirOf(root, projectId);
    final index = File('${dir.path}/index.json');
    try {
      if (await index.exists()) {
        final j = jsonDecode(await index.readAsString()) as Map;
        return ProjectHistory._(
          dir,
          [for (final e in (j['entries'] as List? ?? const [])) if (e is Map) HistoryEntry.fromJson(e)],
          [for (final b in (j['branches'] as List? ?? const [])) if (b is Map) HistoryBranch.fromJson(b)],
          j['active'] as String?,
        );
      }
    } catch (_) {}
    return ProjectHistory._(dir, [], [], null);
  }

  /// The main line's versions, newest first.
  List<HistoryEntry> get main => [for (final e in entries.reversed) if (e.branch == null) e];

  /// A branch's versions, newest first.
  List<HistoryEntry> inBranch(String id) => [for (final e in entries.reversed) if (e.branch == id) e];

  /// The branches started from version `id`.
  List<HistoryBranch> branchesFrom(String id) => [for (final b in branches) if (b.from == id) b];

  File fileOf(HistoryEntry e) => File('${dir.path}/${e.id}.json');

  Future<void> _save() async {
    await dir.create(recursive: true);
    await File('${dir.path}/index.json').writeAsString(jsonEncode({
      'entries': [for (final e in entries) e.toJson()],
      'branches': [for (final b in branches) b.toJson()],
      if (active != null) 'active': active,
    }));
  }

  /// Keeps `text` (a project file) as a new version where versions go now
  /// - not when it is the same as the last one there. Old ones past the
  /// limits go.
  Future<HistoryEntry?> record(String text, {int keepMain = 10, int keepBranch = 5}) async {
    final line = active == null ? main : inBranch(active!);
    if (line.isNotEmpty) {
      try {
        if (await fileOf(line.first).readAsString() == text) return null;
      } catch (_) {}
    }
    await dir.create(recursive: true);
    final e = HistoryEntry(
        id: 'v${DateTime.now().microsecondsSinceEpoch}', time: DateTime.now(), layers: projectFileLayerCount(text), branch: active);
    await fileOf(e).writeAsString(text, flush: true);
    entries.add(e);
    await _prune(keepMain: keepMain, keepBranch: keepBranch);
    await _save();
    return e;
  }

  Future<void> _prune({required int keepMain, required int keepBranch}) async {
    Future<void> trim(List<HistoryEntry> newestFirst, int keep) async {
      for (final e in newestFirst.skip(keep)) {
        entries.remove(e);
        try {
          await fileOf(e).delete();
        } catch (_) {}
      }
    }

    await trim(main, keepMain);
    for (final b in branches.toList()) {
      await trim(inBranch(b.id), keepBranch);
      // an empty branch that is not where versions go: gone.
      if (inBranch(b.id).isEmpty && b.id != active) branches.remove(b);
    }
  }

  /// Back to version `e`: what `projectFile` is now is kept first, then it
  /// becomes `e` - and the versions from now on go into a new branch
  /// started from it (the later ones all stay).
  Future<void> restore(File projectFile, HistoryEntry e, {int keepMain = 10, int keepBranch = 5}) async {
    final text = await fileOf(e).readAsString();
    if (await projectFile.exists()) await record(await projectFile.readAsString(), keepMain: keepMain, keepBranch: keepBranch);
    final b = HistoryBranch(id: 'b${DateTime.now().microsecondsSinceEpoch}', from: e.id, fromTime: e.time);
    branches.add(b);
    active = b.id;
    await _save();
    await writeFileSafely(projectFile, text, keepBackup: false);
  }

  /// The whole history to project `toId` (a copy of the project).
  Future<void> copyTo(Directory root, String toId) async {
    if (!await dir.exists()) return;
    final to = dirOf(root, toId);
    await to.create(recursive: true);
    await for (final f in dir.list()) {
      if (f is File) await f.copy('${to.path}/${f.uri.pathSegments.last}');
    }
  }
}
