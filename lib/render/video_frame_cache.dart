import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:movement_core/movement_core.dart';

import '../services/video_service.dart' show videoFrameFileName;

/// Decodes one extracted frame file.
typedef VideoFrameDecoder = Future<ui.Image> Function(String path);

/// Reads and decodes a frame without the file's bytes ever passing through
/// the Dart heap or the UI thread: the engine reads the file and decodes
/// it on its own threads; only the finished image comes back.
Future<ui.Image> _decodeFile(String path) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  buffer.dispose();
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  return frame.image;
}

/// The decoded frames of video layers kept around the playhead.
///
/// Frames are extracted to disk once at import (video_asset_store.dart);
/// this keeps decoded `ui.Image`s within one memory budget shared by every
/// video (LRU), so memory stays flat however long or many the clips are.
/// Frames of videos no live layer uses (a deleted layer's, kept only for
/// undo) are evicted first; an undone layer refills from disk.
///
/// The editor never waits: when the exact frame isn't decoded yet it gets
/// the nearest decoded frame of the same video (a "hold", never a blank),
/// and a redraw is requested once the exact one lands.
/// - Playing (the frame moves forward a little at a time): the frames just
///   ahead are decoded in advance.
/// - Scrubbing / jumping: only the latest wanted frame matters - frames
///   asked for earlier and not started yet are dropped as stale, and the
///   exact frame is decoded once the playhead settles (a short pause).
/// At most [maxConcurrent] decodes run at once.
///
/// Export instead awaits the exact frames (`load`), outside the queue.
class VideoFrameCache {
  /// Memory budget for decoded frames, all videos together (bytes, 4 per
  /// pixel).
  int budgetBytes;

  /// Optional cap on the number of frames (tests use it).
  final int? capacity;

  /// How many frames after the requested one are decoded in advance
  /// while playing.
  final int prefetch;

  /// Decodes running at once.
  final int maxConcurrent;

  /// How long the playhead has to rest before a scrubbed-to frame is
  /// decoded.
  Duration settle;

  VideoFrameDecoder decoder;

  /// `<cache>/video_frames` - frames of asset `a` are in `<root>/a/`.
  String? framesRoot;

  /// A frame that wasn't ready has been decoded: redraw.
  void Function()? onDecoded;

  /// A frame left the cache (its derived data can go too).
  void Function(String key)? onEvict;

  /// Frames an export is about to draw - never evicted (see
  /// CanvasRenderer.prepareFrame), even past the budget.
  Set<String> pinned = {};

  /// Videos used by layers of the project now (the renderer keeps this up
  /// to date); frames of other videos are evicted first.
  Set<String> liveAssets = const {};

  static const defaultBudgetBytes = 96 * 1024 * 1024;

  VideoFrameCache({
    this.budgetBytes = defaultBudgetBytes,
    this.capacity,
    this.prefetch = 6,
    this.maxConcurrent = 2,
    this.settle = const Duration(milliseconds: 60),
    VideoFrameDecoder? decoder,
  }) : decoder = decoder ?? _decodeFile;

  final LinkedHashMap<String, ui.Image> _frames = LinkedHashMap();
  final Map<String, SplayTreeSet<int>> _decodedByAsset = {};
  final Map<String, Future<ui.Image?>> _loading = {};
  final Set<String> _failed = {};
  int _bytes = 0;

  // the decode queue: jobs not started yet, in order.
  final LinkedHashMap<String, _Job> _queue = LinkedHashMap();
  int _running = 0;
  final Map<String, int> _lastIndex = {};
  final Map<String, Timer> _settleTimers = {};

  // statistics (for the performance HUD).
  int decodeCount = 0;
  int _decodeMicros = 0;
  int holds = 0;
  int staleDropped = 0;

  @visibleForTesting
  int get length => _frames.length;

  int get bytes => _bytes;

  /// Average time from starting a frame's decode to having its image, ms.
  double get avgDecodeMs => decodeCount == 0 ? 0 : _decodeMicros / decodeCount / 1000;

  void resetStats() {
    decodeCount = 0;
    _decodeMicros = 0;
    holds = 0;
    staleDropped = 0;
  }

  /// Decoded frames held, their estimated size, failed frames.
  ({int count, int bytes, int failures}) imageStats() =>
      (count: _frames.length, bytes: _bytes, failures: _failed.length);

  static String? assetOf(Content c) => c.videoAssetId ?? c.videoPath;

  static String keyOf(String asset, int index) => 'video:$asset:$index';

  String? pathOf(Content c, int index) {
    final root = framesRoot, id = c.videoAssetId;
    if (root == null || id == null) return null;
    return '$root/$id/${videoFrameFileName(index, alpha: c.videoAlpha)}';
  }

  bool isDecoded(Content c, int index) {
    final a = assetOf(c);
    return a != null && _frames.containsKey(keyOf(a, index));
  }

  /// The frame to draw now: the exact one if decoded, else the nearest
  /// decoded frame of this video (null only before any frame of it is).
  /// Asks for the exact frame (and, while playing, the ones after it).
  ({String key, ui.Image image})? frameFor(Content c, int index) {
    final asset = assetOf(c);
    if (asset == null) return null;
    final key = keyOf(asset, index);
    final last = _lastIndex[asset];
    _lastIndex[asset] = index;
    // playing: a small step forward. The same frame again (a redraw, or a
    // 30 fps clip in a 60 fps project) changes nothing. Anything else is
    // a scrub or a jump.
    final playing = last == null || (index > last && index - last <= prefetch + 1);
    if (index == last) {
      if (!_settleTimers.containsKey(asset)) _enqueue(c, asset, index);
    } else if (playing) {
      _settleTimers.remove(asset)?.cancel();
      // queued frames behind the playhead won't be shown any more.
      _dropQueued(asset, (i) => i < index);
      final count = c.videoFrameCount ?? 0;
      _enqueue(c, asset, index);
      for (var i = index + 1; i <= index + prefetch && i < count; i++) {
        _enqueue(c, asset, i);
      }
    } else {
      // only the latest wanted frame matters; decode it once it rests.
      _dropQueued(asset, (_) => true);
      _settleTimers.remove(asset)?.cancel();
      if (!_frames.containsKey(key)) {
        _settleTimers[asset] = Timer(settle, () {
          _settleTimers.remove(asset);
          if (_lastIndex[asset] == index) _enqueue(c, asset, index);
        });
      }
    }
    final exact = _touch(key);
    if (exact != null) return (key: key, image: exact);
    final nearest = _nearest(asset, index);
    if (nearest == null) return null;
    holds++;
    final nearKey = keyOf(asset, nearest);
    return (key: nearKey, image: _touch(nearKey)!);
  }

  /// Decodes exactly `index` (for export) - null if it can't be read.
  Future<ui.Image?> load(Content c, int index) async {
    final asset = assetOf(c);
    if (asset == null) return null;
    final key = keyOf(asset, index);
    final have = _touch(key);
    if (have != null) return have;
    if (_failed.contains(key)) return null;
    _queue.remove(key);
    return _loading[key] ?? _start(key, c, asset, index, notify: false);
  }

  void _enqueue(Content c, String asset, int index) {
    final key = keyOf(asset, index);
    if (_frames.containsKey(key) || _failed.contains(key) || _loading.containsKey(key) || _queue.containsKey(key)) {
      return;
    }
    if (pathOf(c, index) == null) return;
    _queue[key] = _Job(c, asset, index);
    _pump();
  }

  void _dropQueued(String asset, bool Function(int index) stale) {
    final drop = [
      for (final e in _queue.entries)
        if (e.value.asset == asset && stale(e.value.index)) e.key
    ];
    for (final k in drop) {
      _queue.remove(k);
    }
    staleDropped += drop.length;
  }

  void _pump() {
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      final key = _queue.keys.first;
      final job = _queue.remove(key)!;
      _start(key, job.content, job.asset, job.index, notify: true);
    }
  }

  Future<ui.Image?> _start(String key, Content c, String asset, int index, {required bool notify}) {
    final future = () async {
      _running++;
      final path = pathOf(c, index);
      final watch = Stopwatch()..start();
      try {
        if (path == null) throw StateError('no frame path');
        final image = await decoder(path);
        decodeCount++;
        _decodeMicros += watch.elapsedMicroseconds;
        _frames[key] = image;
        _bytes += image.width * image.height * 4;
        (_decodedByAsset[asset] ??= SplayTreeSet()).add(index);
        _evictOver(keep: key);
        if (notify) onDecoded?.call();
        return image;
      } catch (_) {
        _failed.add(key);
        return null;
      } finally {
        _running--;
        _loading.remove(key);
        _pump();
      }
    }();
    _loading[key] = future;
    return future;
  }

  ui.Image? _touch(String key) {
    final image = _frames.remove(key);
    if (image != null) _frames[key] = image; // most recently used last
    return image;
  }

  int? _nearest(String asset, int index) {
    final set = _decodedByAsset[asset];
    if (set == null || set.isEmpty) return null;
    final below = set.lastWhere((i) => i <= index, orElse: () => -1);
    final above = set.firstWhere((i) => i >= index, orElse: () => -1);
    if (below < 0) return above;
    if (above < 0) return below;
    return index - below <= above - index ? below : above;
  }

  static String _assetOfKey(String key) {
    final parts = key.split(':');
    return parts.sublist(1, parts.length - 1).join(':');
  }

  /// Bytes of decoded frames of videos no live layer uses (kept only for
  /// a possible undo).
  int get unusedBytes {
    var total = 0;
    _frames.forEach((k, image) {
      if (!liveAssets.contains(_assetOfKey(k))) total += image.width * image.height * 4;
    });
    return total;
  }

  bool get _over => _bytes > budgetBytes || (capacity != null && _frames.length > capacity!);

  void _evictOver({required String keep}) {
    while (_over) {
      bool evictable(String k) => k != keep && !pinned.contains(k);
      // frames of videos no layer uses go first, then the least recently
      // used of the rest.
      var victim = _frames.keys.firstWhere((k) => evictable(k) && !liveAssets.contains(_assetOfKey(k)), orElse: () => '');
      if (victim.isEmpty) victim = _frames.keys.firstWhere(evictable, orElse: () => '');
      if (victim.isEmpty) return;
      _drop(victim);
    }
  }

  void _drop(String key) {
    final image = _frames.remove(key);
    if (image == null) return;
    _bytes -= image.width * image.height * 4;
    // drawn pictures keep their own reference to the pixels.
    image.dispose();
    final index = int.parse(key.split(':').last);
    _decodedByAsset[_assetOfKey(key)]?.remove(index);
    onEvict?.call(key);
  }

  /// Forgets one video's frames (e.g. after they were extracted again).
  void clearAsset(String asset) {
    for (final k in _frames.keys.where((k) => k.startsWith('video:$asset:')).toList()) {
      _drop(k);
    }
    _failed.removeWhere((k) => k.startsWith('video:$asset:'));
    _queue.removeWhere((k, _) => k.startsWith('video:$asset:'));
  }

  /// Releases the decoded frames of videos no live layer uses.
  void releaseUnused() {
    for (final k in _frames.keys.where((k) => !liveAssets.contains(_assetOfKey(k)) && !pinned.contains(k)).toList()) {
      _drop(k);
    }
  }

  void dispose() {
    for (final t in _settleTimers.values) {
      t.cancel();
    }
    _settleTimers.clear();
    _queue.clear();
    for (final k in _frames.keys.toList()) {
      _drop(k);
    }
    _failed.clear();
  }
}

class _Job {
  final Content content;
  final String asset;
  final int index;
  _Job(this.content, this.asset, this.index);
}
