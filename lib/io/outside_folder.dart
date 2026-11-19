import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show MethodChannel;

import 'backup.dart';
import 'project_store.dart';

/// A folder outside the app's own files (Android: a folder the user
/// picked, kept across restarts - a content:// link; elsewhere a path).
/// Projects are kept there too, as one backup file written over each
/// time: they outlive the app (a reinstall, a broken update).
const _folders = MethodChannel('mcore/folders');

/// The file the projects go into in the outside folder.
const outsideBackupName = 'MCore-projects.zip';

/// Picks a folder: its link (or path) and a readable name; null: none.
Future<({String uri, String name})?> pickOutsideFolder({String title = 'Choose a folder'}) async {
  if (Platform.isAndroid) {
    try {
      final r = await _folders.invokeMapMethod<String, String>('pickFolder');
      final uri = r?['uri'];
      if (uri == null) return null;
      return (uri: uri, name: r?['name'] ?? uri);
    } catch (_) {}
  }
  final path = await FilePicker.platform.getDirectoryPath(dialogTitle: title);
  return path == null ? null : (uri: path, name: path);
}

/// Writes `src` into the folder as `name` (over a file of that name with
/// `replace`). Returns where it went.
Future<String> writeIntoFolder(String folder, String name, File src, {String mime = 'application/zip', bool replace = false}) async {
  if (folder.startsWith('content://')) {
    final uri = await _folders.invokeMethod<String>('writeFile', {
      'tree': folder,
      'name': name,
      'mime': mime,
      'src': src.path,
      'replace': replace,
    });
    return uri ?? folder;
  }
  final out = File('$folder/$name');
  await src.copy(out.path);
  return out.path;
}

/// Every project with its media (the whole documents folder, caches
/// left out) written into the outside folder - off the UI thread.
/// Returns the backup's size in bytes.
Future<int> backUpProjectsTo(String folder, ProjectStore store) async {
  final root = store.root;
  final bytes = await Isolate.run(() => makeBackup(root));
  final tmp = await Directory.systemTemp.createTemp('mcore_outside_');
  try {
    final f = File('${tmp.path}/$outsideBackupName');
    await f.writeAsBytes(bytes, flush: true);
    await writeIntoFolder(folder, outsideBackupName, f, replace: true);
    return bytes.length;
  } finally {
    await tmp.delete(recursive: true);
  }
}

/// Leftovers in the cache from earlier runs (export / save scratch
/// folders, files the system's picker copied in) - gone at start.
Future<void> cleanStaleCache(Directory? cache, {bool systemTemp = true}) async {
  for (final d in _cacheDirs(cache, systemTemp)) {
    try {
      if (!await d.exists()) continue;
      await for (final e in d.list()) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final stale = name.startsWith('movement_mobile_') ||
            name.startsWith('mcore_save_') ||
            name.startsWith('mcore_outside_') ||
            name == 'file_picker';
        if (stale) await e.delete(recursive: true);
      }
    } catch (_) {}
  }
}

/// Everything in the cache (video frames, decoded sound, scratch): all
/// of it is made again when needed.
Future<void> clearCache(Directory? cache, {bool systemTemp = true}) async {
  for (final d in _cacheDirs(cache, systemTemp)) {
    try {
      if (!await d.exists()) continue;
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// The cache's size in bytes.
Future<int> cacheSize(Directory? cache, {bool systemTemp = true}) async {
  var n = 0;
  for (final d in _cacheDirs(cache, systemTemp)) {
    try {
      if (!await d.exists()) continue;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) n += await e.length();
      }
    } catch (_) {}
  }
  return n;
}

/// The cache folders (the system's temp and the app's cache - often the
/// same one), once each.
List<Directory> _cacheDirs(Directory? cache, bool systemTemp) {
  final byPath = <String, Directory>{if (systemTemp) Directory.systemTemp.path: Directory.systemTemp};
  if (cache != null) byPath[cache.path] = cache;
  return byPath.values.toList();
}
