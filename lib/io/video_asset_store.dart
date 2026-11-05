import 'dart:io';

import '../services/video_service.dart' show videoFrameFileName;

/// Where imported videos live on disk.
///
/// - the source copy: `<documents>/videos/<assetId>.<ext>` - kept so the
///   frames can be extracted again if the cache is cleared, and so a later
///   project archive only has to pack this folder;
/// - the extracted frames: `<cache>/video_frames/<assetId>/000001.jpg`
///   (or `.png` with transparency) - rebuildable, so the cache directory.
///
/// Projects only store the asset id and the source path; every other path
/// is derived here, so moving the storage later touches only this class.
class VideoAssetStore {
  final Directory documents;
  final Directory cache;
  VideoAssetStore({required this.documents, required this.cache});

  Directory get sourcesDir => Directory('${documents.path}/videos');
  Directory get framesRoot => Directory('${cache.path}/video_frames');
  Directory framesDir(String assetId) => Directory('${framesRoot.path}/$assetId');

  String newAssetId() => 'v${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// Copies the picked file into the app's own storage (the picker's path
  /// may be a temporary one that disappears).
  Future<File> copySource(File source, String assetId) async {
    await sourcesDir.create(recursive: true);
    final dot = source.path.lastIndexOf('.');
    final ext = dot >= 0 && source.path.length - dot <= 6 ? source.path.substring(dot) : '.mp4';
    return source.copy('${sourcesDir.path}/$assetId$ext');
  }

  /// Whether all `frameCount` frames are still in the cache.
  bool hasFrames(String assetId, int frameCount, {required bool alpha}) {
    if (frameCount <= 0) return false;
    final dir = framesDir(assetId).path;
    return File('$dir/${videoFrameFileName(0, alpha: alpha)}').existsSync() &&
        File('$dir/${videoFrameFileName(frameCount - 1, alpha: alpha)}').existsSync();
  }

  Future<void> removeAsset(String assetId) async {
    final frames = framesDir(assetId);
    if (await frames.exists()) await frames.delete(recursive: true);
    if (await sourcesDir.exists()) {
      await for (final f in sourcesDir.list()) {
        if (f is File && _assetIdOfSource(f) == assetId) await f.delete();
      }
    }
  }

  static final _assetIdPattern = RegExp(r'"videoAssetId"\s*:\s*"([^"]+)"');

  // a video's sound layer plays straight from the video's kept copy.
  static final _soundSourcePattern = RegExp(r'"audioPath"\s*:\s*"[^"]*/videos/([^"/.]+)\.[^"/]*"');

  /// Asset ids referenced by a saved project file (by a video layer, or by
  /// the sound layer taken from that video).
  static Set<String> assetIdsInProjectFile(String json) => {
        for (final m in _assetIdPattern.allMatches(json)) m.group(1)!,
        for (final m in _soundSourcePattern.allMatches(json)) m.group(1)!,
      };

  /// Deletes every asset (source copy and frames) that no saved project
  /// references, nor `keep` (what the open project's layers and its undo
  /// history still use). Runs when a project is closed or deleted, or its
  /// undo cache is cleared - an asset goes only once nothing anywhere can
  /// bring its layer back. Returns the removed ids.
  Future<Set<String>> cleanup(Iterable<File> projectFiles, {Set<String> keep = const {}}) async {
    final used = <String>{...keep};
    for (final f in projectFiles) {
      try {
        used.addAll(assetIdsInProjectFile(await f.readAsString()));
      } catch (_) {
        // unreadable project: keep everything rather than guess.
        return {};
      }
    }
    final present = <String>{};
    if (await sourcesDir.exists()) {
      await for (final f in sourcesDir.list()) {
        if (f is File) present.add(_assetIdOfSource(f));
      }
    }
    if (await framesRoot.exists()) {
      await for (final d in framesRoot.list()) {
        if (d is Directory) present.add(d.uri.pathSegments.where((s) => s.isNotEmpty).last);
      }
    }
    final unused = present.difference(used);
    for (final id in unused) {
      await removeAsset(id);
    }
    return unused;
  }

  /// Bytes of one asset on disk: its source copy and its frames.
  Future<({int source, int frames})> assetSize(String assetId) async {
    var source = 0;
    if (await sourcesDir.exists()) {
      await for (final f in sourcesDir.list()) {
        if (f is File && _assetIdOfSource(f) == assetId) source += await f.length();
      }
    }
    return (source: source, frames: await directorySize(framesDir(assetId)));
  }

  File? sourceOf(String assetId) {
    if (!sourcesDir.existsSync()) return null;
    for (final f in sourcesDir.listSync()) {
      if (f is File && _assetIdOfSource(f) == assetId) return f;
    }
    return null;
  }

  static String _assetIdOfSource(File f) {
    final name = f.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}

/// Total bytes of the files under `dir` (0 if it doesn't exist).
Future<int> directorySize(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final e in dir.list(recursive: true, followLinks: false)) {
    if (e is File) total += await e.length();
  }
  return total;
}
