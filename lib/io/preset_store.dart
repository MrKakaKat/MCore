import 'dart:convert';
import 'dart:io';

/// One saved preset: a name plus a movement_core `layerParamsToJson`
/// snapshot.
class Preset {
  final File file;
  final String name;
  final DateTime created;
  final Map<String, dynamic> params;
  Preset({required this.file, required this.name, required this.created, required this.params});
}

/// Presets live outside any project, as `<root>/presets/<id>.json`, so a
/// preset saved in one project is available in every other one. `root`
/// is the app documents directory in the app, a temp dir in tests.
class PresetStore {
  final Directory root;

  /// The sub-folder - 'presets' for full parameter presets,
  /// 'animation_presets' for keyed-animation-only ones.
  final String folder;
  PresetStore(this.root, {this.folder = 'presets'});

  Directory get _dir => Directory('${root.path}/$folder');

  /// Newest first; unreadable files are skipped.
  Future<List<Preset>> list() async {
    if (!await _dir.exists()) return [];
    final presets = <Preset>[];
    await for (final entity in _dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final data = jsonDecode(await entity.readAsString());
        if (data is! Map || data['params'] is! Map) continue;
        presets.add(Preset(
          file: entity,
          name: data['name'] as String? ?? 'Preset',
          created: DateTime.tryParse(data['created'] as String? ?? '') ?? DateTime(2000),
          params: Map<String, dynamic>.from(data['params'] as Map),
        ));
      } catch (_) {
        continue;
      }
    }
    presets.sort((a, b) {
      final byTime = b.created.compareTo(a.created);
      return byTime != 0 ? byTime : b.file.path.compareTo(a.file.path);
    });
    return presets;
  }

  Future<File> save(String name, Map<String, dynamic> params) async {
    await _dir.create(recursive: true);
    final file = File('${_dir.path}/${DateTime.now().microsecondsSinceEpoch}.json');
    await _write(file, name, DateTime.now(), params);
    return file;
  }

  Future<void> rename(Preset preset, String name) =>
      _write(preset.file, name, preset.created, preset.params);

  Future<void> delete(Preset preset) => preset.file.delete();

  Future<void> _write(File file, String name, DateTime created, Map<String, dynamic> params) =>
      file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'name': name,
        'created': created.toIso8601String(),
        'params': params,
      }));
}
