import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

/// The phone's own copy of a picture, found by its file name in the
/// gallery (pictures whose kept copy was lost come back from there).
/// Null: not found, or no access to the gallery.
class GalleryFinder {
  Map<String, AssetEntity>? _byName;

  Future<File?> find(String fileName) async {
    final byName = _byName ??= await _index();
    final e = byName[fileName.toLowerCase()];
    if (e == null) return null;
    return e.originFile;
  }

  static Future<Map<String, AssetEntity>> _index() async {
    final out = <String, AssetEntity>{};
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) return out;
      final paths = await PhotoManager.getAssetPathList(type: RequestType.image, onlyAll: true);
      if (paths.isEmpty) return out;
      final all = paths.first;
      final n = await all.assetCountAsync;
      for (var start = 0; start < n; start += 500) {
        for (final e in await all.getAssetListRange(start: start, end: start + 500)) {
          final t = e.title;
          if (t != null) out.putIfAbsent(t.toLowerCase(), () => e);
        }
      }
    } catch (_) {}
    return out;
  }
}
