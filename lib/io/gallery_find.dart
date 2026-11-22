import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

/// The phone's own copy of a picture, found by its file name in the
/// gallery (pictures whose kept copy was lost come back from there).
/// Null: not found, or no access to the gallery.
class GalleryFinder {
  /// What it is doing now (shown while it looks).
  final void Function(String status)? onStatus;
  GalleryFinder({this.onStatus});

  Map<String, AssetEntity>? _byName;

  /// False when the gallery could not be read (no permission).
  bool access = true;

  Future<File?> find(String fileName) async {
    final byName = _byName ??= await _index();
    final e = byName[fileName.toLowerCase()];
    if (e == null) return null;
    return e.originFile;
  }

  Future<Map<String, AssetEntity>> _index() async {
    final out = <String, AssetEntity>{};
    try {
      onStatus?.call('Asking for access to the gallery...');
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        access = false;
        return out;
      }
      final paths = await PhotoManager.getAssetPathList(type: RequestType.common, onlyAll: true);
      if (paths.isEmpty) return out;
      final all = paths.first;
      final n = await all.assetCountAsync;
      for (var start = 0; start < n; start += 500) {
        onStatus?.call('Reading the gallery: ${start + 1}-${start + 500 > n ? n : start + 500} of $n');
        for (final e in await all.getAssetListRange(start: start, end: start + 500)) {
          // (the name is not always filled in at once)
          var t = e.title;
          if (t == null || t.isEmpty) t = await e.titleAsync;
          if (t.isNotEmpty) out.putIfAbsent(t.toLowerCase(), () => e);
        }
      }
    } catch (_) {}
    return out;
  }
}
