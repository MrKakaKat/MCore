import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app_state.dart';
import '../layer_panel/add_layer_dialog.dart';

/// The media library: the phone's own videos, pictures, GIFs and music,
/// by album, with what each file is (MP4, PNG, GIF, MP3...) - one place to
/// bring any of them in (Recently used first). Search by name.
Future<void> openMediaLibrary(BuildContext context, AppState app, {String? replaceId, String section = 'recent'}) =>
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => MediaLibraryScreen(app: app, replaceId: replaceId, section: section, hostContext: context),
    ));

/// What a file is, from its name / type: 'gif' | 'image' | 'video' | 'audio'.
String mediaKindOf(String name, {String? mime, AssetType? type}) {
  final ext = mediaExtension(name, mime: mime);
  if (ext == 'GIF') return 'gif';
  if (type == AssetType.video) return 'video';
  if (type == AssetType.audio) return 'audio';
  if (type == AssetType.image) return 'image';
  const video = {'MP4', 'MOV', 'WEBM', 'MKV', '3GP', 'AVI', 'M4V'};
  const audio = {'MP3', 'M4A', 'AAC', 'WAV', 'OGG', 'OPUS', 'FLAC', 'AMR'};
  if (video.contains(ext)) return 'video';
  if (audio.contains(ext)) return 'audio';
  return 'image';
}

/// The file's type label (PNG, JPEG, GIF, MP4...).
String mediaExtension(String name, {String? mime}) {
  final dot = name.lastIndexOf('.');
  if (dot >= 0 && dot < name.length - 1) {
    final e = name.substring(dot + 1).toUpperCase();
    return e == 'JPG' ? 'JPEG' : e;
  }
  if (mime != null && mime.contains('/')) return mime.split('/').last.toUpperCase();
  return '?';
}

class MediaLibraryScreen extends StatefulWidget {
  final AppState app;
  final String? replaceId;
  final String section;

  /// The page it was opened from: the imports' dialogs go there (this one
  /// closes first).
  final BuildContext hostContext;
  const MediaLibraryScreen(
      {super.key, required this.app, this.replaceId, this.section = 'recent', required this.hostContext});

  @override
  State<MediaLibraryScreen> createState() => _MediaLibraryScreenState();
}

class _MediaLibraryScreenState extends State<MediaLibraryScreen> {
  static const sections = [
    ('recent', 'Recently used', Icons.history),
    ('video', 'Videos', Icons.movie_outlined),
    ('image', 'Images', Icons.image_outlined),
    ('gif', 'GIFs', Icons.gif_box_outlined),
    ('audio', 'Music', Icons.music_note_outlined),
  ];

  late String _section = widget.section;
  bool? _access; // null: asking
  List<AssetPathEntity> _albums = [];
  AssetPathEntity? _album;
  final List<AssetEntity> _items = [];
  int _page = 0;
  bool _more = true, _loading = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _askAccess();
  }

  Future<void> _askAccess() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(type: RequestType.all, mediaLocation: false),
        ),
      );
      if (!mounted) return;
      setState(() => _access = ps.hasAccess);
      if (ps.hasAccess) await _loadAlbums();
    } catch (_) {
      if (mounted) setState(() => _access = false);
    }
  }

  RequestType get _type => switch (_section) {
        'video' => RequestType.video,
        'audio' => RequestType.audio,
        _ => RequestType.image,
      };

  Future<void> _loadAlbums() async {
    if (_section == 'recent' || _access != true) return;
    // newest first (left to itself the system lists oldest first).
    final albums = await PhotoManager.getAssetPathList(
      type: _type,
      filterOption: FilterOptionGroup(orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)]),
    );
    if (!mounted) return;
    setState(() {
      _albums = albums;
      _album = albums.where((a) => a.isAll).firstOrNull ?? albums.firstOrNull;
    });
    await _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _items.clear();
      _page = 0;
      _more = true;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final album = _album;
    if (album == null || _loading || !_more) return;
    _loading = true;
    try {
      final page = await album.getAssetListPaged(page: _page, size: 80);
      if (!mounted) return;
      setState(() {
        _page++;
        _more = page.length == 80;
        _items.addAll(page);
      });
    } finally {
      _loading = false;
    }
  }

  void _setSection(String s) {
    if (s == _section) return;
    setState(() {
      _section = s;
      _albums = [];
      _album = null;
      _items.clear();
    });
    _loadAlbums();
  }

  bool _shown(AssetEntity e) {
    final name = e.title ?? '';
    if (_section == 'gif' && mediaExtension(name, mime: e.mimeType) != 'GIF') return false;
    if (_section == 'image' && mediaExtension(name, mime: e.mimeType) == 'GIF') return false;
    return _query.isEmpty || name.toLowerCase().contains(_query.toLowerCase());
  }

  /// Brings the file in (by its kind), remembered as recently used.
  Future<void> _use(String path, String kind, String name) async {
    widget.app.addRecentMedia(path, kind, name);
    final host = widget.hostContext;
    Navigator.of(context).pop();
    if (!host.mounted) return;
    switch (kind) {
      case 'video':
        await importVideoFlow(host, widget.app, replaceId: widget.replaceId, pickedPath: path);
      case 'gif':
        await importGifFlow(host, widget.app, replaceId: widget.replaceId, pickedPath: path);
      case 'audio':
        await importAudioFlow(host, widget.app, pickedPath: path);
      default:
        await importImageFlow(host, widget.app, replaceId: widget.replaceId, pickedPath: path);
    }
  }

  Future<void> _useAsset(AssetEntity e) async {
    final file = await e.originFile;
    if (file == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This file can\'t be read')));
      }
      return;
    }
    final name = e.title ?? file.path.split('/').last;
    await _use(file.path, mediaKindOf(name, mime: e.mimeType, type: e.type), name);
  }

  @override
  Widget build(BuildContext context) {
    final recent = [
      for (final r in widget.app.recentMedia)
        if (_query.isEmpty || r.name.toLowerCase().contains(_query.toLowerCase())) r
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Media'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(children: [
            // the kinds
            SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                for (final (id, label, icon) in sections)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: ValueKey('media-section-$id'),
                      avatar: Icon(icon, size: 16),
                      label: Text(label),
                      selected: _section == id,
                      onSelected: (_) => _setSection(id),
                    ),
                  ),
              ]),
            ),
            // search by name
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: TextField(
                key: const ValueKey('media-search'),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: _section == 'audio' ? 'Search music' : 'Search by name',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ]),
        ),
        actions: [
          // the system's own picker, for files elsewhere.
          TextButton(
            key: const ValueKey('media-from-files'),
            onPressed: () async {
              final host = widget.hostContext;
              Navigator.of(context).pop();
              if (host.mounted) await showFilePickers(host, widget.app, replaceId: widget.replaceId);
            },
            child: const Text('Files...'),
          ),
        ],
      ),
      body: _section == 'recent' ? _recentGrid(recent) : _libraryBody(),
    );
  }

  Widget _recentGrid(List<({String path, String kind, String name})> recent) {
    if (recent.isEmpty) {
      return const Center(child: Text('Nothing used yet', style: TextStyle(color: Colors.grey)));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 4, crossAxisSpacing: 4),
      itemCount: recent.length,
      itemBuilder: (_, i) {
        final r = recent[i];
        final exists = File(r.path).existsSync();
        return _Tile(
          key: ValueKey('media-recent-$i'),
          label: mediaExtension(r.name),
          name: r.name,
          thumb: exists && (r.kind == 'image' || r.kind == 'gif')
              ? Image.file(File(r.path), fit: BoxFit.cover, cacheWidth: 260, errorBuilder: (_, __, ___) => _kindIcon(r.kind))
              : _kindIcon(r.kind, missing: !exists),
          onTap: exists ? () => _use(r.path, r.kind, r.name) : null,
        );
      },
    );
  }

  Widget _libraryBody() {
    if (_access == null) return const Center(child: CircularProgressIndicator());
    if (_access == false) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No access to the phone\'s media. Allow it in the settings, or pick a file.', textAlign: TextAlign.center),
          ),
          const FilledButton(onPressed: PhotoManager.openSetting, child: Text('Open settings')),
          TextButton(onPressed: _askAccess, child: const Text('Try again')),
        ]),
      );
    }
    final shown = _items.where(_shown).toList();
    return Column(children: [
      // the albums
      if (_albums.isNotEmpty)
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
            for (final a in _albums)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(a.isAll ? 'All' : a.name),
                  selected: identical(a, _album),
                  onSelected: (_) {
                    setState(() => _album = a);
                    _reload();
                  },
                ),
              ),
          ]),
        ),
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) _loadMore();
            return false;
          },
          child: _section == 'audio'
              ? ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final e = shown[i];
                    final name = e.title ?? '';
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.music_note),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${mediaExtension(name, mime: e.mimeType)} · ${_duration(e.duration)}'),
                      onTap: () => _useAsset(e),
                    );
                  },
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisSpacing: 4, crossAxisSpacing: 4),
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final e = shown[i];
                    final name = e.title ?? '';
                    return _Tile(
                      label: mediaExtension(name, mime: e.mimeType),
                      name: name,
                      duration: e.type == AssetType.video ? _duration(e.duration) : null,
                      thumb: _Thumb(e),
                      onTap: () => _useAsset(e),
                    );
                  },
                ),
        ),
      ),
    ]);
  }

  static Widget _kindIcon(String kind, {bool missing = false}) => Center(
        child: Icon(
          missing
              ? Icons.broken_image_outlined
              : switch (kind) {
                  'video' => Icons.movie_outlined,
                  'audio' => Icons.music_note_outlined,
                  'gif' => Icons.gif_box_outlined,
                  _ => Icons.image_outlined,
                },
          size: 36,
          color: Colors.grey,
        ),
      );

  static String _duration(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// One file: its picture, its type (top left), its length (videos).
class _Tile extends StatelessWidget {
  final String label, name;
  final String? duration;
  final Widget thumb;
  final VoidCallback? onTap;
  const _Tile({super.key, required this.label, required this.name, required this.thumb, this.duration, this.onTap});

  @override
  Widget build(BuildContext context) {
    Widget badge(String text) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
          child: Text(text, style: const TextStyle(fontSize: 10, color: Colors.white)),
        );
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: Colors.black12, child: thumb),
          Positioned(left: 3, top: 3, child: badge(label)),
          if (duration != null) Positioned(right: 3, bottom: 3, child: badge(duration!)),
        ]),
      ),
    );
  }
}

/// A file's small picture (loaded once).
class _Thumb extends StatefulWidget {
  final AssetEntity entity;
  const _Thumb(this.entity);

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Future<Uint8List?>? _data;

  @override
  void initState() {
    super.initState();
    _data = widget.entity.thumbnailDataWithSize(const ThumbnailSize.square(240), quality: 80);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _data,
        builder: (_, s) => s.data == null ? const SizedBox.shrink() : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
      );
}
