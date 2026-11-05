import 'dart:io';
import 'dart:typed_data';

export 'video_asset_store.dart' show directorySize;

/// Where imported sounds live on disk.
///
/// - the source copy: `<documents>/audio/<assetId>.<ext>` - kept so the
///   sound can be decoded again if the cache is cleared;
/// - the decoded PCM and its waveform: `<cache>/audio_pcm/<assetId>.pcm`
///   and `.peaks` - rebuildable, so the cache directory;
/// - the preview mixdown: `<cache>/audio_pcm/preview_mix.wav`.
class AudioAssetStore {
  final Directory documents;
  final Directory cache;
  AudioAssetStore({required this.documents, required this.cache});

  Directory get sourcesDir => Directory('${documents.path}/audio');
  Directory get pcmRoot => Directory('${cache.path}/audio_pcm');
  File pcmFile(String assetId) => File('${pcmRoot.path}/$assetId.pcm');
  File peaksFile(String assetId) => File('${pcmRoot.path}/$assetId.peaks');
  File get previewMixFile => File('${pcmRoot.path}/preview_mix.wav');

  String newAssetId() => 'a${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// Copies the picked file into the app's own storage.
  Future<File> copySource(File source, String assetId) async {
    await sourcesDir.create(recursive: true);
    final dot = source.path.lastIndexOf('.');
    final ext = dot >= 0 && source.path.length - dot <= 6 ? source.path.substring(dot) : '.m4a';
    return source.copy('${sourcesDir.path}/$assetId$ext');
  }

  bool hasPcm(String assetId) => pcmFile(assetId).existsSync() && peaksFile(assetId).existsSync();

  Future<void> writePeaks(String assetId, Uint8List peaks) async {
    await pcmRoot.create(recursive: true);
    await peaksFile(assetId).writeAsBytes(peaks);
  }

  Future<void> removeAsset(String assetId) async {
    for (final f in [pcmFile(assetId), peaksFile(assetId)]) {
      if (await f.exists()) await f.delete();
    }
    if (await sourcesDir.exists()) {
      await for (final f in sourcesDir.list()) {
        if (f is File && _assetIdOfSource(f) == assetId) await f.delete();
      }
    }
  }

  static final _assetIdPattern = RegExp(r'"audioAssetId"\s*:\s*"([^"]+)"');

  static Set<String> assetIdsInProjectFile(String json) =>
      {for (final m in _assetIdPattern.allMatches(json)) m.group(1)!};

  /// Deletes every sound no saved project uses (same rules as
  /// VideoAssetStore.cleanup). Returns the removed ids.
  Future<Set<String>> cleanup(Iterable<File> projectFiles, {Set<String> keep = const {}}) async {
    final used = <String>{...keep};
    for (final f in projectFiles) {
      try {
        used.addAll(assetIdsInProjectFile(await f.readAsString()));
      } catch (_) {
        return {};
      }
    }
    final present = <String>{};
    if (await sourcesDir.exists()) {
      await for (final f in sourcesDir.list()) {
        if (f is File) present.add(_assetIdOfSource(f));
      }
    }
    if (await pcmRoot.exists()) {
      await for (final f in pcmRoot.list()) {
        if (f is File && (f.path.endsWith('.pcm') || f.path.endsWith('.peaks'))) present.add(_assetIdOfSource(f));
      }
    }
    final unused = present.difference(used);
    for (final id in unused) {
      await removeAsset(id);
    }
    return unused;
  }

  /// Bytes of one sound on disk: its source copy and its decoded PCM +
  /// waveform.
  Future<({int source, int decoded})> assetSize(String assetId) async {
    var source = 0;
    if (await sourcesDir.exists()) {
      await for (final f in sourcesDir.list()) {
        if (f is File && _assetIdOfSource(f) == assetId) source += await f.length();
      }
    }
    var decoded = 0;
    for (final f in [pcmFile(assetId), peaksFile(assetId)]) {
      if (await f.exists()) decoded += await f.length();
    }
    return (source: source, decoded: decoded);
  }

  static String _assetIdOfSource(File f) {
    final name = f.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
