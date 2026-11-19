import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/backup.dart';
import 'package:movement_mobile/io/outside_folder.dart';
import 'package:movement_mobile/io/project_store.dart';

void main() {
  test('projects kept in an outside folder: one backup file there, written over each time', () async {
    final root = Directory.systemTemp.createTempSync('mcore_root_test_');
    final out = Directory.systemTemp.createTempSync('mcore_out_test_');
    addTearDown(() {
      root.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });
    File('${root.path}/projects/1.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"name":"one"}');
    File('${root.path}/cache/video_frames/a/000001.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final store = ProjectStore(root);
    await backUpProjectsTo(out.path, store);
    File('${root.path}/projects/2.json').writeAsStringSync('{"name":"two"}');
    await backUpProjectsTo(out.path, store);
    final files = out.listSync().whereType<File>().toList();
    expect(files.map((f) => f.uri.pathSegments.last), [outsideBackupName], reason: 'one file, written over');
    final zip = ZipDecoder().decodeBytes(files.single.readAsBytesSync());
    expect(zip.findFile(backupMarker), isNotNull);
    expect(zip.findFile('projects/2.json'), isNotNull);
    expect(zip.findFile('cache/video_frames/a/000001.jpg'), isNull, reason: 'the cache is left out');
  });

  test('the cache: leftovers gone at start, all of it on asking, its size', () async {
    final cache = Directory.systemTemp.createTempSync('mcore_cache_test_');
    addTearDown(() {
      if (cache.existsSync()) cache.deleteSync(recursive: true);
    });
    File('${cache.path}/movement_mobile_export_x/a.mp4')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(100, 1));
    File('${cache.path}/file_picker/v.mp4')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(50, 1));
    File('${cache.path}/video_frames/a/000001.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(30, 1));
    expect(await cacheSize(cache, systemTemp: false), 180);
    await cleanStaleCache(cache, systemTemp: false);
    expect(await cacheSize(cache, systemTemp: false), 30, reason: 'only the video frames stay');
    await clearCache(cache, systemTemp: false);
    expect(await cacheSize(cache, systemTemp: false), 0);
  });
}
