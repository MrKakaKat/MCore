import 'dart:io';
import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';

/// Fonts the user loaded (.ttf / .otf), kept in `<root>/fonts/` so every
/// project can use them. A text layer refers to its font by id (the file
/// name); a project opened where that font is missing falls back to the
/// default font.
class FontStore {
  final Directory root;
  FontStore(this.root);

  Directory get _dir => Directory('${root.path}/fonts');

  /// Registers every stored font with movement_core; unreadable files are
  /// skipped.
  Future<void> registerAll() async {
    if (!await _dir.exists()) return;
    await for (final entity in _dir.list()) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) continue;
      try {
        registerFont(_idOf(entity), await entity.readAsBytes());
      } catch (_) {
        continue;
      }
    }
  }

  /// Checks, stores and registers a font file; returns its id. Throws
  /// FontFormatException if the file isn't a font this app can read.
  Future<String> import(Uint8List bytes, String fileName) async {
    OpenTypeFont.parse(bytes); // validate before keeping it
    final ext = fileName.toLowerCase().endsWith('.otf') ? 'otf' : 'ttf';
    await _dir.create(recursive: true);
    final file = File('${_dir.path}/font_${DateTime.now().microsecondsSinceEpoch}.$ext');
    await file.writeAsBytes(bytes);
    final id = _idOf(file);
    registerFont(id, bytes);
    return id;
  }

  /// Deletes a stored font file and unloads it.
  Future<void> delete(String id) async {
    unregisterFont(id);
    if (id.contains('/') || id.contains('..')) return;
    final file = File('${_dir.path}/$id');
    if (await file.exists()) await file.delete();
  }

  String _idOf(File f) => f.uri.pathSegments.last;
}
