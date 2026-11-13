import 'dart:async';
import 'dart:convert' show base64Encode, jsonDecode, jsonEncode;
import 'dart:isolate';
import 'dart:typed_data' show ByteData, Float64List, Int16List, Uint8List;
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show Canvas, Color, FilterQuality, Offset, Paint, Picture, PictureRecorder;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_core/movement_core.dart' as core show bakeFollowToKeys;

import 'io/app_settings.dart';
import 'io/audio_asset_store.dart';
import 'io/font_store.dart';
import 'perf/perf_monitor.dart';
import 'io/preset_store.dart';
import 'io/project_store.dart';
import 'io/save_load.dart';
import 'io/video_asset_store.dart';
import 'render/canvas_renderer.dart';
import 'ui/common/hint.dart' show descriptionsVisible;
import 'ui/common/param_editor.dart' show ParamEditor, rulerLengthScale;
import 'ui/common/color_row.dart' show eyedropperOwner;
import 'ui/stage/stage_camera.dart' show stageRotateEnabled;
import 'ui/stage/stage_painter.dart' show cameraViewActive, showBoxOverEffectGrid, showFootprints, showMaskViz, showPropLinks, showRegionTints, stageRegionPickActive, stageSelectedRegionDepth, stageSelectedRegionSig, stageSelectedRegionNumber;
import 'services/audio_playback.dart';
import 'services/audio_service.dart';
import 'services/video_service.dart';
import 'services/video_service_stub.dart';

/// App-wide mutable state, mirroring what movement-core/src/ui/*
/// modules each read off the bare project/selection singletons plus
/// ui/timeline/scrub.js's `playback` object - collapsed into one
/// ChangeNotifier here since Dart has no module-level singleton import
/// the way JS's `import { project } from "./model/project.js"` gave
/// every UI file free access to the same live object (see
/// model/project.dart's own doc comment on this). Every widget in ui/
/// reads this via a single instance passed down from main.dart, rather
/// than each importing its own copy.
///
/// Deliberately nothing heavier than ChangeNotifier, per the plan doc's
/// own "State management" note - this mirrors the pull-model philosophy
/// already validated in movement-core (render(frame) recomputes fresh
/// from current state every call).
/// The palettes a fresh app starts with.
const defaultPalettesJson = [
  {
    'name': 'Basic',
    'colors': ['#ffffff', '#000000', '#e0a06a', '#7fc4a8', '#e07f9a', '#8ab4d8', '#c9a8e0', '#e0d47f']
  },
  {
    'name': 'Sunset',
    'colors': ['#2d1b4e', '#6b2d5c', '#c2475b', '#f08a4b', '#f9c74f']
  },
];

List<({String name, List<String> colors})> decodePalettes(String json) {
  try {
    return [
      for (final p in jsonDecode(json) as List)
        (name: p['name'] as String, colors: [for (final c in p['colors'] as List) c as String])
    ];
  } catch (_) {
    return [];
  }
}

class AppState extends ChangeNotifier {
  Project project = createDefaultProject();
  final Selection selection = Selection();
  final UndoHistory undo = UndoHistory();
  // the editor's stage shows the scene itself; export / the player go
  // through the stage camera (see setCameraView).
  final CanvasRenderer renderer = CanvasRenderer()..useStageCamera = false;
  VideoService videoService = createVideoService();

  int currentFrame = 0;
  int maxFrame = 180;
  // The timeline is as long as its furthest layer end
  // (recomputeMaxFrameToFit), never shorter than a length the user set
  // explicitly via setMaxFrame. a fixed 180-frame default floor kept the ruler
  // running to 3s past shorter layers.
  int? _explicitTimelineLength;
  int get _maxFrameFloor => _explicitTimelineLength ?? 1;

  double playbackSpeed = 1;
  bool playing = false;
  Ticker? _playTicker;

  /// the project's own frame resolution - a FIXED property (this is
  /// what canvas_renderer.dart actually exports at), matching what
  /// CanvasRenderer's own field defaults already were. Real device bug
  /// this closes: stage_view.dart used to call renderer.setSize() from
  /// the WIDGET's current layout size instead, so the project's
  /// coordinate system got silently redefined to match whatever
  /// viewport happened to be current the moment it first got locked in
  /// - meaning the same anchor value landed at a different physical
  /// position depending on device rotation. Setting it exactly once,
  /// here, completely decoupled from any widget's layout, is what makes
  /// "same anchor -> same physical position regardless of orientation"
  /// actually hold; StageCamera's fit transform (stage_camera.dart) is
  /// the ONLY thing allowed to react to viewport size after this point,
  /// and it only ever affects how this fixed frame is letterboxed into
  /// whatever space is available, never the frame's own coordinates.
  // mutable (was `static const`) - see setFrameSize's own doc comment for why
  // converting these to instance fields, now, is low-risk: no external code
  // ever read AppState.frameWidth/frameHeight statically (confirmed by grep),
  // only stage_view.dart's own doc-comment reference and this class's own
  // constructor. default changed from 640x400 (no exact preset match) to 1:1
  // (480x480, the "1:1 (square)" preset in stage_settings_dialog.dart) so a
  // fresh project's own aspect-ratio picker actually shows a selected chip.
  double frameWidth = 480;
  double frameHeight = 480;

  // when on, setFrameSize also rescales every layer's own content geometry
  // (see layer_ops.dart's rescaleProjectContent) so objects keep the same size
  // relative to the frame across a resolution change, instead of only their
  // (already stage-relative) anchor position moving. Default on, matching the
  // behavior requested going forward.
  bool scaleContentOnResize = true;

  // a toggle so the live stage can show content that's currently outside the
  // frame's own boundaries (useful once zoomed out via StageCamera's
  // pinch-zoom) - the frame's own outline always stays drawn regardless
  // (stage_painter.dart never gates it on this), this only controls whether
  // canvas_renderer.dart clips LAYER CONTENT to that boundary.
  // Export/captureFrame is never affected - see canvas_renderer.dart's own
  // renderFrame doc comment.
  bool showOffCanvasContent = false;

  /// Canvas background (Stage tab): null = transparent - the default, and
  /// what PNG export keeps as real alpha. Only affects the frame itself;
  /// the stage around it stays gray. Saved per project.
  /// Stage mirror: flips the whole frame - on the stage (via the camera)
  /// and in every export (via the renderer). Saved with the project.
  bool get stageMirrorX => renderer.mirrorX;
  bool get stageMirrorY => renderer.mirrorY;

  void toggleStageMirror({required bool horizontal}) {
    if (horizontal) {
      renderer.mirrorX = !renderer.mirrorX;
    } else {
      renderer.mirrorY = !renderer.mirrorY;
    }
    notifyListeners();
  }

  void resetStageMirror() {
    renderer.mirrorX = false;
    renderer.mirrorY = false;
    notifyListeners();
  }

  /// Image layers whose source failed to decode (the renderer won't
  /// retry them on its own - see CanvasRenderer.isImageFailed).
  List<String> get failedImageLayerIds => [
        for (final l in project.layers)
          if ((l.content.shape == 'image' && renderer.isImageFailed(l.content)) || _videoMissing(l.content)) l.id
      ];

  // ===== video =====

  VideoAssetStore? _videoStore;

  /// Where imported videos and their frames are kept (the home screen
  /// passes the app's; tests use a temp dir).
  VideoAssetStore? get videoStore => _videoStore;
  set videoStore(VideoAssetStore? store) {
    _videoStore = store;
    renderer.videoFrames.framesRoot = store?.framesRoot.path;
  }

  /// Videos whose frames are being extracted again (cache was cleared).
  final Set<String> videosRebuilding = {};

  /// Whether each video's frames are on disk - checked once per video, not
  /// on every draw (the stage asks on every frame; two file checks per
  /// video per frame on the UI thread showed up as stutter).
  final Map<String, bool> _framesPresent = {};

  /// Forgets what's known about frames on disk: they are checked again.
  void recheckVideoFrames() => _framesPresent.clear();

  bool _videoMissing(Content c) {
    final store = _videoStore, id = c.videoAssetId;
    if (c.shape != 'video' || store == null || id == null || videosRebuilding.contains(id)) return false;
    return !(_framesPresent[id] ??= store.hasFrames(id, c.videoFrameCount ?? 0, alpha: c.videoAlpha));
  }

  /// Imports a video as a new layer (or, with `replaceId`, as that layer's
  /// new content): copies the file into app storage, extracts its frames
  /// once (downscaled to the project frame; PNG with transparency when
  /// `alpha`), and adds a layer as long as the clip. No sound. Throws
  /// VideoImportCancelled when `cancel` fires; nothing is left behind on
  /// failure.
  ///
  /// With `withSound` (not when replacing), the video's own sound comes in
  /// too, as a separate audio layer linked to it on the timeline (they
  /// move together; unlink to move them apart). A video without sound
  /// just gets no audio layer.
  Future<void> importVideo(File source,
      {bool alpha = false,
      bool withSound = true,
      String? replaceId,
      void Function(int done, int total)? onProgress,
      CancelToken? cancel}) async {
    final store = _videoStore;
    if (store == null) throw StateError('No storage for videos');
    final id = store.newAssetId();
    String? soundId;
    try {
      final copy = await store.copySource(source, id);
      if (cancel?.isCancelled ?? false) throw VideoImportCancelled();
      final x = await videoService.extractToCache(copy, store.framesDir(id),
          maxWidth: frameWidth, maxHeight: frameHeight, alpha: alpha, onProgress: onProgress, cancel: cancel);
      final layer = createVideoLayer(
          path: copy.path,
          assetId: id,
          width: x.sourceWidth,
          height: x.sourceHeight,
          sourceFps: x.fps,
          frameCount: x.frameCount,
          alpha: x.alpha,
          // its own pixel size against the frame (bigger than the frame
          // reaches past the stage) - no shrinking to fit.
          maxDimension: math.max(x.sourceWidth, x.sourceHeight).toDouble());
      unawaited(_hashMedia(layer.content, copy));
      if (replaceId != null) {
        replaceLayerContentWith(replaceId, layer.content);
        return;
      }
      // its sound: decoded from the same kept copy (no second copy).
      Layer? sound;
      final audio = audioStore;
      if (withSound && audio != null) {
        final aid = audio.newAssetId();
        soundId = aid;
        try {
          await _decodeAudio(audio, aid, copy, cancel: cancel);
          final seconds = (_pcm[aid]!.length ~/ audioChannels) / audioSampleRate;
          sound = createAudioLayer(path: copy.path, assetId: aid, durationSeconds: seconds);
          unawaited(_hashMedia(sound.content, copy));
        } catch (e) {
          if (e is AudioImportCancelled || (cancel?.isCancelled ?? false)) throw VideoImportCancelled();
          // no sound track (or unreadable): the video comes in silent.
          _pcm.remove(aid);
          _peaks.remove(aid);
          await audio.removeAsset(aid);
          soundId = null;
        }
      }
      undo.pushUndoState(project);
      layer.startFrame = currentFrame;
      nameNewLayer(project, layer); // first free number of its type
      project.layers.add(layer);
      if (sound != null) {
        final base = '${layer.name}_sound';
        sound
          ..startFrame = layer.startFrame
          ..name = project.layers.any((l) => l.name == base) ? nextFreeLayerName(project, base) : base;
        project.layers.add(sound);
        linkInTime(project, layer, sound);
      }
      selection.selectedLayer = layer.id;
      freshFillLayerId = layer.id;
      _fitTimeline();
      _render();
      notifyListeners();
    } catch (_) {
      await store.removeAsset(id);
      final audio = audioStore;
      if (soundId != null && audio != null) {
        _pcm.remove(soundId);
        _peaks.remove(soundId);
        await audio.removeAsset(soundId);
      }
      rethrow;
    }
  }

  /// Extracts again the frames of videos whose frame cache was cleared
  /// (the OS may empty the cache directory) from their kept source copy.
  Future<void> restoreVideoFrames() async {
    final store = _videoStore;
    if (store == null) return;
    recheckVideoFrames();
    final todo = <String, Content>{};
    for (final l in project.layers) {
      final c = l.content, id = c.videoAssetId;
      if (c.shape != 'video' || id == null || c.videoPath == null) continue;
      if (store.hasFrames(id, c.videoFrameCount ?? 0, alpha: c.videoAlpha)) continue;
      if (!File(c.videoPath!).existsSync()) continue;
      todo[id] = c;
    }
    for (final e in todo.entries) {
      videosRebuilding.add(e.key);
      notifyListeners();
      try {
        final dir = store.framesDir(e.key);
        if (await dir.exists()) await dir.delete(recursive: true);
        await videoService.extractToCache(File(e.value.videoPath!), dir,
            maxWidth: frameWidth, maxHeight: frameHeight, alpha: e.value.videoAlpha);
      } catch (_) {
        // stays missing - shown as a broken layer.
      } finally {
        videosRebuilding.remove(e.key);
        _framesPresent.remove(e.key);
        renderer.videoFrames.clearAsset(e.key);
        _render();
        notifyListeners();
      }
    }
  }

  // ===== audio =====

  /// Where imported sounds and their decoded PCM live (the home screen
  /// passes the app's; tests use a temp dir).
  AudioAssetStore? audioStore;
  AudioService audioService = createAudioService();

  /// Makes the preview player - tests put in a fake one with their own
  /// clock.
  AudioPlayback Function() audioPlaybackFactory = createAudioPlayback;
  AudioPlayback? _playback;
  String? _loadedMixKey;
  final Map<String, Int16List> _pcm = {};
  final Map<String, Uint8List> _peaks = {};

  /// Sounds being decoded again (their cache was cleared).
  final Set<String> audioRebuilding = {};

  /// Why the last preview played without sound, or null.
  String? audioError;

  /// Something in the project is heard.
  bool get hasAudio => audibleLayers(project).isNotEmpty;

  /// The waveform of an imported sound (see computePeaks), or null while
  /// it isn't decoded.
  Uint8List? audioPeaks(String? assetId) {
    if (assetId == null) return null;
    final cached = _peaks[assetId];
    if (cached != null) return cached;
    final f = audioStore?.peaksFile(assetId);
    if (f == null || !f.existsSync()) return null;
    return _peaks[assetId] = f.readAsBytesSync();
  }

  Future<Int16List> _loadPcm(AudioAssetStore store, String id) async =>
      _pcm[id] ??= pcmFromBytes(await store.pcmFile(id).readAsBytes());

  Future<void> _decodeAudio(AudioAssetStore store, String id, File source,
      {void Function(double fraction)? onProgress, CancelToken? cancel}) async {
    final decoded = await audioService.decodeToPcm(source, store.pcmFile(id), onProgress: onProgress, cancel: cancel);
    _pcm.remove(id);
    final pcm = await _loadPcm(store, id);
    final peaks = await Isolate.run(() => computePeaks(pcm));
    await store.writePeaks(id, peaks);
    _peaks[id] = peaks;
    if (decoded.durationSeconds <= 0) throw StateError('No sound could be read from this file.');
  }

  /// Imports a sound (any audio file, or the sound of a video) as a new
  /// audio layer as long as the clip: copies the file into app storage,
  /// decodes it once to PCM and draws its waveform. Throws
  /// AudioImportCancelled when `cancel` fires; nothing is left behind on
  /// failure.
  Future<void> importAudio(File source, {void Function(double fraction)? onProgress, CancelToken? cancel}) async {
    final store = audioStore;
    if (store == null) throw StateError('No storage for sounds');
    final id = store.newAssetId();
    try {
      final copy = await store.copySource(source, id);
      if (cancel?.isCancelled ?? false) throw AudioImportCancelled();
      await _decodeAudio(store, id, copy, onProgress: onProgress, cancel: cancel);
      final seconds = (_pcm[id]!.length ~/ audioChannels) / audioSampleRate;
      final layer = createAudioLayer(path: copy.path, assetId: id, durationSeconds: seconds);
      unawaited(_hashMedia(layer.content, copy));
      undo.pushUndoState(project);
      layer.startFrame = currentFrame;
      nameNewLayer(project, layer);
      project.layers.add(layer);
      selection.selectedLayer = layer.id;
      _fitTimeline();
      _render();
      notifyListeners();
    } catch (_) {
      _pcm.remove(id);
      _peaks.remove(id);
      await store.removeAsset(id);
      rethrow;
    }
  }

  /// Decodes again the sounds whose PCM was cleared from the cache (the OS
  /// may empty it), from their kept source copy.
  Future<void> restoreAudio() async {
    final store = audioStore;
    if (store == null) return;
    final todo = <String, String>{};
    for (final l in project.layers) {
      final c = l.content, id = c.audioAssetId;
      if (c.shape != 'audio' || id == null || c.audioPath == null) continue;
      if (store.hasPcm(id) || !File(c.audioPath!).existsSync()) continue;
      todo[id] = c.audioPath!;
    }
    for (final e in todo.entries) {
      audioRebuilding.add(e.key);
      notifyListeners();
      try {
        await _decodeAudio(store, e.key, File(e.value));
      } catch (_) {
        // stays silent.
      } finally {
        audioRebuilding.remove(e.key);
        notifyListeners();
      }
    }
  }

  /// Mutes / unmutes an audio layer (one undo step).
  void setAudioMuted(String layerId, bool muted) {
    final l = findLayer(project, layerId);
    if (l == null || l.content.shape != 'audio' || l.content.audioMuted == muted) return;
    pushUndo();
    l.content.audioMuted = muted;
    notifyListeners();
  }

  /// The timeline's sound - every audible layer mixed (mixTimeline) into
  /// one WAV from frame 0, `seconds` long (default: the whole timeline).
  /// Null when nothing is heard.
  Future<File?> buildAudioMix({double? seconds, File? into}) async {
    final store = audioStore;
    final layers = audibleLayers(project);
    if (store == null || layers.isEmpty) return null;
    final length = seconds ?? (maxFrame + 1) / fps;
    final pcm = <String, Int16List>{};
    for (final id in {for (final l in layers) l.content.audioAssetId!}) {
      if (store.pcmFile(id).existsSync()) pcm[id] = await _loadPcm(store, id);
    }
    final snapshot = Project(fps: project.fps, layers: [for (final l in layers) cloneLayer(l)]);
    final rate = fps;
    final bytes = await Isolate.run(() {
      fps = rate; // the engine's frame rate is a per-isolate global
      return wavBytes(mixTimeline(snapshot, pcm, seconds: length));
    });
    final out = into ?? File('${store.pcmRoot.path}/preview_${_audioMixKey().hashCode.toUnsigned(32).toRadixString(16)}.wav');
    await out.parent.create(recursive: true);
    await out.writeAsBytes(bytes);
    return out;
  }

  /// Everything the preview mix depends on.
  String _audioMixKey() => jsonEncode([fps, maxFrame, for (final l in audibleLayers(project)) layerToJson(l)]);

  // ===== playback =====

  int _playSession = 0;
  bool _audioClock = false;

  /// While the preview plays with sound, the frames follow the player's
  /// position (the sound is the clock), so picture and sound can't drift.
  bool get playingWithSound => _audioClock;

  Timer? _audioPrepTimer;

  /// After sound-related edits, the preview mix is made and loaded ahead
  /// of time (debounced), so pressing play doesn't wait for it.
  void _prepareAudioSoon() {
    if (audioStore == null || playing || !hasAudio) return;
    _audioPrepTimer?.cancel();
    // (a while after the last edit: dragging sound around stays light.)
    _audioPrepTimer = Timer(const Duration(milliseconds: 1500), () {
      if (playing || _loadedMixKey == _audioMixKey()) return;
      unawaited(_loadMix(_playSession).then((_) {}, onError: (Object e) {
        audioError = '$e';
      }));
    });
  }

  /// Makes the preview mix for the current timeline and loads it into the
  /// player, unless it is already loaded. False when there is nothing to
  /// hear or a newer play/stop overtook it.
  Future<bool> _loadMix(int session) async {
    final key = _audioMixKey();
    final p = _playback ??= audioPlaybackFactory();
    if (_loadedMixKey == key) return true;
    final mix = await buildAudioMix();
    if (mix == null || session != _playSession) return false;
    await p.load(mix.path);
    _loadedMixKey = key;
    // older preview mixes aren't needed any more.
    for (final f in mix.parent.listSync().whereType<File>()) {
      if (f.path != mix.path && f.uri.pathSegments.last.startsWith('preview_')) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    return true;
  }

  Future<void> _startAudioClock(int session) async {
    try {
      final p = _playback ??= audioPlaybackFactory();
      if (_loadedMixKey != _audioMixKey()) {
        if (!await _loadMix(session)) return;
      }
      if (session != _playSession) return;
      // starts where the frame clock has got to while the mix was made.
      await p.start(Duration(microseconds: (currentFrame * 1e6 / fps).round()), speed: playbackSpeed);
      if (session != _playSession) {
        await p.pause();
        return;
      }
      _audioClock = true;
      audioError = null;
    } catch (e) {
      audioError = '$e';
      notifyListeners();
    }
  }

  /// One display frame of playback: the frame the preview should show.
  /// With sound playing it is read off the player's position; otherwise
  /// counted from real time since `startFrame` began playing.
  @visibleForTesting
  void playTick(Duration elapsed, int startFrame) {
    if (!canPlay) {
      if (playing) togglePlay(); // everything was deleted while playing
      return;
    }
    final total = maxFrame + 1;
    final int raw;
    if (_audioClock) {
      raw = (_playback!.position.inMicroseconds * fps / 1e6).floor();
    } else {
      final framesElapsed = (elapsed.inMicroseconds * fps * playbackSpeed / 1e6).floor();
      raw = startFrame + framesElapsed;
    }
    if (!loopPlayback && raw >= maxFrame) {
      // loop off: stop on the last frame.
      if (currentFrame != maxFrame) setFrame(maxFrame, quiet: true);
      if (playing) togglePlay();
      return;
    }
    final next = raw % total;
    if (next != currentFrame) setFrame(next, quiet: true);
  }

  /// Playback starts over at the end (on) or stops there (off). Saved with
  /// the project.
  bool loopPlayback = true;


  /// Timeline detail rows under the focused layer: 'none', 'effects'
  /// (one line per effect, its time range) or 'keys' (the expanded key
  /// view, a row per params tab).
  String timelineDetail = 'none';

  bool get showEffectRows => timelineDetail == 'effects' || timelineDetail == 'both';
  bool get showKeyRows => timelineDetail == 'keys' || timelineDetail == 'both';

  /// The effect whose time range is being edited on the timeline.
  String? editingEffectId;

  /// Layers whose contour is drawn over the stage (Effects tab, "Show
  /// contour") - a debug view, not saved.
  final Set<String> contourDebugLayers = {};

  void toggleContourDebug(String layerId) {
    // several selected together: all of them (one contour around them).
    final ids = selectedGroup.length > 1 && selectedGroup.contains(layerId) ? selectedGroup : {layerId};
    final on = !contourDebugLayers.contains(layerId);
    on ? contourDebugLayers.addAll(ids) : contourDebugLayers.removeAll(ids);
    notifyListeners();
  }

  /// Contour physics: the layer's push becomes normal position keys and
  /// its Collide goes off. One undo step.
  void bakePhysicsToKeys(String layerId) {
    final layer = findLayer(project, layerId);
    if (layer == null || !layer.physics.collide) return;
    pushUndo();
    bakePushToKeys(project, physicsWorldOf(project), layer);
    commitEdit();
  }

  /// Follow: the followed motion becomes the layer's position/rotation/
  /// scale keys and the effect goes off. One undo step; false when it
  /// can't (a parented layer).
  bool bakeFollowToKeys(String layerId) {
    final layer = findLayer(project, layerId);
    if (layer == null || !layer.follow.enabled) return false;
    pushUndo();
    final ok = core.bakeFollowToKeys(project, layer);
    commitEdit();
    return ok;
  }

  /// Mask regions: the region picked in the list, on the stage or on the
  /// timeline (its number when it's a numbered piece).
  int? selectedRegionSig;
  int? selectedRegionNumber;

  /// Picking an area on the stage for a field (Masks tab, Reactions):
  /// the next tap on an area gives it here. `regionPickKey` names the field.
  void Function(int sig, int? number)? regionPick;
  String? regionPickKey;

  void startRegionPick(String key, void Function(int sig, int? number) onPick) {
    if (regionPickKey == key) {
      regionPick = null;
      regionPickKey = null;
    } else {
      regionPick = onPick;
      regionPickKey = key;
    }
    stageRegionPickActive = regionPick != null;
    notifyListeners();
  }

  /// A short note shown over the stage (e.g. a region's signature in
  /// words after a long press).
  final ValueNotifier<String?> stageNotice = ValueNotifier(null);

  void selectRegion(int? sig, [int? number, int depth = 0]) {
    selectedRegionSig = sig;
    selectedRegionNumber = number;
    stageSelectedRegionSig = sig;
    stageSelectedRegionNumber = number;
    stageSelectedRegionDepth = depth;
    notifyListeners();
  }

  /// Mask time lines under the focused layer (like the effect lines).
  bool showMaskRows = false;

  /// The mask (by index) whose time is being edited on the timeline.
  int? editingMaskIndex;

  void toggleMaskRows() {
    showMaskRows = !showMaskRows;
    editingMaskIndex = null;
    notifyListeners();
  }

  /// A mask's time limited (Masks tab): its own indicators on the
  /// timeline, ready to drag.
  void showMaskTimeOnTimeline(int i) {
    showMaskRows = true;
    editingMaskIndex = i;
    editingEffectId = null;
    notifyListeners();
  }

  void setEditingMask(int? i) {
    editingMaskIndex = editingMaskIndex == i ? null : i;
    if (editingMaskIndex != null) editingEffectId = null;
    notifyListeners();
  }

  void setTimelineDetail(String mode) {
    // effect lines and key rows are shown each on its own (both at once).
    final on = {if (showEffectRows) 'effects', if (showKeyRows) 'keys'};
    on.contains(mode) ? on.remove(mode) : on.add(mode);
    timelineDetail = on.length == 2 ? 'both' : on.isEmpty ? 'none' : on.single;
    editingEffectId = null;
    notifyListeners();
  }

  /// The expanded key view's selected line: a tab and its two keys
  /// (local frames) of the focused layer.
  ({String layerId, String tab, int a, int b, String? track})? keyDetailSelection;

  void selectKeyDetailSpan(({String layerId, String tab, int a, int b, String? track})? span) {
    keyDetailSelection = span;
    keyDetailExtra = [];
    notifyListeners();
  }

  /// "Select several" on: more lines with the first one (they move and
  /// are deleted together).
  List<({String layerId, String tab, int a, int b, String? track})> keyDetailExtra = [];

  /// Adds / removes a line from the several selected.
  void toggleKeyDetailExtra(({String layerId, String tab, int a, int b, String? track}) span) {
    if (keyDetailSelection == null) {
      keyDetailSelection = span;
    } else if (keyDetailSelection == span) {
      keyDetailSelection = keyDetailExtra.isEmpty ? null : keyDetailExtra.removeAt(0);
    } else if (!keyDetailExtra.remove(span)) {
      keyDetailExtra = [...keyDetailExtra, span];
    }
    notifyListeners();
  }

  /// Deletes both keys of the selected line (one undo step).
  void deleteSelectedKeyDetailSpan() {
    final s = keyDetailSelection;
    final layer = s == null ? null : findLayer(project, s.layerId);
    if (s == null || layer == null) return;
    pushUndo();
    for (final x in [s, ...keyDetailExtra]) {
      final l = findLayer(project, x.layerId);
      if (l != null) deleteKeyDetailSpan(l, x.tab, x.a, x.b, track: x.track);
    }
    keyDetailSelection = null;
    keyDetailExtra = [];
    commitEdit();
  }

  /// Moves the selected line's keys: its start by `da`, its end by `db`
  /// (both: the whole line). Live - the caller pushed the undo step.
  void moveSelectedKeySpan(int da, int db) {
    final s = keyDetailSelection;
    final layer = s == null ? null : findLayer(project, s.layerId);
    if (s == null || layer == null) return;
    final (na, nb) = moveKeyDetailSpan(layer, s.tab, s.a, s.b, da, db, track: s.track);
    keyDetailSelection = (layerId: s.layerId, tab: s.tab, a: na, b: nb, track: s.track);
    // the other selected lines by as much as the first one went.
    keyDetailExtra = [
      for (final x in keyDetailExtra)
        if (findLayer(project, x.layerId) case final l?)
          () {
            final (xa, xb) = moveKeyDetailSpan(l, x.tab, x.a, x.b, na - s.a, nb - s.b, track: x.track);
            return (layerId: x.layerId, tab: x.tab, a: xa, b: xb, track: x.track);
          }()
    ];
    commitEdit();
  }

  /// The selected key line's path (its position keys, two or more), if it
  /// has one.
  Track? get selectedSpanPath {
    final s = keyDetailSelection;
    final layer = s == null ? null : findLayer(project, s.layerId);
    if (s == null || layer == null) return null;
    final trk = spanPositionTrack(layer, s.tab);
    return trk != null && hasPathIn(trk, s.a, s.b) ? trk : null;
  }

  /// What the Timeline tab's Path edits: the selected key line's path
  /// when one of the selected layer's is selected, else its whole
  /// position path (its own keys, or the key layer being edited). Null:
  /// no path (fewer than two position keys).
  ({Layer layer, Track trk, int a, int b, bool line})? get pathTarget {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null) return null;
    final s = keyDetailSelection;
    if (s != null && s.layerId == layer.id) {
      final trk = spanPositionTrack(layer, s.tab);
      if (trk != null && hasPathIn(trk, s.a, s.b)) return (layer: layer, trk: trk, a: s.a, b: s.b, line: true);
    }
    final trk = editTrackOf(layer.transform.anchor);
    if (trk.keyframes.length < 2) return null;
    final fs = trk.keyframes.map((k) => k.frame);
    return (layer: layer, trk: trk, a: fs.reduce(math.min), b: fs.reduce(math.max), line: false);
  }

  /// Path: moved as a whole to `to` (px from where it was set out). Live -
  /// the caller pushed the undo step.
  void movePathTo(List<double> to) {
    final t = pathTarget;
    if (t == null) return;
    final d = [to[0] - t.layer.pathOffset[0], to[1] - t.layer.pathOffset[1]];
    shiftPathKeys(t.trk, t.a, t.b, [d[0] / stageSize.width, d[1] / stageSize.height]);
    t.layer.pathOffset = [...to];
    clearStateCaches();
    commitEdit();
  }

  /// Path: turned as a whole round its middle to `degrees`. Live.
  void turnPathTo(double degrees) {
    final t = pathTarget;
    if (t == null) return;
    turnPathKeys(t.trk, t.a, t.b, degrees: degrees - t.layer.pathTurn, w: stageSize.width, h: stageSize.height);
    t.layer.pathTurn = degrees;
    clearStateCaches();
    commitEdit();
  }

  /// Path: sized as a whole round its middle to `k` times. Live.
  void scalePathTo(double k) {
    final t = pathTarget;
    if (t == null || k <= 0 || t.layer.pathScale <= 0) return;
    turnPathKeys(t.trk, t.a, t.b, k: k / t.layer.pathScale, w: stageSize.width, h: stageSize.height);
    t.layer.pathScale = k;
    clearStateCaches();
    commitEdit();
  }

  /// The layer's action row on a selected line: a key at the playhead
  /// (splits the line in two). One undo step.
  void splitSelectedKeySpan() {
    final s = keyDetailSelection;
    final layer = s == null ? null : findLayer(project, s.layerId);
    if (s == null || layer == null) return;
    final f = currentFrame - layer.startFrame;
    if (f <= s.a || f >= s.b) return;
    pushUndo();
    visitLayerTracksNamed(layer, (name, trk) {
      if (keyDetailTabOf(name) != s.tab || (s.track != null && name != s.track)) return;
      if (!trk.keyframes.any((k) => k.frame == s.a) || trk.keyframes.any((k) => k.frame == f)) return;
      setTrackValueAt(trk, f, evaluateTrack(project, trk, f.toDouble(), layer));
    });
    keyDetailSelection = (layerId: s.layerId, tab: s.tab, a: s.a, b: f, track: s.track);
    commitEdit();
  }

  /// The selected line's start (or, `nearest`, its nearer end) to the
  /// playhead. One undo step.
  void selectedKeySpanToPlayhead({bool nearest = false}) {
    final s = keyDetailSelection;
    final layer = s == null ? null : findLayer(project, s.layerId);
    if (s == null || layer == null) return;
    final f = currentFrame - layer.startFrame;
    pushUndo();
    if (!nearest) {
      moveSelectedKeySpan(f - s.a, f - s.a);
    } else if ((f - s.a).abs() <= (f - s.b).abs()) {
      moveSelectedKeySpan(f - s.a, 0);
    } else {
      moveSelectedKeySpan(0, f - s.b);
    }
  }

  void setEditingEffect(String? id) {
    editingEffectId = editingEffectId == id ? null : id;
    if (editingEffectId != null) editingMaskIndex = null;
    notifyListeners();
  }

  void toggleLoopPlayback() {
    loopPlayback = !loopPlayback;
    notifyListeners();
  }

  /// Nothing to play: an empty project has no frames worth looping.
  bool get canPlay => project.layers.isNotEmpty;

  void retryImage(String layerId) {
    final layer = findLayer(project, layerId);
    if (layer == null) return;
    renderer.retryImage(layer.content);
    _render();
    notifyListeners();
  }

  Color? get background => renderer.backgroundColor;
  void setBackground(Color? color) {
    if (renderer.backgroundColor == color) return;
    renderer.backgroundColor = color;
    _render();
    notifyListeners();
  }

  // (allow quickly switching between layers, without needing to tap again to
  // exit the selected one first) - a toggle (placed in TimelineToolbar, left
  // of undo/redo) that lets LayersTimelineView's tap-to-focus switch DIRECTLY
  // to a different (previously dimmed/non-interactive) layer's line, instead
  // of requiring the currently-focused line to be tapped first to unfocus it.
  bool layerQuickSwitchEnabled = false;

  // (moving a layer to the edge of the timeline should scroll the whole
  // timeline - convenience for dragging layers around) - a toggle, same
  // field/method/TimelineToolbar-icon pattern as layerQuickSwitchEnabled
  // above. Off by default, matching that toggle's own convention.
  bool timelineEdgeAutoScrollEnabled = false;

  // (add a toggle, near undo, that pins the playhead to the middle of the
  // timeline and keeps it there while the timeline scrolls) - the classic
  // "filmstrip scrolls under a fixed- center playhead" DAW paradigm, opt-in
  // rather than replacing the existing draggable-playhead model. See
  // layers_timeline_view.dart's own doc comment for the scroll<->frame sync
  // this drives. Off by default, same convention as the two toggles above.
  /// The playhead stays in the middle of the timeline (always).
  bool timelineCenterPlayheadEnabled = true;

  // (layers should snap to each other's edges in the timeline - near the other
  // layer settings, near undo) - a plain bool, same
  // field/method/TimelineToolbar-icon pattern as the three toggles above.
  // Deliberately separate from the 2D stage-object Snapping tab/dialog - a
  // different 1D/integer-frame mechanism (layer_track_snap.dart), with no
  // sensitivity slider requested. Lives in the new collapsible drawer row
  // (timelineDrawerExpanded below), not the main toolbar row itself.
  bool snapTimelineLayersEnabled = false;

  // (make all these icons appear in a separate field via one caret button) -
  // opens/closes TimelineDrawerRow, a secondary row of timeline toggles tucked
  // above TimelineToolbar. Off by default, same convention as every other
  // timeline toggle here.
  bool timelineDrawerExpanded = false;

  /// Drawer toggle: tapping a keyframe on the timeline selects it without
  /// moving the playhead onto it.
  bool keyframeSelectKeepsPlayhead = false;

  /// Drawer toggle mirroring the Keyframes tab's multiselect button
  /// (movement_core's kfMultiselectMode global): taps add/remove keys
  /// from the selection instead of replacing it.
  bool get kfMultiselectEnabled => kfMultiselectMode;

  // snapping ("movement-mobile-snapping-spec.md"): the per-category
  // sensitivity SLIDERS in SnappingSettingsView edit these screen-px
  // preferences - stage_gesture_controller.dart converts each into a
  // frame-space radius (via camera.radiusInFrameSpace, zoom-aware) and
  // writes it into the matching movement_core global right before every
  // relevant drag-apply call. The master/category-enabled toggles and
  // the frame-space radii themselves live as plain globals in
  // movement_core's model/project.dart (drag_ops.dart, pure Dart, must
  // read them directly) - only the raw screen-px numbers live here,
  // since nothing outside this settings UI ever needs them in that unit.
  double snapSensitivityEdgeToEdgePx = 8;
  double snapSensitivityCenterToCenterPx = 8;
  double snapSensitivityCornerToCornerPx = 8;
  double snapSensitivityEqualSizePx = 8;
  double snapSensitivityGridPx = 8;
  double snapSensitivityFrameBoundaryPx = 10;

  // the project never persisted anything at all - (everything reset to
  // defaults). Debounced autosave, per the decision (both "after every change"
  // AND "on background/close"). `_autosaveFile` is only set by `initAutosave`
  // below - deliberately NOT called from this constructor, which stays
  // synchronous and free of any file I/O, so every existing `AppState` test
  // construction keeps working completely unchanged (no autosave Timer ever
  // gets scheduled unless something actually calls initAutosave - only
  // main.dart does).
  File? _autosaveFile;
  Timer? _autosaveTimer;

  AppState() {
    // sound links read the sounds' waveforms through this.
    soundPeaksProvider = audioPeaks;
    // the user's own ruler stations are kept with the app's settings.
    ParamEditor.onStationsChanged = () => setAppPreference('paramStations', jsonEncode(ParamEditor.stations));
    registerBuiltinEffects();
    // a fresh project runs at the default rate (the frame rate is a
    // movement_core global shared by the whole engine).
    fps = 60;
    project.fps = 60;
    // a new project starts with the default view settings (they're
    // engine globals - nothing may leak from the last project opened)
    // and the app's own editing preferences.
    applyProjectUiState(const {});
    final settings = AppSettings.instance;
    if (settings != null) {
      applyAppUiState(settings.ui);
      _savedAppUi = jsonEncode(appUiState());
    }
    renderer.setSize(frameWidth, frameHeight);
    selection.selectedLayer =
        project.layers.isNotEmpty ? project.layers.last.id : null;
    _fitTimeline();
    // the timeline range is part of each undo step.
    // the range and the picked keys go back with an undo too (undoing a
    // key move used to drop the keys' selection: they weren't at the
    // moved frames any more).
    undo.captureExtra = () => (
          range: timeRange,
          keys: {...kfSelectedFrames},
          line: keyDetailSelection,
          lines: [...keyDetailExtra],
          held: {for (final e in heldKeys.entries) e.key: {...e.value}},
        );
    undo.restoreExtra = (e) {
      if (e is! ({
        ({int a, int b})? range,
        Set<int> keys,
        ({String layerId, String tab, int a, int b, String? track})? line,
        List<({String layerId, String tab, int a, int b, String? track})> lines,
        Map<String, Set<int>> held,
      })) {
        return;
      }
      timeRange = e.range;
      kfSelectedFrames = e.keys;
      keyDetailSelection = e.line;
      keyDetailExtra = e.lines;
      heldKeys = e.held;
    };
    undo.onRestore = () {
      _fitTimeline();
      _render();
      notifyListeners();
    };
    // an imported image decodes asynchronously (see canvas_renderer.dart's
    // own doc comment on this) - once it's ready, re-render so it
    // actually appears instead of staying blank until some unrelated
    // later edit happens to trigger a render.
    renderer.onImageDecoded = () {
      _render();
      notifyListeners();
    };
    _render();
  }

  /// Renders the frame again (the stage's handle cuts changed size).
  void rerender() {
    _render();
    notifyListeners();
  }

  void _render() {
    renderer.renderFrame(project, currentFrame,
        clipToFrame: !(showOffCanvasContent || cameraView), underlay: contextUnderlay);
    _freshRender = true;
  }

  bool _freshRender = false;

  /// Whether the renderer's picture is up to date with a change made
  /// since the stage last took it - then the stage doesn't render the
  /// frame a second time. Consumes the flag.
  bool takeFreshRender() {
    final fresh = _freshRender;
    _freshRender = false;
    return fresh;
  }

  /// configurable frame size (aspect-ratio/custom-size settings). cascades
  /// to CanvasRenderer.setSize, which is itself what actually redefines
  /// movement_core's stageSize global that every coordinate in the project is
  /// normalized against - so this is a real, one-shot resolution change, same
  /// as the constructor's own one-time setSize call (see this class's own
  /// frameWidth/frameHeight doc comment on why that has to stay a single,
  /// explicit, non-layout-driven call).
  void setFrameSize(double width, double height) {
    final oldWidth = frameWidth, oldHeight = frameHeight;
    final changed = oldWidth != width || oldHeight != height;
    if (changed) {
      undo.pushUndoState(project); // now also rescales every layer's own geometry below
    }
    frameWidth = width;
    frameHeight = height;
    if (changed && oldWidth > 0 && oldHeight > 0) {
      if (resizeEvenly) {
        // no stretching: objects scale evenly and keep their places.
        refitProjectEvenly(project, oldWidth, oldHeight, width, height);
      } else if (scaleContentOnResize) {
        rescaleProjectContent(project, width / oldWidth, height / oldHeight);
      }
    }
    renderer.setSize(width, height);
    _render();
    notifyListeners();
  }

  /// A new frame size never stretches objects: they scale evenly (by the
  /// smaller change) and keep their places around the middle.
  bool resizeEvenly = true;

  /// The frame takes the shape of a picture / video layer (the selected
  /// one, or the first there is), keeping its short side.
  bool fitFrameToMedia() {
    final sel = findLayer(project, selection.selectedLayer);
    final media = sel != null && isMediaShape(sel.content.shape)
        ? sel
        : project.layers.where((l) => isMediaShape(l.content.shape)).firstOrNull;
    if (media == null) return false;
    final w = media.content.size[0].abs(), h = media.content.size[1].abs();
    if (w <= 0 || h <= 0) return false;
    final short = math.min(frameWidth, frameHeight);
    final ratio = w / h;
    double even(double v) => (v / 2).round() * 2.0;
    setFrameSize(ratio >= 1 ? even(short * ratio) : short, ratio >= 1 ? short : even(short / ratio));
    return true;
  }

  void toggleScaleContentOnResize() {
    scaleContentOnResize = !scaleContentOnResize;
    notifyListeners();
  }

  void toggleShowOffCanvasContent() {
    showOffCanvasContent = !showOffCanvasContent;
    _render();
    notifyListeners();
  }

  // ===== the stage eyedropper (every colour field) =====

  ValueChanged<String>? _stagePick;

  /// The frame as a picture while picking (the loupe magnifies it).
  ui.Image? stagePickImage;
  ByteData? _stagePickRgba;

  /// Starts picking a colour off the stage for `onPick`: press on the
  /// stage, slide (a loupe shows it), lift to take it.
  Future<void> startStageColorPick(ValueChanged<String> onPick) async {
    _stagePick = onPick;
    chromaTool = 'stagePick';
    notifyListeners();
    _render();
    final image = await renderer.captureFrame();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    // the alpha of what is there (without the background): once more,
    // with the background off.
    ByteData? alpha;
    if (eyedropperAlpha) {
      final bg = renderer.backgroundColor;
      renderer.backgroundColor = null;
      _render();
      final clear = await renderer.captureFrame();
      renderer.backgroundColor = bg;
      _render();
      alpha = await clear.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      clear.dispose();
    }
    if (_stagePick != onPick) return; // finished or replaced meanwhile
    stagePickImage = image;
    _stagePickRgba = bytes;
    _stagePickAlpha = alpha;
    notifyListeners();
  }

  ByteData? _stagePickAlpha;

  /// Movement, "Fit to the contour": the layer's box (its handles) drawn
  /// in to what shows of it - for a picture the edge of its pixels (the
  /// empty margins around them go), found from its contour's outermost
  /// points. It is a crop: Reset crop brings the margins back. False:
  /// nothing to fit to (yet).
  Future<bool> fitBoxToContour(String layerId) async {
    final layer = findLayer(project, layerId);
    if (layer == null) return false;
    final old = [...layer.crop];
    layer.crop = [0, 0, 0, 0];
    Contour? c;
    try {
      // a picture's contour is read off its pixels: wait for it.
      final sw = Stopwatch()..start();
      while ((c = renderer.layerContour(project, layer, currentFrame, const ContourParams(simplify: 0.2, minAreaFraction: 0))) ==
              null &&
          sw.elapsed < const Duration(seconds: 4)) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    } finally {
      layer.crop = old;
    }
    if (c == null || c.rings.isEmpty) return false;
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final r in c.rings) {
      for (final q in r.points) {
        minX = math.min(minX, q[0]);
        minY = math.min(minY, q[1]);
        maxX = math.max(maxX, q[0]);
        maxY = math.max(maxY, q[1]);
      }
    }
    final b = shapeBoundingBox(layer.content);
    final w = b.maxX - b.minX, h = b.maxY - b.minY;
    if (w <= 0 || h <= 0 || maxX <= minX || maxY <= minY) return false;
    undo.pushUndoState(project);
    layer.crop = [
      ((minX - b.minX) / w).clamp(0.0, 0.95),
      ((minY - b.minY) / h).clamp(0.0, 0.95),
      ((b.maxX - maxX) / w).clamp(0.0, 0.95),
      ((b.maxY - maxY) / h).clamp(0.0, 0.95),
    ];
    commitEdit();
    return true;
  }

  /// Export: the folder files are saved to (null: the save window asks).
  String? exportDir;

  /// Settings: the eyedropper takes the alpha of what it picks too (a
  /// see-through colour, and the layer's opacity) - off: always opaque.
  bool eyedropperAlpha = false;

  /// The picked point without the background: its own colour and alpha.
  List<int>? _stagePickAlphaAt(List<double> framePoint) {
    final img = stagePickImage, b = _stagePickAlpha;
    if (img == null || b == null) return null;
    final x = framePoint[0].floor(), y = framePoint[1].floor();
    if (x < 0 || y < 0 || x >= img.width || y >= img.height) return null;
    final i = (y * img.width + x) * 4;
    return [b.getUint8(i), b.getUint8(i + 1), b.getUint8(i + 2), b.getUint8(i + 3)];
  }

  /// The colour of the frame at `framePoint` while picking (null: outside,
  /// or the picture isn't read yet).
  List<int>? stagePickRgbAt(List<double> framePoint) {
    final img = stagePickImage, b = _stagePickRgba;
    if (img == null || b == null) return null;
    final x = framePoint[0].floor(), y = framePoint[1].floor();
    if (x < 0 || y < 0 || x >= img.width || y >= img.height) return null;
    final i = (y * img.width + x) * 4;
    return [b.getUint8(i), b.getUint8(i + 1), b.getUint8(i + 2)];
  }

  /// Lifted at `framePoint` (null: cancelled): the colour there goes to
  /// the field that asked.
  void finishStageColorPick(List<double>? framePoint) {
    final cb = _stagePick;
    final rgb = framePoint == null ? null : stagePickRgbAt(framePoint);
    final a = framePoint == null ? null : _stagePickAlphaAt(framePoint);
    _stagePick = null;
    _stagePickAlpha = null;
    eyedropperOwner.value = null;
    stagePickImage = null;
    _stagePickRgba = null;
    chromaTool = 'none';
    if (cb != null && rgb != null) {
      if (a != null && a[3] < 255) {
        // see-through: its own colour (not mixed with the background).
        final c = a[3] == 0 ? rgb : a;
        cb('${rgbHex(c[0], c[1], c[2])}${a[3].toRadixString(16).padLeft(2, '0')}');
      } else {
        cb(rgbHex(rgb[0], rgb[1], rgb[2]));
      }
    }
    notifyListeners();
  }

  /// Text tab: the animator open in its panel (its units are tinted on
  /// the stage by their amount). Null: none.
  int? selectedTextAnimator;

  /// The open animator's units tinted on the stage (can be switched off).
  bool showTextRangeOverlay = true;

  void setTextRangeOverlay(bool v) {
    showTextRangeOverlay = v;
    notifyListeners();
  }

  void selectTextAnimator(int? i) {
    selectedTextAnimator = i;
    _render();
    notifyListeners();
  }

  /// Adds a text animator (a preset's, or empty) to text layer `id`, its
  /// keys from the playhead. One undo step.
  void addTextAnimator(String id, String? preset) {
    final l = findLayer(project, id);
    final t = l?.content.text;
    if (l == null || t == null) return;
    pushUndo();
    final f0 = layerLocalFrame(l, currentFrame).round();
    final frames = math.min(60, math.max(10, l.durationFrames - f0));
    t.animators.add(preset == null ? TextAnimator(name: 'Animator ${t.animators.length + 1}') : textAnimatorPreset(preset, f0: f0, frames: frames));
    selectedTextAnimator = t.animators.length - 1;
    commitEdit();
  }

  /// Line tab / stage: the selected point of the selected line.
  void selectLinePoint(int i) {
    lineSelectedPoint = i;
    notifyListeners();
  }

  /// Edits the selected vector line (one undo step), keeping its box
  /// around its points.
  void editLine(String layerId, void Function(Content c) edit) {
    final l = findLayer(project, layerId);
    if (l == null || !isNodeLine(l.content)) return;
    pushUndo();
    edit(l.content);
    syncLineBox(l.content);
    // it turns about the middle of its points.
    if (l.content.lineNodes!.isNotEmpty) centerLinePivot(project, l, currentFrame);
    _render();
    notifyListeners();
  }

  /// Live edit of a line without an undo step (slider drags).
  void editLineLive(String layerId, void Function(Content c) edit) {
    final l = findLayer(project, layerId);
    if (l == null || !isNodeLine(l.content)) return;
    edit(l.content);
    syncLineBox(l.content);
    _render();
    notifyListeners();
  }

  /// Close & fill: the line becomes a filled shape. One undo step.
  void closeLineOf(String layerId) => editLine(layerId, closeLine);

  /// Timeline: folders folded shut (their layers' rows hidden).
  Set<String> collapsedTimelineFolders = {};

  void toggleTimelineFolder(String folder) {
    if (!collapsedTimelineFolders.remove(folder)) collapsedTimelineFolders.add(folder);
    notifyListeners();
  }

  /// Parent picked on the stage: the layer that becomes the parent while
  /// taps pick its children (null: not picking).
  String? parentPickFor;

  /// The children picked so far.
  Set<String> parentPicked = {};

  void startParentPick(String parentId) {
    parentPickFor = parentId;
    parentPicked = {
      for (final l in project.layers)
        if (l.parentId == parentId) l.id
    };
    notifyListeners();
  }

  /// A tap on `id` while picking: in or out of the children (never the
  /// parent itself, nor a layer it hangs from).
  void toggleParentPick(String id) {
    final p = parentPickFor;
    if (p == null || id == p || wouldCreateCycle(project, id, p)) return;
    if (!parentPicked.remove(id)) parentPicked.add(id);
    notifyListeners();
  }

  /// Done: the picked layers hang from the parent (where they are on the
  /// stage stays), the ones taken out let go. One undo step.
  void finishParentPick({bool apply = true}) {
    final p = parentPickFor;
    parentPickFor = null;
    if (p == null || !apply) {
      parentPicked = {};
      notifyListeners();
      return;
    }
    pushUndo();
    for (final l in [...project.layers]) {
      final want = parentPicked.contains(l.id);
      if (want && l.parentId != p) {
        newParentLinkDefaults(l);
        reparentPreservingWorldPosition(project, l, p, currentFrame);
      }
      if (!want && l.parentId == p) reparentPreservingWorldPosition(project, l, null, currentFrame);
    }
    parentPicked = {};
    commitEdit();
  }

  /// Line tab, "Add by tapping": while on, a tap on the stage adds a point
  /// to the selected line (past the selected end), or - from a point in
  /// the middle - starts a new line there. Done turns it off.
  bool lineTapAdd = false;

  void setLineTapAdd(bool on) {
    lineTapAdd = on;
    notifyListeners();
  }

  /// A tap at frame point `fp` while adding by tapping. One undo step.
  void lineTapAt(List<double> fp) {
    final l = findLayer(project, selection.selectedLayer);
    if (l == null || !isNodeLine(l.content)) return;
    final c = l.content;
    final m = getTransformBoxHandles(project, l, currentFrame).mCanvas;
    final local = applyAffine(invertAffine(m), fp);
    pushUndo();
    // on the line itself: a point goes in there.
    final k = math.sqrt((m[0] * m[3] - m[1] * m[2]).abs());
    final inside = insertLinePointOn(c, local, k <= 1e-9 ? 12 : 14 / k);
    if (inside != null) {
      lineSelectedPoint = inside;
      centerLinePivot(project, l, currentFrame);
      commitEdit();
      return;
    }
    final sel = lineSelectedPoint.clamp(0, c.lineNodes!.length - 1);
    final i = addLinePointAt(c, sel, local);
    if (i != null) {
      lineSelectedPoint = i;
      centerLinePivot(project, l, currentFrame);
      commitEdit();
      return;
    }
    // from a point in the middle (or a loop): a new line leaves it.
    final from = c.lineNodes![sel];
    final branch = cloneLayer(l);
    layerCounter++;
    branch
      ..id = 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter'
      ..rowId = null;
    branch.content
      ..lineNodes = [LineNode(from.x, from.y, w: from.w), LineNode(local[0], local[1])]
      ..lineClosed = false
      ..lineFilled = false;
    syncLineBox(branch.content);
    project.layers.insert(project.layers.indexOf(l) + 1, branch);
    ensureUniqueLayerNames(project);
    normalizeTimelineRows(project);
    selection.selectedLayer = branch.id;
    multiSelection = {};
    lineSelectedPoint = 1;
    centerLinePivot(project, branch, currentFrame);
    commitEdit();
  }

  /// Origami "through two points": the effect and fold waiting for its two
  /// points (layer-local, snapped to the shape's corners), and those so far.
  ({String instId, int n, List<List<double>> points})? origamiPick;

  void startOrigamiPick(String instId, int n) {
    origamiPick = origamiPick == null ? (instId: instId, n: n, points: <List<double>>[]) : null;
    notifyListeners();
  }

  /// A tap while picking: the nearest corner of the shape within reach
  /// (else the spot); the second one sets the fold. True: it was taken.
  bool origamiPickTap(List<double> fp, double reachFrame) {
    final pick = origamiPick;
    if (pick == null) return false;
    final l = findLayer(project, selection.selectedLayer);
    final inst = l?.effectStack.where((i) => i.id == pick.instId).firstOrNull;
    if (l == null || inst == null) {
      origamiPick = null;
      notifyListeners();
      return true;
    }
    final m = getTransformBoxHandles(project, l, currentFrame).mCanvas;
    var p = applyAffine(invertAffine(m), fp);
    final k = math.sqrt((m[0] * m[3] - m[1] * m[2]).abs());
    var best = k <= 1e-9 ? 0.0 : reachFrame / k;
    for (final q in layerFlatOutline(l)) {
      final d = math.sqrt(math.pow(q[0] - p[0], 2) + math.pow(q[1] - p[1], 2));
      if (d < best) {
        best = d;
        p = q;
      }
    }
    pick.points.add(p);
    if (pick.points.length >= 2) {
      pushUndo();
      final lf = layerLocalFrame(l, currentFrame).round();
      origamiFoldThrough(inst, buildGrid(l.content, 2, 2), pick.n, pick.points[0], pick.points[1], lf,
          (t, f, v) => setTrackValueAt(t, f, v));
      origamiPick = null;
      commitEdit();
      return true;
    }
    notifyListeners();
    return true;
  }

  /// Line tab: the line splits in two at the selected point (a loop opens
  /// there); the second half becomes its own line, right above.
  void splitSelectedLine() {
    final l = findLayer(project, selection.selectedLayer);
    if (l == null || !isNodeLine(l.content)) return;
    final sel = lineSelectedPoint.clamp(0, l.content.lineNodes!.length - 1);
    pushUndo();
    final rest = splitLineAt(l.content, sel);
    if (rest == null) {
      undo.discardLastUndoState();
      return;
    }
    if (rest.isNotEmpty) {
      final part = cloneLayer(l);
      layerCounter++;
      part
        ..id = 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter'
        ..rowId = null;
      part.content
        ..lineNodes = rest
        ..lineClosed = false
        ..lineFilled = false;
      syncLineBox(part.content);
      project.layers.insert(project.layers.indexOf(l) + 1, part);
      ensureUniqueLayerNames(project);
      normalizeTimelineRows(project);
      centerLinePivot(project, part, currentFrame);
    }
    centerLinePivot(project, l, currentFrame);
    commitEdit();
  }

  /// The other lines with a point where line `layer`'s point `i` is now
  /// (a shared station): their names.
  List<String> linesSharingPoint(Layer layer, int i) {
    final nodes = layer.content.lineNodes;
    if (nodes == null || i >= nodes.length) return const [];
    final m = getTransformBoxHandles(project, layer, currentFrame).mCanvas;
    final p = applyAffine(m, [nodes[i].x, nodes[i].y]);
    final out = <String>[];
    for (final o in project.layers) {
      if (o.id == layer.id || !isNodeLine(o.content)) continue;
      final om = getTransformBoxHandles(project, o, currentFrame).mCanvas;
      for (final n in o.content.lineNodes!) {
        final q = applyAffine(om, [n.x, n.y]);
        if ((q[0] - p[0]).abs() < 0.75 && (q[1] - p[1]).abs() < 0.75) {
          out.add(o.name);
          break;
        }
      }
    }
    return out;
  }

  /// A line's points were dragged: its pivot goes back to their middle.
  void lineEdited(String layerId) {
    final l = findLayer(project, layerId);
    if (l == null || !isNodeLine(l.content)) return;
    centerLinePivot(project, l, currentFrame);
    commitEdit();
  }

  /// Several lines selected: joins them at their nearest ends into the
  /// selected one. One undo step; false when fewer than two open lines.
  bool joinSelectedLines() {
    final lead = findLayer(project, selection.selectedLayer);
    if (lead == null || !isNodeLine(lead.content) || lead.content.lineClosed) return false;
    final others = [
      for (final id in multiSelection)
        if (findLayer(project, id) case final l? when isNodeLine(l.content) && !l.content.lineClosed) l
    ];
    if (others.isEmpty) return false;
    pushUndo();
    for (final o in others) {
      joinLines(project, lead, o, currentFrame);
      multiSelection.remove(o.id);
    }
    centerLinePivot(project, lead, currentFrame);
    normalizeTimelineRows(project);
    commitEdit();
    return true;
  }

  /// Stage settings: a blue outline around every project reference layer
  /// (editor only).
  bool showProjectOutlines = false;

  void toggleShowProjectOutlines() {
    showProjectOutlines = !showProjectOutlines;
    notifyListeners();
  }

  void toggleLayerQuickSwitch() {
    layerQuickSwitchEnabled = !layerQuickSwitchEnabled;
    notifyListeners();
  }

  void toggleTimelineEdgeAutoScroll() {
    timelineEdgeAutoScrollEnabled = !timelineEdgeAutoScrollEnabled;
    notifyListeners();
  }

  /// Unpinned timeline: the side the playhead went off to (-1 / 1), 0
  /// while it is in view.
  final ValueNotifier<int> playheadSide = ValueNotifier(0);

  /// Bumped to bring the playhead back into the timeline's view.
  final ValueNotifier<int> scrollToPlayheadRequest = ValueNotifier(0);
  void scrollToPlayhead() => scrollToPlayheadRequest.value++;

  /// Palettes tab: named colour lists (kept with the app's settings).
  List<({String name, List<String> colors})> palettes = decodePalettes(jsonEncode(defaultPalettesJson));

  void setPalettes(List<({String name, List<String> colors})> p) => setAppPreference(
      'palettes', jsonEncode([for (final x in p) {'name': x.name, 'colors': x.colors}]));

  /// The tool fields' guides, already seen (Settings shows them again;
  /// a new project can ask for them).
  bool guideBottomSeen = true;
  bool guideTopSeen = true;
  bool guideActionSeen = true;

  void showToolGuidesAgain() {
    setAppPreference('guideBottomSeen', false);
    setAppPreference('guideTopSeen', false);
    setAppPreference('guideActionSeen', false);
  }

  /// With the pin on: a tap on the pinned playhead plays / pauses.
  bool playOnPlayheadTap = false;

  void toggleTimelineCenterPlayhead() {
    timelineCenterPlayheadEnabled = !timelineCenterPlayheadEnabled;
    notifyListeners();
  }

  void toggleSnapTimelineLayers() {
    snapTimelineLayersEnabled = !snapTimelineLayersEnabled;
    notifyListeners();
  }

  void toggleKeyframeSelectKeepsPlayhead() {
    keyframeSelectKeepsPlayhead = !keyframeSelectKeepsPlayhead;
    notifyListeners();
  }

  void toggleKfMultiselect() {
    kfMultiselectMode = !kfMultiselectMode;
    notifyListeners();
  }

  /// True when every drawer toggle is on.
  bool get allTimelineToggles =>
      snapTimelineLayersEnabled &&
      layerQuickSwitchEnabled &&
      timelineEdgeAutoScrollEnabled &&
      timelineCenterPlayheadEnabled &&
      keyframeSelectKeepsPlayhead &&
      kfMultiselectMode;

  /// The drawer's "all" button: turns every toggle on, or all off when
  /// they already are.
  void toggleAllTimelineToggles() {
    final on = !allTimelineToggles;
    snapTimelineLayersEnabled = on;
    layerQuickSwitchEnabled = on;
    timelineEdgeAutoScrollEnabled = on;
    timelineCenterPlayheadEnabled = on;
    keyframeSelectKeepsPlayhead = on;
    kfMultiselectMode = on;
    notifyListeners();
  }

  void toggleTimelineDrawerExpanded() {
    timelineDrawerExpanded = !timelineDrawerExpanded;
    notifyListeners();
  }

  /// The current frame alone, for the few widgets that follow it live
  /// (the stage, the playhead, the frame counter). Playback and scrubbing
  /// change only this: the rest of the UI - panels, lists, the timeline's
  /// lanes - isn't rebuilt on every frame, it catches up once the frame
  /// rests (see setFrame's `quiet`).
  final ValueNotifier<int> frameNotifier = ValueNotifier(0);
  bool _frameUnannounced = false;

  /// `quiet` (playback ticks, scrubbing): only [frameNotifier] fires now;
  /// everything listening to the whole state hears about the new frame
  /// when the scrub ends ([frameSettled]) or playback stops.
  void setFrame(int frame, {bool quiet = false}) {
    // an empty project has nothing to move through: the head stays put.
    currentFrame = project.layers.isEmpty ? 0 : frame.clamp(0, maxFrame);
    // lines with keyed points: their points move to this frame.
    for (final l in project.layers) {
      if (l.content.lineNodes != null) syncLineToFrame(l, currentFrame);
    }
    _render();
    if (!quiet) {
      notifyListeners();
      return;
    }
    _frameUnannounced = true;
    frameNotifier.value = currentFrame;
    if (perfInstrumentation) PerfMonitor.instance.markActive();
  }

  /// A scrub ended (finger lifted, scroll stopped): the panels catch up
  /// with the frame it left.
  void frameSettled() {
    if (_frameUnannounced && !playing) notifyListeners();
  }

  /// Fits the timeline to the layers after the layer list changes (add,
  /// delete, duplicate, undo/redo, load).
  void _fitTimeline() {
    maxFrame = recomputeMaxFrameToFit(project.layers, _maxFrameFloor);
    // nothing left: no frame to stand on but 0.
    currentFrame = project.layers.isEmpty ? 0 : currentFrame.clamp(0, maxFrame);
  }

  /// direct control over the timeline's own length (there was nothing to
  /// adjust it directly). Becomes the new floor recomputeMaxFrameToFit
  /// respects going forward (see _maxFrameFloor's own doc comment).
  ///
  /// this used to immediately re-run recomputeMaxFrameToFit(clamped), which is
  /// max(clamped, furthest layer extent + 1s) - so typing a value SMALLER than
  /// existing content silently snapped back to the larger number, with zero
  /// feedback, looking completely broken. The typed value is now
  /// authoritative: it's what maxFrame actually becomes, full stop.
  /// _maxFrameFloor still updates to the same value, so a LATER drag can't
  /// shrink the timeline back below this explicit choice (see
  /// updateLayerDrag/endLayerDrag) - it just no longer overrides this
  /// direct-input path itself.
  ///
  /// Shortening it also trims every layer that would stick out past the new
  /// end they stayed past it until trimmed by hand - and the next fit grew the
  /// timeline right back, so the ruler seemed not to follow). A layer entirely
  /// past the end is moved to end there. One undo step when anything is
  /// trimmed.
  void setMaxFrame(int frame) {
    final clamped = frame.clamp(1, 1 << 30);
    final sticking = [
      for (final l in project.layers)
        if (l.startFrame + l.durationFrames > clamped) l
    ];
    if (sticking.isNotEmpty) {
      pushUndo();
      for (final l in sticking) {
        if (l.startFrame >= clamped) {
          // wholly past the end: keep its length if it fits, ending at the end.
          final dur = math.min(l.durationFrames, clamped);
          final move = (clamped - dur) - l.startFrame;
          l.startFrame += move;
          l.durationFrames = dur;
        } else {
          l.durationFrames = math.max(1, clamped - l.startFrame);
        }
      }
      clearStateCaches();
    }
    _explicitTimelineLength = clamped;
    maxFrame = clamped;
    currentFrame = currentFrame.clamp(0, maxFrame);
    _render();
    notifyListeners();
  }

  void togglePlay() {
    if (!playing && !canPlay) return;
    playing = !playing;
    _playSession++;
    _audioClock = false;
    if (perfInstrumentation) {
      playing ? PerfMonitor.instance.playbackStarted() : PerfMonitor.instance.playbackStopped();
      renderer.videoFrames.resetStats();
    }
    if (playing) {
      // loop off and already at the end: play from the start again.
      if (!loopPlayback && currentFrame >= maxFrame) setFrame(0);
      final startFrame = currentFrame;
      // with sound the player becomes the clock once it has started
      // (playTick); until then - and without sound - frames are counted
      // from real time as before.
      if (hasAudio && audioStore != null) unawaited(_startAudioClock(_playSession));
      // vsync-synced via a Ticker, replacing a fixed-period Timer.periodic -
      // the playhead visibly "teleported" unevenly during playback (0, 1, or
      // occasionally 2 steps per rendered frame) because the old ~17ms timer
      // period wasn't synced to the display's own refresh interval, beating
      // against it unpredictably. A Ticker fires once per rendered frame by
      // construction; the target frame is computed fresh from real elapsed
      // time on every tick (fps/playbackSpeed convert it to a frame count), so
      // it can never drift or double/skip a step
      // - exactly one step lands per rendered frame whenever fps
      // roughly matches the display's refresh rate, and throttles
      // correctly (e.g. advancing every other tick) on a
      // higher-refresh display instead of playing back too fast.
      _playTicker = Ticker((elapsed) => playTick(elapsed, startFrame))..start();
    } else {
      _playTicker?.stop();
      _playTicker = null;
      final p = _playback;
      if (p != null) unawaited(p.pause());
    }
    notifyListeners();
  }

  /// Layers selected together with the selected one (on the timeline:
  /// "select several", then tap lanes; in the Layers tab: long-press):
  /// they move with it on the timeline and on the stage, and light up
  /// with it. Only the main one shows its handles / indicators.
  Set<String> multiSelection = {};

  /// Timeline: tapping other lanes adds them to the selection.
  bool timelineGroupPick = false;

  void toggleTimelineGroupPick() {
    timelineGroupPick = !timelineGroupPick;
    notifyListeners();
  }

  /// The selected layer and the ones selected with it.
  Set<String> get selectedGroup => {
        if (findLayer(project, selection.selectedLayer) != null) selection.selectedLayer!,
        for (final id in multiSelection)
          if (findLayer(project, id) != null) id,
      };

  /// Adds `id` to the selection (or takes it out). With nothing selected
  /// yet it just becomes the selected layer.
  void toggleMultiSelect(String id) {
    if (selection.selectedLayer == null) {
      selectLayer(id);
      return;
    }
    if (id == selection.selectedLayer) {
      // the main one leaves: the next of the group takes its place.
      final rest = multiSelection.where((m) => m != id && findLayer(project, m) != null).toList();
      if (rest.isEmpty) return;
      selection.selectedLayer = rest.first;
      multiSelection = rest.skip(1).toSet();
    } else if (!multiSelection.remove(id)) {
      multiSelection.add(id);
    }
    notifyListeners();
  }

  // a stage drag of the selected layer: the others of the group follow
  // its move / turn / resize (values at the playhead).
  Map<Layer, ({List<double> anchor, double rot, List<double> scale})>? _groupDragStart;
  ({List<double> anchor, double rot, List<double> scale})? _groupLeaderStart;

  ({List<double> anchor, double rot, List<double> scale}) _transformAt(Layer l) {
    final f = layerLocalFrame(l, currentFrame).toDouble();
    return (
      anchor: evaluateTrack(project, l.transform.anchor, f, l) as List<double>,
      rot: evaluateTrack(project, l.transform.rotation, f, l) as double,
      scale: evaluateTrack(project, l.transform.scale, f, l) as List<double>,
    );
  }

  void beginGroupTransform() {
    final leader = findLayer(project, selection.selectedLayer);
    final group = selectedGroup;
    if (leader == null || group.length < 2) {
      _groupDragStart = null;
      return;
    }
    _groupLeaderStart = _transformAt(leader);
    _groupDragStart = {
      for (final id in group)
        if (id != leader.id) findLayer(project, id)!: _transformAt(findLayer(project, id)!),
    };
    // the middle of the members sharing the selected one's space.
    final same = [_groupLeaderStart!.anchor, for (final e in _groupDragStart!.entries) if (e.key.parentId == leader.parentId) e.value.anchor];
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final a in same) {
      x0 = math.min(x0, a[0]);
      x1 = math.max(x1, a[0]);
      y0 = math.min(y0, a[1]);
      y1 = math.max(y1, a[1]);
    }
    _groupPivot = [(x0 + x1) / 2, (y0 + y1) / 2];
  }

  void applyGroupTransform() {
    final start = _groupDragStart, lead0 = _groupLeaderStart;
    final leader = findLayer(project, selection.selectedLayer);
    if (start == null || lead0 == null || leader == null) return;
    final now = _transformAt(leader);
    final da = [now.anchor[0] - lead0.anchor[0], now.anchor[1] - lead0.anchor[1]];
    final dr = now.rot - lead0.rot;
    double ratio(int i) => lead0.scale[i] == 0 ? 1 : now.scale[i] / lead0.scale[i];
    final turned = dr != 0 || ratio(0) != 1 || ratio(1) != 1;
    // keep the group's shape: a turn / resize swings every member (the
    // selected one too) round the middle of the group, so the whole reads
    // as one figure. Only the members in the selected one's own space
    // (same parent); the others just follow as before.
    if (groupKeepsShape && turned && _groupPivot != null) {
      final w = stageSize.width, h = stageSize.height;
      final piv = _groupPivot!;
      final r0 = lead0.rot * math.pi / 180, r1 = now.rot * math.pi / 180;
      List<double> swing(List<double> a) {
        // to px, into the selected one's own axes, resized there, back out
        // turned by the new angle.
        final vx = (a[0] - piv[0]) * w, vy = (a[1] - piv[1]) * h;
        final lx = (vx * math.cos(-r0) - vy * math.sin(-r0)) * ratio(0);
        final ly = (vx * math.sin(-r0) + vy * math.cos(-r0)) * ratio(1);
        final ox = lx * math.cos(r1) - ly * math.sin(r1), oy = lx * math.sin(r1) + ly * math.cos(r1);
        return [piv[0] + ox / w, piv[1] + oy / h];
      }

      setTrackValueAt(leader.transform.anchor, layerLocalFrame(leader, currentFrame).round(), swing(lead0.anchor));
      start.forEach((l, s) {
        final f = layerLocalFrame(l, currentFrame).round();
        if (l.parentId == leader.parentId) setTrackValueAt(l.transform.anchor, f, swing(s.anchor));
        if (dr != 0) setTrackValueAt(l.transform.rotation, f, s.rot + dr);
        if (ratio(0) != 1 || ratio(1) != 1) setTrackValueAt(l.transform.scale, f, [s.scale[0] * ratio(0), s.scale[1] * ratio(1)]);
      });
      return;
    }
    start.forEach((l, s) {
      final f = layerLocalFrame(l, currentFrame).round();
      if (!turned && (da[0] != 0 || da[1] != 0)) setTrackValueAt(l.transform.anchor, f, [s.anchor[0] + da[0], s.anchor[1] + da[1]]);
      if (dr != 0) setTrackValueAt(l.transform.rotation, f, s.rot + dr);
      if (ratio(0) != 1 || ratio(1) != 1) setTrackValueAt(l.transform.scale, f, [s.scale[0] * ratio(0), s.scale[1] * ratio(1)]);
    });
  }

  /// The middle of the group when its drag began (the selected one's
  /// space): what a turn / resize keeps the shape around.
  List<double>? _groupPivot;

  /// Several selected: a turn / resize keeps the group's overall shape
  /// (each one moves its anchor round the middle) - or (off) each turns /
  /// resizes on its own spot. Scale fold.
  bool groupKeepsShape = true;

  /// Stage: a tap adds the layer to the selection (or takes it out).
  bool stageMultiSelect = false;

  /// Stage: drag a rectangle to select every layer under it.
  bool marqueeMode = false;

  /// Hold a finger still on the stage, then drag: the same rectangle.
  bool marqueeOnHold = false;

  /// Kinds the rectangle leaves out: a shape name ('rect', 'ellipse', ...),
  /// 'line', 'video', 'image', 'svg', 'text'.
  Set<String> marqueeSkip = {};

  /// Selects every layer whose drawn box touches the frame rectangle
  /// [x0, y0]-[x1, y1] (adding to the selection while picking several).
  void selectInRect(double x0, double y0, double x1, double y1, {bool add = false}) {
    final lx = math.min(x0, x1), hx = math.max(x0, x1), ly = math.min(y0, y1), hy = math.max(y0, y1);
    final hits = <String>[];
    for (final l in project.layers.reversed) {
      if (l.hidden || l.locked || isCameraShape(l.content.shape) || isAudioShape(l.content.shape)) continue;
      if (marqueeSkip.contains(marqueeKind(l))) continue;
      if (!getLayerStateAt(project, l.id, currentFrame).inRange) continue;
      final b = layerFrameBounds(project, l, currentFrame);
      if (b == null) continue;
      if (b.$1 <= hx && b.$3 >= lx && b.$2 <= hy && b.$4 >= ly) hits.add(l.id);
    }
    final keep = add ? selectedGroup.toList() : <String>[];
    final all = [...keep, for (final id in hits) if (!keep.contains(id)) id];
    if (all.isEmpty) {
      if (!add) selectLayer(null);
      return;
    }
    selectLayer(all.first);
    multiSelection = all.skip(1).toSet();
    notifyListeners();
  }

  /// The selected one's turn / resize (Movement fields): the rest of the
  /// group follows like on the stage.
  void groupEdit(void Function() edit) {
    beginGroupTransform();
    edit();
    applyGroupTransform();
    endGroupTransform();
  }

  void endGroupTransform() {
    _groupDragStart = _groupLeaderStart = null;
    _groupPivot = null;
  }

  void selectLayer(String? id) {
    multiSelection = {};
    if (id != freshFillLayerId) freshFillLayerId = null;
    if (id != selection.selectedLayer) cropLine = null; // the line belongs to its layer
    switchKeySelection(selection.selectedLayer, id, notify: false);
    selection.selectedLayer = id;
    // a keyframe selection tied to the PREVIOUS layer's tracks doesn't
    // mean anything once a different layer is selected - kfSelectedFrames
    // is a movement_core global keyed only by frame number, with no
    // layer identity of its own, so it has to be cleared explicitly here
    // rather than staying stale (matches this file's own doc comment on
    // kfSelectedFrames: clearing it on selection change is the UI
    // layer's job, not keyframe_strip.dart's).
    cropEditing = false; // crop handles belong to the layer they were opened on
    pieceInsets = null;
    selectedTextPart = null; // so does an open text part
    pieceRectTool = false;
    chromaTool = 'none'; // so do the chroma tools
    notifyListeners();
  }

  // ===== layer actions (timeline action row, Layers tab menu) =====

  /// Merges the layers `ids` into one contour layer (see mergeLayers),
  /// selected afterwards; one undo step. False when they can't be merged.
  /// Merge with pictures among the layers: all of them as one picture -
  /// what they show together at the playhead (vector shapes turned into
  /// pixels), a new picture layer in their place. One undo step.
  Future<bool> mergeLayersAsPicture(List<String> ids) async {
    final layers = [for (final id in ids) findLayer(project, id)].whereType<Layer>().toList();
    if (layers.length < 2) return false;
    final keep = {for (final l in layers) l.id};
    // drawn alone: the others hidden, no background, no stage camera, at
    // twice the frame's size (it may be scaled up later).
    final hiddenNow = [for (final l in project.layers) if (!l.hidden && !keep.contains(l.id)) l];
    for (final l in hiddenNow) {
      l.hidden = true;
    }
    final bg = renderer.backgroundColor, cam = renderer.useStageCamera, scale = renderer.outputScale;
    final cuts = renderer.stageCuts;
    ui.Image image;
    try {
      renderer
        ..backgroundColor = null
        ..useStageCamera = false
        ..stageCuts = null
        ..outputScale = 2;
      clearStateCaches();
      await renderer.prepareFrame(project, currentFrame);
      renderer.renderFrame(project, currentFrame, clipToFrame: false);
      image = await renderer.captureFrame();
    } finally {
      for (final l in hiddenNow) {
        l.hidden = false;
      }
      renderer
        ..backgroundColor = bg
        ..useStageCamera = cam
        ..stageCuts = cuts
        ..outputScale = scale;
      clearStateCaches();
      _render();
    }
    final w = image.width, h = image.height;
    final px = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose();
    if (px == null) return false;
    // what shows: its box.
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (px.getUint8((y * w + x) * 4 + 3) == 0) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    if (maxX < 0) return false;
    final bw = maxX - minX + 1, bh = maxY - minY + 1;
    final out = Uint8List(bw * bh * 4);
    final src = px.buffer.asUint8List();
    for (var y = 0; y < bh; y++) {
      out.setRange(y * bw * 4, (y + 1) * bw * 4, src, ((y + minY) * w + minX) * 4);
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(out, bw, bh, ui.PixelFormat.rgba8888, done.complete);
    final cropped = await done.future;
    final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
    cropped.dispose();
    if (png == null) return false;
    pushUndo();
    final k = w / frameWidth; // picture px per frame px
    final ordered = [...layers]..sort((a, b) => project.layers.indexOf(a).compareTo(project.layers.indexOf(b)));
    final top = ordered.last;
    final start = layers.map((l) => l.startFrame).reduce(math.min);
    final end = layers.map((l) => l.startFrame + l.durationFrames).reduce(math.max);
    final merged = createImageLayer(
        imageSourceType: 'embedded',
        imageData: base64Encode(png.buffer.asUint8List()),
        naturalWidth: bw,
        naturalHeight: bh,
        maxDimension: math.max(bw, bh) / k)
      ..id = _newLayerId()
      ..name = nextFreeLayerName(project, '${top.name} merged')
      ..folder = top.folder
      ..startFrame = start
      ..durationFrames = end - start;
    merged.content.size = [bw / k, bh / k];
    merged.transform.anchor.defaultValue = [
      (minX + bw / 2) / k / stageSize.width,
      (minY + bh / 2) / k / stageSize.height,
    ];
    project.layers.insert(project.layers.indexOf(top) + 1, merged);
    // children of a merged layer keep their place, under no parent.
    for (final l in project.layers) {
      if (l.parentId != null && keep.contains(l.parentId) && !keep.contains(l.id)) {
        reparentPreservingWorldPosition(project, l, null, currentFrame);
      }
    }
    project.layers.removeWhere((l) => keep.contains(l.id));
    normalizeTimelineRows(project);
    clearStateCaches();
    selection.selectedLayer = merged.id;
    multiSelection = {};
    commitEdit();
    return true;
  }

  bool mergeLayersById(List<String> ids) {
    final layers = [for (final id in ids) findLayer(project, id)].whereType<Layer>().toList();
    // pictures among them: one picture of them all.
    if (layers.length >= 2 &&
        layers.any(mergesAsPicture) &&
        layers.every((l) => mergeBlocker(l) == null || mergesAsPicture(l))) {
      unawaited(mergeLayersAsPicture(ids));
      return true;
    }
    if (layers.length < 2 || layers.any((l) => mergeBlocker(l) != null)) return false;
    pushUndo();
    final merged = mergeLayers(project, layers, _newLayerId(), currentFrame);
    if (merged == null) return false;
    selection.selectedLayer = merged.id;
    commitEdit();
    return true;
  }

  /// Parenting for a time only: sets (or with null clears) where the
  /// link starts / ends. One undo step.
  void setParentWindow(String layerId, {int? from, int? until, bool clearFrom = false, bool clearUntil = false}) {
    final l = findLayer(project, layerId);
    if (l == null || l.parentId == null) return;
    pushUndo();
    if (from != null || clearFrom) l.parentFrom = from;
    if (until != null || clearUntil) l.parentUntil = until;
    final a = l.parentFrom, b = l.parentUntil;
    if (a != null && b != null && a > b) {
      l.parentFrom = b;
      l.parentUntil = a;
    }
    commitEdit();
  }

  // ===== timeline range =====

  /// The Timeline tab's range selection (global frames), or null.
  ({int a, int b})? timeRange;

  /// Sets one edge of the range to the playhead (the other defaults to
  /// the timeline's start / end).
  void setTimeRangeEdge({required bool start}) {
    pushUndo();
    final r = timeRange ?? (a: 0, b: maxFrame);
    var a = start ? currentFrame : r.a, b = start ? r.b : currentFrame;
    if (a > b) (a, b) = (b, a);
    timeRange = (a: a, b: b);
    notifyListeners();
  }

  /// A range edge drag begins: one undo step for the whole drag.
  void beginRangeEdgeDrag() => pushUndo();

  /// Moves one edge of the range to `frame` (the edges can't cross).
  void setTimeRangeEdgeAt({required bool start, required int frame}) {
    final r = timeRange;
    if (r == null) return;
    final f = frame.clamp(0, maxFrame);
    timeRange = start ? (a: math.min(f, r.b - 1), b: r.b) : (a: r.a, b: math.max(f, r.a + 1));
    notifyListeners();
  }

  /// Timeline tab, "Range": on puts the range around the playhead.
  /// Settings: the range lights up only the layers in it (like selected
  /// layers), not the whole height of the timeline.
  bool rangeAsSelection = false;

  void setTimeRangeEnabled(bool on) {
    pushUndo();
    timeRange = on
        ? (a: math.max(0, currentFrame - 30), b: math.min(maxFrame, math.max(currentFrame - 30, 0) + 60))
        : null;
    notifyListeners();
  }

  // a range drag: its edges at the grab.
  ({int a, int b})? _rangeMove;

  /// Holding the range and dragging slides the range itself along the
  /// timeline (both edges); the layers stay where they are.
  void beginRangeMove() {
    final r = timeRange;
    if (r == null) return;
    pushUndo();
    _rangeMove = r;
  }

  void updateRangeMove(int delta) {
    final m = _rangeMove;
    if (m == null) return;
    final d = delta.clamp(-m.a, math.max(0, maxFrame - m.b)).toInt();
    timeRange = (a: m.a + d, b: m.b + d);
    notifyListeners();
  }

  void endRangeMove() => _rangeMove = null;

  /// Range: effect `effectId` on every layer in it, only inside it.
  int rangeAddEffect(String effectId) {
    var n = 0, k = 0;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    rangeEdit((a, b) => n = addEffectInRange(project, a, b, effectId, () => 'fx_${stamp}_${k++}'));
    return n;
  }

  /// Range: every layer in it masked by layer `sourceId`.
  int rangeAddMask(String sourceId) {
    var n = 0;
    rangeEdit((a, b) => n = addMaskInRange(project, a, b, sourceId));
    return n;
  }

  void clearTimeRange() {
    timeRange = null;
    notifyListeners();
  }

  /// Runs a range action as one undo step.
  void rangeEdit(void Function(int a, int b) edit) {
    final r = timeRange;
    if (r == null) return;
    pushUndo();
    edit(r.a, r.b);
    commitEdit();
  }

  /// Moves the selected keys (kfSelectedFrames) of the selected layer to
  /// the same parameters of layer `toId`, at the same moments; that layer
  /// becomes the selected one, its moved keys selected. One undo step.
  int moveSelectedKeysToLayer(String toId) {
    final from = findLayer(project, selection.selectedLayer), to = findLayer(project, toId);
    if (from == null || to == null || identical(from, to) || kfSelectedFrames.isEmpty) return 0;
    pushUndo();
    final frames = {...kfSelectedFrames};
    final n = moveKeysToLayer(from, to, frames);
    selectLayer(toId);
    kfSelectedFrames = frames;
    commitEdit();
    return n;
  }

  /// Movement tab: scale x and y change together.
  bool scaleLinked = true;

  // ===== layered keys =====

  /// Keyframes tab: the parameters with keys shown (folded by default).
  bool showKeyParams = false;

  void toggleShowKeyParams() {
    showKeyParams = !showKeyParams;
    notifyListeners();
  }

  /// Keyframes tab: 'base' | 'order' | 'layers' (see keyMode).
  void setKeyMode(String mode, {String? layerId}) {
    keyMode = mode;
    final l = findLayer(project, layerId ?? selection.selectedLayer);
    activeAnimLayer = switch (mode) {
      'base' => 0,
      'order' => l == null ? 0 : (openOrderLayer(l) ?? 0),
      _ => l == null || l.transform.anchor.animLayers.isEmpty ? 0 : (activeAnimLayer == 0 ? 1 : activeAnimLayer),
    };
    notifyListeners();
  }

  void setActiveAnimLayer(int n) {
    activeAnimLayer = n;
    notifyListeners();
  }

  /// A new animation layer on `layerId`'s transform, made the one edited.
  void addAnimLayer(String layerId) {
    final l = findLayer(project, layerId);
    if (l == null) return;
    pushUndo();
    activeAnimLayer = addTransformAnimLayer(l);
    commitEdit();
  }

  void removeAnimLayer(String layerId, int n) {
    final l = findLayer(project, layerId);
    if (l == null) return;
    pushUndo();
    removeTransformAnimLayer(l, n);
    activeAnimLayer = 0;
    commitEdit();
  }

  void setAnimLayerEnabled(String layerId, int n, bool on) {
    final l = findLayer(project, layerId);
    if (l == null) return;
    pushUndo();
    setTransformAnimLayerEnabled(l, n, on);
    commitEdit();
  }

  // ===== stage camera =====

  /// The stage shows the picture through the camera (no handles then).
  bool cameraView = false;

  void setCameraView(bool on) {
    cameraView = on;
    renderer.useStageCamera = on;
    cameraViewActive = on;
    _render();
    notifyListeners();
  }

  /// Adds a stage camera (as long as the timeline), selected.
  void addStageCamera() {
    pushUndo();
    final cam = createCameraLayer(frameWidth, frameHeight, durationFrames: math.max(1, maxFrame));
    project.layers.add(cam);
    normalizeTimelineRows(project);
    focusNewLayer(cam.id);
    commitEdit();
  }

  String _newLayerId() {
    layerCounter++;
    return 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter';
  }

  /// Splits the layer at the playhead (see movement_core's splitLayer).
  /// No-op unless the playhead is strictly inside the layer.
  void splitLayerAtPlayhead(String id) {
    final layer = findLayer(project, id);
    if (layer == null) return;
    final s = currentFrame - layer.startFrame;
    if (s <= 0 || s >= layer.durationFrames) return;
    pushUndo();
    final right = splitLayer(project, layer, currentFrame, _newLayerId());
    if (right != null) selection.selectedLayer = right.id;
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Moves the layer so it starts at the playhead.
  void moveLayerStartToPlayhead(String id) {
    final layer = findLayer(project, id);
    if (layer == null || layer.startFrame == currentFrame) return;
    pushUndo();
    shiftTimeLinked(project, layer, currentFrame); // linked layers come along
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Extends or shrinks the layer to the playhead: past the end -> the
  /// end moves out to it; before the start -> the start moves back to
  /// it; inside -> the nearer edge moves in to it. Same keyframe
  /// behaviour as dragging that edge on the timeline.
  void fitLayerEdgeToPlayhead(String id) {
    final layer = findLayer(project, id);
    if (layer == null) return;
    final start = layer.startFrame, end = layer.startFrame + layer.durationFrames;
    final f = currentFrame;
    final LayerDragMode mode;
    if (f > end) {
      mode = LayerDragMode.trimRight;
    } else if (f < start) {
      mode = LayerDragMode.trimLeft;
    } else if (f == start || f == end) {
      return;
    } else {
      mode = (f - start) <= (end - f) ? LayerDragMode.trimLeft : LayerDragMode.trimRight;
    }
    pushUndo();
    _grabTrack(layer, mode)
        .apply(mode == LayerDragMode.trimLeft ? f - start : f - end);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Swaps a layer's shape/media, keeping every parameter.
  void replaceLayerContentWith(String id, Content content) {
    final layer = findLayer(project, id);
    if (layer == null) return;
    pushUndo();
    replaceLayerContent(layer, content);
    _render();
    notifyListeners();
  }

  /// Copy/paste parameters (Layers tab): everything except the shape and
  /// the timing - see movement_core's layerParamsToJson.
  Map<String, dynamic>? copiedLayerParams;

  void copyLayerParamsOf(String id) {
    final layer = findLayer(project, id);
    if (layer == null) return;
    copiedLayerParams = layerParamsToJson(layer);
    notifyListeners();
  }

  void pasteLayerParamsInto(String id) => applyParamsTo(id, copiedLayerParams);

  /// Applies a parameter snapshot (a copied one or a preset) as one undo
  /// step.
  void applyParamsTo(String id, Map<String, dynamic>? params) {
    final layer = findLayer(project, id);
    if (layer == null || params == null) return;
    pushUndo();
    applyLayerParamsJson(project, layer, params);
    _render();
    notifyListeners();
  }

  /// Where presets are kept - across every project. Null in tests that
  /// don't use it; the Presets tab says so.
  PresetStore? presetStore;

  /// Animation presets (keyed animation only) - a separate list.
  PresetStore? get animationPresetStore =>
      presetStore == null ? null : PresetStore(presetStore!.root, folder: 'animation_presets');

  /// Applies an animation preset so it starts at the playhead.
  void applyAnimationPresetTo(String id, Map<String, dynamic> preset) {
    final layer = findLayer(project, id);
    if (layer == null) return;
    pushUndo();
    applyAnimationPreset(project, layer, preset, localFrameOf(layer, currentFrame));
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// The copy-effect clipboard (one Effects-list entry as JSON).
  Map<String, dynamic>? copiedEffect;

  void copyEffectEntry(String layerId, String entryId) {
    final layer = findLayer(project, layerId);
    if (layer == null) return;
    copiedEffect = effectEntryToJson(layer, entryId);
    notifyListeners();
  }

  void pasteEffectInto(String layerId) {
    final layer = findLayer(project, layerId);
    final clip = copiedEffect;
    if (layer == null || clip == null) return;
    pushUndo();
    pasteEffectEntry(layer, clip);
    _render();
    notifyListeners();
  }

  // ===== chroma key (Chroma tab) =====

  /// Chroma tab stage tool: 'none' | 'pick' | 'region' (movement_core's
  /// chromaTool global, so the painter/gestures read it directly).
  /// Chroma tab, the contrast view: the layer shows exactly what its keys
  /// keep (white) and remove (black). Never part of an export.
  void setChromaMatteView(String? layerId) {
    renderer.chromaMatteLayerId = layerId;
    _render();
    notifyListeners();
  }

  void setChromaTool(String tool) {
    chromaTool = tool;
    notifyListeners();
  }

  /// Edits the selected layer's chroma key as one undo step.
  void editChromaKey(String layerId, void Function(ChromaKey ck) edit) {
    final layer = findLayer(project, layerId);
    if (layer == null) return;
    pushUndo();
    edit(layer.chromaKey);
    _render();
    notifyListeners();
  }

  /// Chroma "Submit": the current key joins the list of removed colours
  /// and the editor is free for the next colour.
  void submitChromaKeyOf(String layerId) {
    final layer = findLayer(project, layerId);
    if (layer == null || !layer.chromaKey.enabled) return;
    // the contrast view ends with the colour it was for.
    if (renderer.chromaMatteLayerId == layerId) renderer.chromaMatteLayerId = null;
    editChromaKey(layerId, submitChromaKey);
  }

  /// Hides / shows one removed colour (without deleting it).
  void toggleAppliedChromaKey(String layerId, int index) => editChromaKey(layerId, (ck) {
        if (index >= 0 && index < ck.applied.length) ck.applied[index].enabled = !ck.applied[index].enabled;
      });

  void deleteAppliedChromaKey(String layerId, int index) => editChromaKey(layerId, (ck) {
        if (index >= 0 && index < ck.applied.length) ck.applied.removeAt(index);
      });

  /// Commits a drawn region (image fractions) and switches the key to it.
  void setChromaRegion(String layerId, List<List<double>> uv) {
    if (uv.length < 3) return;
    editChromaKey(layerId, (ck) {
      ck.region = [for (final p in uv) [...p]];
      ck.scope = 'region';
    });
  }

  /// Eyedropper: the key colour becomes the image's colour under the
  /// frame point (the original, unkeyed pixels).
  /// Masks tab, edge matte: the background colour to take out, picked on
  /// the stage with the loupe (from the original picture).
  Future<void> pickMatteColorAt(String layerId, List<double> framePoint) async {
    final layer = findLayer(project, layerId);
    if (layer == null) return;
    final uv = framePointToImageUv(project, layer, currentFrame, framePoint);
    if (uv[0] < 0 || uv[0] > 1 || uv[1] < 0 || uv[1] > 1) return;
    final rgb = await renderer.sampleImageRgb(layer, currentFrame, uv[0], uv[1]);
    chromaTool = 'none';
    if (rgb == null) {
      notifyListeners();
      return;
    }
    pushUndo();
    layer
      ..edgeMatte = true
      ..edgeMatteColor = rgbHex(rgb[0], rgb[1], rgb[2]);
    commitEdit();
  }

  Future<void> pickChromaColorAt(String layerId, List<double> framePoint) async {
    final layer = findLayer(project, layerId);
    if (layer == null) return;
    final uv = framePointToImageUv(project, layer, currentFrame, framePoint);
    if (uv[0] < 0 || uv[0] > 1 || uv[1] < 0 || uv[1] > 1) return;
    final rgb = await renderer.sampleImageRgb(layer, currentFrame, uv[0], uv[1]);
    if (rgb == null) return;
    editChromaKey(layerId, (ck) {
      ck.color = rgbHex(rgb[0], rgb[1], rgb[2]);
      ck.seed = [...uv]; // where "connected only" starts
      ck.enabled = true;
    });
  }

  /// Settings: the project's frame rate. Re-times layers and keys so the
  /// animation keeps its real speed; the timeline, playhead and set
  /// timeline length follow. Undo history is cleared - its snapshots are
  /// timed for the old rate.
  void setProjectFps(int newFps) {
    if (newFps <= 0 || newFps == fps) return;
    final k = newFps / fps;
    retimeProject(project, newFps);
    if (_explicitTimelineLength != null) {
      _explicitTimelineLength = (_explicitTimelineLength! * k).round();
    }
    currentFrame = (currentFrame * k).round();
    undo.clearHistory();
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Settings tab: hides the icons over the top of the stage.
  bool hideStageIcons = false;

  void toggleHideStageIcons() {
    hideStageIcons = !hideStageIcons;
    notifyListeners();
  }

  // ===== crop & mirror (Crop tab) =====

  Layer? get _selected => findLayer(project, selection.selectedLayer);

  /// Crop tab: the stage rectangle tool for detaching a piece.
  void togglePieceRectTool() {
    pieceRectTool = !pieceRectTool;
    if (pieceRectTool) {
      cropEditing = false;
      pieceInsets = null;
    }
    notifyListeners();
  }

  /// Crop tab, Detach a piece: the part set like a crop (four sides and
  /// handles on the stage), then detached with a button.
  void togglePieceCropTool() {
    pieceInsets = pieceInsets == null ? [0.25, 0.25, 0.25, 0.25] : null;
    if (pieceInsets != null) {
      cropEditing = false;
      pieceRectTool = false;
    }
    notifyListeners();
  }

  /// One side of the piece rect (0..0.95), kept from crossing the other.
  void setPieceInset(int i, double v) {
    final p = pieceInsets;
    if (p == null) return;
    final other = p[i < 2 ? i + 2 : i - 2];
    p[i] = v.clamp(0.0, math.max(0.0, 0.95 - other)).toDouble();
    notifyListeners();
  }

  /// Detaches the piece rect; the tool closes.
  Layer? detachPieceInsets(String layerId) {
    if (pieceInsets == null) return null;
    final piece = _detach(layerId, (l) => pieceRectRing(l));
    pieceInsets = null;
    notifyListeners();
    return piece;
  }

  /// Detaches `region` (content-local) of a layer into a new layer above
  /// it and selects the new one. One undo step.
  Layer? _detach(String layerId, List<List<double>> Function(Layer layer) region) {
    final layer = findLayer(project, layerId);
    if (layer == null) return null;
    undo.pushUndoState(project);
    final piece = detachPiece(project, layer, region(layer), _newLayerId());
    if (piece == null) {
      undo.discardLastUndoState();
      return null;
    }
    selectLayer(piece.id);
    _fitTimeline();
    _render();
    notifyListeners();
    return piece;
  }

  /// The quick tool: a rectangle dragged on the stage (frame corners).
  Layer? detachPieceRect(String layerId, List<double> a, List<double> b) {
    if ((a[0] - b[0]).abs() < 2 || (a[1] - b[1]).abs() < 2) return null; // a tap, not a rectangle
    pieceRectTool = false;
    return _detach(layerId, (l) => rectRegion(project, l, currentFrame, a, b));
  }

  // ===== crop lines (Crop tab) =====

  /// The line being drawn over the selected layer (frame points; null:
  /// the tool is off). It is not a layer: nothing of it is saved, it
  /// lives until it is applied or cancelled.
  List<List<double>>? cropLine;

  /// Closed: the area inside it; open: the side on its left.
  bool cropLineClosed = false;

  /// The other side (everything but the marked area).
  bool cropLineInvert = false;

  void startCropLine() {
    cropLine = [];
    cropLineClosed = false;
    cropLineInvert = false;
    pieceRectTool = false;
    notifyListeners();
  }

  void cancelCropLine() {
    cropLine = null;
    notifyListeners();
  }

  /// A tap: one more point, pulled onto what is near (`radius`, frame px).
  void cropLineTap(List<double> framePoint, double radius) {
    final line = cropLine;
    final layer = findLayer(project, selection.selectedLayer);
    if (line == null || layer == null) return;
    line.add(snapCropLinePoint(project, layer, currentFrame, framePoint, radius));
    notifyListeners();
  }

  /// A point dragged.
  void moveCropLinePoint(int i, List<double> framePoint, double radius) {
    final line = cropLine;
    final layer = findLayer(project, selection.selectedLayer);
    if (line == null || layer == null || i < 0 || i >= line.length) return;
    line[i] = snapCropLinePoint(project, layer, currentFrame, framePoint, radius);
    notifyListeners();
  }

  void undoCropLinePoint() {
    if (cropLine?.isNotEmpty ?? false) cropLine!.removeLast();
    notifyListeners();
  }

  void setCropLineClosed(bool v) {
    cropLineClosed = v;
    notifyListeners();
  }

  void setCropLineInvert(bool v) {
    cropLineInvert = v;
    notifyListeners();
  }

  /// The marked area in the selected layer's own space (empty: not
  /// enough points).
  List<List<double>> cropLineRegion(Layer layer) {
    final line = cropLine;
    if (line == null || line.length < 2) return const [];
    return cutLineRegion(layer, frameToLayerLocal(project, layer, currentFrame, line), closed: cropLineClosed);
  }

  /// Applies the line: the marked area (the other side when inverted) is
  /// erased - or becomes a new layer of its own (`extract`), the rest
  /// staying. One undo step; the line is gone after.
  Layer? applyCropLine({required bool extract}) {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null) return null;
    final region = cropLineRegion(layer);
    if (region.length < 3) return null;
    Layer? piece;
    if (extract) {
      piece = _detach(layer.id, (_) => region);
      // inverted: the new layer takes everything but the area.
      if (piece != null && cropLineInvert) {
        piece.pieceClips.last.inside = false;
        layer.pieceClips.last.inside = true;
        if (recenterDetachedPieces) recenterPiece(project, piece);
        clearStateCaches();
      }
    } else {
      undo.pushUndoState(project);
      layer.pieceClips.add(PieceClip(points: region, inside: cropLineInvert));
      clearStateCaches();
    }
    cropLine = null;
    _render();
    notifyListeners();
    return piece;
  }

  /// The precise tool: the current shape of another layer.
  Layer? detachPieceByLayer(String layerId, String referenceId) {
    final ref = findLayer(project, referenceId);
    if (ref == null || referenceId == layerId) return null;
    return _detach(layerId, (l) => layerShapeRegion(project, l, ref, currentFrame));
  }

  /// Puts back all of a layer's own cuts (the detached pieces stay).
  void clearPieceCuts(String layerId) {
    final layer = findLayer(project, layerId);
    if (layer == null || layer.pieceClips.isEmpty) return;
    pushUndo();
    layer.pieceClips.clear();
    _render();
    notifyListeners();
  }

  void toggleCropEditing() {
    cropEditing = !cropEditing;
    notifyListeners();
  }

  void setCropAspect(String aspect) {
    final layer = _selected;
    if (layer == null) return;
    pushUndo();
    layer.cropAspect = aspect;
    fitCropToAspect(project, layer, currentFrame);
    commitEdit();
  }

  /// Sets one inset (0 left, 1 top, 2 right, 3 bottom), keeping at least
  /// 5% of the box visible on that axis.
  void setCropInset(int side, double value) {
    if (_selected == null) return;
    pushUndo();
    setCropInsetLive(side, value);
  }

  /// setCropInset without its own undo step (slider drags push one when
  /// the drag starts).
  void setCropInsetLive(int side, double value) {
    final layer = _selected;
    if (layer == null) return;
    final opposite = layer.crop[(side + 2) % 4];
    layer.crop[side] = value.clamp(0.0, 0.95 - opposite);
    commitEdit();
  }

  /// Crop tab: fits the selected object's visible part to the whole
  /// frame ('fit' | 'fill' | 'stretch') - one undo step.
  void fitSelectedToStage(String mode) {
    final layer = _selected;
    if (layer == null) return;
    pushUndo();
    fitLayerToStage(project, layer, currentFrame, mode);
    commitEdit();
  }

  void resetCrop() {
    final layer = _selected;
    if (layer == null) return;
    pushUndo();
    layer.crop = [0.0, 0.0, 0.0, 0.0];
    commitEdit();
  }

  void toggleMirror({required bool horizontal}) {
    final layer = _selected;
    if (layer == null) return;
    pushUndo();
    if (isNodeLine(layer.content)) {
      // a line flips its own points (its handles on the stage with them).
      flipLineNodes(layer.content, horizontal: horizontal);
    } else if (horizontal) {
      layer.mirrorX = !layer.mirrorX;
    } else {
      layer.mirrorY = !layer.mirrorY;
    }
    // "Move it too": its place flips with it - about the frame's middle
    // (about its parent for a child), keys included.
    if (mirrorMovesLayer) {
      final i = horizontal ? 0 : 1;
      List<double> flip(dynamic v) {
        final p = [...(v as List).map((x) => (x as num).toDouble())];
        p[i] = layer.parentId == null ? 1 - p[i] : -p[i];
        return p;
      }

      final t = layer.transform.anchor;
      t.defaultValue = flip(t.defaultValue);
      for (final k in t.keyframes) {
        k.value = flip(k.value);
      }
      if (t.spatial) autoComputeTangents(t);
    }
    commitEdit();
  }

  /// Crop tab, Mirror: flipping a layer moves it to the mirror place too.
  bool mirrorMovesLayer = false;

  // ===== Drawing tab =====

  /// The stage tool of the Drawing tab: 'none' | 'fill'.
  String drawTool = 'none';

  // ===== free move (Keyframes tab) =====

  /// Free move: the stage records where the selected object is dragged
  /// (its middle, frame px); confirming makes it a key layer.
  bool freeMoveRecording = false;
  List<List<double>> freeMovePath = [];

  /// How long the recorded move takes, seconds.
  double freeMoveSeconds = 1.0;

  // the drag's hold on the object: finger to its middle.
  List<double> _freeMoveGrab = const [0, 0];

  void startFreeMove() {
    if (findLayer(project, selection.selectedLayer) == null) return;
    freeMoveRecording = true;
    freeMovePath = [];
    stageNotice.value = 'Drag the object along its way, then Confirm';
    notifyListeners();
  }

  void cancelFreeMove() {
    freeMoveRecording = false;
    freeMovePath = [];
    notifyListeners();
  }

  void setFreeMoveSeconds(double s) {
    freeMoveSeconds = s.clamp(0.05, 600.0).toDouble();
    notifyListeners();
  }

  /// A new drag: it starts from where the object stands (a drag again
  /// draws the path anew).
  void beginFreeMoveStroke(List<double> p) {
    final l = findLayer(project, selection.selectedLayer);
    if (l == null) return;
    final c = computeLayerFrameGeometry(project, l, currentFrame, includeVertices: false).center;
    _freeMoveGrab = [c[0] - p[0], c[1] - p[1]];
    freeMovePath = [c];
    notifyListeners();
  }

  void addFreeMovePoint(List<double> p) {
    if (freeMovePath.isEmpty) return;
    final q = [p[0] + _freeMoveGrab[0], p[1] + _freeMoveGrab[1]];
    final last = freeMovePath.last;
    if ((q[0] - last[0]).abs() < 0.5 && (q[1] - last[1]).abs() < 0.5) return;
    freeMovePath = [...freeMovePath, q];
    notifyListeners();
  }

  /// The recorded path as a key layer: two keys, `freeMoveSeconds` apart
  /// from the playhead, the curve in their handles.
  void confirmFreeMove() {
    final l = findLayer(project, selection.selectedLayer);
    if (l == null || freeMovePath.length < 2) {
      cancelFreeMove();
      return;
    }
    pushUndo();
    final keep = activeAnimLayer;
    final n = addFreeMoveLayer(project, l, freeMovePath, currentFrame, math.max(1, (freeMoveSeconds * fps).round()));
    activeAnimLayer = keep;
    freeMoveRecording = false;
    freeMovePath = [];
    if (n == 0) {
      undo.discardLastUndoState();
      notifyListeners();
      return;
    }
    _notice('Key layer $n: the free move');
    _fitTimeline();
    commitEdit();
  }

  /// Drawing: a new trail point in the middle of the stage, selected.
  void addTrailPoint() {
    undo.pushUndoState(project);
    final layer = createTrailLayer(width: 6 * _resolutionScale, color: fillColor.length >= 7 ? fillColor.substring(0, 7) : '#ffffff');
    nameNewLayer(project, layer);
    _fitNewLayerToLength(layer);
    project.layers.add(layer);
    selection.groupSelection.clear();
    selectLayer(layer.id);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Fill: what bounds it - only the selected layers (else all of them),
  /// its colour, and a hole through everything under it instead.
  bool fillOnlySelected = false;
  String fillColor = '#ff8a65';
  bool fillDig = false;

  void setDrawTool(String t) {
    drawTool = t;
    cropLine = null;
    notifyListeners();
  }

  void setFillOptions({bool? onlySelected, String? color, bool? dig}) {
    if (onlySelected != null) fillOnlySelected = onlySelected;
    if (color != null) fillColor = color;
    if (dig != null) fillDig = dig;
    notifyListeners();
  }

  /// The last fill, said for a moment in the stage's corner.
  final ValueNotifier<String?> fillNotice = ValueNotifier(null);

  void _notice(String text) {
    fillNotice.value = text;
    Future.delayed(const Duration(seconds: 3), () {
      if (fillNotice.value == text) fillNotice.value = null;
    });
  }

  /// A fill tap at frame point `p` (as the stage shows it): the region
  /// there, bounded by the layers' own vector outlines (crop, cuts,
  /// masks, flips, deformations as they are), as a new shape on top of
  /// everything.
  Layer? fillAt(List<double> p) {
    var at = p;
    // seen through the stage camera: the point back in the scene.
    final view = renderer.useStageCamera ? cameraViewMatrix(project, currentFrame, frameWidth, frameHeight) : null;
    if (view != null) at = applyAffine(invertAffine(view), p);
    final plan = planFill(project, currentFrame, at, only: fillOnlySelected ? selectedGroup : null);
    final region = plan.region;
    if (region.isEmpty || windingNumber(region, at[0], at[1]) == 0) {
      _notice('Nothing to fill there');
      return null;
    }
    undo.pushUndoState(project);
    final layer = addFillShape(project, region, _newLayerId(), color: fillColor, dig: fillDig);
    _notice('${layer.name} filled');
    _fitTimeline();
    _render();
    notifyListeners();
    return layer;
  }

  /// The mirror line on the stage (two frame points; null: off): the
  /// selected layers are mirrored across it.
  List<List<double>>? mirrorLine;

  void startMirrorLine() {
    final w = stageSize.width, h = stageSize.height;
    mirrorLine = [
      [w / 2, h * 0.15],
      [w / 2, h * 0.85],
    ];
    notifyListeners();
  }

  void cancelMirrorLine() {
    mirrorLine = null;
    notifyListeners();
  }

  /// End `i` (0, 1) dragged - or the whole line (2: by its middle, by
  /// `delta`). Snaps onto points, and straight / 45 degrees.
  void moveMirrorLine(int i, List<double> framePoint, double radius, {List<double>? delta}) {
    final line = mirrorLine;
    if (line == null) return;
    if (i == 2 && delta != null) {
      for (final p in line) {
        p[0] += delta[0];
        p[1] += delta[1];
      }
    } else if (i == 0 || i == 1) {
      line[i] = snapMirrorLineEnd(project, currentFrame, framePoint, line[1 - i], radius);
    }
    notifyListeners();
  }

  /// Mirrors the selected layers across the line. One undo step; the
  /// line stays for another go.
  void applyMirrorLine() {
    final line = mirrorLine;
    if (line == null) return;
    final ids = selectedGroup;
    if (ids.isEmpty) return;
    undo.pushUndoState(project);
    for (final id in ids) {
      final l = findLayer(project, id);
      if (l == null) continue;
      mirrorLayerAcross(l, line[0], line[1]);
      if (l.transform.anchor.spatial) autoComputeTangents(l.transform.anchor);
    }
    clearStateCaches();
    commitEdit();
  }

  void toggleHidden(String id) {
    final layer = findLayer(project, id);
    if (layer == null) return;
    undo.pushUndoState(project);
    layer.hidden = !layer.hidden;
    _render();
    notifyListeners();
  }

  /// New shapes/images are sized relative to the frame (real device
  /// report: at high resolutions they came out tiny) - the sizes that
  /// look right on the 480px default, scaled by the frame's short side.
  double get _resolutionScale => math.min(frameWidth, frameHeight) / 480;

  /// A new shape/text/image layer is no longer than a timeline length the
  /// user set: adding one doesn't silently grow a timeline they shortened.
  /// It starts where the playhead is.
  void _fitNewLayerToLength(Layer layer) {
    layer.startFrame = currentFrame;
    final length = _explicitTimelineLength;
    if (length != null && layer.startFrame + layer.durationFrames > length) {
      layer.durationFrames = math.max(1, length - layer.startFrame);
    }
  }

  void addLayer(String presetShape) {
    undo.pushUndoState(project);
    final layer = createLayer(presetShape, size: 46 * _resolutionScale);
    nameNewLayer(project, layer); // first free number of its type
    _fitNewLayerToLength(layer);
    project.layers.add(layer);
    focusNewLayer(layer.id);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Shapes window: a new shape is drawn on the stage - a box dragged
  /// anywhere, any size (a line from where the drag starts to where it
  /// ends) - instead of appearing in the middle.
  bool placeOnStage = false;

  /// The shape waiting for its box on the stage (null: none).
  String? pendingPlaceShape;

  void startPlacing(String shape) {
    pendingPlaceShape = shape;
    _pendingLinePoint = null;
    stageNotice.value =
        shape == 'line' ? 'Tap the stage: each tap is a point of the line (Done when finished)' : 'Drag a box on the stage for it';
    notifyListeners();
  }

  void cancelPlacing() {
    pendingPlaceShape = null;
    _pendingLinePoint = null;
    notifyListeners();
  }

  /// Shapes window: a drawn box stays square.
  bool placeSquare = false;

  /// Drawing a line by taps: its first point, waiting for the second.
  List<double>? _pendingLinePoint;

  /// A tap while drawing a line: the first tap marks the start, the second
  /// makes the line (the usual width); more taps add points until Done.
  void placeLinePoint(List<double> p) {
    final first = _pendingLinePoint;
    if (first == null) {
      _pendingLinePoint = p;
      notifyListeners();
      return;
    }
    if ((first[0] - p[0]).abs() < 2 && (first[1] - p[1]).abs() < 2) return;
    _pendingLinePoint = null;
    pendingPlaceShape = null;
    addLayer('line');
    final l = project.layers.last;
    final cx = (first[0] + p[0]) / 2, cy = (first[1] + p[1]) / 2;
    final anchor = anchorLocalFromScreen(project, l, cx, cy, currentFrame);
    setTrackValueAt(l.transform.anchor, layerLocalFrame(l, currentFrame).round(), anchor);
    clearStateCaches();
    final c = l.content
      ..lineNodes = [LineNode(first[0] - cx, first[1] - cy), LineNode(p[0] - cx, p[1] - cy)]
      ..lineWidth = 4;
    syncLineBox(c);
    lineSelectedPoint = 1;
    lineTapAdd = true;
    commitEdit();
  }

  /// The first tapped point of a line being drawn (the stage marks it).
  List<double>? get pendingLinePoint => _pendingLinePoint;

  /// The new shape in the frame box from `a` to `b` (frame px).
  void placeShapeIn(List<double> a, List<double> b) {
    final shape = pendingPlaceShape;
    pendingPlaceShape = null;
    if (shape == null) return;
    final w = (b[0] - a[0]).abs(), h = (b[1] - a[1]).abs();
    if (w < 2 && h < 2) {
      notifyListeners();
      return;
    }
    addLayer(shape);
    final l = project.layers.last;
    final cx = (a[0] + b[0]) / 2, cy = (a[1] + b[1]) / 2;
    final anchor = anchorLocalFromScreen(project, l, cx, cy, currentFrame);
    setTrackValueAt(l.transform.anchor, layerLocalFrame(l, currentFrame).round(), anchor);
    clearStateCaches();
    final c = l.content;
    if (isNodeLine(c)) {
      // from where the finger went down to where it came up.
      c.lineNodes = [LineNode((a[0] - cx), (a[1] - cy)), LineNode((b[0] - cx), (b[1] - cy))];
      syncLineBox(c);
      lineSelectedPoint = 1;
      // more points by tapping, Done to stop.
      lineTapAdd = true;
    } else {
      c
        ..offset = [0, 0]
        ..size = [math.max(2, w), math.max(2, h)];
    }
    commitEdit();
  }

  // ===== vector text (Text tab) =====

  /// Where loaded fonts are kept (null in tests that don't use it).
  FontStore? fontStore;

  /// Adds a text layer at the frame centre, sized to the resolution.
  void addTextLayer() {
    undo.pushUndoState(project);
    final layer = createTextLayer(fontSize: (48 * _resolutionScale).roundToDouble());
    nameNewLayer(project, layer); // first free number of its type
    _fitNewLayerToLength(layer);
    project.layers.add(layer);
    focusNewLayer(layer.id);
    _fitTimeline();
    _render();
    notifyListeners();
    showTab('Text'); // straight on to typing it
  }

  // ===== tab requests =====

  /// The params tab the UI was last asked to open (see showTab).
  String? requestedTab;

  /// Bumps on every showTab call; the tab sheets listen to it.
  final ValueNotifier<int> tabRequests = ValueNotifier(0);

  /// Asks the params sheet / drawer to switch to tab `name`.
  /// A just-added layer is selected on its own - not added to the
  /// layers selected before (a "select several" mode that is on stays on).
  void focusNewLayer(String id) {
    selection.groupSelection.clear();
    selectLayer(id);
    final l = findLayer(project, id);
    // a shape or a picture: a Fill button in the stage's corner until it
    // is let go.
    if (l != null && l.content.shape != 'text' && l.content.shape != 'audio' && l.content.shape != 'line') {
      freshFillLayerId = id;
    }
  }

  /// Filters, Match Color: the layer's colour wheels set so its colours
  /// take on those of what is under it. False: nothing to match.
  Future<bool> matchColor(String layerId) async {
    final layer = findLayer(project, layerId);
    if (layer == null) return false;
    final st = await renderer.matchColorStats(project, layer, currentFrame);
    if (st == null) return false;
    undo.pushUndoState(project);
    matchColorInto(layer.filters, st.srcMean, st.srcDev, st.dstMean, st.dstDev);
    commitEdit();
    return true;
  }

  /// The new layer showing the stage's Fill button (gone once another
  /// layer, or none, is selected - it never comes back).
  String? freshFillLayerId;

  void showTab(String name, {bool open = true}) {
    requestedTab = name;
    tabRequestOpens = open;
    tabRequests.value++;
  }

  /// Whether the last showTab may open a closed sheet (false: the tab is
  /// only picked for the next time it opens).
  bool tabRequestOpens = true;

  /// Masks `targetId` with the text layer `textId` (its letters become the
  /// target's outline) or, with `on` false, removes those masks. One undo
  /// step.
  void setTextMask(String textId, String targetId, bool on) {
    final target = findLayer(project, targetId);
    if (target == null || targetId == textId) return;
    final has = target.masks.any((m) => m.sourceLayerId == textId);
    if (has == on) return;
    pushUndo();
    if (on) {
      target.masks.add(Mask(sourceLayerId: textId));
    } else {
      target.masks.removeWhere((m) => m.sourceLayerId == textId);
    }
    commitEdit();
  }

  /// Edits a text layer's style/text as one undo step.
  void editText(String layerId, void Function(TextSpec t) edit) {
    final t = findLayer(project, layerId)?.content.text;
    if (t == null) return;
    pushUndo();
    edit(t);
    _autoBox(layerId);
    _render();
    notifyListeners();
  }

  /// The text layers a style edit of `layerId` goes to: with several
  /// texts selected together, all of them (font, size, colours, outline,
  /// shadow, background...); otherwise just it.
  List<TextSpec> textStyleTargets(String layerId) {
    final group = selectedGroup;
    if (!group.contains(layerId) || group.length < 2) {
      final t = findLayer(project, layerId)?.content.text;
      return t == null ? const [] : [t];
    }
    return [
      for (final id in [layerId, ...group.where((g) => g != layerId)])
        if (findLayer(project, id)?.content.text case final t?) t
    ];
  }

  /// A style edit for every selected text (see textStyleTargets). One
  /// undo step.
  void editTextAll(String layerId, void Function(TextSpec t) edit) {
    final ts = textStyleTargets(layerId);
    if (ts.isEmpty) return;
    pushUndo();
    for (final t in ts) {
      edit(t);
    }
    for (final id in selectedGroup.contains(layerId) ? selectedGroup : {layerId}) {
      _autoBox(id);
    }
    _render();
    notifyListeners();
  }

  /// The live (no undo step) form of [editTextAll].
  void editTextLiveAll(String layerId, void Function(TextSpec t) edit) {
    final ts = textStyleTargets(layerId);
    if (ts.isEmpty) return;
    for (final t in ts) {
      edit(t);
    }
    for (final id in selectedGroup.contains(layerId) ? selectedGroup : {layerId}) {
      _autoBox(id);
    }
    _render();
    notifyListeners();
  }

  /// Text groups: a layer for each group of the text that has none.
  void addTextGroupLayersOf(String layerId) {
    final l = findLayer(project, layerId);
    if (l == null) return;
    pushUndo();
    final made = addTextGroupLayers(project, l);
    if (made.isNotEmpty) focusNewLayer(made.first.id);
    commitEdit();
  }

  /// Text: the text becomes a layer per word / letter (`by`: 'word' |
  /// 'char'), each where its letters were; the first is selected.
  void separateTextLayers(String layerId, String by) {
    final l = findLayer(project, layerId);
    if (l == null) return;
    pushUndo();
    final made = splitTextIntoLayers(project, l, by, currentFrame);
    if (made.isEmpty) {
      undo.discardLastUndoState();
      _notice('Nothing to separate: one ${by == 'char' ? 'letter' : 'word'}');
      return;
    }
    selection.groupSelection
      ..clear()
      ..addAll(made.map((m) => m.id));
    selectLayer(made.first.id);
    commitEdit();
  }

  // auto box: the box follows the text.
  void _autoBox(String layerId) {
    final l = findLayer(project, layerId);
    final t = l?.content.text;
    if (l == null || t == null || !t.autoBox) return;
    l.content.size = fitTextBoxAll(t);
  }

  /// Live edit without an undo step (slider drags, typing - the caller
  /// pushed one undo step when the edit began).
  void editTextLive(String layerId, void Function(TextSpec t) edit) {
    final t = findLayer(project, layerId)?.content.text;
    if (t == null) return;
    edit(t);
    _autoBox(layerId);
    _render();
    notifyListeners();
  }

  /// Resizes the text box to fit its text on one line per paragraph.
  void fitTextBoxOf(String layerId) {
    final layer = findLayer(project, layerId);
    final t = layer?.content.text;
    if (layer == null || t == null) return;
    pushUndo();
    layer.content.size = fitTextBox(t);
    _render();
    notifyListeners();
  }

  /// Turns a text layer into a vector shape (corner pin / mesh warp edits
  /// do this; the caller already pushed the undo step for the edit).
  void convertTextLayer(Layer layer) {
    if (layer.content.shape != 'text') return;
    convertTextToShape(layer);
    _render();
    notifyListeners();
  }

  /// Loads a .ttf/.otf into the font library and applies it to the text
  /// layer. Throws FontFormatException for files that aren't fonts.
  Future<void> importFontFor(String layerId, Uint8List bytes, String fileName) async {
    final id = fontStore != null
        ? await fontStore!.import(bytes, fileName)
        : (() {
            final id = 'font_${DateTime.now().microsecondsSinceEpoch}';
            registerFont(id, bytes);
            return id;
          })();
    editText(layerId, (t) => t.fontId = id);
  }

  /// Text layers (in this project) set to font `id`.
  int textLayersUsingFont(String id) =>
      project.layers.where((l) => l.content.shape == 'text' && l.content.text?.fontId == id).length;

  /// Removes a loaded font from the library (its stored file too); text
  /// layers that used it switch to the default font. Not an undo step -
  /// the file is gone.
  Future<void> deleteFont(String id) async {
    if (id == defaultFontId) return;
    if (fontStore != null) {
      await fontStore!.delete(id);
    } else {
      unregisterFont(id);
    }
    for (final l in project.layers) {
      if (l.content.shape == 'text' && l.content.text?.fontId == id) l.content.text!.fontId = defaultFontId;
    }
    clearStateCaches();
    _render();
    notifyListeners();
  }

  /// createLayer/addLayer's sibling for an imported image - the actual
  /// file picking/decoding happens in the UI (io/image_import.dart),
  /// which hands this the already-resolved source data and natural
  /// pixel dimensions.
  void addImageLayer({
    required String imageSourceType,
    String? imageData,
    String? imagePath,
    required int naturalWidth,
    required int naturalHeight,
  }) {
    undo.pushUndoState(project);
    final layer = createImageLayer(
      imageSourceType: imageSourceType,
      imageData: imageData,
      imagePath: imagePath,
      naturalWidth: naturalWidth,
      naturalHeight: naturalHeight,
      // its own pixel size against the frame - no shrinking to fit.
      maxDimension: math.max(naturalWidth, naturalHeight).toDouble(),
    );
    nameNewLayer(project, layer); // first free number of its type
    _fitNewLayerToLength(layer);
    project.layers.add(layer);
    focusNewLayer(layer.id);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// createLayer/addImageLayer's sibling for SVG import - the actual
  /// file picking/parsing happens in the UI
  /// (lib/ui/layer_panel/add_layer_dialog.dart), which hands this the
  /// already-parsed layers from `importShapesFromSvg`. A no-op for an
  /// empty list (every element in the file failed to import) rather
  /// than pushing a pointless undo state.
  void importSvgLayers(List<Layer> layers) {
    if (layers.isEmpty) return;
    undo.pushUndoState(project);
    for (final l in layers) {
      nameNewLayer(project, l);
      l.startFrame = currentFrame;
      project.layers.add(l);
    }
    focusNewLayer(layers.last.id);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Layers-tab reconstruction, (duplicate, next to hide/delete in each
  /// layer's own row). Reuses the existing cloneLayer (project.dart -
  /// previously only used for undo snapshots) but overrides the clone's
  /// id/name so it doesn't collide with the source, and inserts it right after
  /// the source rather than at the end of the list. Mirror: a copy of the
  /// layer's shape as its probe (never drawn, only outlined on the stage), set
  /// beside it; the layer shows what lies under the probe. One undo step.
  void makeMirror(String id) {
    final src = findLayer(project, id);
    if (src == null) return;
    undo.pushUndoState(project);
    final old = src.mirrorSourceId == null ? null : findLayer(project, src.mirrorSourceId);
    if (old != null && old.mirrorProbe) project.layers.remove(old);
    final probe = cloneLayer(src);
    layerCounter++;
    probe
      ..id = 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter'
      ..name = '${src.name} mirror'
      ..rowId = null
      ..mirrorSourceId = null
      ..mirrorProbe = true
      ..masks = [];
    // beside the layer (its own width over), moved keys and all.
    final dx = (src.content.size[0].abs() + 40) / stageSize.width;
    final a = probe.transform.anchor;
    final a0 = a.defaultValue as List;
    a.defaultValue = <double>[(a0[0] as num).toDouble() + dx, (a0[1] as num).toDouble()];
    for (final k in a.keyframes) {
      final v = k.value as List;
      k.value = <double>[(v[0] as num).toDouble() + dx, (v[1] as num).toDouble()];
    }
    project.layers.insert(project.layers.indexOf(src) + 1, probe);
    src.mirrorSourceId = probe.id;
    normalizeTimelineRows(project);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// The mirror's copy back beside the layer (where Make mirror put it).
  void resetMirrorProbe(String id) {
    final src = findLayer(project, id);
    final probe = src?.mirrorSourceId == null ? null : findLayer(project, src!.mirrorSourceId);
    if (src == null || probe == null || !probe.mirrorProbe) return;
    undo.pushUndoState(project);
    final dx = (src.content.size[0].abs() + 40) / stageSize.width;
    final a0 = src.transform.anchor.defaultValue as List;
    probe.transform.anchor
      ..defaultValue = <double>[(a0[0] as num).toDouble() + dx, (a0[1] as num).toDouble()]
      ..keyframes = [
        for (final k in src.transform.anchor.keyframes)
          Keyframe(
              frame: k.frame,
              value: <double>[((k.value as List)[0] as num).toDouble() + dx, ((k.value as List)[1] as num).toDouble()],
              temporal: k.temporal)
      ];
    probe.transform.rotation = cloneTrack(src.transform.rotation);
    probe.transform.scale = cloneTrack(src.transform.scale);
    _render();
    notifyListeners();
  }

  /// "Edit with AI": the project's layers replaced by an imported MCJ
  /// result - one undo step. A placeholder named like one of the old media
  /// layers keeps that layer's media.
  void replaceWithMcj(McjResult r) {
    undo.pushUndoState(project);
    final old = {for (final l in project.layers) if (isMediaShape(l.content.shape)) l.name: l};
    for (final l in r.project.layers) {
      final m = old[l.name];
      if (l.content.placeholder && m != null) {
        final size = l.content.size;
        l.content = cloneLayer(m).content..size = size;
        l.color = m.color;
      }
    }
    // the import set the stage to its canvas: back to this frame (anchors
    // are fractions, so nothing moves).
    setStageSize(frameWidth, frameHeight);
    project.layers
      ..clear()
      ..addAll(r.project.layers);
    selection.selectedLayer = project.layers.isEmpty ? null : project.layers.last.id;
    multiSelection = {};
    clearStateCaches();
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Not a mirror any more: its probe goes too. One undo step.
  void removeMirror(String id) {
    final src = findLayer(project, id);
    if (src == null || src.mirrorSourceId == null) return;
    undo.pushUndoState(project);
    final probe = findLayer(project, src.mirrorSourceId);
    if (probe != null && probe.mirrorProbe) project.layers.remove(probe);
    src.mirrorSourceId = null;
    normalizeTimelineRows(project);
    _render();
    notifyListeners();
  }

  /// Locks / unlocks a layer on the stage (one undo step).
  void toggleLocked(String id) {
    final l = findLayer(project, id);
    if (l == null) return;
    undo.pushUndoState(project);
    l.locked = !l.locked;
    notifyListeners();
  }

  void renameLayer(String id, String name) {
    final l = findLayer(project, id);
    if (l == null || l.name == name) return;
    undo.pushUndoState(project);
    // names are unique: a taken one gets a number.
    l.name = uniqueLayerName(project, name.trim().isEmpty ? l.name : name.trim(), exceptId: id);
    notifyListeners();
  }

  /// Puts a layer into a Layers tab folder (null: out of any). Layers of
  /// a folder are kept together in the stack.
  void setLayerFolder(String id, String? folder) {
    final l = findLayer(project, id);
    if (l == null) return;
    undo.pushUndoState(project);
    _putInFolder(l, folder);
    _render();
    notifyListeners();
  }

  void _putInFolder(Layer l, String? folder) {
    final old = l.folder;
    l.folder = folder;
    if (folder == null) return;
    // next to the folder's other layers (above the top one).
    final mates = [for (final x in project.layers) if (x.folder == folder && !identical(x, l)) x];
    if (mates.isNotEmpty) {
      project.layers.remove(l);
      project.layers.insert(project.layers.indexOf(mates.last) + 1, l);
      return;
    }
    // a new folder made from inside another: it goes just under that one
    // (it used to stay in the middle and split it in two).
    final oldMates = [for (final x in project.layers) if (old != null && x.folder == old && !identical(x, l)) x];
    if (oldMates.isNotEmpty) {
      project.layers.remove(l);
      project.layers.insert(project.layers.indexOf(oldMates.first), l);
    }
  }

  /// Layers (in their order) to the very top of the stack (or bottom).
  void moveLayersToEdge(Iterable<String> ids, {required bool top}) {
    final ls = [for (final l in project.layers) if (ids.contains(l.id)) l];
    if (ls.isEmpty) return;
    undo.pushUndoState(project);
    project.layers.removeWhere(ls.contains);
    top ? project.layers.addAll(ls) : project.layers.insertAll(0, ls);
    _render();
    notifyListeners();
  }

  /// The selected layers (several) into one folder, in their order.
  void setLayersFolder(Iterable<String> ids, String? folder) {
    final ls = [for (final l in project.layers) if (ids.contains(l.id)) l];
    if (ls.isEmpty) return;
    undo.pushUndoState(project);
    for (final l in ls) {
      _putInFolder(l, folder);
    }
    _render();
    notifyListeners();
  }

  /// A folder's layers all shown, or all hidden when any is shown.
  void toggleFolderHidden(String folder) {
    final ls = [for (final l in project.layers) if (l.folder == folder) l];
    if (ls.isEmpty) return;
    undo.pushUndoState(project);
    final hide = ls.any((l) => !l.hidden);
    for (final l in ls) {
      l.hidden = hide;
    }
    _render();
    notifyListeners();
  }

  /// A copy of a whole folder ("<name> copy"), right above it; parents
  /// inside the folder follow their copies.
  void duplicateFolder(String folder) {
    final ls = [for (final l in project.layers) if (l.folder == folder) l];
    if (ls.isEmpty) return;
    undo.pushUndoState(project);
    final used = {for (final l in project.layers) if (l.folder != null) l.folder!};
    var name = '$folder copy';
    for (var n = 2; used.contains(name); n++) {
      name = '$folder copy $n';
    }
    final ids = <String, String>{};
    final copies = <Layer>[];
    for (final src in ls) {
      final c = cloneLayer(src);
      layerCounter++;
      c.id = 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter';
      c.rowId = null;
      c.folder = name;
      ids[src.id] = c.id;
      copies.add(c);
    }
    for (final c in copies) {
      if (ids[c.parentId] case final p?) c.parentId = p;
    }
    project.layers.insertAll(project.layers.indexOf(ls.last) + 1, copies);
    ensureUniqueLayerNames(project);
    normalizeTimelineRows(project);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Layers copied together (Layers tab, several selected) - pasted as
  /// new copies, parents inside the set following their copies.
  List<Layer>? copiedLayers;

  void copySelectedLayers() {
    final group = selectedGroup;
    copiedLayers = [
      for (final l in project.layers)
        if (group.contains(l.id)) cloneLayer(l)
    ];
    notifyListeners();
  }

  /// Pastes the copied layers on top; they become the selection.
  void pasteCopiedLayers() {
    final src = copiedLayers;
    if (src == null || src.isEmpty) return;
    undo.pushUndoState(project);
    final ids = <String, String>{};
    final copies = <Layer>[];
    for (final l in src) {
      final c = cloneLayer(l);
      layerCounter++;
      c.id = 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter';
      c.rowId = null;
      ids[l.id] = c.id;
      copies.add(c);
    }
    for (final c in copies) {
      if (ids[c.parentId] case final p?) c.parentId = p;
    }
    project.layers.addAll(copies);
    ensureUniqueLayerNames(project);
    normalizeTimelineRows(project);
    selectLayer(copies.last.id);
    multiSelection = {for (final c in copies.take(copies.length - 1)) c.id};
    _fitTimeline();
    _render();
    notifyListeners();
  }

  void duplicateLayer(String id) {
    final src = findLayer(project, id);
    if (src == null) return;
    undo.pushUndoState(project);
    final clone = cloneLayer(src);
    layerCounter++;
    clone.id =
        'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter';
    clone.name = '${src.name}_copy';
    clone.rowId = null; // same time as the original - can't share its row
    final idx = project.layers.indexOf(src);
    project.layers.insert(idx + 1, clone);
    normalizeTimelineRows(project);
    focusNewLayer(clone.id);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Layer drag-to-reorder, from both the Layers tab (its colored circle as a
  /// drag handle) and the timeline (a new fixed-right-edge button column) -
  /// `newIndex` is a real, POST-REMOVAL target index into `project.layers`
  /// itself (0 = bottom/back, matching canvas_renderer.dart's own
  /// paint-order-is-array-order convention - the LAST index paints on
  /// top/front). Callers own translating their own UI-index space (the Layers
  /// tab displays the list reversed; the timeline displays it in direct order
  /// already) into this real index. Undo/redo is free via the existing
  /// whole-list snapshot every other list mutation here already gets.
  // ===== timeline rows =====

  LayerTrackDragOp _grabTrack(Layer layer, LayerDragMode mode) {
    // a move takes the layers linked to this one along (time_links.dart),
    // and the layers selected with it.
    final group = mode == LayerDragMode.move
        ? {
            ...timeLinkGroup(project, layer),
            if (selectedGroup.contains(layer.id))
              for (final id in selectedGroup) ...timeLinkGroup(project, findLayer(project, id)!),
          }.toList()
        : [layer];
    final limits = timelineRowLimits(project, layer, ignore: group.toSet());
    if (group.length < 2) {
      return LayerTrackDragOp.grab(layer, mode, minStart: limits.minStart, maxEnd: limits.maxEnd);
    }
    final shift = timeLinkShiftLimits(project, group);
    return LayerTrackDragOp.grab(layer, mode,
        minStart: limits.minStart,
        maxEnd: limits.maxEnd,
        partners: group,
        minDelta: shift.minDelta,
        maxDelta: shift.maxDelta);
  }

  /// Runs a row edit as one undo step; false (and no undo entry) when it
  /// couldn't be done.
  bool _rowEdit(bool Function() edit) {
    undo.pushUndoState(project);
    if (!edit()) {
      undo.discardLastUndoState();
      return false;
    }
    _fitTimeline();
    _render();
    notifyListeners();
    return true;
  }

  /// Timeline reorder handle: into row `row` (`join`) or as a new row at
  /// that position - rows counted with the layer taken out.
  bool placeLayerInRow(String id, int row, {required bool join}) =>
      _rowEdit(() => placeLayerInTimelineRows(project, id, row, join: join));

  /// Timeline tab: into the row above / below, when it has room.
  bool joinNeighbourRow(String id, {required bool up}) =>
      _rowEdit(() => joinNeighbourTimelineRow(project, id, up: up));

  bool takeOwnRow(String id) => _rowEdit(() => takeOwnTimelineRow(project, id));

  /// Timeline tab, "fill the gaps": the layer keeps only its parts inside
  /// the gaps of row `row` and joins that row.
  bool fillRowGapsWith(String id, int row) => _rowEdit(() {
        final kept = fillTimelineRowGaps(project, selection, id, row,
            newLayerId: _newLayerId, globalFrame: currentFrame);
        if (kept == null) return false;
        selection.selectedLayer = kept.first.id;
        return true;
      });

  /// Timeline tab, "lay over a row": the layer keeps only its parts where
  /// row `row` has layers and goes into a new row drawn over it.
  bool overlayRowWith(String id, int row) => _rowEdit(() {
        final kept = overlayTimelineRow(project, selection, id, row,
            newLayerId: _newLayerId, globalFrame: currentFrame);
        if (kept == null) return false;
        selection.selectedLayer = kept.first.id;
        return true;
      });

  /// Timeline tab, loop: repeat the layer after its end - to the end of
  /// the timeline (`until` null) or until a frame. One undo step.
  void setLayerLoop(String id, {required bool enabled, int? until}) {
    final layer = findLayer(project, id);
    if (layer == null || (layer.loopEnabled == enabled && layer.loopUntil == until)) return;
    undo.pushUndoState(project);
    layer.loopEnabled = enabled;
    layer.loopUntil = until;
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Selective parenting (Movement tab): which parts of the parent this
  /// layer follows. One undo step.
  void setInherit(String id, {bool? position, bool? rotation, bool? scale, bool? keepDifference}) {
    final layer = findLayer(project, id);
    if (layer == null) return;
    pushUndo();
    if (position != null) layer.inheritPosition = position;
    if (rotation != null) layer.inheritRotation = rotation;
    if (scale != null) layer.inheritScale = scale;
    if (keepDifference != null) layer.parentKeepDifference = keepDifference;
    _render();
    notifyListeners();
  }

  void moveLayer(String id, int newIndex) {
    final idx = project.layers.indexWhere((l) => l.id == id);
    if (idx == -1) return;
    undo.pushUndoState(project);
    final layer = project.layers.removeAt(idx);
    project.layers.insert(newIndex.clamp(0, project.layers.length), layer);
    // moved in the paint order: it leaves its timeline row, and a row it
    // landed inside stays together.
    layer.rowId = null;
    normalizeTimelineRows(project);
    _render();
    notifyListeners();
  }

  /// createLayer/addLayer's sibling for an "add layer" jump - the plain
  /// "go to frame" field moves the PLAYHEAD; this moves the SELECTED
  /// LAYER's own startFrame to an arbitrary target with no bounds
  /// (unlike LayerTrackDragOp, which is delta-based and the wrong shape
  /// for "jump to an absolute frame"). No-ops with nothing selected,
  /// matching deleteSelected's own guard.
  void moveSelectedLayerToFrame(int frame) {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null) return;
    undo.pushUndoState(project);
    shiftTimeLinked(project, layer, frame); // linked layers come along
    _fitTimeline();
    _render();
    notifyListeners();
  }

  void deleteSelected() {
    final id = selection.selectedLayer;
    if (id == null) return;
    deleteLayerById(id);
  }

  /// deleteSelected's sibling for the Layers tab's per-layer delete button) -
  /// deletes a SPECIFIC layer by id, which may not be the currently-selected
  /// one, without requiring a selection change first.
  void deleteLayerById(String id) {
    undo.pushUndoState(project);
    deleteLayer(project, selection, id, currentFrame);
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// commits a mutation the caller already applied directly to the
  /// selected layer's fields (e.g. a params-panel slider) - pushes
  /// undo state BEFORE the caller's own edit is expected to have
  /// happened is the JS convention (pushUndoState captures "before"),
  /// so callers push first, mutate, then call this to re-render/notify.
  void commitEdit() {
    // no two layers share a name (copies, merges, pieces...).
    ensureUniqueLayerNames(project);
    _render();
    notifyListeners();
  }

  void pushUndo() => undo.pushUndoState(project);

  void performUndo() {
    final before = project.layers;
    undo.undo(project, selection);
    lastUndoMessage = _undoMessage('Undo', before);
  }

  void performRedo() {
    final before = project.layers;
    undo.redo(project, selection);
    lastUndoMessage = _undoMessage('Redo', before);
  }

  /// What the last undo / redo did, for its toast ("Undo: rotation of
  /// rect_1"), or null when there was nothing to undo / redo.
  String? lastUndoMessage;

  String? _undoMessage(String verb, List<Layer> before) {
    if (identical(before, project.layers)) return null; // nothing to undo / redo
    final what = describeLayerChange(before, project.layers);
    return what.isEmpty ? verb : '$verb: $what';
  }

  /// physical/visual toggles from movement-mobile-gesture-spec.md -
  /// hideHandles/hideVisualLayer themselves are plain top-level bools in
  /// movement_core's model/project.dart (mirroring hideHandles's own
  /// pre-existing pattern there), not AppState fields; these just give
  /// ui/ a ChangeNotifier-driven way to flip them and have the stage
  /// actually repaint, the same as every other mutation in this class.
  void toggleHideHandles() {
    hideHandles = !hideHandles;
    notifyListeners();
  }

  void toggleHideVisualLayer() {
    hideVisualLayer = !hideVisualLayer;
    notifyListeners();
  }

  /// visual grid overlay - fully decoupled from Snapping, see
  /// gridOverlayEnabled's own doc comment in project.dart.
  void toggleGridOverlay() {
    gridOverlayEnabled = !gridOverlayEnabled;
    notifyListeners();
  }

  /// snapping toggles - same pattern as toggleHideHandles/
  /// toggleHideVisualLayer above (plain movement_core globals, this
  /// just flips + notifyListeners so the stage/settings UI repaint).
  /// No pushUndo()/commitEdit() anywhere in this group: these are app
  /// preferences, not part of the animatable project model, same
  /// category as layerQuickSwitchEnabled/timelineEdgeAutoScrollEnabled.
  void toggleSnapEnabled() {
    snapEnabled = !snapEnabled;
    notifyListeners();
  }

  void toggleSnapGuidesVisible() {
    snapGuidesVisible = !snapGuidesVisible;
    notifyListeners();
  }

  void toggleSnapEdgeToEdge() {
    snapEdgeToEdgeEnabled = !snapEdgeToEdgeEnabled;
    notifyListeners();
  }

  void toggleSnapCenterToCenter() {
    snapCenterToCenterEnabled = !snapCenterToCenterEnabled;
    notifyListeners();
  }

  void toggleSnapCenterHorizontal() {
    snapCenterHorizontalEnabled = !snapCenterHorizontalEnabled;
    notifyListeners();
  }

  void toggleSnapCenterVertical() {
    snapCenterVerticalEnabled = !snapCenterVerticalEnabled;
    notifyListeners();
  }

  void toggleSnapCenterDiagonal() {
    snapCenterDiagonalEnabled = !snapCenterDiagonalEnabled;
    notifyListeners();
  }

  void toggleSnapCenterLine() {
    snapCenterLineEnabled = !snapCenterLineEnabled;
    notifyListeners();
  }

  void toggleSnapEqualSpacing() {
    snapEqualSpacingEnabled = !snapEqualSpacingEnabled;
    notifyListeners();
  }

  void toggleSnapCornerToCorner() {
    snapCornerToCornerEnabled = !snapCornerToCornerEnabled;
    notifyListeners();
  }

  void toggleSnapEqualSize() {
    snapEqualSizeEnabled = !snapEqualSizeEnabled;
    notifyListeners();
  }

  void toggleSnapGrid() {
    snapGridEnabled = !snapGridEnabled;
    // one- directional: turning snap-to-grid OFF doesn't touch the overlay,
    // which may still be wanted independently via its own Grid dialog.
    if (snapGridEnabled) gridOverlayEnabled = true;
    notifyListeners();
  }

  void toggleSnapFrameBoundary() {
    snapFrameBoundaryEnabled = !snapFrameBoundaryEnabled;
    notifyListeners();
  }

  void setSnapSizeMeasurement(SnapSizeMeasurement mode) {
    snapSizeMeasurement = mode;
    notifyListeners();
  }

  // ===== rotation snapping (RotateDragOp only) =====
  void toggleSnapRotation() {
    snapRotationEnabled = !snapRotationEnabled;
    notifyListeners();
  }

  void toggleSnapRotationHorizontal() {
    snapRotationHorizontalEnabled = !snapRotationHorizontalEnabled;
    notifyListeners();
  }

  void toggleSnapRotationVertical() {
    snapRotationVerticalEnabled = !snapRotationVerticalEnabled;
    notifyListeners();
  }

  void toggleSnapRotationDiagonal() {
    snapRotationDiagonalEnabled = !snapRotationDiagonalEnabled;
    notifyListeners();
  }

  void toggleSnapRotationMatchNearby() {
    snapRotationMatchNearbyEnabled = !snapRotationMatchNearbyEnabled;
    notifyListeners();
  }

  /// degrees; no px->frame conversion needed (same precedent as
  /// setSnapFixedGapFrame below) - an angle means the same thing at
  /// every zoom level.
  void setSnapRotationToleranceDeg(double deg) {
    snapRotationToleranceDeg = deg.clamp(1.0, 15.0);
    notifyListeners();
  }

  void setSnapFixedGapFrame(double v) {
    snapFixedGapFrame = v;
    notifyListeners();
  }

  void setSnapGridCols(int v) {
    snapGridCols = v.clamp(2, 32);
    notifyListeners();
  }

  void setSnapGridRows(int v) {
    snapGridRows = v.clamp(2, 32);
    notifyListeners();
  }

  void setSnapSensitivityEdgeToEdgePx(double px) {
    snapSensitivityEdgeToEdgePx = px;
    notifyListeners();
  }

  void setSnapSensitivityCenterToCenterPx(double px) {
    snapSensitivityCenterToCenterPx = px;
    notifyListeners();
  }

  void setSnapSensitivityCornerToCornerPx(double px) {
    snapSensitivityCornerToCornerPx = px;
    notifyListeners();
  }

  void setSnapSensitivityEqualSizePx(double px) {
    snapSensitivityEqualSizePx = px;
    notifyListeners();
  }

  void setSnapSensitivityGridPx(double px) {
    snapSensitivityGridPx = px;
    notifyListeners();
  }

  void setSnapSensitivityFrameBoundaryPx(double px) {
    snapSensitivityFrameBoundaryPx = px;
    notifyListeners();
  }

  /// ui_geometry/keyframe_strip.dart's data layer, wired up the same
  /// way as every other mutation in this class (pushUndo before,
  /// _render()+notifyListeners() after). kfSelectedFrames/
  /// kfMultiselectMode are movement_core globals (mirroring hideHandles's
  /// own pattern), not fields here.
  KeyframeGroupDragOp? _kfDragOp;

  void selectKeyframeFrame(int frame) {
    if (kfMultiselectMode) {
      final next = {...kfSelectedFrames};
      next.contains(frame) ? next.remove(frame) : next.add(frame);
      kfSelectedFrames = next;
    } else if (kfSelectedFrames.length == 1 &&
        kfSelectedFrames.contains(frame)) {
      // a marker, once selected, could never be deselected by tapping it again
      // - The ORIGINAL JS (keyframeStrip.js's marker click handler) has this
      // exact same gap - its non-multiselect branch unconditionally does
      // `kfSelection.frames = new Set([f])` regardless of whether f was
      // already the sole selection, so re-tapping a selected marker is a no-op
      // there too, not a porting bug introduced here. Fixed as a disclosed,
      // deliberate improvement beyond straight JS parity: tapping the
      // ALREADY-selected marker again clears the selection.
      kfSelectedFrames = {};
    } else {
      kfSelectedFrames = {frame};
    }
    if (keyframeSelectKeepsPlayhead) {
      _render();
      notifyListeners();
    } else {
      setFrame(
          frame); // matches keyframeStrip.js's own marker-click behavior: selecting a marker also jumps the playhead there
    }
  }

  /// The key selection only names keys that exist: after a delete, an
  /// undo/redo, a move or a trim, frames with no key left on the selected
  /// layer drop out the marker of a deleted key, or of a moved-then-undone
  /// key, stayed where it was).
  void _revalidateKeySelection() {
    // another layer selected (or a new one added): its key line goes.
    final ks = keyDetailSelection;
    if (ks != null && ks.layerId != selection.selectedLayer) {
      keyDetailSelection = null;
      keyDetailExtra = [];
    }
    // kept selections of other layers: only keys that still exist.
    if (heldKeys.isNotEmpty) {
      heldKeys = {
        for (final e in heldKeys.entries)
          if (findLayer(project, e.key) case final l?)
            if (collectLayerKeyframeFrames(l).toSet() case final have
                when e.value.where(have.contains).isNotEmpty)
              e.key: e.value.where(have.contains).toSet(),
      };
    }
    if (kfSelectedFrames.isEmpty) return;
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null) {
      kfSelectedFrames = {};
      return;
    }
    final existing = collectLayerKeyframeFrames(layer).toSet();
    if (!kfSelectedFrames.every(existing.contains)) {
      kfSelectedFrames = kfSelectedFrames.where(existing.contains).toSet();
    }
  }

  /// Timeline tab: selected keys stay selected (glowing) on a layer you
  /// leave, so keys of several layers can be picked and moved together.
  bool keepKeysAcrossLayers = true;

  /// Kept key selections of layers that are not the active one: layer id
  /// -> global frames.
  Map<String, Set<int>> heldKeys = {};

  /// The key selection moving from layer `from` to layer `to`: kept on
  /// `from` (keepKeysAcrossLayers) and `to`'s own kept keys picked up.
  void switchKeySelection(String? from, String? to, {bool notify = true}) {
    if (from == to) return;
    if (keepKeysAcrossLayers) {
      if (from != null && kfSelectedFrames.isNotEmpty) heldKeys[from] = {...kfSelectedFrames};
      kfSelectedFrames = to == null ? {} : (heldKeys.remove(to) ?? {});
    } else {
      heldKeys = {};
      kfSelectedFrames = {};
    }
    if (notify) notifyListeners();
  }

  /// Drops every kept key selection (and the active one).
  void clearAllKeySelections() {
    heldKeys = {};
    kfSelectedFrames = {};
    notifyListeners();
  }

  Map<Layer, KeyframeGroupDragOp> _heldDragOps = {};

  void beginKeyframeDrag(int frame) {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null) return;
    // the keys kept selected on other layers move along.
    _heldDragOps = {
      for (final e in heldKeys.entries)
        if (findLayer(project, e.key) case final l? when e.value.isNotEmpty)
          l: KeyframeGroupDragOp.grab(l, e.value, frame),
    };
    // dragging a marker that ISN'T already part of the selection starts
    // a fresh single-marker selection, rather than dragging whatever was
    // selected before - matches direct-manipulation touch expectations
    // (you drag what your finger is on).
    if (!kfSelectedFrames.contains(frame)) kfSelectedFrames = {frame};
    pushUndo();
    _kfDragOp = KeyframeGroupDragOp.grab(layer, kfSelectedFrames, frame);
  }

  void updateKeyframeDrag(int currentFrame) {
    final layer = findLayer(project, selection.selectedLayer);
    final op = _kfDragOp;
    if (layer == null || op == null) return;
    kfSelectedFrames = op.apply(layer, currentFrame);
    _heldDragOps.forEach((l, o) => heldKeys[l.id] = o.apply(l, currentFrame));
    _render();
    notifyListeners();
  }

  void endKeyframeDrag() {
    final op = _kfDragOp;
    _kfDragOp = null;
    if (op == null) return;
    op.finish();
    for (final o in _heldDragOps.values) {
      o.finish();
    }
    _heldDragOps = {};
    _render();
    notifyListeners();
  }

  /// Deletes the selected keys (kfSelectedFrames) of the selected layer.
  void deleteSelectedKfs() {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null || kfSelectedFrames.isEmpty) return;
    pushUndo();
    final local = {for (final f in kfSelectedFrames) f - layer.startFrame};
    visitLayerTracks(layer, (trk) {
      trk.keyframes.removeWhere((k) => local.contains(k.frame));
      if (trk.spatial) autoComputeTangents(trk);
    });
    kfSelectedFrames = {};
    commitEdit();
  }

  void copySelectedKfs() {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null) return;
    copySelectedKeyframes(layer, kfSelectedFrames);
  }

  /// Reverse: a mirrored copy of the selected key cluster, placed right
  /// after its last key; the copy becomes the selection so it can be
  /// dragged anywhere.
  void reverseSelectedKfs() {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null || kfSelectedFrames.isEmpty) return;
    pushUndo();
    final newSelection = reverseKeyframeCluster(layer, kfSelectedFrames);
    if (newSelection != null) kfSelectedFrames = newSelection;
    _fitTimeline();
    _render();
    notifyListeners();
  }

  void pasteKfsAtCurrentFrame() {
    final layer = findLayer(project, selection.selectedLayer);
    if (layer == null) return;
    pushUndo();
    final newSelection = pasteKeyframes(layer, currentFrame);
    if (newSelection != null) kfSelectedFrames = newSelection;
    _render();
    notifyListeners();
  }

  /// ui_geometry/layer_track.dart's drag mechanics, wired up the same
  /// way as keyframe dragging above - pushUndo before, _render()+
  /// notifyListeners() after every update so the stage/other panels stay
  /// live during the drag, matching this whole app's convention.
  LayerTrackDragOp? _layerDragOp;

  void beginLayerDrag(String layerId, LayerDragMode mode) {
    final layer = findLayer(project, layerId);
    if (layer == null) return;
    // a layer of the group moves the whole group; the main one stays.
    if (selection.selectedLayer != layerId && !selectedGroup.contains(layerId)) selectLayer(layerId);
    pushUndo();
    _layerDragOp = _grabTrack(layer, mode);
    // a trim of a layer of the group trims the whole group by as much.
    _groupTrimOps = mode == LayerDragMode.move
        ? const {}
        : {
            for (final id in selectedGroup)
              if (id != layerId) findLayer(project, id)!: _grabTrack(findLayer(project, id)!, mode),
          };
    _trimGrab = (start: layer.startFrame, end: layer.startFrame + layer.durationFrames);
  }

  Map<Layer, LayerTrackDragOp> _groupTrimOps = const {};
  ({int start, int end}) _trimGrab = (start: 0, end: 0);

  void _applyGroupTrim(LayerTrackDragOp op) {
    if (_groupTrimOps.isEmpty) return;
    final d = op.mode == LayerDragMode.trimLeft
        ? op.layer.startFrame - _trimGrab.start
        : op.layer.startFrame + op.layer.durationFrames - _trimGrab.end;
    for (final o in _groupTrimOps.values) {
      o.apply(d);
    }
  }

  /// A layer drag's vertical part (finger offset, px): the dragged layers
  /// follow it until they're dropped into other rows.
  double layerDragDy = 0;

  void setLayerDragDy(double dy) {
    layerDragDy = dy;
    notifyListeners();
  }

  /// Moves the selected layers `delta` rows up (< 0) or down, each into
  /// that row when it has room there, else into a new row there. One undo
  /// step.
  void moveGroupRows(Iterable<String> ids, int delta) {
    if (delta == 0) return;
    pushUndo();
    final order = [...ids];
    int rowOf(String id) => timelineRows(project).indexWhere((r) => r.any((l) => l.id == id));
    order.sort((x, y) => delta > 0 ? rowOf(y).compareTo(rowOf(x)) : rowOf(x).compareTo(rowOf(y)));
    for (final id in order) {
      final layer = findLayer(project, id);
      if (layer == null) continue;
      final rows = timelineRows(project);
      final own = rowOf(id);
      if (own < 0) continue;
      final target = (own + delta).clamp(0, rows.length - 1);
      final alone = rows[own].length == 1;
      int post(int i) => alone && i > own ? i - 1 : i;
      if (target != own && fitsInTimelineRow(rows[target], layer)) {
        placeLayerInTimelineRows(project, id, post(target), join: true);
      } else {
        // past the last / first row: a new row there.
        final at = delta > 0 ? math.min(own + delta + 1, rows.length) : math.max(own + delta, 0);
        if (!(alone && post(at) == own)) placeLayerInTimelineRows(project, id, post(at), join: false);
      }
    }
    _render();
    notifyListeners();
  }

  void updateLayerDrag(int dxFrames) {
    final op = _layerDragOp;
    if (op == null) return;
    op.apply(dxFrames);
    _applyGroupTrim(op);
    if (snapTimelineLayersEnabled) {
      // linked layers move along - they're no edge to snap to.
      applyLayerEdgeSnap(op.layer, [for (final l in project.layers) if (!op.isPartner(l)) l], op.mode,
          thresholdFrames: timelineSnapFrames);
      // a snap never pushes it into a neighbour in its row.
      final end = op.layer.startFrame + op.layer.durationFrames;
      if (op.layer.startFrame < op.minStart || (op.maxEnd != null && end > op.maxEnd!)) op.apply(dxFrames);
      op.followLeader();
      _applyGroupTrim(op);
    }
    // growing a layer past the current end live- extended the timeline, but
    // shrinking it only contracted the timeline once the drag was released -
    // recomputeMaxFrameToFit can both grow AND shrink, so calling it here on
    // every move (not just extendedMaxFrameForLayer's grow-only check) makes
    // both directions equally live.
    maxFrame = recomputeMaxFrameToFit(project.layers, _maxFrameFloor);
    _render();
    notifyListeners();
  }

  /// The layer drag's gesture was cancelled (e.g. another finger won the
  /// gesture arena): put the layer back where it was and drop the undo
  /// entry beginLayerDrag pushed. No-op without a live drag.
  void cancelLayerDrag() {
    final op = _layerDragOp;
    if (op == null) return;
    op.apply(0); // back to the grab state
    for (final o in _groupTrimOps.values) {
      o.apply(0);
    }
    _groupTrimOps = const {};
    layerDragDy = 0;
    _layerDragOp = null;
    undo.discardLastUndoState();
    _fitTimeline();
    _render();
    notifyListeners();
  }

  /// Links `otherId` (and its own group) to `layerId` on the timeline -
  /// they move together from now on. One undo step.
  void linkLayersInTime(String layerId, String otherId) {
    final a = findLayer(project, layerId), b = findLayer(project, otherId);
    if (a == null || b == null || identical(a, b) || areTimeLinked(a, b)) return;
    pushUndo();
    linkInTime(project, a, b);
    notifyListeners();
  }

  /// Takes the layer out of its timeline link group. One undo step.
  void unlinkLayerInTime(String layerId) {
    final l = findLayer(project, layerId);
    if (l == null || l.linkId == null) return;
    pushUndo();
    unlinkInTime(project, l);
    notifyListeners();
  }

  /// Whether a layer drag (move/trim) is in progress.
  bool get layerDragActive => _layerDragOp != null;

  void endLayerDrag() {
    if (_layerDragOp == null) return;
    _layerDragOp = null;
    _groupTrimOps = const {};
    layerDragDy = 0;
    // maxFrame is already correct - updateLayerDrag's own live recompute
    // (above) has been running on every move, so there's nothing left
    // to correct here on release.
    _render();
    notifyListeners();
  }

  /// The open project's display name (home-screen list); saved in the
  /// project file.
  String projectName = 'Untitled';

  /// Opens a project file from the home screen: loads it (frame size and
  /// background included) and autosaves every change back to that same
  /// file - debounced, plus `saveNow()` on backgrounding. A missing or
  /// unreadable file leaves the current (default) state in place.
  Future<void> openProject(File file) async {
    _autosaveFile = file;
    if (await file.exists()) {
      try {
        final data = await loadProjectFromFile(file);
        projectId = data.id ?? newProjectId();
        projectRevision = data.revision;
        project = data.project;
        fps = data.fps > 0 ? data.fps : 60;
        project.fps = fps;
        _explicitTimelineLength = data.timelineLength;
        renderer.mirrorX = data.mirrorX;
        renderer.mirrorY = data.mirrorY;
        maxFrame = recomputeMaxFrameToFit(project.layers, _maxFrameFloor);
        playbackSpeed = data.playbackSpeed;
        selection.selectedLayer = data.selectedLayer;
        projectName = data.name ?? projectName;
        frameWidth = data.frameWidth;
        frameHeight = data.frameHeight;
        renderer.setSize(frameWidth, frameHeight);
        renderer.backgroundColor = data.backgroundRgb == null
            ? null
            : Color(0xFF000000 | data.backgroundRgb!);
        normalizeTimelineRows(project);
        dissolveLonelyTimeLinks(project); // files saved with a lone link
        applyProjectUiState(data.ui);
        _savedContent = _contentSignature();
        currentFrame = currentFrame.clamp(0, maxFrame);
        _render();
        notifyListeners();
        unawaited(restoreVideoFrames());
        unawaited(restoreAudio());
        await loadReferences();
      } catch (_) {
        // not a recognized project file - keep the default project.
      }
    }
    addListener(_scheduleAutosave);
    addListener(_prepareAudioSoon);
  }

  void _scheduleAutosave() {
    if (_autosaveFile == null) return;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_writeAutosave());
    });
  }

  /// What the project is, without the view (selection, toggles): a save
  /// that changes none of it keeps the file's date, so opening a project
  /// doesn't move it up the list.
  String? _savedContent;

  String _contentSignature() => jsonEncode([
        projectLayersToJson(project),
        project.stageWalls,
        maxFrame,
        playbackSpeed,
        projectName,
        frameWidth,
        frameHeight,
        background?.value,
        _explicitTimelineLength,
        stageMirrorX,
        stageMirrorY,
        fps,
      ]);

  Future<void> _writeAutosave() async {
    final file = _autosaveFile;
    if (file == null) return;
    // a save of the host clears the "updated" badges.
    for (final l in project.layers) {
      final src = l.content.shape == 'projectRef' ? refSourceOf(l.content, refSources) : null;
      if (src != null && l.content.refEmbedded == null) l.content.refLastSeenRevision = src.revision;
    }
    final content = _contentSignature();
    final same = content == _savedContent;
    DateTime? keepDate;
    if (same) {
      try {
        if (await file.exists()) keepDate = await file.lastModified();
      } catch (_) {}
    } else {
      projectRevision++;
    }
    _savedContent = content;
    await _saveFile(file);
    if (keepDate != null) {
      try {
        await file.setLastModified(keepDate);
      } catch (_) {}
    }
  }

  Future<void> _saveFile(File file) async {
    await saveProjectToFile(file, project,
        projectId: projectId,
        revision: projectRevision,
        maxFrame: maxFrame,
        playbackSpeed: playbackSpeed,
        selectedLayer: selection.selectedLayer,
        name: projectName,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        backgroundRgb: background == null ? null : background!.value & 0xFFFFFF,
        timelineLength: _explicitTimelineLength,
        mirrorX: stageMirrorX,
        mirrorY: stageMirrorY,
        projectFps: fps,
        ui: projectUiState());
  }

  // ===== view settings that are kept switched-on settings were lost on
  // leaving a project) =====

  /// name -> (read, write, default). Per project: how this project is
  /// looked at and snapped (stage icons, Stage/Snapping/Grid settings,
  /// loop). Saved in the project file.
  late final Map<String, (Object? Function(), void Function(Object?), Object?)> _projectUi = {
    'showOffCanvasContent': (() => showOffCanvasContent, (v) => showOffCanvasContent = v as bool, false),
    'projectOutlines': (() => showProjectOutlines, (v) => showProjectOutlines = v as bool, false),
    'hideHandles': (() => hideHandles, (v) => hideHandles = v as bool, false),
    'hideVisualLayer': (() => hideVisualLayer, (v) => hideVisualLayer = v as bool, false),
    'outlineMode': (() => globalOutlineMode, (v) => globalOutlineMode = v as bool, false),
    'gridOverlay': (() => gridOverlayEnabled, (v) => gridOverlayEnabled = v as bool, false),
    'gridCols': (() => snapGridCols, (v) => snapGridCols = (v as num).toInt(), 4),
    'gridKinds': (() => gridLineKinds, (v) => gridLineKinds = (v as num).toInt(), 3),
    'gridRows': (() => snapGridRows, (v) => snapGridRows = (v as num).toInt(), 4),
    'scaleContentOnResize': (() => scaleContentOnResize, (v) => scaleContentOnResize = v as bool, true),
    'snap': (() => snapEnabled, (v) => snapEnabled = v as bool, false),
    'snapGuides': (() => snapGuidesVisible, (v) => snapGuidesVisible = v as bool, true),
    'snapEdge': (() => snapEdgeToEdgeEnabled, (v) => snapEdgeToEdgeEnabled = v as bool, false),
    'snapCenter': (() => snapCenterToCenterEnabled, (v) => snapCenterToCenterEnabled = v as bool, false),
    'snapCenterH': (() => snapCenterHorizontalEnabled, (v) => snapCenterHorizontalEnabled = v as bool, false),
    'snapCenterV': (() => snapCenterVerticalEnabled, (v) => snapCenterVerticalEnabled = v as bool, false),
    'snapCenterDiagonal': (() => snapCenterDiagonalEnabled, (v) => snapCenterDiagonalEnabled = v as bool, false),
    'snapCenterLine': (() => snapCenterLineEnabled, (v) => snapCenterLineEnabled = v as bool, false),
    'snapEqualSpacing': (() => snapEqualSpacingEnabled, (v) => snapEqualSpacingEnabled = v as bool, false),
    'snapCorner': (() => snapCornerToCornerEnabled, (v) => snapCornerToCornerEnabled = v as bool, false),
    'snapEqualSize': (() => snapEqualSizeEnabled, (v) => snapEqualSizeEnabled = v as bool, false),
    'snapGrid': (() => snapGridEnabled, (v) => snapGridEnabled = v as bool, false),
    'snapFrame': (() => snapFrameBoundaryEnabled, (v) => snapFrameBoundaryEnabled = v as bool, false),
    'snapRotation': (() => snapRotationEnabled, (v) => snapRotationEnabled = v as bool, false),
    'snapRotationH': (() => snapRotationHorizontalEnabled, (v) => snapRotationHorizontalEnabled = v as bool, false),
    'snapRotationV': (() => snapRotationVerticalEnabled, (v) => snapRotationVerticalEnabled = v as bool, false),
    'snapRotationDiagonal': (() => snapRotationDiagonalEnabled, (v) => snapRotationDiagonalEnabled = v as bool, false),
    'snapRotationMatch': (() => snapRotationMatchNearbyEnabled, (v) => snapRotationMatchNearbyEnabled = v as bool, false),
    'snapRotationMirror': (() => snapRotationMirrorEnabled, (v) => snapRotationMirrorEnabled = v as bool, true),
    'mirrorMovesLayer': (() => mirrorMovesLayer, (v) => mirrorMovesLayer = v as bool, false),
    'snapEdgeMid': (() => snapEdgeMidpointsEnabled, (v) => snapEdgeMidpointsEnabled = v as bool, true),
    'snapTextCenters': (() => snapTextCentersEnabled, (v) => snapTextCentersEnabled = v as bool, true),
    'snapTextEdges': (() => snapTextEdgesEnabled, (v) => snapTextEdgesEnabled = v as bool, true),
    'snapEqualRounding': (() => snapEqualRoundingEnabled, (v) => snapEqualRoundingEnabled = v as bool, true),
    'snapReach': (() => snapReachBySize, (v) => snapReachBySize = (v as num).toDouble(), 1.5),
    'snapRectGrid': (() => snapRectGridEnabled, (v) => snapRectGridEnabled = v as bool, true),
    'snapLineAngle': (() => snapLineAngleEnabled, (v) => snapLineAngleEnabled = v as bool, true),
    'snapLineLength': (() => snapLineLengthEnabled, (v) => snapLineLengthEnabled = v as bool, true),
    'snapLinePoints': (() => snapLinePointsEnabled, (v) => snapLinePointsEnabled = v as bool, true),
    'rectExtendMode': (() => rectExtendMode, (v) => rectExtendMode = v as bool, false),
    'scaleKeepsOppositeEdge': (() => scaleKeepsOppositeEdge, (v) => scaleKeepsOppositeEdge = v as bool, false),
    'lineHandlesMirrored': (() => lineHandlesMirrored, (v) => lineHandlesMirrored = v as bool, true),
    'lineRoundHandles': (() => lineRoundHandlesVisible, (v) => lineRoundHandlesVisible = v as bool, false),
    'placeOnStage': (() => placeOnStage, (v) => placeOnStage = v as bool, false),
    'placeSquare': (() => placeSquare, (v) => placeSquare = v as bool, false),
    'resizeEvenly': (() => resizeEvenly, (v) => resizeEvenly = v as bool, true),
    'groupKeepsShape': (() => groupKeepsShape, (v) => groupKeepsShape = v as bool, true),
    'stageMultiSelect': (() => stageMultiSelect, (v) => stageMultiSelect = v as bool, false),
    'marqueeMode': (() => marqueeMode, (v) => marqueeMode = v as bool, false),
    'marqueeOnHold': (() => marqueeOnHold, (v) => marqueeOnHold = v as bool, false),
    'marqueeSkip': (() => marqueeSkip.toList(), (v) => marqueeSkip = {for (final e in v as List) e as String}, const <String>[]),
    'snapRotationTolerance': (() => snapRotationToleranceDeg, (v) => snapRotationToleranceDeg = (v as num).toDouble(), 5.0),
    'snapSizeMeasurement': (
      () => snapSizeMeasurement.name,
      (v) => snapSizeMeasurement =
          SnapSizeMeasurement.values.firstWhere((m) => m.name == v, orElse: () => SnapSizeMeasurement.edgeGap),
      SnapSizeMeasurement.edgeGap.name
    ),
    'snapFixedGap': (() => snapFixedGapFrame, (v) => snapFixedGapFrame = (v as num).toDouble(), 40.0),
    'snapDiagonalStep': (() => snapDiagonalAngleIncrementDeg, (v) => snapDiagonalAngleIncrementDeg = (v as num).toDouble(), 45.0),
    'snapPxEdge': (() => snapSensitivityEdgeToEdgePx, (v) => snapSensitivityEdgeToEdgePx = (v as num).toDouble(), 8.0),
    'snapPxCenter': (() => snapSensitivityCenterToCenterPx, (v) => snapSensitivityCenterToCenterPx = (v as num).toDouble(), 8.0),
    'snapPxCorner': (() => snapSensitivityCornerToCornerPx, (v) => snapSensitivityCornerToCornerPx = (v as num).toDouble(), 8.0),
    'snapPxEqualSize': (() => snapSensitivityEqualSizePx, (v) => snapSensitivityEqualSizePx = (v as num).toDouble(), 8.0),
    'snapPxGrid': (() => snapSensitivityGridPx, (v) => snapSensitivityGridPx = (v as num).toDouble(), 8.0),
    'snapPxFrame': (() => snapSensitivityFrameBoundaryPx, (v) => snapSensitivityFrameBoundaryPx = (v as num).toDouble(), 10.0),
  };

  /// Per app: how the editor behaves while editing any project (the
  /// timeline drawer toggles, keys, the stage icon row). Saved in
  /// app_settings.json.
  late final Map<String, (Object? Function(), void Function(Object?), Object?)> _appUi = {
    'rulerLength': (() => rulerLengthScale, (v) => rulerLengthScale = (v as num).toDouble(), 1.0),
    'layerQuickSwitch': (() => layerQuickSwitchEnabled, (v) => layerQuickSwitchEnabled = v as bool, false),
    'timelineEdgeAutoScroll': (() => timelineEdgeAutoScrollEnabled, (v) => timelineEdgeAutoScrollEnabled = v as bool, false),
    'timelineCenterPlayhead': (() => timelineCenterPlayheadEnabled, (_) {}, true),
    'snapTimelineLayers': (() => snapTimelineLayersEnabled, (v) => snapTimelineLayersEnabled = v as bool, false),
    'timelineDrawer': (() => timelineDrawerExpanded, (v) => timelineDrawerExpanded = v as bool, false),
    'keySelectKeepsPlayhead': (() => keyframeSelectKeepsPlayhead, (v) => keyframeSelectKeepsPlayhead = v as bool, false),
    'keyMultiselect': (() => kfMultiselectMode, (v) => kfMultiselectMode = v as bool, false),
    'hideStageIcons': (() => hideStageIcons, (v) => hideStageIcons = v as bool, false),
    'recenterDetachedPieces': (() => recenterDetachedPieces, (v) => recenterDetachedPieces = v as bool, true),
    'keysMayLeaveLayer': (() => keysMayLeaveLayer, (v) => keysMayLeaveLayer = v as bool, false),
    'timelineLayerColors': (() => timelineLayerColors, (v) => timelineLayerColors = v as bool, true),
    'timelineFrameCounts': (() => timelineFrameCounts, (v) => timelineFrameCounts = v as bool, false),
    'defaultKeyEase': (() => defaultKeyEasingName, (v) => defaultKeyEasingName = v as String, 'easeInOut'),
    'masterKeysShareEase': (() => masterKeysShareEase, (v) => masterKeysShareEase = v as bool, true),
    'stageZoomLock': (() => stageZoomLock, (v) => stageZoomLock = v as bool, false),
    'timelineHandlesLocked': (() => timelineHandlesLocked, (v) => timelineHandlesLocked = v as bool, false),
    'loopPlayback': (() => loopPlayback, (v) => loopPlayback = v as bool, true),
    'timelineDetail': (() => timelineDetail, (v) => timelineDetail = v as String, 'none'),
    'rangeAsSelection': (() => rangeAsSelection, (v) => rangeAsSelection = v as bool, false),
    'timelineMaskRows': (() => showMaskRows, (v) => showMaskRows = v as bool, false),
    'loopExtendedVideos': (() => loopExtendedVideos, (v) => loopExtendedVideos = v as bool, false),
    'keepKeysAcrossLayers': (() => keepKeysAcrossLayers, (v) => keepKeysAcrossLayers = v as bool, true),
    'handlesRightHanded': (() => handlesRightHanded, (v) => handlesRightHanded = v as bool, true),
    'showPropLinks': (() => showPropLinks, (v) => showPropLinks = v as bool, true),
    'showMaskViz': (() => showMaskViz, (v) => showMaskViz = v as bool, false),
    'showRegionTints': (() => showRegionTints, (v) => showRegionTints = v as bool, false),
    'showFootprints': (() => showFootprints, (v) => showFootprints = v as bool, false),
    'showBoxOverEffectGrid': (() => showBoxOverEffectGrid, (v) => showBoxOverEffectGrid = v as bool, false),
    'stageRotate': (() => stageRotateEnabled, (v) => stageRotateEnabled = v as bool, false),
    'paramStations': (() => jsonEncode(ParamEditor.stations), (v) {
          ParamEditor.stations
            ..clear()
            ..addAll({
              for (final e in (jsonDecode(v as String) as Map).entries)
                e.key as String: [for (final x in e.value as List) (x as num).toDouble()]
            });
        }, '{}'),
    'palettes': (() => jsonEncode([for (final p in palettes) {'name': p.name, 'colors': p.colors}]),
        (v) => palettes = decodePalettes(v as String), jsonEncode(defaultPalettesJson)),
    'guideBottomSeen': (() => guideBottomSeen, (v) => guideBottomSeen = v as bool, true),
    'guideActionSeen': (() => guideActionSeen, (v) => guideActionSeen = v as bool, true),
    'guideTopSeen': (() => guideTopSeen, (v) => guideTopSeen = v as bool, true),
    'playOnPlayheadTap': (() => playOnPlayheadTap, (v) => playOnPlayheadTap = v as bool, false),
    'rulerTapSteps': (() => rulerTapSteps, (v) => rulerTapSteps = v as bool, true),
    'rulerStepFrames': (() => rulerStepFrames, (v) => rulerStepFrames = (v as num).toInt(), 1),
    'rulerInFrames': (() => rulerInFrames, (v) => rulerInFrames = v as bool, false),
    'showDescriptions': (() => descriptionsVisible.value, (v) => descriptionsVisible.value = v as bool, true),
    'keyMode': (() => keyMode, (v) => keyMode = v as String, 'base'),
    'showKeyParams': (() => showKeyParams, (v) => showKeyParams = v as bool, false),
    'scaleLinked': (() => scaleLinked, (v) => scaleLinked = v as bool, true),
    'eyedropperAlpha': (() => eyedropperAlpha, (v) => eyedropperAlpha = v as bool, false),
    'exportDir': (() => exportDir ?? '', (v) => exportDir = (v as String).isEmpty ? null : v, ''),
    'videoDecoder': (() => videoDecoder, (v) => videoDecoder = v as String, 'auto'),
    'timelineSnapFrames': (() => timelineSnapFrames, (v) => timelineSnapFrames = (v as num).toInt(), kLayerEdgeSnapThresholdFrames),
  };

  /// A tap on the timeline ruler steps the playhead `rulerStepFrames`
  /// (right of it: forward, left: back).
  bool rulerTapSteps = true;
  int rulerStepFrames = 1;

  /// The ruler counts frames (every 10th, every 100th zoomed out) instead
  /// of seconds.
  bool rulerInFrames = false;

  /// The zoom lock: the canvas's side edges stay on the screen's sides
  /// (see StageCamera.lockSides). Off by default.
  bool stageZoomLock = false;

  void setDefaultKeyEase(String name) {
    if (!easingPresets.containsKey(name)) return;
    defaultKeyEasingName = name;
    notifyListeners();
  }

  /// An ease curve copied in the curve editor, to paste on another key.
  Easing? copiedEasing;

  /// Every timeline handle off at once: no key markers, edge trims or layer
  /// moves on the timeline (taps still focus and scrub).
  bool timelineHandlesLocked = false;

  void toggleTimelineHandlesLocked() {
    timelineHandlesLocked = !timelineHandlesLocked;
    notifyListeners();
  }

  /// How near (frames) a dragged layer edge must come to another layer's
  /// edge to snap to it (Timeline tab).
  int timelineSnapFrames = kLayerEdgeSnapThresholdFrames;

  void setTimelineSnapFrames(int frames) {
    timelineSnapFrames = frames.clamp(1, 120);
    notifyListeners();
  }

  /// Timeline lanes in their layer's colour (off: one neutral colour).
  bool timelineLayerColors = true;

  /// Frame counts on the timeline: each layer's length at its end, the
  /// frames between neighbouring keys.
  bool timelineFrameCounts = false;

  /// Flips one of the Settings tab's app preferences above.
  /// Sets one of the remembered toggles / values, wherever it is kept
  /// (per app or per project).
  void setAppPreference(String name, Object value) {
    (_appUi[name] ?? _projectUi[name]!).$2(value);
    notifyListeners();
  }

  bool appPreference(String name) => (_appUi[name] ?? _projectUi[name]!).$1() as bool;

  /// Snapping tab: "Enable all" - snapping and every category and sub-
  /// option on.
  void enableAllSnapping() {
    snapEnabled = true;
    snapEdgeToEdgeEnabled = true;
    snapCenterToCenterEnabled = true;
    snapCenterHorizontalEnabled = true;
    snapCenterVerticalEnabled = true;
    snapCenterDiagonalEnabled = true;
    snapCenterLineEnabled = true;
    snapEqualSpacingEnabled = true;
    snapCornerToCornerEnabled = true;
    snapEqualSizeEnabled = true;
    snapGridEnabled = true;
    gridOverlayEnabled = true; // snapping to an invisible grid would be confusing
    snapFrameBoundaryEnabled = true;
    snapRotationEnabled = true;
    snapRotationHorizontalEnabled = true;
    snapRotationVerticalEnabled = true;
    snapRotationDiagonalEnabled = true;
    snapRotationMatchNearbyEnabled = true;
    notifyListeners();
  }

  void toggleRecenterDetachedPieces() {
    recenterDetachedPieces = !recenterDetachedPieces;
    notifyListeners();
  }

  static Map<String, dynamic> _readUi(Map<String, (Object? Function(), void Function(Object?), Object?)> table) => {
        for (final e in table.entries)
          if (e.value.$1() != e.value.$3) e.key: e.value.$1(),
      };

  /// Sets every entry to the saved value, or its default when not saved
  /// (so one project's settings never leak into the next).
  static void _applyUi(Map<String, (Object? Function(), void Function(Object?), Object?)> table, Map<String, dynamic> saved) {
    for (final e in table.entries) {
      final v = saved.containsKey(e.key) ? saved[e.key] : e.value.$3;
      try {
        e.value.$2(v);
      } catch (_) {
        e.value.$2(e.value.$3); // a value of the wrong type: the default
      }
    }
  }

  /// This project's view settings that differ from the defaults.
  Map<String, dynamic> projectUiState() => _readUi(_projectUi);

  void applyProjectUiState(Map<String, dynamic> saved) => _applyUi(_projectUi, saved);

  /// The app's editing preferences that differ from the defaults.
  Map<String, dynamic> appUiState() => _readUi(_appUi);

  void applyAppUiState(Map<String, dynamic> saved) => _applyUi(_appUi, saved);

  String? _savedAppUi;

  /// Writes the app preferences when one changed (checked on every
  /// notification - a dozen values).
  void _persistAppUi() {
    final settings = AppSettings.instance;
    if (settings == null) return;
    final ui = appUiState();
    final key = jsonEncode(ui);
    if (key == _savedAppUi) return;
    _savedAppUi = key;
    unawaited(settings.setUi(ui));
  }

  // ===== storage: what media the project keeps, clearing undo, trimming =====

  /// The app's projects - to delete media no project uses any more (the
  /// home screen passes it; null in plain tests).
  ProjectStore? projectStore;

  /// Media the open project can still bring back: its layers and, unless
  /// `includeUndo` is false, every undo / redo step.
  ({Set<String> videos, Set<String> audios}) referencedMedia({bool includeUndo = true}) {
    final layers = [
      ...project.layers,
      if (includeUndo)
        for (final s in undo.snapshots) ...s,
    ];
    return (videos: videoAssetIdsOf(layers), audios: audioAssetIdsOf(layers));
  }

  /// Deletes imported media (source copies, frames, decoded sound) nothing
  /// references any more: no saved project, no layer of this one, no undo
  /// step. Saves first, so this project's file is current.
  Future<void> cleanupUnusedMedia() async {
    final store = projectStore;
    if (store == null) return;
    await saveNow();
    final keep = referencedMedia();
    await store.cleanupVideos(keepVideos: keep.videos, keepAudios: keep.audios);
  }

  /// Sizes for the Settings tab: copies of imported media, the rebuildable
  /// caches (frames, decoded sound), and what the undo history alone
  /// keeps (its steps, media only it uses, their decoded frames).
  Future<StorageOverview> storageOverview() async {
    final vs = videoStore, au = audioStore;
    var copies = 0, caches = 0, undoOnly = 0;
    if (vs != null) {
      copies += await directorySize(vs.sourcesDir);
      caches += await directorySize(vs.framesRoot);
    }
    if (au != null) {
      copies += await directorySize(au.sourcesDir);
      caches += await directorySize(au.pcmRoot);
    }
    final live = referencedMedia(includeUndo: false), all = referencedMedia();
    for (final id in all.videos.difference(live.videos)) {
      final s = await vs?.assetSize(id);
      if (s != null) undoOnly += s.source + s.frames;
    }
    for (final id in all.audios.difference(live.audios)) {
      final s = await au?.assetSize(id);
      if (s != null) undoOnly += s.source + s.decoded;
    }
    // every stored file, largest first.
    final files = <(String, int)>[];
    for (final dir in [vs?.sourcesDir, au?.sourcesDir]) {
      if (dir == null || !dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        files.add((f.uri.pathSegments.last, f.lengthSync()));
      }
    }
    files.sort((a, b) => b.$2.compareTo(a.$2));
    return StorageOverview(
      files: files,
      mediaCopyBytes: copies,
      cacheBytes: caches,
      undoSteps: undo.length,
      undoMediaBytes: undoOnly,
      undoDecodedBytes: renderer.videoFrames.unusedBytes,
    );
  }

  /// "Clear undo cache": forgets the undo / redo history, frees the
  /// decoded frames of videos no layer uses, and deletes media nothing
  /// references any more.
  Future<void> clearUndoCache() async {
    undo.clearHistory();
    renderer.videoFrames.releaseUnused();
    notifyListeners();
    await cleanupUnusedMedia();
  }

  /// What "Trim unused media" would cut: per video / sound, the stretches
  /// its layers play (+1 s each side), and roughly the bytes freed.
  Future<MediaTrimPreview> previewMediaTrim() async {
    final au = audioStore, vs = videoStore;
    final samples = <String, int>{};
    if (au != null) {
      for (final id in audioAssetIdsOf(project.layers)) {
        final f = au.pcmFile(id);
        if (f.existsSync()) samples[id] = f.lengthSync() ~/ (2 * audioChannels);
      }
    }
    final plan = planMediaTrim(project.layers, audioSamples: samples);
    var freed = 0;
    for (final e in plan.videos.entries) {
      final c = project.layers.firstWhere((l) => l.content.videoAssetId == e.key).content;
      final s = await vs?.assetSize(e.key);
      if (s == null) continue;
      freed += ((s.source + s.frames) * (1 - keptUnits(e.value) / c.videoFrameCount!)).round();
    }
    for (final e in plan.audios.entries) {
      final s = await au?.assetSize(e.key);
      if (s == null) continue;
      freed += ((s.source + s.decoded) * (1 - keptUnits(e.value) / samples[e.key]!)).round();
    }
    return MediaTrimPreview(videos: plan.videos, audios: plan.audios, freedBytes: freed);
  }

  /// "Trim unused media": rewrites each long video / sound to keep only
  /// what its layers play (+1 s margins) - the frames are copied (exactly
  /// the same pictures), the PCM sliced (exactly the same samples), the
  /// source copy re-encoded from them (VP9 / Opus) - and moves every
  /// layer's in-point to the same frame / sample of the new file. Clears
  /// undo (the cut parts no longer exist), then deletes the old files
  /// nothing else uses. Returns the names of media that couldn't be
  /// trimmed (left as they were).
  Future<List<String>> trimUnusedMedia(MediaTrimPreview preview) async {
    final failed = <String>[];
    final vs = videoStore, au = audioStore;
    for (final e in preview.videos.entries) {
      final layers = [for (final l in project.layers) if (l.content.videoAssetId == e.key) l];
      if (vs == null || layers.isEmpty) continue;
      final c = layers.first.content;
      if (!vs.hasFrames(e.key, c.videoFrameCount ?? 0, alpha: c.videoAlpha)) {
        failed.add(layers.first.name); // frames not extracted (yet) - nothing to copy from
        continue;
      }
      final newId = vs.newAssetId();
      final dst = vs.framesDir(newId);
      var out = File('${vs.sourcesDir.path}/$newId.webm');
      try {
        await dst.create(recursive: true);
        final src = vs.framesDir(e.key).path;
        for (final span in e.value) {
          for (var i = span.start; i < span.end; i++) {
            await File('$src/${videoFrameFileName(i, alpha: c.videoAlpha)}')
                .copy('${dst.path}/${videoFrameFileName(span.offset + i - span.start, alpha: c.videoAlpha)}');
          }
        }
        await vs.sourcesDir.create(recursive: true);
        out = await videoService.encodeFrameSequence(dst, fps: c.videoFps!, alpha: c.videoAlpha, outputPath: out.path);
      } catch (_) {
        failed.add(layers.first.name);
        if (await dst.exists()) await dst.delete(recursive: true);
        if (await out.exists()) await out.delete();
        continue;
      }
      for (final l in layers) {
        l.content
          ..sourceIn = remapSourceIn(l.content.sourceIn, e.value, c.videoFps!) ?? l.content.sourceIn
          ..videoAssetId = newId
          ..videoPath = out.path
          ..videoFrameCount = keptUnits(e.value);
      }
      renderer.videoFrames.clearAsset(e.key);
      _framesPresent.remove(e.key);
    }
    for (final e in preview.audios.entries) {
      final layers = [for (final l in project.layers) if (l.content.shape == 'audio' && l.content.audioAssetId == e.key) l];
      if (au == null || layers.isEmpty) continue;
      final newId = au.newAssetId();
      var out = File('${au.sourcesDir.path}/$newId.ogg');
      try {
        final pcm = await _loadPcm(au, e.key);
        const ch = audioChannels;
        final kept = Int16List(keptUnits(e.value) * ch);
        for (final span in e.value) {
          kept.setRange(span.offset * ch, (span.offset + span.length) * ch, pcm, span.start * ch);
        }
        await au.pcmRoot.create(recursive: true);
        await au.pcmFile(newId).writeAsBytes(kept.buffer.asUint8List());
        final peaks = await Isolate.run(() => computePeaks(kept));
        await au.writePeaks(newId, peaks);
        await au.sourcesDir.create(recursive: true);
        out = await audioService.encodePcm(au.pcmFile(newId), out.path);
        _pcm[newId] = kept;
        _peaks[newId] = peaks;
      } catch (_) {
        failed.add(layers.first.name);
        await au.removeAsset(newId);
        if (await out.exists()) await out.delete();
        continue;
      }
      for (final l in layers) {
        l.content
          ..sourceIn = remapSourceIn(l.content.sourceIn, e.value, audioSampleRate.toDouble()) ?? l.content.sourceIn
          ..audioAssetId = newId
          ..audioPath = out.path
          ..audioDuration = keptUnits(e.value) / audioSampleRate;
      }
    }
    undo.clearHistory();
    _loadedMixKey = null;
    _render();
    notifyListeners();
    _prepareAudioSoon();
    await cleanupUnusedMedia();
    return failed;
  }

  /// Media files carry their content hash next to their path (found by
  /// it when the path no longer resolves - see resolveMediaPath). Off the
  /// UI thread; files over 512 MB are left without one.
  Future<void> _hashMedia(Content content, File file) async {
    try {
      if (await file.length() > 512 << 20) return;
      final path = file.path;
      content.mediaHash = await Isolate.run(() => sha256Hex(File(path).readAsBytesSync()));
    } catch (_) {
      // no hash: the path alone still works.
    }
  }

  // ===== project references (model/project_ref.dart) =====

  /// The open project's stable id and save count (see save_load.dart).
  String projectId = newProjectId();
  int projectRevision = 0;

  /// The projects this one refers to (and theirs), as last saved - shared
  /// with the renderer.
  RefSources get refSources => renderer.refSources;

  /// Opens another project in the editor (the home screen sets it).
  Future<void> Function(String projectId)? onOpenProject;

  /// (Re)loads every referenced project's latest saved state: on opening,
  /// and on returning to the app (a source may have been edited in the
  /// meantime). Creates no undo step.
  /// How many saved projects show this one (Show in context needs one).
  int usedInCount = 0;

  Future<void> loadReferences() async {
    final store = projectStore;
    renderer.refChain = [projectId];
    if (store != null) {
      final n = (await store.usedIn(projectId)).length;
      if (n != usedInCount) {
        usedInCount = n;
        notifyListeners();
      }
    }
    final ids = directRefs(project);
    if (store == null || ids.isEmpty) return;
    renderer.refsLoading = true;
    try {
      final loaded = await store.loadSources(ids);
      renderer.refSources
        ..clear()
        ..addAll(loaded);
    } finally {
      renderer.refsLoading = false;
    }
    renderer.clearRefFrames();
    _render();
    notifyListeners();
  }

  /// The source of a reference layer, as loaded (null: missing).
  RefSource? refSourceOfLayer(String layerId) {
    final l = findLayer(project, layerId);
    return l == null || l.content.shape != 'projectRef' ? null : refSourceOf(l.content, refSources);
  }

  /// Whether the layer's source was saved since this project last saw it.
  bool refUpdatedLayer(Layer l) => refUpdated(l.content, refSources);

  /// The "updated" badge was seen (no undo step).
  void acknowledgeRefUpdate(String layerId) {
    final l = findLayer(project, layerId);
    final s = l == null ? null : refSourceOf(l.content, refSources);
    if (l == null || s == null) return;
    l.content.refLastSeenRevision = s.revision;
    notifyListeners();
  }

  /// Whether `sourceId` may be placed here (no projects containing each
  /// other).
  Future<bool> canReference(String sourceId) async {
    final store = projectStore;
    if (store == null) return sourceId != projectId;
    final graph = await store.graph();
    graph[projectId] = directRefs(project);
    return !refWouldCycle(projectId, sourceId, graph);
  }

  Future<RefSource?> _loadSource(String id) async {
    final store = projectStore;
    if (store == null) return null;
    final loaded = await store.loadSources([id]);
    renderer.refSources.addAll(loaded);
    return loaded[id];
  }

  /// Add -> Project...: a reference to saved project `sourceId`, centred
  /// and fit into the frame, as long as the source. One undo step.
  /// Returns an error to show, or null.
  Future<String?> addProjectRef(String sourceId) async {
    if (!await canReference(sourceId)) return refCycleMessage;
    final s = await _loadSource(sourceId);
    if (s == null) return 'Project not found';
    undo.pushUndoState(project);
    final layer = createProjectRefLayer(s,
        id: _newLayerId(), frameW: frameWidth, frameH: frameHeight, hostFps: fps, startFrame: 0);
    project.layers.add(layer);
    selection.selectedLayer = layer.id;
    _fitTimeline();
    _render();
    notifyListeners();
    return null;
  }

  /// Relink...: the reference shows `sourceId` instead. One undo step.
  Future<String?> relinkProjectRefLayer(String layerId, String sourceId) async {
    final l = findLayer(project, layerId);
    if (l == null) return null;
    if (!await canReference(sourceId)) return refCycleMessage;
    final s = await _loadSource(sourceId);
    if (s == null) return 'Project not found';
    undo.pushUndoState(project);
    relinkProjectRef(l, s);
    renderer.clearRefFrames();
    _render();
    notifyListeners();
    return null;
  }

  /// Unlink (embed copy): the reference keeps a copy of the source as it
  /// is now and no longer follows it. One undo step.
  Future<void> unlinkProjectRefLayer(String layerId) async {
    final l = findLayer(project, layerId);
    final id = l?.content.refProjectId;
    final store = projectStore;
    if (l == null || id == null || store == null) return;
    final json = await store.fileJsonOf(id);
    if (json == null) return;
    undo.pushUndoState(project);
    unlinkProjectRef(l, json);
    _render();
    notifyListeners();
  }

  // ===== Show in context =====

  /// The host project shown behind this one (null: off), which of its
  /// references to this project lines up with the stage, and how.
  RefSource? contextHost;
  int contextInstance = 0;
  bool contextVisible = false;
  double contextOpacity = 0.5;
  double contextResolution = 0.5;

  /// Where the stage frame falls outside that reference's time in the
  /// host (the host is held at the nearest end).
  bool contextOutside = false;

  final CanvasRenderer _contextRenderer = CanvasRenderer();

  /// The live version of this project, for the host's render: unsaved
  /// edits included (revision -1: never cached).
  RefSource get _liveSelf => RefSource(
        id: projectId,
        name: projectName,
        revision: -1,
        project: project,
        fps: fps,
        width: frameWidth,
        height: frameHeight,
        durationFrames: math.max(1, maxFrame),
        backgroundRgb: background == null ? null : background!.value & 0xFFFFFF,
      );

  /// Show in context -> `hostId`: loads that project (and what it refers
  /// to) and draws it behind the stage. Off again with [hideContext].
  Future<void> showInContext(String hostId, {int instance = 0}) async {
    final store = projectStore;
    if (store == null) return;
    final json = await store.fileJsonOf(hostId);
    final host = json == null ? null : RefSource.fromFileJson(json);
    if (host == null) return;
    final sources = await store.loadSources(directRefs(host.project));
    _contextRenderer
      ..refSources = sources
      ..refChain = [host.id]
      ..onImageDecoded = (() {
        _render();
        notifyListeners();
      });
    contextHost = host;
    contextInstance = instance;
    contextVisible = true;
    _render();
    notifyListeners();
  }

  void setContextVisible(bool v) {
    contextVisible = v && contextHost != null;
    _render();
    notifyListeners();
  }

  void hideContext() {
    contextHost = null;
    contextVisible = false;
    _render();
    notifyListeners();
  }

  void setContextLook({double? opacity, double? resolution}) {
    if (opacity != null) contextOpacity = opacity.clamp(0.0, 1.0);
    if (resolution != null) contextResolution = resolution.clamp(0.1, 1.0);
    _render();
    notifyListeners();
  }

  /// What the host's render uses for project `id` (tests).
  @visibleForTesting
  RefSource? contextSourceOf(String id) => _contextRenderer.refSources[id];

  /// The host's references to this project.
  List<Layer> get contextInstances => contextHost == null ? const [] : refInstances(contextHost!.project, projectId);

  /// Draws the host behind the stage (see renderFrame's underlay): the
  /// host at the matching time, rendered with this project's live state,
  /// placed so this project's frame lines up with where it sits there.
  void Function(Canvas canvas)? get contextUnderlay {
    final host = contextHost;
    if (host == null || !contextVisible) return null;
    final instances = contextInstances;
    if (instances.isEmpty) return null;
    final inst = instances[contextInstance.clamp(0, instances.length - 1)];
    return (canvas) {
      final self = _liveSelf;
      _contextRenderer.refSources[projectId] = self;
      final at = contextHostFrame(inst, currentFrame, self, host.fps);
      contextOutside = at.outside;
      // the instance's placement in host frame px, under the host's own
      // stage and frame rate.
      final hostW = stageSize.width, hostH = stageSize.height, hostFps = fps;
      List<double> m;
      Picture? pic;
      try {
        fps = host.fps;
        _contextRenderer.backgroundColor = host.backgroundRgb == null ? null : Color(0xFF000000 | host.backgroundRgb!);
        _contextRenderer.setSize(host.width, host.height);
        _contextRenderer.renderFrame(host.project, at.frame);
        pic = _contextRenderer.currentPicture;
        clearStateCaches();
        m = toFrameMatrix(getLayerStateAt(host.project, inst.id, at.frame).matrix);
      } finally {
        fps = hostFps;
        setStageSize(hostW, hostH);
        clearStateCaches();
      }
      if (pic == null) return;
      // this project's px -> the instance's content box -> host px.
      final c = inst.content;
      final sx = c.size[0] / self.width, sy = c.size[1] / self.height;
      final local = [sx, 0.0, 0.0, sy, c.offset[0] - c.size[0] / 2, c.offset[1] - c.size[1] / 2];
      final inv = invertAffine(matMul(m, local));
      // reduced resolution: the host as a smaller picture, scaled up.
      final k = contextResolution;
      final w = math.max(1, (host.width * k).round()), h = math.max(1, (host.height * k).round());
      final rec = PictureRecorder();
      Canvas(rec)
        ..scale(k)
        ..drawPicture(pic);
      final image = rec.endRecording().toImageSync(w, h);
      canvas.save();
      canvas.transform(Float64List.fromList(
          [inv[0], inv[1], 0, 0, inv[2], inv[3], 0, 0, 0, 0, 1, 0, inv[4], inv[5], 0, 1]));
      canvas.scale(1 / k);
      canvas.drawImage(image, Offset.zero,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Color.fromRGBO(0, 0, 0, contextOpacity));
      canvas.restore();
      image.dispose();
    };
  }

  /// Immediate, non-debounced save - for the app-lifecycle hook
  /// (backgrounding/closing, main.dart's WidgetsBindingObserver). A
  /// no-op if `openProject()` was never called (e.g. every plain
  /// `AppState()` test construction).
  Future<void> saveNow() async {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    await _writeAutosave();
  }

  /// Counted for the performance HUD: every notification rebuilds all the
  /// UI listening to this state.
  @override
  void notifyListeners() {
    if (perfInstrumentation) {
      PerfMonitor.instance
        ..countNotify()
        ..markActive();
    }
    frameNotifier.value = currentFrame;
    _frameUnannounced = false;
    // the selected layer's "Edit the whole object".
    editAllKeys = findLayer(project, selection.selectedLayer)?.editAll ?? false;
    _revalidateKeySelection();
    _persistAppUi();
    super.notifyListeners();
    _scheduleRegionBake();
  }

  Timer? _regionBakeTimer;

  /// Mask regions: their episodes (the areas' rows on the timeline,
  /// numbers, commands) are baked a
  /// few ms at a time between frames (a long animation with many sources
  /// takes seconds); when one is done the app redraws with it.
  void _scheduleRegionBake() {
    if (_regionBakeTimer != null) return;
    if (!project.layers.any((l) =>
        l.maskRegions != null &&
        l.maskRegions!.enabled &&
        l.maskRegions!.sources.isNotEmpty &&
        !regionBakeCurrent(project, l))) {
      return;
    }
    _regionBakeTimer = Timer(const Duration(milliseconds: 16), () {
      _regionBakeTimer = null;
      var pending = false, finished = false;
      for (final l in project.layers) {
        final mr = l.maskRegions;
        if (mr == null || !mr.enabled || mr.sources.isEmpty) continue;
        final before = regionEpisodesReady(project, l);
        if (!regionBakeStep(project, l, budgetMs: 8)) {
          pending = true;
          break;
        }
        if (!identical(before, regionEpisodesReady(project, l))) finished = true;
      }
      if (finished) {
        notifyListeners(); // schedules the next layer's, if any
      } else if (pending) {
        _scheduleRegionBake();
      }
    });
  }

  @override
  void dispose() {
    _playTicker?.dispose();
    if (playing) PerfMonitor.instance.playbackStopped();
    _playback?.dispose();
    _audioPrepTimer?.cancel();
    _autosaveTimer?.cancel();
    renderer.dispose();
    super.dispose();
  }
}

/// Storage sizes shown in Settings (bytes).
class StorageOverview {
  final int mediaCopyBytes, cacheBytes, undoSteps, undoMediaBytes, undoDecodedBytes;

  /// The stored media copies (file name, bytes), largest first.
  final List<(String, int)> files;
  const StorageOverview({
    this.files = const [],
    required this.mediaCopyBytes,
    required this.cacheBytes,
    required this.undoSteps,
    required this.undoMediaBytes,
    required this.undoDecodedBytes,
  });
}

/// What "Trim unused media" would keep of each video / sound (asset id ->
/// kept spans) and about how many bytes it frees.
class MediaTrimPreview {
  final Map<String, List<KeptSpan>> videos, audios;
  final int freedBytes;
  const MediaTrimPreview({required this.videos, required this.audios, required this.freedBytes});
  bool get isEmpty => videos.isEmpty && audios.isEmpty;
}
