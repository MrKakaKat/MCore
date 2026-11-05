/// Video layers: the mapping from the layer's own time to a frame of the
/// extracted (constant-rate) source, and creating a video layer.
library;

import 'dart:math' as math;

import 'audio.dart' show mediaSourceTime;
import 'project.dart';

/// Which source frame a video layer shows at `localFrame` (the layer's
/// own frame, at the project rate): t = sourceIn + localFrame / fps,
/// frame = floor(t * sourceFps), held at the first / last frame outside
/// the source. Null for non-video content.
int? videoSourceFrame(Content c, num localFrame) {
  if (c.shape != 'video') return null;
  final count = c.videoFrameCount ?? 0;
  final srcFps = c.videoFps ?? 0;
  if (count <= 0 || srcFps <= 0) return null;
  final t = mediaSourceTime(c, localFrame);
  final raw = (t * srcFps + 1e-6).floor();
  if (loopExtendedVideos && raw >= count) {
    // played to its end: again from where the layer starts in it.
    final first = (c.sourceIn * srcFps + 1e-6).floor().clamp(0, count - 1);
    return first + (raw - first) % (count - first);
  }
  return raw.clamp(0, count - 1);
}

/// Settings (Timeline tab): a video made longer than its source plays it
/// again from the start (like a GIF) instead of holding its last frame.
bool loopExtendedVideos = false;

/// The layer length (project frames) that plays the whole source once.
int videoDurationFrames(int frameCount, double sourceFps) =>
    math.max(1, (frameCount / sourceFps * fps).round());

int _videoCounter = 0;

/// A new video layer, sized to the frame's aspect inside `maxDimension`
/// and as long as the clip.
Layer createVideoLayer({
  required String path,
  required String assetId,
  required int width,
  required int height,
  required double sourceFps,
  required int frameCount,
  bool alpha = false,
  double maxDimension = 200,
}) {
  _videoCounter++;
  final aspect = (width <= 0 || height <= 0) ? 1.0 : width / height;
  final w = aspect >= 1 ? maxDimension : maxDimension * aspect;
  final h = aspect >= 1 ? maxDimension / aspect : maxDimension;
  return Layer(
    id: 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}v$_videoCounter',
    name: niceLayerName('video', _videoCounter),
    durationFrames: videoDurationFrames(frameCount, sourceFps),
    transform: Transform(
      anchor: track([0.5, 0.5], true),
      scale: track([1.0, 1.0]),
      rotation: track(0.0),
      opacity: track(1.0),
    ),
    content: Content(
      shape: 'video',
      offset: [0, 0],
      size: [w, h],
      imageNaturalWidth: width,
      imageNaturalHeight: height,
      videoPath: path,
      videoAssetId: assetId,
      videoFps: sourceFps,
      videoFrameCount: frameCount,
      videoAlpha: alpha,
    ),
  );
}

/// Asset ids of every video in the project.
Set<String> videoAssetIds(Project project) => {
      for (final l in project.layers)
        if (l.content.shape == 'video' && l.content.videoAssetId != null) l.content.videoAssetId!
    };
