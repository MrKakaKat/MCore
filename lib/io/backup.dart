import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Backup of everything the app keeps: projects, their media (images,
/// videos, audio), fonts, presets and the app settings - the app's
/// documents folder as one zip. Restoring it into a fresh install (one
/// signed with another key, which Android makes you reinstall) brings it
/// all back.
const backupMarker = 'mcore-backup.txt';

/// The documents folder as a zip (caches left out).
Uint8List makeBackup(Directory root) {
  final archive = Archive()..add(ArchiveFile.bytes(backupMarker, 'MCore backup 1\n'.codeUnits));
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(root.path.length + 1).replaceAll('\\', '/');
    if (rel.startsWith('cache/') || rel.split('/').any((p) => p.startsWith('.'))) continue;
    archive.add(ArchiveFile.bytes(rel, e.readAsBytesSync()));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Unpacks a backup into the documents folder: its files replace the ones
/// with the same name, the rest stay. Returns how many files came back;
/// throws FormatException for a zip that isn't a backup.
int restoreBackup(Uint8List zip, Directory root) {
  final archive = ZipDecoder().decodeBytes(zip);
  if (archive.findFile(backupMarker) == null) throw const FormatException('not an MCore backup');
  var n = 0;
  for (final f in archive) {
    if (!f.isFile || f.name == backupMarker) continue;
    final parts = f.name.split('/');
    if (f.name.startsWith('/') || parts.contains('..')) continue; // stays inside
    final out = File('${root.path}/${f.name}');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(f.content);
    n++;
  }
  return n;
}
