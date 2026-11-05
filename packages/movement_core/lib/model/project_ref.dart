/// Project references: a layer whose content is another saved project
/// (content shape "projectRef"), rendered live from that project's
/// latest saved state.
///
/// - Sources are found by the project's stable id (never a name or path);
///   the app loads them (a [RefSources] map) when the host opens.
/// - Time maps in seconds, so projects of different frame rates mix:
///   local frame / host fps = source seconds, x source fps = source frame.
///   After the source's end: hold its last frame, loop, or hide.
/// - A reference may not lead back to its host (A -> B -> A); nesting is
///   capped at [maxRefDepth] levels. Either one, and a missing source,
///   draws a placeholder instead.
library;

import 'dart:math' as math;

import '../geometry/shapes.dart';
import '../ui_geometry/keyframe_strip.dart' show visitLayerTracks;
import 'project.dart';
import 'project_json.dart';

/// Nested references deeper than this draw a placeholder.
const int maxRefDepth = 4;

/// A referenced project as loaded: its saved file, parsed.
class RefSource {
  final String id;
  final String name;
  final int revision;
  final Project project;
  final int fps;
  final double width, height;

  /// Its length (frames at its own fps).
  final int durationFrames;

  /// "#RRGGBB" background, or null (transparent).
  final int? backgroundRgb;

  RefSource({
    required this.id,
    required this.name,
    required this.revision,
    required this.project,
    required this.fps,
    required this.width,
    required this.height,
    required this.durationFrames,
    this.backgroundRgb,
  });

  /// From a project file's JSON (see the app's save_load.dart envelope).
  /// Null when it isn't one.
  static RefSource? fromFileJson(Map<String, dynamic> data, {String? fallbackId}) {
    final p = data['project'];
    if (p is! Map || p['layers'] is! List) return null;
    final fps = (data['fps'] as num?)?.toInt() ?? 60;
    final maxFrame = (data['maxFrame'] as num?)?.toInt() ?? 180;
    final bg = data['background'];
    return RefSource(
      id: data['id'] as String? ?? fallbackId ?? '',
      name: data['name'] as String? ?? 'Untitled',
      revision: (data['revision'] as num?)?.toInt() ?? 0,
      project: Project(fps: fps, layers: projectLayersFromJson(p['layers'] as List<dynamic>)),
      fps: fps > 0 ? fps : 60,
      width: (data['frameWidth'] as num?)?.toDouble() ?? 480,
      height: (data['frameHeight'] as num?)?.toDouble() ?? 480,
      durationFrames: math.max(1, (data['timelineLength'] as num?)?.toInt() ?? maxFrame),
      backgroundRgb: bg is String ? int.tryParse(bg.replaceFirst('#', ''), radix: 16) : null,
    );
  }
}

/// Loaded sources by project id.
typedef RefSources = Map<String, RefSource>;

// a frozen copy (Unlink) parses once per map.
final Expando<RefSource> _embedded = Expando('embedded ref');

/// The source a reference draws: its frozen copy, or the loaded project.
RefSource? refSourceOf(Content c, RefSources sources) {
  final e = c.refEmbedded;
  if (e != null) return _embedded[e] ??= RefSource.fromFileJson(e, fallbackId: c.refProjectId);
  final id = c.refProjectId;
  return id == null ? null : sources[id];
}

/// The ids a project refers to directly (frozen copies don't count: they
/// never load anything).
Set<String> directRefs(Project p) => {
      for (final l in p.layers)
        if (l.content.shape == 'projectRef' && l.content.refEmbedded == null && l.content.refProjectId != null)
          l.content.refProjectId!
    };

/// Whether `target` is reachable from `from` through references.
bool refReaches(String from, String target, Map<String, Set<String>> graph) {
  final seen = <String>{};
  final todo = [from];
  while (todo.isNotEmpty) {
    final id = todo.removeLast();
    if (id == target) return true;
    if (!seen.add(id)) continue;
    todo.addAll(graph[id] ?? const {});
  }
  return false;
}

/// Whether placing `sourceId` in `hostId` would make projects contain
/// each other.
bool refWouldCycle(String hostId, String sourceId, Map<String, Set<String>> graph) =>
    hostId == sourceId || refReaches(sourceId, hostId, graph);

const refCycleMessage = 'This would make projects contain each other';

/// Why a reference draws a placeholder instead of its source.
enum RefStatus { ok, missing, cycle, tooDeep }

/// `chain`: the projects being rendered around this one (the host and its
/// hosts), outermost first.
RefStatus refStatus(Content c, RefSources sources, List<String> chain) {
  final src = refSourceOf(c, sources);
  if (src == null) return RefStatus.missing;
  if (c.refEmbedded == null && chain.contains(src.id)) return RefStatus.cycle;
  if (chain.length > maxRefDepth) return RefStatus.tooDeep;
  return RefStatus.ok;
}

/// The default length of a reference: the source's, in host frames.
int refDefaultDuration(RefSource s, int hostFps) => math.max(1, (s.durationFrames * hostFps / s.fps).round());

/// Source frame for host-local frame `local` (seconds-based); null while
/// hidden (after the end with "hide").
int? refSourceFrameAt(num local, RefSource s, int hostFps, String endBehavior) {
  final seconds = local / hostFps;
  final f = (seconds * s.fps + 1e-6).floor();
  final n = s.durationFrames;
  if (f < 0) return 0;
  if (f < n) return f;
  return switch (endBehavior) {
    'loop' => f % n,
    'hold' => n - 1,
    _ => null,
  };
}

/// Source frame a reference layer shows at host `globalFrame`.
int? refSourceFrame(Layer layer, num globalFrame, RefSource s, int hostFps) =>
    refSourceFrameAt(layerTimeFrame(layer, globalFrame) - layer.startFrame, s, hostFps, layer.content.refEndBehavior);

/// The host frame where host-local `local` frames fall for a source frame
/// (inverse of [refSourceFrameAt] within the first run).
int refHostLocalFrame(int sourceFrame, RefSource s, int hostFps) => (sourceFrame / s.fps * hostFps).round();

/// Whether nothing in the project moves (one rendered frame serves all).
bool projectIsStatic(Project p) {
  for (final l in p.layers) {
    if (isTimedMedia(l.content.shape) || l.content.shape == 'projectRef') return false;
    if (l.wiggle.enabled || l.pendulum.enabled || l.swing.enabled || l.physics.collide) return false;
    var keyed = false;
    visitLayerTracks(l, (t) {
      if (t.keyframes.length > 1 || t.expression != null) keyed = true;
    });
    if (keyed) return false;
    for (final e in l.effectStack) {
      for (final v in e.params.values) {
        if (v is Track && v.keyframes.length > 1) return false;
      }
    }
  }
  return true;
}

/// A new reference layer to `s` in a host of `frameW` x `frameH` at
/// `hostFps`: centred, the source's canvas fit inside the frame
/// ("contain") or at its own size ("original").
Layer createProjectRefLayer(RefSource s, {required String id, required double frameW, required double frameH,
    required int hostFps, int startFrame = 0, String fit = 'contain'}) {
  final k = fit == 'original' ? 1.0 : math.min(frameW / s.width, frameH / s.height);
  return Layer(
    id: id,
    name: s.name,
    startFrame: startFrame,
    durationFrames: refDefaultDuration(s, hostFps),
    transform: Transform(
      anchor: track([0.5, 0.5], true),
      scale: track([1.0, 1.0]),
      rotation: track(0.0),
      opacity: track(1.0),
    ),
    content: Content(shape: 'projectRef', offset: [0, 0], size: [s.width * k, s.height * k])
      ..refProjectId = s.id
      ..refFit = fit
      ..refLastSeenRevision = s.revision,
  );
}

/// Points a reference at another project, keeping its place, size on
/// stage (the box's longer side) and everything else.
void relinkProjectRef(Layer layer, RefSource s) {
  final c = layer.content;
  final box = math.max(c.size[0], c.size[1]);
  final k = box / math.max(s.width, s.height);
  c
    ..refProjectId = s.id
    ..refEmbedded = null
    ..refLastSeenRevision = s.revision
    ..size = [s.width * k, s.height * k];
  layer.name = s.name;
}

/// Unlink: the reference keeps a frozen copy of `fileJson` (the source's
/// file now) and no longer follows the source.
void unlinkProjectRef(Layer layer, Map<String, dynamic> fileJson) {
  layer.content.refEmbedded = fileJson;
}

/// Whether the source was saved again since the host last acknowledged
/// it ("updated" badge).
bool refUpdated(Content c, RefSources sources) {
  if (c.shape != 'projectRef' || c.refEmbedded != null) return false;
  final s = refSourceOf(c, sources);
  return s != null && s.revision > c.refLastSeenRevision;
}

/// The reference layers of `host` that show `sourceId`.
List<Layer> refInstances(Project host, String sourceId) => [
      for (final l in host.layers)
        if (l.content.shape == 'projectRef' && l.content.refEmbedded == null && l.content.refProjectId == sourceId) l
    ];

/// "Show in context": the host frame for source frame `sourceFrame` of
/// `instance`, clamped into the instance's time range; `outside` when it
/// had to be.
({int frame, bool outside}) contextHostFrame(Layer instance, int sourceFrame, RefSource s, int hostFps) {
  final f = instance.startFrame + refHostLocalFrame(sourceFrame, s, hostFps);
  final first = instance.startFrame, last = instance.startFrame + instance.durationFrames;
  return (frame: f.clamp(first, last), outside: f < first || f > last);
}
