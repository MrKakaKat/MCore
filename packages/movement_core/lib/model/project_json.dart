/// ============================================================
/// project <-> JSON, matching movement-core's own `JSON.stringify`
/// shape exactly (key names included: `default`, not `defaultValue` -
/// that Dart field is named around a reserved word, but the wire
/// format isn't) - a project saved on desktop (movement-core, the
/// Electron/JS port) opens on mobile and back, because the file format
/// never diverges between the two ports.
///
/// This intentionally stops at layer data (Project.layers), the same
/// scope movement-core/src/io/saveLoad.js's own `project.layers` field
/// covers - the wrapping `{version, project, maxFrame, playbackSpeed,
/// selectedLayer}` envelope and the actual file-picker/file-write are
/// app-level (playback/selection are UI state, not project data) and
/// touch platform file APIs, so they belong in movement_mobile/lib/io/
/// save_load.dart, not this platform-agnostic package.
/// ============================================================
library;

import 'line_path.dart' show LineNode;
import '../text/text_animators.dart' show TextAnimator;
import '../effects/motion/follow.dart' show FollowSettings;
import 'project.dart';

Map<String, dynamic> easingToJson(Easing e) => {
      'x1': e.x1,
      'y1': e.y1,
      'x2': e.x2,
      'y2': e.y2,
      if (e.isOvershoot) 'overshoot': {'kind': e.kind, 'amount': e.amount, 'bounces': e.bounces},
    };
Easing easingFromJson(Map<String, dynamic> j) {
  final o = j['overshoot'] as Map?;
  return Easing((j['x1'] as num).toDouble(), (j['y1'] as num).toDouble(), (j['x2'] as num).toDouble(),
      (j['y2'] as num).toDouble(),
      kind: o == null ? 'bezier' : o['kind'] as String? ?? 'overshoot',
      amount: (o?['amount'] as num?)?.toDouble() ?? 0.2,
      bounces: (o?['bounces'] as num?)?.toInt() ?? 0);
}

Map<String, dynamic> spatialTangentToJson(SpatialTangent t) =>
    {'in': t.inTan, 'out': t.outTan};
SpatialTangent spatialTangentFromJson(Map<String, dynamic> j) => SpatialTangent(
      inTan: (j['in'] as List).map((v) => (v as num).toDouble()).toList(),
      outTan: (j['out'] as List).map((v) => (v as num).toDouble()).toList(),
    );

dynamic _valueToJson(dynamic v) => v is List<double> ? v : v;
dynamic _valueFromJson(dynamic v) => v is List
    ? v.map((e) => (e as num).toDouble()).toList()
    : (v as num).toDouble();

Map<String, dynamic> keyframeToJson(Keyframe k) => {
      'frame': k.frame,
      'value': _valueToJson(k.value),
      'temporal': easingToJson(k.temporal),
      'spatialTangent': spatialTangentToJson(k.spatialTangent),
    };
Keyframe keyframeFromJson(Map<String, dynamic> j) => Keyframe(
      frame: j['frame'] as int,
      value: _valueFromJson(j['value']),
      temporal: j['temporal'] != null
          ? easingFromJson(j['temporal'] as Map<String, dynamic>)
          : null,
      spatialTangent: j['spatialTangent'] != null
          ? spatialTangentFromJson(j['spatialTangent'] as Map<String, dynamic>)
          : null,
    );

Map<String, dynamic> trackToJson(Track t) => {
      'default': _valueToJson(t.defaultValue),
      'spatial': t.spatial,
      'keyframes': t.keyframes.map(keyframeToJson).toList(),
      if (t.loop) 'loop': t.loop,
      if (t.tension != null) 'tension': t.tension,
      if (t.globalEasing != null) 'globalEasing': easingToJson(t.globalEasing!),
      if (t.constantSpeed) 'constantSpeed': true,
      if (t.animLayers.isNotEmpty)
        'animLayers': [
          for (final a in t.animLayers)
            {'track': trackToJson(a.track), if (a.multiply) 'multiply': true, if (!a.enabled) 'enabled': false}
        ],
      if (t.expression != null) 'expression': t.expression,
      if (t.hidden) 'hidden': t.hidden,
    };
Track trackFromJson(Map<String, dynamic> j) {
  final t = Track(_valueFromJson(j['default']), j['spatial'] as bool? ?? false);
  t.keyframes = ((j['keyframes'] as List?) ?? [])
      .map((k) => keyframeFromJson(k as Map<String, dynamic>))
      .toList();
  t.loop = j['loop'] as bool? ?? false;
  t.tension = (j['tension'] as num?)?.toDouble();
  t.constantSpeed = j['constantSpeed'] == true;
  t.animLayers = [
    for (final a in (j['animLayers'] as List? ?? const []))
      AnimLayer(
          track: trackFromJson((a as Map)['track'] as Map<String, dynamic>),
          multiply: a['multiply'] == true,
          enabled: a['enabled'] as bool? ?? true)
  ];
  t.globalEasing = j['globalEasing'] != null
      ? easingFromJson(j['globalEasing'] as Map<String, dynamic>)
      : null;
  t.expression = j['expression'] as String?;
  t.hidden = j['hidden'] as bool? ?? false;
  return t;
}

Map<String, dynamic> pathFollowToJson(PathFollow p) => {
      'enabled': p.enabled,
      'sourceLayerId': p.sourceLayerId,
      't': trackToJson(p.t),
      'parametrization': p.parametrization
    };
PathFollow pathFollowFromJson(Map<String, dynamic> j) => PathFollow(
      enabled: j['enabled'] as bool? ?? false,
      sourceLayerId: j['sourceLayerId'] as String?,
      t: trackFromJson(j['t'] as Map<String, dynamic>),
      parametrization: j['parametrization'] as String? ?? 'arcLength',
    );

Map<String, dynamic> transformToJson(Transform t) => {
      'anchor': trackToJson(t.anchor),
      'scale': trackToJson(t.scale),
      'rotation': trackToJson(t.rotation),
      'opacity': trackToJson(t.opacity),
      'pathFollow': pathFollowToJson(t.pathFollow),
    };
Transform transformFromJson(Map<String, dynamic> j) => Transform(
      anchor: trackFromJson(j['anchor'] as Map<String, dynamic>),
      scale: trackFromJson(j['scale'] as Map<String, dynamic>),
      rotation: trackFromJson(j['rotation'] as Map<String, dynamic>),
      opacity: trackFromJson(j['opacity'] as Map<String, dynamic>),
      pathFollow: j['pathFollow'] != null
          ? pathFollowFromJson(j['pathFollow'] as Map<String, dynamic>)
          : null,
    );

Map<String, dynamic> contentToJson(Content c) => {
      'shape': c.shape,
      'offset': c.offset,
      'size': c.size,
      if (c.sides != null) 'sides': c.sides,
      if (c.points != null) 'points': c.points,
      if (c.imageSourceType != null) 'imageSourceType': c.imageSourceType,
      if (c.imageData != null) 'imageData': c.imageData,
      if (c.imagePath != null) 'imagePath': c.imagePath,
      if (c.imageNaturalWidth != null) 'imageNaturalWidth': c.imageNaturalWidth,
      if (c.imageNaturalHeight != null) 'imageNaturalHeight': c.imageNaturalHeight,
      if (c.text != null) 'text': textSpecToJson(c.text!),
      if (c.contours != null) 'contours': c.contours,
      if (c.contourColors != null) 'contourColors': c.contourColors,
      if (c.contourJoin != null) 'contourJoin': c.contourJoin,
      if (c.videoPath != null) 'videoPath': c.videoPath,
      if (c.videoAssetId != null) 'videoAssetId': c.videoAssetId,
      if (c.shape == 'video') 'videoSourceIn': c.sourceIn,
      if (c.shape == 'audio') 'sourceIn': c.sourceIn,
      if (c.videoFps != null) 'videoFps': c.videoFps,
      if (c.videoFrameCount != null) 'videoFrameCount': c.videoFrameCount,
      if (c.videoAlpha) 'videoAlpha': true,
      if (c.playReversed) 'playReversed': true,
      if (c.audioPath != null) 'audioPath': c.audioPath,
      if (c.audioAssetId != null) 'audioAssetId': c.audioAssetId,
      if (c.audioDuration != null) 'audioDuration': c.audioDuration,
      if (c.volume != null) 'volume': trackToJson(c.volume!),
      if (c.audioMuted) 'audioMuted': true,
      if (c.mediaHash != null) 'mediaHash': c.mediaHash,
      if (c.gridCols != null && c.gridRows != null) 'grid': [c.gridCols, c.gridRows],
      if (c.lineNodes != null) ...{
        'lineNodes': [for (final n in c.lineNodes!) n.toJson()],
        'lineWidth': c.lineWidth,
        if (c.lineClosed) 'lineClosed': true,
        if (c.lineFilled) 'lineFilled': true,
        if (c.lineHidden) 'lineHidden': true,
        if (c.lineLocked) 'lineLocked': true,
        if (c.lineShowBox) 'lineShowBox': true,
        if (c.lineTrimStart != null) 'lineTrimStart': trackToJson(c.lineTrimStart!),
        if (c.lineTrimEnd != null) 'lineTrimEnd': trackToJson(c.lineTrimEnd!),
        if (c.lineCap != 'round') 'lineCap': c.lineCap,
        if (c.lineFillMode != 'outer') 'lineFillMode': c.lineFillMode,
        if (c.lineCapRound != 0) 'lineCapRound': c.lineCapRound,
        if (c.lineCapLength != 1) 'lineCapLength': c.lineCapLength,
        if (c.lineCapShape != 0.5523) 'lineCapShape': c.lineCapShape,
        if (c.lineJoin != 'round') 'lineJoin': c.lineJoin,
        if (c.lineMiterLimit != 4) 'lineMiterLimit': c.lineMiterLimit,
        if (!c.lineMirrorLength) 'lineMirrorLength': false,
      },
      if (c.shape == 'projectRef') ...{
        'projectId': c.refProjectId,
        'fit': c.refFit,
        'endBehavior': c.refEndBehavior,
        'lastSeenRevision': c.refLastSeenRevision,
        if (c.refEmbedded != null) 'embedded': c.refEmbedded,
      },
      if (c.placeholder) 'placeholder': true,
      if (c.shape == 'textGroup') ...{'textGroup': c.textGroup, 'textGroupPivot': c.textGroupPivot},
    };
Content contentFromJson(Map<String, dynamic> j) => Content(
      shape: j['shape'] as String,
      offset: (j['offset'] as List).map((v) => (v as num).toDouble()).toList(),
      size: (j['size'] as List).map((v) => (v as num).toDouble()).toList(),
      sides: j['sides'] as int?,
      points: (j['points'] as List?)
          ?.map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
          .toList(),
      imageSourceType: j['imageSourceType'] as String?,
      imageData: j['imageData'] as String?,
      imagePath: j['imagePath'] as String?,
      imageNaturalWidth: j['imageNaturalWidth'] as int?,
      imageNaturalHeight: j['imageNaturalHeight'] as int?,
      text: j['text'] is Map ? textSpecFromJson(j['text'] as Map<String, dynamic>) : null,
      videoPath: j['videoPath'] as String?,
      videoAssetId: j['videoAssetId'] as String?,
      sourceIn: ((j['sourceIn'] ?? j['videoSourceIn']) as num?)?.toDouble() ?? 0,
      videoFps: (j['videoFps'] as num?)?.toDouble(),
      videoFrameCount: (j['videoFrameCount'] as num?)?.toInt(),
      videoAlpha: j['videoAlpha'] as bool? ?? false,
      audioPath: j['audioPath'] as String?,
      audioAssetId: j['audioAssetId'] as String?,
      audioDuration: (j['audioDuration'] as num?)?.toDouble(),
      volume: j['volume'] != null
          ? trackFromJson(j['volume'] as Map<String, dynamic>)
          : (j['shape'] == 'audio' ? track(1.0) : null),
      audioMuted: j['audioMuted'] as bool? ?? false,
      contours: (j['contours'] as List?)
          ?.map((c) => (c as List)
              .map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
              .toList())
          .toList(),
    )
      ..playReversed = j['playReversed'] == true
      ..contourColors = (j['contourColors'] as List?)?.map((v) => v as String?).toList()
      ..contourJoin = (j['contourJoin'] as List?)?.map((v) => v == true).toList()
      ..mediaHash = j['mediaHash'] as String?
      ..gridCols = j['grid'] is List ? ((j['grid'] as List)[0] as num).toInt() : null
      ..gridRows = j['grid'] is List ? ((j['grid'] as List)[1] as num).toInt() : null
      ..lineNodes = (j['lineNodes'] as List?)?.map((n) => LineNode.fromJson(n as Map<String, dynamic>)).toList()
      ..lineWidth = (j['lineWidth'] as num?)?.toDouble() ?? 4
      ..lineClosed = j['lineClosed'] as bool? ?? false
      // files from before loops: closed meant filled.
      ..lineFilled = j['lineFilled'] as bool? ?? (j['lineClosed'] as bool? ?? false)
      ..lineHidden = j['lineHidden'] as bool? ?? false
      ..lineLocked = j['lineLocked'] as bool? ?? false
      ..lineShowBox = j['lineShowBox'] as bool? ?? false
      ..lineTrimStart = j['lineTrimStart'] is Map ? trackFromJson(j['lineTrimStart'] as Map<String, dynamic>) : null
      ..lineTrimEnd = j['lineTrimEnd'] is Map ? trackFromJson(j['lineTrimEnd'] as Map<String, dynamic>) : null
      ..lineCap = j['lineCap'] as String? ?? 'round'
      // files from before the fill kinds filled through the points.
      ..lineFillMode = j['lineFillMode'] as String? ?? (j['lineFilled'] == true ? 'points' : 'outer')
      ..lineCapRound = (j['lineCapRound'] as num?)?.toDouble() ?? 0
      ..lineCapLength = (j['lineCapLength'] as num?)?.toDouble() ?? 1
      ..lineCapShape = (j['lineCapShape'] as num?)?.toDouble() ?? 0.5523
      ..lineJoin = j['lineJoin'] as String? ?? 'round'
      ..lineMiterLimit = (j['lineMiterLimit'] as num?)?.toDouble() ?? 4
      ..lineMirrorLength = j['lineMirrorLength'] as bool? ?? true
      ..refProjectId = j['projectId'] as String?
      ..refFit = j['fit'] as String? ?? 'contain'
      ..refEndBehavior = j['endBehavior'] as String? ?? 'hide'
      ..refLastSeenRevision = (j['lastSeenRevision'] as num?)?.toInt() ?? 0
      ..refEmbedded = j['embedded'] is Map ? Map<String, dynamic>.from(j['embedded'] as Map) : null
      ..placeholder = j['placeholder'] == true
      ..textGroup = (j['textGroup'] as num?)?.toInt() ?? 0
      ..textGroupPivot = j['textGroupPivot'] is List
          ? [for (final v in j['textGroupPivot'] as List) (v as num).toDouble()]
          : const [0, 0];

Map<String, dynamic> textSpecToJson(TextSpec t) => {
      'text': t.text,
      'fontId': t.fontId,
      'fontSize': t.fontSize,
      'letterSpacing': t.letterSpacing,
      'lineSpacing': t.lineSpacing,
      'align': t.align,
      'color': t.color,
      'strokeWidth': t.strokeWidth,
      'strokeColor': t.strokeColor,
      'shadow': _shadowToJson(t.shadow),
      if (t.autoBox) 'autoBox': true,
      if (t.knockout) 'knockout': true,
      if (t.groupsEnabled) 'groupsEnabled': true,
      if (t.groupChar != '#') 'groupChar': t.groupChar,
      if (t.animators.isNotEmpty) 'animators': [for (final a in t.animators) a.toJson()],
      if (t.keys.isNotEmpty) 'keys': [for (final k in t.keys) {'frame': k.frame, 'text': k.value as String}],
      if (t.spans.isNotEmpty)
        'spans': [
          for (final s in t.spans)
            {
              'start': s.start,
              'end': s.end,
              if (s.size != null) 'size': s.size,
              if (s.color != null) 'color': s.color,
              if (s.rise != null) 'rise': s.rise,
              if (s.fontId != null) 'font': s.fontId,
              if (s.name.isNotEmpty) 'name': s.name,
              if (s.move != null) 'move': trackToJson(s.move!),
              if (s.turn != null) 'turn': trackToJson(s.turn!),
              if (s.scale != null) 'scale': trackToJson(s.scale!),
              if (s.opacity != null) 'opacity': trackToJson(s.opacity!),
              for (final e in {'blur': s.blur, 'spacing': s.spacing, 'shake': s.shake, 'wobble': s.wobble, 'tint': s.tint}.entries)
                if (e.value != null) e.key: trackToJson(e.value!),
              if (s.tintColor != null) 'tintColor': s.tintColor,
              if (s.from != null) 'from': s.from,
              if (s.to != null) 'to': s.to,
            }
        ],
      'background': {
        'enabled': t.background.enabled,
        'color': t.background.color,
        'opacity': t.background.opacity,
        'padding': t.background.padding,
        if (t.background.radius > 0) 'radius': t.background.radius,
        if (t.background.radiusShape != 0.5523) 'radiusShape': t.background.radiusShape,
      },
    };

TextSpec textSpecFromJson(Map<String, dynamic> j) {
  double n(Map<String, dynamic>? m, String k, double d) => (m?[k] as num?)?.toDouble() ?? d;
  final sh = j['shadow'] as Map<String, dynamic>?, bg = j['background'] as Map<String, dynamic>?;
  final defaults = TextSpec();
  final spec = TextSpec(
    text: j['text'] as String? ?? '',
    groupsEnabled: j['groupsEnabled'] as bool? ?? false,
    groupChar: j['groupChar'] as String? ?? '#',
    fontId: j['fontId'] as String? ?? defaults.fontId,
    fontSize: n(j, 'fontSize', defaults.fontSize),
    letterSpacing: n(j, 'letterSpacing', 0),
    lineSpacing: n(j, 'lineSpacing', defaults.lineSpacing),
    align: j['align'] as String? ?? defaults.align,
    color: j['color'] as String? ?? defaults.color,
    strokeWidth: n(j, 'strokeWidth', 0),
    strokeColor: j['strokeColor'] as String? ?? defaults.strokeColor,
    shadow: _shadowFromJson(sh),
    autoBox: j['autoBox'] as bool? ?? false,
    animators: [for (final a in (j['animators'] as List?) ?? const []) TextAnimator.fromJson(a as Map<String, dynamic>)],
    textKeys: Track('', false)
      ..keyframes = [
        for (final k in (j['keys'] as List?) ?? const [])
          Keyframe(frame: (k['frame'] as num).toInt(), value: k['text'] as String? ?? '')
      ],
    spans: [
      for (final s in (j['spans'] as List?) ?? const [])
        TextStyleSpan((s['start'] as num).toInt(), (s['end'] as num).toInt(),
            size: (s['size'] as num?)?.toDouble(),
            color: s['color'] as String?,
            rise: (s['rise'] as num?)?.toDouble(),
            fontId: s['font'] as String?,
            name: s['name'] as String? ?? '',
            move: s['move'] is Map ? trackFromJson(Map<String, dynamic>.from(s['move'] as Map)) : null,
            turn: s['turn'] is Map ? trackFromJson(Map<String, dynamic>.from(s['turn'] as Map)) : null,
            scale: s['scale'] is Map ? trackFromJson(Map<String, dynamic>.from(s['scale'] as Map)) : null,
            opacity: s['opacity'] is Map ? trackFromJson(Map<String, dynamic>.from(s['opacity'] as Map)) : null,
            from: (s['from'] as num?)?.toInt(),
            to: (s['to'] as num?)?.toInt(),
            blur: s['blur'] is Map ? trackFromJson(Map<String, dynamic>.from(s['blur'] as Map)) : null,
            spacing: s['spacing'] is Map ? trackFromJson(Map<String, dynamic>.from(s['spacing'] as Map)) : null,
            shake: s['shake'] is Map ? trackFromJson(Map<String, dynamic>.from(s['shake'] as Map)) : null,
            wobble: s['wobble'] is Map ? trackFromJson(Map<String, dynamic>.from(s['wobble'] as Map)) : null,
            tint: s['tint'] is Map ? trackFromJson(Map<String, dynamic>.from(s['tint'] as Map)) : null,
            tintColor: s['tintColor'] as String?)
    ],
    background: TextBackgroundSpec(
      enabled: bg?['enabled'] as bool? ?? false,
      color: bg?['color'] as String? ?? '#000000',
      opacity: n(bg, 'opacity', 0.6),
      padding: n(bg, 'padding', 8),
      radius: n(bg, 'radius', 0),
      radiusShape: n(bg, 'radiusShape', 0.5523),
    ),
  );
  spec.knockout = j['knockout'] == true;
  return spec;
}

Map<String, dynamic> maskToJson(Mask m) => {
      'enabled': m.enabled,
      'mode': m.mode,
      'sourceLayerId': m.sourceLayerId,
      if (m.moreSources.isNotEmpty) 'moreSources': m.moreSources,
      if (m.sourcePart != null) 'sourcePart': m.sourcePart,
      'feather': trackToJson(m.feather),
      if (m.featherOutside != 1) 'featherOutside': m.featherOutside,
      if (m.invert) 'invert': true,
      if (m.range != null) 'range': m.range,
    };
Mask maskFromJson(Map<String, dynamic> j) => Mask(
      enabled: j['enabled'] as bool? ?? true,
      mode: j['mode'] as String? ?? 'add',
      sourceLayerId: j['sourceLayerId'] as String?,
      moreSources: [for (final e in (j['moreSources'] as List? ?? const [])) e as String],
      sourcePart: (j['sourcePart'] as num?)?.toInt(),
      feather: j['feather'] != null
          ? trackFromJson(j['feather'] as Map<String, dynamic>)
          : null,
      featherOutside: (j['featherOutside'] as num?)?.toDouble() ?? 1,
      invert: j['invert'] == true,
      range: (j['range'] as List?)?.map((v) => (v as num).toInt()).toList(),
    );

dynamic _paramValueToJson(dynamic v) => v is Track ? trackToJson(v) : v;
dynamic _paramValueFromJson(dynamic v) =>
    (v is Map && v.containsKey('keyframes'))
        ? trackFromJson(v.cast<String, dynamic>())
        : v;

Map<String, dynamic> effectInstanceToJson(EffectInstance i) => {
      'id': i.id,
      'effectId': i.effectId,
      'enabled': i.enabled,
      'params': {
        for (final e in i.params.entries) e.key: _paramValueToJson(e.value)
      },
    };
EffectInstance effectInstanceFromJson(Map<String, dynamic> j) => EffectInstance(
      id: j['id'] as String,
      effectId: j['effectId'] as String,
      enabled: j['enabled'] as bool? ?? true,
      params: {
        for (final e in (j['params'] as Map<String, dynamic>).entries)
          e.key: _paramValueFromJson(e.value),
      },
    );

Map<String, dynamic> motionBlurToJson(MotionBlur m) => {
      'enabled': m.enabled,
      'shutterAngle': m.shutterAngle,
      'samples': m.samples
    };
MotionBlur motionBlurFromJson(Map<String, dynamic> j) => MotionBlur(
      enabled: j['enabled'] as bool? ?? false,
      shutterAngle: (j['shutterAngle'] as num?)?.toDouble() ?? 180,
      samples: j['samples'] as int? ?? 8,
    );

Map<String, dynamic> wiggleToJson(Wiggle w) => {
      'enabled': w.enabled,
      'speed': w.speed,
      'amplitude': w.amplitude,
      'smoothness': w.smoothness
    };
Wiggle wiggleFromJson(Map<String, dynamic> j) => Wiggle(
      enabled: j['enabled'] as bool? ?? false,
      speed: (j['speed'] as num?)?.toDouble() ?? 30,
      amplitude: (j['amplitude'] as num?)?.toDouble() ?? 20,
      smoothness: (j['smoothness'] as num?)?.toDouble() ?? 70,
    );

Map<String, dynamic> pendulumToJson(Pendulum p) => {
      'enabled': p.enabled,
      'frequency': p.frequency,
      'damping': p.damping,
      'sensitivity': p.sensitivity,
      'pivotOffset': trackToJson(p.pivotOffset),
      'maxAngle': p.maxAngle,
      'freeze': p.freeze,
      'rotateWithLine': p.rotateWithLine,
      if (p.weightPoint != null) 'weightPoint': p.weightPoint,
    };
Pendulum pendulumFromJson(Map<String, dynamic> j) => Pendulum(
      enabled: j['enabled'] as bool? ?? false,
      frequency: (j['frequency'] as num?)?.toDouble() ?? 20,
      damping: (j['damping'] as num?)?.toDouble() ?? 50,
      sensitivity: (j['sensitivity'] as num?)?.toDouble() ?? 50,
      pivotOffset: j['pivotOffset'] != null
          ? trackFromJson(j['pivotOffset'] as Map<String, dynamic>)
          : null,
      maxAngle: (j['maxAngle'] as num?)?.toDouble() ?? 40,
      freeze: (j['freeze'] as num?)?.toDouble() ?? 60,
      rotateWithLine: j['rotateWithLine'] as bool? ?? true,
      weightPoint: (j['weightPoint'] as List?)?.map((v) => (v as num).toDouble()).toList(),
    );

Map<String, dynamic> swingToJson(Swing s) => {
      'enabled': s.enabled,
      'minAngle': s.minAngle,
      'maxAngle': s.maxAngle,
      'frequency': s.frequency,
      'phase': s.phase,
      'damping': s.damping,
    };
Swing swingFromJson(Map<String, dynamic> j) => Swing(
      enabled: j['enabled'] as bool? ?? false,
      minAngle: (j['minAngle'] as num?)?.toDouble() ?? -20,
      maxAngle: (j['maxAngle'] as num?)?.toDouble() ?? 20,
      frequency: (j['frequency'] as num?)?.toDouble() ?? 1,
      phase: (j['phase'] as num?)?.toDouble() ?? 0,
      damping: (j['damping'] as num?)?.toDouble() ?? 0,
    );

Map<String, dynamic> timeQuantizeToJson(TimeQuantize q) => {'enabled': q.enabled, 'fps': q.fps};
TimeQuantize timeQuantizeFromJson(Map<String, dynamic> j) => TimeQuantize(
      enabled: j['enabled'] as bool? ?? false,
      fps: (j['fps'] as num?)?.toDouble() ?? 12,
    );

Map<String, dynamic> chromaKeyToJson(ChromaKey c) => {
      'enabled': c.enabled,
      'color': c.color,
      'strength': c.strength,
      'softness': c.softness,
      'scope': c.scope,
      if (c.region.isNotEmpty) 'region': c.region,
      if (c.applied.isNotEmpty) 'applied': [for (final k in c.applied) chromaKeyToJson(k)],
      if (c.contiguous) 'contiguous': true,
      if (c.seed != null) 'seed': c.seed,
      if (c.expand != 0) 'expand': c.expand,
      if (c.invert) 'invert': true,
      if (c.feather != 0) 'feather': c.feather,
    };
ChromaKey chromaKeyFromJson(Map<String, dynamic> j) => ChromaKey(
      enabled: j['enabled'] as bool? ?? false,
      color: j['color'] as String? ?? '#00ff00',
      strength: (j['strength'] as num?)?.toDouble() ?? 0.4,
      softness: (j['softness'] as num?)?.toDouble() ?? 0.2,
      scope: j['scope'] as String? ?? 'whole',
      region: (j['region'] as List?)
          ?.map((p) => (p as List).map((v) => (v as num).toDouble()).toList())
          .toList(),
      applied: (j['applied'] as List?)?.map((k) => chromaKeyFromJson(k as Map<String, dynamic>)).toList(),
    )
      ..contiguous = j['contiguous'] == true
      ..seed = (j['seed'] as List?)?.map((v) => (v as num).toDouble()).toList()
      ..expand = (j['expand'] as num?)?.toDouble() ?? 0
      ..invert = j['invert'] == true
      ..feather = (j['feather'] as num?)?.toDouble() ?? 0;

Map<String, dynamic> shapeFillToJson(ShapeFill f) => {
      'gradient': f.gradient,
      'glows': [
        for (final g in f.glows)
          {
            'id': g.id,
            'kind': g.kind,
            'color': g.color,
            'enabled': g.enabled,
            'position': trackToJson(g.position),
            'end': trackToJson(g.end),
            'radius': trackToJson(g.radius),
            'strength': trackToJson(g.strength),
          }
      ],
      if (f.cornerRadius > 0) 'cornerRadius': f.cornerRadius,
      if (f.cornerShape != 0.5523) 'cornerShape': f.cornerShape,
      if (f.outerRadius > 0) 'outerRadius': f.outerRadius,
      if (!f.cornersKeepRound) 'cornersKeepRound': false,
      if (f.shadow.enabled) 'shadow': _shadowToJson(f.shadow),
      if (f.paint != null) 'paint': fillGradientToJson(f.paint!),
    };

Map<String, dynamic> fillGradientToJson(FillGradient g) => {
      'type': g.type,
      if (g.type == 'linear') ...{'x1': g.x1, 'y1': g.y1, 'x2': g.x2, 'y2': g.y2},
      if (g.type == 'radial') ...{'cx': g.cx, 'cy': g.cy, 'r': g.r},
      'matrix': g.matrix,
      'stops': [
        for (final s in g.stops) {'offset': s.offset, 'color': s.color, if (s.opacity != 1) 'opacity': s.opacity}
      ],
      if (g.spread != 'pad') 'spread': g.spread,
    };

FillGradient fillGradientFromJson(Map<String, dynamic> j) {
  double n(String k, double d) => (j[k] as num?)?.toDouble() ?? d;
  return FillGradient(
    type: j['type'] as String? ?? 'linear',
    x1: n('x1', 0),
    y1: n('y1', 0),
    x2: n('x2', 1),
    y2: n('y2', 0),
    cx: n('cx', 0.5),
    cy: n('cy', 0.5),
    r: n('r', 0.5),
    matrix: j['matrix'] is List ? [for (final v in j['matrix'] as List) (v as num).toDouble()] : null,
    stops: [
      for (final s in (j['stops'] as List? ?? const []))
        GradientStop((s['offset'] as num).toDouble(), s['color'] as String, (s['opacity'] as num?)?.toDouble() ?? 1)
    ],
    spread: j['spread'] as String? ?? 'pad',
  );
}

Map<String, dynamic> _shadowToJson(TextShadowSpec s) => {
      'enabled': s.enabled,
      'dx': s.dx,
      'dy': s.dy,
      'color': s.color,
      'opacity': s.opacity,
      if (s.long) 'long': true,
      if (s.scale != 1) 'scale': s.scale,
      if (s.lag) 'lag': true,
      if (s.lagSpeed != 60) 'lagSpeed': s.lagSpeed,
      if (s.lagBounciness != 30) 'lagBounciness': s.lagBounciness,
      if (s.perLetter) 'perLetter': true,
      if (s.echo) 'echo': true,
      if (s.echoCount != 5) 'echoCount': s.echoCount,
      if (s.echoFade.defaultValue != 0.8 || s.echoFade.keyframes.isNotEmpty) 'echoFade': trackToJson(s.echoFade),
    };

TextShadowSpec _shadowFromJson(Map<String, dynamic>? sh) => TextShadowSpec(
      enabled: sh?['enabled'] as bool? ?? false,
      dx: (sh?['dx'] as num?)?.toDouble() ?? 4,
      dy: (sh?['dy'] as num?)?.toDouble() ?? 4,
      color: sh?['color'] as String? ?? '#000000',
      opacity: (sh?['opacity'] as num?)?.toDouble() ?? 0.6,
      long: sh?['long'] as bool? ?? false,
      scale: (sh?['scale'] as num?)?.toDouble() ?? 1,
      lag: sh?['lag'] as bool? ?? false,
      lagSpeed: (sh?['lagSpeed'] as num?)?.toDouble() ?? 60,
      lagBounciness: (sh?['lagBounciness'] as num?)?.toDouble() ?? 30,
      perLetter: sh?['perLetter'] as bool? ?? false,
      echo: sh?['echo'] as bool? ?? false,
      echoCount: (sh?['echoCount'] as num?)?.toInt() ?? 5,
      echoFade: sh?['echoFade'] is Map
          ? trackFromJson(sh!['echoFade'] as Map<String, dynamic>)
          : Track((sh?['echoFade'] as num?)?.toDouble() ?? 0.8, false),
    );
ShapeFill shapeFillFromJson(Map<String, dynamic> j) {
  Track? t(Map g, String k) => g[k] != null ? trackFromJson(g[k] as Map<String, dynamic>) : null;
  return ShapeFill(
    gradient: j['gradient'] as bool? ?? false,
    glows: [
      for (final g in (j['glows'] as List? ?? const []))
        GlowEmitter(
          id: (g as Map)['id'] as String? ?? 'glow',
          kind: g['kind'] as String? ?? 'point',
          color: g['color'] as String? ?? '#ffffff',
          enabled: g['enabled'] as bool? ?? true,
          position: t(g, 'position'),
          end: t(g, 'end'),
          radius: t(g, 'radius'),
          strength: t(g, 'strength'),
        )
    ],
    cornerRadius: (j['cornerRadius'] as num?)?.toDouble() ?? 0,
    cornerShape: (j['cornerShape'] as num?)?.toDouble() ?? 0.5523,
    outerRadius: (j['outerRadius'] as num?)?.toDouble() ?? 0,
    cornersKeepRound: j['cornersKeepRound'] != false,
    shadow: j['shadow'] is Map ? _shadowFromJson(j['shadow'] as Map<String, dynamic>) : null,
    paint: j['paint'] is Map ? fillGradientFromJson(j['paint'] as Map<String, dynamic>) : null,
  );
}

Map<String, dynamic> layerToJson(Layer l) => {
      'id': l.id,
      'name': l.name,
      'parentId': l.parentId,
      'startFrame': l.startFrame,
      'durationFrames': l.durationFrames,
      'transform': transformToJson(l.transform),
      'content': contentToJson(l.content),
      'masks': l.masks.map(maskToJson).toList(),
      'effectStack': l.effectStack.map(effectInstanceToJson).toList(),
      'color': l.color,
      'renderMode': l.renderMode,
      'hidden': l.hidden,
      'motionBlur': motionBlurToJson(l.motionBlur),
      'wiggle': wiggleToJson(l.wiggle),
      'pendulum': pendulumToJson(l.pendulum),
      if (l.groupedChildren != null) 'groupedChildren': l.groupedChildren,
      if (l.precompose != null) 'precompose': l.precompose,
      // mobile-only additions, written only when set so older readers
      // (and the desktop port) see the same file as before.
      if (l.crop.any((v) => v != 0)) 'crop': l.crop,
      if (l.cropAspect != 'free') 'cropAspect': l.cropAspect,
      if (l.mirrorX) 'mirrorX': true,
      if (l.mirrorY) 'mirrorY': true,
      if (l.effectPanelOrder.isNotEmpty) 'effectPanelOrder': l.effectPanelOrder,
      if (l.effectRanges.isNotEmpty) 'effectRanges': l.effectRanges,
      if (l.parentFrom != null) 'parentFrom': l.parentFrom,
      if (l.parentUntil != null) 'parentUntil': l.parentUntil,
      if (l.mirrorSourceId != null) 'mirror': {'source': l.mirrorSourceId, 'axis': l.mirrorAxis},
      if (l.mirrorProbe) 'mirrorProbe': true,
      if (l.mirrorAllLayers) 'mirrorAllLayers': true,
      if (l.locked) 'locked': true,
      if (l.parentKeepDifference) 'parentKeepDifference': true,
      if (l.folder != null) 'folder': l.folder,
      if (l.rowId != null) 'row': l.rowId,
      if (l.splitRoot != null) 'splitRoot': l.splitRoot,
      if (l.loopEnabled) 'loop': {'until': l.loopUntil},
      if (!l.inheritPosition || !l.inheritRotation || !l.inheritScale)
        'inherit': {'position': l.inheritPosition, 'rotation': l.inheritRotation, 'scale': l.inheritScale},
      if (l.swing.enabled) 'swing': swingToJson(l.swing),
      if (l.maskRegions != null)
        'maskRegions': {
          'enabled': l.maskRegions!.enabled,
          'sources': l.maskRegions!.sources,
          'opacity': {for (final e in l.maskRegions!.opacity.entries) '${e.key}': trackToJson(e.value)},
          if (l.maskRegions!.feather.any((f) => f != 0)) 'feather': l.maskRegions!.feather,
          if (l.maskRegions!.numbered) 'numbered': true,
          if (l.maskRegions!.commands.isNotEmpty) 'commands': [for (final c in l.maskRegions!.commands) c.toJson()],
        },
      if (l.links.isNotEmpty)
        'links': [
          for (final k in l.links)
            {if (!k.enabled) 'enabled': false, 'source': k.sourceId, 'from': k.from, 'to': k.to, 'factor': k.factor, if (k.base != null) 'base': k.base}
        ],
      if (l.cuts.isNotEmpty)
        'cuts': [
          for (final c in l.cuts)
            {
              if (!c.enabled) 'enabled': false,
              'cutter': c.cutterId,
              'mode': c.mode,
              'gap': trackToJson(c.gap),
              'join': c.join,
              if (c.hideCutter) 'hideCutter': true,
              if (c.onlyWhenTouching) 'onlyWhenTouching': true,
            }
        ],
      if (l.filters.any) 'filters': {'negative': trackToJson(l.filters.negative)},
      if (l.follow.enabled || l.follow.targetId != null) 'follow': l.follow.toJson(),
      if (l.confirmHistory.isNotEmpty) 'confirmHistory': l.confirmHistory,
      if (l.pieceClips.isNotEmpty)
        'pieces': [
          for (final c in l.pieceClips) {'points': c.points, 'inside': c.inside}
        ],
      if (l.fill.gradient ||
          l.fill.glows.isNotEmpty ||
          l.fill.cornerRadius > 0 ||
          l.fill.outerRadius > 0 ||
          l.fill.shadow.enabled ||
          l.fill.paint != null)
        'fill': shapeFillToJson(l.fill),
      if (l.linkId != null) 'link': l.linkId,
      if (l.edgeMatte) 'edgeMatte': {'color': l.edgeMatteColor, 'strength': l.edgeMatteStrength},
      if (l.timeQuantize.enabled) 'timeQuantize': timeQuantizeToJson(l.timeQuantize),
      if (l.physics.collide) 'physics': l.physics.toJson(),
      if (l.chromaKey.enabled || l.chromaKey.region.isNotEmpty || l.chromaKey.applied.isNotEmpty) 'chromaKey': chromaKeyToJson(l.chromaKey),
    };

/// (Older mask regions on a shape take the layer itself in - see
/// ensureRegionSelf.)
Layer layerFromJson(Map<String, dynamic> j) {
  final l = _layerFromJson(j);
  l.confirmHistory = [
    for (final h in (j['confirmHistory'] as List? ?? const [])) Map<String, dynamic>.from(h as Map)
  ];
  ensureRegionSelf(l);
  return l;
}

Layer _layerFromJson(Map<String, dynamic> j) => Layer(
      id: j['id'] as String,
      name: j['name'] as String,
      parentId: j['parentId'] as String?,
      startFrame: j['startFrame'] as int? ?? 0,
      durationFrames: j['durationFrames'] as int? ?? 180,
      transform: transformFromJson(j['transform'] as Map<String, dynamic>),
      content: contentFromJson(j['content'] as Map<String, dynamic>),
      masks: (j['masks'] as List?)
          ?.map((m) => maskFromJson(m as Map<String, dynamic>))
          .toList(),
      effectStack: (j['effectStack'] as List?)
          ?.map((e) => effectInstanceFromJson(e as Map<String, dynamic>))
          .toList(),
      color: j['color'] as String?,
      renderMode: j['renderMode'] as String? ?? 'fill',
      hidden: j['hidden'] as bool? ?? false,
      motionBlur: j['motionBlur'] != null
          ? motionBlurFromJson(j['motionBlur'] as Map<String, dynamic>)
          : null,
      wiggle: j['wiggle'] != null
          ? wiggleFromJson(j['wiggle'] as Map<String, dynamic>)
          : null,
      pendulum: j['pendulum'] != null
          ? pendulumFromJson(j['pendulum'] as Map<String, dynamic>)
          : null,
      groupedChildren:
          (j['groupedChildren'] as List?)?.map((e) => e as String).toList(),
      precompose: j['precompose'] as bool?,
      crop: (j['crop'] as List?)?.map((v) => (v as num).toDouble()).toList(),
      cropAspect: j['cropAspect'] as String? ?? 'free',
      mirrorX: j['mirrorX'] as bool? ?? false,
      mirrorY: j['mirrorY'] as bool? ?? false,
      effectPanelOrder: (j['effectPanelOrder'] as List?)?.map((e) => e as String).toList(),
      rowId: j['row'] as String?,
      splitRoot: j['splitRoot'] as String?,
      loopEnabled: j['loop'] is Map,
      loopUntil: (j['loop'] as Map?)?['until'] as int?,
      inheritPosition: (j['inherit'] as Map?)?['position'] as bool? ?? true,
      inheritRotation: (j['inherit'] as Map?)?['rotation'] as bool? ?? true,
      inheritScale: (j['inherit'] as Map?)?['scale'] as bool? ?? true,
      swing: j['swing'] != null ? swingFromJson(j['swing'] as Map<String, dynamic>) : null,
      maskRegions: j['maskRegions'] is Map
          ? MaskRegions(
              enabled: (j['maskRegions'] as Map)['enabled'] as bool? ?? true,
              sources: [for (final s in ((j['maskRegions'] as Map)['sources'] as List? ?? const [])) s as String],
              opacity: {
                for (final e in (((j['maskRegions'] as Map)['opacity'] as Map?) ?? const {}).entries)
                  int.parse(e.key as String): trackFromJson(e.value as Map<String, dynamic>)
              },
              feather: [for (final f in ((j['maskRegions'] as Map)['feather'] as List? ?? const [])) (f as num).toDouble()],
              numbered: (j['maskRegions'] as Map)['numbered'] == true,
              commands: [
                for (final c in ((j['maskRegions'] as Map)['commands'] as List? ?? const []))
                  RegionCommand.fromJson(c as Map)
              ],
            )
          : null,
      links: [
        for (final k in (j['links'] as List? ?? const []))
          PropLink(
            enabled: k['enabled'] as bool? ?? true,
            sourceId: k['source'] as String?,
            from: k['from'] as String? ?? 'x',
            to: k['to'] as String? ?? 'x',
            factor: (k['factor'] as num?)?.toDouble() ?? 1,
            base: (k['base'] as num?)?.toDouble(),
          )
      ],
      cuts: [
        for (final c in (j['cuts'] as List? ?? const []))
          CutByLayer(
            enabled: c['enabled'] as bool? ?? true,
            cutterId: c['cutter'] as String?,
            mode: c['mode'] as String? ?? 'subtract',
            gap: c['gap'] is Map ? trackFromJson(c['gap'] as Map<String, dynamic>) : null,
            join: c['join'] as String? ?? 'miter',
            hideCutter: c['hideCutter'] as bool? ?? false,
            onlyWhenTouching: c['onlyWhenTouching'] as bool? ?? false,
          )
      ],
      filters: j['filters'] is Map && j['filters']['negative'] is Map
          ? LayerFilters(negative: trackFromJson(j['filters']['negative'] as Map<String, dynamic>))
          : null,
      follow: j['follow'] is Map ? FollowSettings.fromJson(j['follow'] as Map<String, dynamic>) : null,
      pieceClips: [
        for (final c in (j['pieces'] as List? ?? const []))
          PieceClip(
            points: [for (final p in (c as Map)['points'] as List) [for (final v in p as List) (v as num).toDouble()]],
            inside: c['inside'] as bool? ?? true,
          )
      ],
      fill: j['fill'] != null ? shapeFillFromJson(j['fill'] as Map<String, dynamic>) : null,
      edgeMatte: j['edgeMatte'] is Map,
      edgeMatteColor: (j['edgeMatte'] as Map?)?['color'] as String? ?? '#000000',
      edgeMatteStrength: ((j['edgeMatte'] as Map?)?['strength'] as num?)?.toDouble() ?? 1,
      linkId: j['link'] as String?,
      physics: j['physics'] is Map ? PhysicsSettings.fromJson(j['physics'] as Map<String, dynamic>) : null,
      timeQuantize: j['timeQuantize'] != null
          ? timeQuantizeFromJson(j['timeQuantize'] as Map<String, dynamic>)
          : null,
      chromaKey: j['chromaKey'] != null
          ? chromaKeyFromJson(j['chromaKey'] as Map<String, dynamic>)
          : null,
    )
      ..effectRanges = effectRangesFromJson(j['effectRanges'])
      ..parentFrom = (j['parentFrom'] as num?)?.toInt()
      ..parentUntil = (j['parentUntil'] as num?)?.toInt()
      ..mirrorProbe = j['mirrorProbe'] == true
      ..mirrorAllLayers = j['mirrorAllLayers'] == true
      ..locked = j['locked'] == true
      ..parentKeepDifference = j['parentKeepDifference'] == true
      ..folder = j['folder'] as String?
      ..mirrorSourceId = (j['mirror'] as Map?)?['source'] as String?
      ..mirrorAxis = (j['mirror'] as Map?)?['axis'] as String? ?? 'x';

Map<String, List<int>> effectRangesFromJson(Object? j) => {
      if (j is Map)
        for (final e in j.entries)
          e.key as String: [for (final v in e.value as List) (v as num).toInt()],
    };

List<Map<String, dynamic>> projectLayersToJson(Project p) =>
    p.layers.map(layerToJson).toList();
List<Layer> projectLayersFromJson(List<dynamic> j) =>
    j.map((l) => layerFromJson(l as Map<String, dynamic>)).toList();

/// Before a "Confirm shape": what to keep so editing can resume (see
/// Layer.confirmHistory).
void recordConfirm(Layer layer, EffectInstance inst, String label, int frame) {
  layer.confirmHistory.add({
    'label': label,
    'frame': frame,
    'content': contentToJson(layer.content),
    'effect': effectInstanceToJson(inst),
    'at': layer.effectStack.indexOf(inst),
  });
}

/// Back to before confirm `i`: the old shape and its effect (live again),
/// that entry and the later ones dropped.
void resumeConfirm(Layer layer, int i) {
  final h = layer.confirmHistory[i];
  layer.content = contentFromJson(Map<String, dynamic>.from(h['content'] as Map));
  final inst = effectInstanceFromJson(Map<String, dynamic>.from(h['effect'] as Map));
  layer.effectStack.removeWhere((e) => e.id == inst.id);
  final at = (h['at'] as num?)?.toInt() ?? layer.effectStack.length;
  layer.effectStack.insert(at.clamp(0, layer.effectStack.length), inst);
  layer.confirmHistory.removeRange(i, layer.confirmHistory.length);
}
