import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:movement_core/movement_core.dart';

/// Ported from movement-core/src/io/saveLoad.js. Same envelope shape
/// ({version, project: {layers}, maxFrame, playbackSpeed, selectedLayer})
/// so a project file round-trips between the desktop (movement-core) and
/// mobile (this) ports without translation - project_json.dart's
/// layer<->JSON codec already guarantees the `layers` array itself uses
/// the exact JS key names, this just wraps it in the same top-level
/// envelope.
///
/// Unlike the browser original (Blob + <a download>), this writes/reads
/// a real file via dart:io - the natural mobile equivalent (no DOM, no
/// download prompt; callers own picking the destination/source File,
/// typically via a file-picker package not decided here).
///
/// Mobile-only additions (optional, so older files and the desktop port
/// still load): `name`, `frameWidth`/`frameHeight` (the frame size used to
/// not be saved at all), and `background` ("#RRGGBB", absent/null =
/// transparent), `mirrorX`/`mirrorY` (stage mirror), and `timelineLength` (a length the user set explicitly
/// via the Layers tab - absent = none, the timeline just fits the layers),
/// and `fps` (the project's frame rate - absent = 60).
///
/// Project references (model/project_ref.dart): `id` (a stable UUID - kept
/// through renames, saves and moves; a duplicate gets a new one; files
/// without one get one on first load), `revision` (+1 on every save) and
/// `savedAt` (ISO time).
class ProjectFileData {
  final Project project;
  final int maxFrame;
  final double playbackSpeed;
  final String? selectedLayer;
  final String? name;
  final double frameWidth;
  final double frameHeight;
  final int? backgroundRgb;
  final int? timelineLength;
  final bool mirrorX;
  final bool mirrorY;

  /// The project's own view settings (AppState.projectUiState) - absent in
  /// files saved before they were kept.
  final Map<String, dynamic> ui;

  /// The project's frame rate (absent in older files = 60).
  final int fps;

  /// Stable id (null in files saved before ids), save count, last save.
  final String? id;
  final int revision;
  final DateTime? savedAt;
  ProjectFileData({
    this.id,
    this.revision = 0,
    this.savedAt,
    this.fps = 60,
    required this.project,
    required this.maxFrame,
    required this.playbackSpeed,
    this.selectedLayer,
    this.name,
    this.frameWidth = defaultFrameWidth,
    this.frameHeight = defaultFrameHeight,
    this.backgroundRgb,
    this.timelineLength,
    this.mirrorX = false,
    this.mirrorY = false,
    this.ui = const {},
  });
}

const double defaultFrameWidth = 480;
const double defaultFrameHeight = 480;

/// A random (v4) UUID - a project's stable id.
String newProjectId() {
  final r = math.Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

Future<void> saveProjectToFile(File file, Project project,
    {required int maxFrame,
    required double playbackSpeed,
    String? selectedLayer,
    String? name,
    double frameWidth = defaultFrameWidth,
    double frameHeight = defaultFrameHeight,
    int? backgroundRgb,
    int? timelineLength,
    bool mirrorX = false,
    bool mirrorY = false,
    int projectFps = 60,
    String? projectId,
    int revision = 0,
    DateTime? savedAt,
    Map<String, dynamic>? ui}) async {
  final data = {
    'version': 1,
    if (projectId != null) 'id': projectId,
    'revision': revision,
    'savedAt': (savedAt ?? DateTime.now()).toUtc().toIso8601String(),
    'project': {'layers': projectLayersToJson(project), if (project.stageWalls) 'stageWalls': true},
    'maxFrame': maxFrame,
    'playbackSpeed': playbackSpeed,
    'selectedLayer': selectedLayer,
    if (name != null) 'name': name,
    'frameWidth': frameWidth,
    'frameHeight': frameHeight,
    'background': backgroundRgb == null
        ? null
        : '#${backgroundRgb.toRadixString(16).padLeft(6, '0')}',
    if (timelineLength != null) 'timelineLength': timelineLength,
    if (mirrorX) 'mirrorX': true,
    if (mirrorY) 'mirrorY': true,
    if (projectFps != 60) 'fps': projectFps,
    if (ui != null && ui.isNotEmpty) 'ui': ui,
  };
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
}

/// Throws FormatException on a file that isn't a recognized project
/// export - same "not a recognized project file" check the JS original
/// makes before touching any app state, so a bad load fails loudly
/// rather than partially clobbering the current project.
Future<ProjectFileData> loadProjectFromFile(File file) async {
  final raw = await file.readAsString();
  final data = jsonDecode(raw);
  if (data is! Map || data['project'] is! Map || (data['project'] as Map)['layers'] is! List) {
    throw const FormatException("not a recognized project file");
  }
  final layers = projectLayersFromJson((data['project'] as Map)['layers'] as List<dynamic>);
  return ProjectFileData(
    id: data['id'] as String?,
    revision: (data['revision'] as num?)?.toInt() ?? 0,
    savedAt: DateTime.tryParse(data['savedAt'] as String? ?? ''),
    project: Project(layers: layers, stageWalls: (data['project'] as Map)['stageWalls'] == true),
    maxFrame: (data['maxFrame'] as num?)?.toInt() ?? 180,
    playbackSpeed: (data['playbackSpeed'] as num?)?.toDouble() ?? 1,
    selectedLayer: data['selectedLayer'] as String?,
    name: data['name'] as String?,
    frameWidth: (data['frameWidth'] as num?)?.toDouble() ?? defaultFrameWidth,
    frameHeight: (data['frameHeight'] as num?)?.toDouble() ?? defaultFrameHeight,
    backgroundRgb: _parseRgb(data['background']),
    timelineLength: (data['timelineLength'] as num?)?.toInt(),
    mirrorX: data['mirrorX'] as bool? ?? false,
    mirrorY: data['mirrorY'] as bool? ?? false,
    fps: (data['fps'] as num?)?.toInt() ?? 60,
    ui: data['ui'] is Map ? Map<String, dynamic>.from(data['ui'] as Map) : const {},
  );
}

int? _parseRgb(Object? v) {
  if (v is! String) return null;
  return int.tryParse(v.replaceFirst('#', ''), radix: 16);
}
