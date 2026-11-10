/// (add a way to import/export vector files when the project has only shapes, no
/// media). New, no JS equivalent to port - movement-core/desktop never had this
/// either.
///
/// Scoped deliberately: this is a STATIC, single-frame export/import of
/// plain vector shapes, not an animation format. Masks, cuts, rounded
/// corners and deforming effects go out as the shape's real outline; export drops
/// effects, motionBlur, wiggle, and pendulum entirely (no SVG
/// equivalent) - disclosed in the export dialog's own UI text, not
/// silently lossy. Import supports `<rect>`, `<circle>`, `<ellipse>`,
/// `<polygon>`, and `<path>` limited to straight-segment (M/L/Z) `d`
/// data - a curved path is a per-element error, not a silent
/// mis-import. An element's own `transform` attribute is read for the
/// two single-function forms actually seen in practice - `matrix(...)`
/// (what this module's own export always emits) and `translate(...)` -
/// see `_parseSimpleTransform`'s own doc comment. Disclosed scope
/// limit: `rotate()`/`scale()`/`skew()`, a chained transform LIST, and
/// an ancestor `<g transform="...">` are NOT read - a real, if narrow,
/// gap in "general-purpose" support, not silently pretended away.
library;

import '../model/line_path.dart';
import '../model/line_stroke.dart';
import 'dart:math' as math;

import '../core/math.dart' show matMul;

import 'package:xml/xml.dart';

import '../core/interpolation.dart';
import '../core/stage_size.dart';
import '../core/state_cache.dart';
import '../effects/geometry_effect_registry.dart' show isDeformingEffect, deformsPointwise;
import '../geometry/contour_layer.dart' show layerVectorRings, layerMaskClipLocal;
import '../model/shape_fill.dart' show evaluateGlows, glowFalloff, GlowSample;
import '../model/stage_camera.dart' show cameraViewMatrix;
import '../geometry/shapes.dart';
import '../model/project.dart';
import '../text/text_animators.dart' show animatedTextUnits;
import '../text/open_type_font.dart';
import '../text/text_layout.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;

/// exports every visible, in-range, non-image layer of `project` at
/// `globalFrame` as a single static SVG document, `frameWidth` x
/// `frameHeight` px. Layers are emitted in `project.layers` order
/// (later = drawn later = on top, matching canvas_renderer.dart's own
/// paint order) - each shape's LOCAL, undeformed geometry
/// (`shapePoints`/rect x/y/width/height) plus an SVG
/// `transform="matrix(...)"` built from that layer's own fully-composed
/// world matrix (`getLayerStateAt` + `toFrameMatrix`, the same
/// composition `ui_geometry/handles.dart` already uses for snapping/
/// drag math) - SVG's own `matrix(a,b,c,d,e,f)` is defined as `x' = a*x
/// + c*y + e; y' = b*x + d*y + f`, exactly `core/math.dart`'s own
/// `applyAffine` convention, so no reshuffling is needed.
/// `mirrorX`/`mirrorY`: the app's stage mirror - the whole frame is
/// wrapped in one flipping group.
String exportProjectToSvg(Project project, int globalFrame, double frameWidth, double frameHeight,
    {bool mirrorX = false, bool mirrorY = false}) {
  final buf = StringBuffer();
  buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buf.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="${_fmt(frameWidth)}" height="${_fmt(frameHeight)}" viewBox="0 0 ${_fmt(frameWidth)} ${_fmt(frameHeight)}">');
  final mirrored = mirrorX || mirrorY;
  if (mirrored) {
    buf.writeln('<g transform="matrix(${mirrorX ? -1 : 1},0,0,${mirrorY ? -1 : 1},'
        '${_fmt(mirrorX ? frameWidth : 0)},${_fmt(mirrorY ? frameHeight : 0)})">');
  }
  // the stage camera: what it sees, as the video export shows it.
  final view = cameraViewMatrix(project, globalFrame, frameWidth, frameHeight);
  final camera = view != null;
  if (camera) buf.writeln('<g transform="matrix(${view.map(_fmt).join(',')})">');
  for (final layer in project.layers) {
    if (layer.hidden || isMediaShape(layer.content.shape) || isAudioShape(layer.content.shape) || isCameraShape(layer.content.shape)) continue;
    final state = getLayerStateAt(project, layer.id, globalFrame);
    if (!state.inRange) continue;
    final m = _withLayerMirror(layer, toFrameMatrix(state.matrix));
    final localFrame = layerLocalFrame(layer, globalFrame);
    final opacity = evaluateTrack(project, layer.transform.opacity, localFrame, layer) as double;
    final transformAttr = 'transform="matrix(${m.map(_fmt).join(',')})"';
    final opacityAttr = opacity < 1 ? ' opacity="${_fmt(opacity)}"' : '';

    final content = layer.content;
    if (content.shape == 'text' && content.text != null) {
      // real vector outlines of the letters (no font needed to view it).
      final t = content.text!.atFrame(localFrame);
      final l = layoutText(t, content.offset, content.size);
      final d = _svgPathData(l.path);
      // masks: a clip path in the text's own space.
      final clip = layerMaskClipLocal(project, layer, globalFrame);
      var clipAttr = '';
      if (clip != null) {
        final cd = [for (final r in clip) if (r.length >= 3) 'M${r.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}Z'].join();
        buf.writeln('  <clipPath id="mask-${layer.id}"><path d="${cd.isEmpty ? 'M0 0Z' : cd}" clip-rule="evenodd"/></clipPath>');
        clipAttr = ' clip-path="url(#mask-${layer.id})"';
      }
      buf.writeln('  <g $transformAttr$opacityAttr>');
      if (clipAttr.isNotEmpty) buf.writeln('  <g$clipAttr>');
      if (t.background.enabled) {
        final pad = t.background.padding, w = content.size[0] + 2 * pad, h = content.size[1] + 2 * pad;
        final r = math.min(t.background.radius, math.min(w, h) / 2);
        buf.writeln('    <rect x="${_fmt(content.offset[0] - w / 2)}" y="${_fmt(content.offset[1] - h / 2)}" '
            'width="${_fmt(w)}" height="${_fmt(h)}"${r > 0 ? ' rx="${_fmt(r)}"' : ''} fill="${t.background.color}" fill-opacity="${_fmt(t.background.opacity)}"/>');
      }
      if (t.shadow.enabled && d.isNotEmpty) {
        buf.writeln('    <path d="$d" fill="${t.shadow.color}" fill-opacity="${_fmt(t.shadow.opacity)}" '
            'transform="translate(${_fmt(t.shadow.dx)},${_fmt(t.shadow.dy)})"/>');
      }
      if (d.isNotEmpty) {
        final stroke = t.strokeWidth > 0
            ? ' stroke="${t.strokeColor}" stroke-width="${_fmt(t.strokeWidth)}" stroke-linejoin="round" paint-order="stroke"'
            : '';
        buf.writeln('    <path d="$d" fill="${t.color}"$stroke/>');
      }
      if (clipAttr.isNotEmpty) buf.writeln('  </g>');
      buf.writeln('  </g>');
    } else if (isNodeLine(content)) {
      buf.writeln('  ${_lineElement(layer, ' $transformAttr$opacityAttr')}');
    } else {
      // every other shape as the stage draws it: its real outline (rounded
      // corners, effects, masks, cuts), its shadow and its glows.
      final el = _contentElement(layer, project, globalFrame);
      if (el == null) continue;
      buf.writeln('  <g $transformAttr$opacityAttr>$el</g>');
    }
  }
  if (camera) buf.writeln('</g>');
  if (mirrored) buf.writeln('</g>');
  buf.writeln('</svg>');
  return buf.toString();
}

/// The whole animation as one SVG that plays by itself (SMIL): every
/// shape layer drawn once in its own local geometry, inside a group whose
/// transform (translate / rotate / skewX / scale, sampled every frame from
/// its fully-composed matrix), opacity and visibility are animated over
/// frames `startFrame..endFrame` at `fps`, looping. Same scope as the
/// still export: shapes and text; masks, effects, motion blur, wiggle and
/// deformation have no SVG equivalent and aren't included.
String exportProjectToAnimatedSvg(Project project, int startFrame, int endFrame, double fps, double frameWidth,
    double frameHeight,
    {bool mirrorX = false, bool mirrorY = false}) {
  final frames = [for (var f = startFrame; f <= endFrame; f++) f];
  final dur = frames.length / fps;
  final buf = StringBuffer();
  buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buf.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="${_fmt(frameWidth)}" height="${_fmt(frameHeight)}" viewBox="0 0 ${_fmt(frameWidth)} ${_fmt(frameHeight)}">');
  final mirrored = mirrorX || mirrorY;
  if (mirrored) {
    buf.writeln('<g transform="matrix(${mirrorX ? -1 : 1},0,0,${mirrorY ? -1 : 1},'
        '${_fmt(mirrorX ? frameWidth : 0)},${_fmt(mirrorY ? frameHeight : 0)})">');
  }
  // the stage camera, where it is at the start.
  final view = cameraViewMatrix(project, startFrame, frameWidth, frameHeight);
  if (view != null) buf.writeln('<g transform="matrix(${view.map(_fmt).join(',')})">');
  String anim(String tag, String attrs, List<String> values, {bool always = false}) {
    final timing = 'dur="${_fmt(dur)}s" repeatCount="indefinite"';
    if (!always && values.toSet().length == 1) return '';
    return '    <$tag $attrs values="${values.join(';')}" $timing/>\n';
  }

  for (final layer in project.layers) {
    if (layer.hidden || isMediaShape(layer.content.shape) || isAudioShape(layer.content.shape) || isCameraShape(layer.content.shape)) continue;
    // the shape itself, per frame: deforming effects, masks, text keys and
    // animators, text parts, line points and reveal change it over time.
    final elements = [for (final f in frames) _contentElement(layer, project, f, idSuffix: '-$f')];
    final element = elements.firstWhere((e) => e != null, orElse: () => null);
    if (element == null) continue;
    final changes = elements.toSet().length > 1;
    final tx = <String>[], rot = <String>[], skew = <String>[], sc = <String>[], op = <String>[], vis = <String>[];
    double? lastRot;
    for (final f in frames) {
      final state = getLayerStateAt(project, layer.id, f);
      final m = _withLayerMirror(layer, toFrameMatrix(state.matrix));
      final a = m[0], b = m[1], c = m[2], d = m[3];
      final sx = math.sqrt(a * a + b * b);
      var r = math.atan2(b, a) * 180 / math.pi;
      // unwrapped, so a turn past 180 doesn't spin back the long way.
      if (lastRot != null) {
        while (r - lastRot > 180) {
          r -= 360;
        }
        while (r - lastRot < -180) {
          r += 360;
        }
      }
      lastRot = r;
      final cs = math.cos(r * math.pi / 180), sn = math.sin(r * math.pi / 180);
      final c2 = c * cs + d * sn, d2 = -c * sn + d * cs;
      final k = d2 == 0 ? 0.0 : c2 / d2;
      tx.add('${_fmt(m[4])} ${_fmt(m[5])}');
      rot.add(_fmt(r));
      skew.add(_fmt(math.atan(k) * 180 / math.pi));
      sc.add('${_fmt(sx)} ${_fmt(d2)}');
      op.add(_fmt(evaluateTrack(project, layer.transform.opacity, layerLocalFrame(layer, f), layer) as double));
      vis.add(state.inRange ? 'visible' : 'hidden');
    }
    buf.writeln('  <g transform="translate(${tx.first}) rotate(${rot.first}) skewX(${skew.first}) scale(${sc.first})" '
        'opacity="${op.first}" visibility="${vis.first}">');
    // the first replaces the static transform, the rest add to it - so
    // when any part moves, all four are written.
    final moves = [tx, rot, skew, sc].any((v) => v.toSet().length > 1);
    if (moves) {
      buf.write(anim('animateTransform', 'attributeName="transform" type="translate"', tx, always: true));
      buf.write(anim('animateTransform', 'attributeName="transform" type="rotate" additive="sum"', rot, always: true));
      buf.write(anim('animateTransform', 'attributeName="transform" type="skewX" additive="sum"', skew, always: true));
      buf.write(anim('animateTransform', 'attributeName="transform" type="scale" additive="sum"', sc, always: true));
    }
    buf.write(anim('animate', 'attributeName="opacity"', op));
    buf.write(anim('animate', 'attributeName="visibility" calcMode="discrete"', vis));
    if (!changes) {
      buf.writeln('    $element');
    } else {
      // each different shape shows over its own frames (discrete steps).
      final runs = <(String?, List<bool>)>[];
      final index = <String?, int>{};
      for (var i = 0; i < elements.length; i++) {
        final e = elements[i];
        final k = index.putIfAbsent(e, () {
          runs.add((e, List<bool>.filled(elements.length, false)));
          return runs.length - 1;
        });
        runs[k].$2[i] = true;
      }
      final timing = 'dur="${_fmt(dur)}s" repeatCount="indefinite"';
      for (final (e, on) in runs) {
        if (e == null) continue;
        buf.writeln('    <g display="${on.first ? 'inline' : 'none'}">');
        buf.writeln('      <animate attributeName="display" calcMode="discrete" '
            'values="${on.map((v) => v ? 'inline' : 'none').join(';')}" $timing/>');
        buf.writeln('      $e');
        buf.writeln('    </g>');
      }
    }
    buf.writeln('  </g>');
  }
  if (view != null) buf.writeln('</g>');
  if (mirrored) buf.writeln('</g>');
  buf.writeln('</svg>');
  return buf.toString();
}

/// A layer's content in its own local space (no transform), or null when
/// it has nothing to draw.

/// A vector line as an SVG element (stroked, or filled when closed).
String _lineElement(Layer layer, String extra, {Project? project, int? frame}) {
  final c = layer.content;
  final color = layer.color ?? '#888888';
  // at a frame: its keyed points and its reveal.
  final lf = frame == null ? null : layerLocalFrame(layer, frame);
  final (t0, t1) = project == null || lf == null ? (0.0, 1.0) : lineReveal(project, c, lf);
  // square / triangle ends, sharp joins, a changing width: the stroke as
  // its filled pieces.
  if (lineNeedsShapedStroke(c) && layer.renderMode != 'outline') {
    final d = [
      for (final r in lineStrokeRings(c, frame: lf, t0: t0, t1: t1)) 'M${r.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}Z'
    ].join();
    return '<path d="$d" fill="$color" fill-rule="nonzero" stroke="none"$extra/>';
  }
  // a fill keeping the line's width: its real outline.
  if (isFilledLine(c) && c.lineFillMode != 'points' && layer.renderMode != 'outline') {
    final d = [
      for (final r in filledLineRings(c, frame: lf)) 'M${r.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}Z'
    ].join();
    return '<path d="$d" fill="$color" fill-rule="evenodd" stroke="none"$extra/>';
  }
  var pts = sampleLine(c.lineNodes!, closed: c.lineClosed, frame: lf);
  final whole = t0 <= 0 && t1 >= 1;
  if (!whole) pts = trimPolyline(pts, t0, t1);
  if (pts.length < 2) return '<g/>';
  final d = 'M${pts.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}${c.lineClosed && whole ? 'Z' : ''}';
  final paint = isFilledLine(c) && layer.renderMode != 'outline'
      ? 'fill="$color" stroke="none"'
      : 'fill="none" stroke="$color" stroke-width="${_fmt(c.lineWidth)}" stroke-linecap="round" stroke-linejoin="round"';
  return '<path d="$d" $paint$extra/>';
}

String? _contentElement(Layer layer, Project project, int frame, {String idSuffix = ''}) {
  final color = layer.color ?? '#888888';
  final fillAttr = layer.renderMode == 'outline' ? 'fill="none" stroke="$color" stroke-width="1.5"' : 'fill="$color" stroke="none"';
  final content = layer.content;
  if (content.shape != 'text' && !isNodeLine(content)) {
    final body = _shapeBody(layer, project, frame, fillAttr);
    if (body == null) return null;
    // its shadow under it, its glows over it (inside its outline).
    final d = _outlineD(project, layer, frame);
    if (d == null) return body;
    final out = StringBuffer();
    final sh = layer.fill.shadow;
    if (sh.enabled && layer.renderMode != 'outline') {
      final c = content.offset;
      out.write('<g opacity="${_fmt(sh.opacity.clamp(0.0, 1.0))}" transform="translate(${_fmt(sh.dx)},${_fmt(sh.dy)}) '
          'translate(${_fmt(c[0])},${_fmt(c[1])}) scale(${_fmt(sh.scale)}) translate(${_fmt(-c[0])},${_fmt(-c[1])})">'
          '<path d="$d" fill-rule="${_rule(layer)}" fill="${sh.color}"/></g>');
    }
    out.write(body);
    final glows = layer.fill.active && layer.renderMode != 'outline' ? evaluateGlows(project, layer, frame) : const <GlowSample>[];
    if (glows.isNotEmpty) {
      final clip = 'glowclip-${layer.id}$idSuffix';
      out.write('<clipPath id="$clip"><path d="$d" clip-rule="${_rule(layer)}"/></clipPath><g clip-path="url(#$clip)">');
      var gi = 0;
      for (final g in glows) {
        if (g.radius <= 0 || g.strength <= 0 || g.glow.color == 'transparent') continue;
        final id = 'glow-${layer.id}$idSuffix-${gi++}';
        const n = 6;
        final stops = [
          for (var i = 0; i <= n; i++)
            '<stop offset="${_fmt(i / n)}" stop-color="${g.glow.color}" stop-opacity="${_fmt((g.strength * glowFalloff(i / n)).clamp(0.0, 1.0))}"/>'
        ].join();
        // a line glow: round its middle (an approximation).
        final cx = (g.a[0] + g.b[0]) / 2, cy = (g.a[1] + g.b[1]) / 2;
        out.write('<radialGradient id="$id" gradientUnits="userSpaceOnUse" cx="${_fmt(cx)}" cy="${_fmt(cy)}" r="${_fmt(g.radius)}">$stops</radialGradient>'
            '<circle cx="${_fmt(cx)}" cy="${_fmt(cy)}" r="${_fmt(g.radius)}" fill="url(#$id)"/>');
      }
      out.write('</g>');
    }
    return out.toString();
  }
  if (content.shape == 'text' && content.text != null) {
    // at its frame: its text keys, animators and parts.
    final lf = layerLocalFrame(layer, frame);
    final t = content.text!.atFrame(lf);
    final stroke = t.strokeWidth > 0
        ? ' stroke="${t.strokeColor}" stroke-width="${_fmt(t.strokeWidth)}" stroke-linejoin="round" paint-order="stroke"'
        : '';
    final out = StringBuffer();
    final units = animatedTextUnits(t, content.offset, content.size, lf);
    if (units != null) {
      for (final u in units) {
        if (u.opacity <= 0.01) continue;
        final d = _svgPathData(u.cmds);
        if (d.isEmpty) continue;
        final col = _mixHex(u.baseColor ?? t.color, u.tint, u.tintAmount);
        out.write('<path d="$d" fill="$col"${u.opacity < 1 ? ' fill-opacity="${_fmt(u.opacity)}"' : ''}$stroke/>');
      }
    } else {
      final l = layoutText(t, content.offset, content.size);
      final d = _svgPathData(l.plain);
      if (d.isNotEmpty) out.write('<path d="$d" fill="${t.color}"$stroke/>');
      for (final e in l.colored.entries) {
        out.write('<path d="${_svgPathData(e.value)}" fill="${e.key}"$stroke/>');
      }
    }
    if (out.isEmpty) return null;
    // masks: clipped in its own space.
    final clip = layerMaskClipLocal(project, layer, frame);
    if (clip == null) return '<g>$out</g>';
    final cd = [for (final r in clip) if (r.length >= 3) 'M${r.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}Z'].join();
    final id = 'mask-${layer.id}$idSuffix';
    return '<g><clipPath id="$id"><path d="${cd.isEmpty ? 'M0 0Z' : cd}" clip-rule="evenodd"/></clipPath>'
        '<g clip-path="url(#$id)">$out</g></g>';
  }
  if (isNodeLine(content)) return _lineElement(layer, '', project: project, frame: frame);
  return null;
}

String _svgPathData(List<PathCmd> cmds) {
  final b = StringBuffer();
  for (final c in cmds) {
    b.write(c.op);
    b.write(c.p.map(_fmt).join(' '));
  }
  return b.toString();
}

String _fmt(num v) {
  // trims trailing zeros/decimal point ("3.0" -> "3") without losing
  // real precision on non-integer values - purely cosmetic, keeps the
  // output readable, but never rounds.
  if (v is double && v == v.roundToDouble() && v.abs() < 1e15) return v.round().toString();
  return v.toString();
}

/// the result of a real-world SVG import: successfully-parsed shapes as
/// new, unparented layers (anchor at the element's own center, as a
/// fraction of `stageSize` - see stageSize's own doc comment; this
/// module has no camera/screen concept beyond that global, same as the
/// rest of ui_geometry/), PLUS one human-readable error string per
/// element that couldn't be imported (an unsupported element type, or a
/// `<path>` using a curve command) - a plain `List<Layer>` return
/// couldn't carry those, and silently dropping unsupported elements
/// would contradict "surfaced as a clear per-element error" above.
class SvgImportResult {
  final List<Layer> layers;
  final List<String> errors;

  /// What came in simplified (a gradient as one colour, a stroke as an
  /// outline, ...) - imported, but not exactly as drawn.
  final List<String> report;
  SvgImportResult({required this.layers, required this.errors, this.report = const []});
}

/// Imports an SVG's shapes as layers, each in its own colours: fills and
/// strokes from attributes, `style`, `<style>` classes and parent groups;
/// linear / radial gradients from `<defs>` (href inheritance, both
/// gradientUnits, gradientTransform) as the layer's paint gradient;
/// fill-opacity / opacity as the layer's opacity. Transforms of any kind
/// (and of the groups above) are baked into the points; curves and arcs
/// are flattened. `<metadata>` and unknown elements are skipped quietly;
/// text, images and `<use>` are listed as errors.
SvgImportResult importShapesFromSvg(String svgSource) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(svgSource);
  } catch (e) {
    return SvgImportResult(layers: [], errors: ['Could not parse this file as XML: $e']);
  }
  final root = doc.rootElement;
  if (root.name.local != 'svg') {
    return SvgImportResult(layers: [], errors: ['Root element is <${root.name.local}>, not <svg>']);
  }
  final imp = _SvgImporter(root);
  imp.walk(root, const {}, _identity, 1);
  return SvgImportResult(layers: imp.layers, errors: imp.errors, report: imp.report);
}

const _identity = <double>[1, 0, 0, 1, 0, 0];

List<double> _mul(List<double> a, List<double> b) => [
      a[0] * b[0] + a[2] * b[1],
      a[1] * b[0] + a[3] * b[1],
      a[0] * b[2] + a[2] * b[3],
      a[1] * b[2] + a[3] * b[3],
      a[0] * b[4] + a[2] * b[5] + a[4],
      a[1] * b[4] + a[3] * b[5] + a[5],
    ];

List<double> _applyMatrix(List<double> m, double x, double y) => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];

bool _isPureTranslation(List<double> m) =>
    (m[0] - 1).abs() < 1e-9 && m[1].abs() < 1e-9 && m[2].abs() < 1e-9 && (m[3] - 1).abs() < 1e-9;

/// A transform list: matrix / translate / scale / rotate / skewX / skewY,
/// applied left to right. Null when there is none or it can't be read.
List<double>? _parseTransform(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  var m = _identity;
  final fns = RegExp(r'([a-zA-Z]+)\s*\(([^)]*)\)').allMatches(raw).toList();
  if (fns.isEmpty) return null;
  for (final f in fns) {
    final a = f.group(2)!.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).map(double.tryParse).toList();
    if (a.any((v) => v == null)) return null;
    final n = a.cast<double>();
    double at(int i, double d) => i < n.length ? n[i] : d;
    List<double> t;
    switch (f.group(1)) {
      case 'matrix':
        if (n.length != 6) return null;
        t = n;
      case 'translate':
        t = [1, 0, 0, 1, at(0, 0), at(1, 0)];
      case 'scale':
        t = [at(0, 1), 0, 0, at(1, at(0, 1)), 0, 0];
      case 'rotate':
        final r = at(0, 0) * math.pi / 180, c = math.cos(r), s = math.sin(r);
        final cx = at(1, 0), cy = at(2, 0);
        t = _mul(_mul([1, 0, 0, 1, cx, cy], [c, s, -s, c, 0, 0]), [1, 0, 0, 1, -cx, -cy]);
      case 'skewX':
        t = [1, 0, math.tan(at(0, 0) * math.pi / 180), 1, 0, 0];
      case 'skewY':
        t = [1, math.tan(at(0, 0) * math.pi / 180), 0, 1, 0, 0];
      default:
        return null;
    }
    m = _mul(m, t);
  }
  return m;
}

/// Styling properties that pass down from groups.
const _inherited = {
  'fill', 'fill-opacity', 'fill-rule', 'stroke', 'stroke-opacity', 'stroke-width', 'visibility', 'color'
};
const _styleProps = {..._inherited, 'opacity', 'display', 'stop-color', 'stop-opacity'};

/// Named colours (CSS).
const _named = {
  'black': '000000', 'white': 'ffffff', 'red': 'ff0000', 'lime': '00ff00', 'green': '008000', 'blue': '0000ff',
  'yellow': 'ffff00', 'cyan': '00ffff', 'aqua': '00ffff', 'magenta': 'ff00ff', 'fuchsia': 'ff00ff',
  'gray': '808080', 'grey': '808080', 'silver': 'c0c0c0', 'maroon': '800000', 'olive': '808000',
  'purple': '800080', 'teal': '008080', 'navy': '000080', 'orange': 'ffa500', 'pink': 'ffc0cb',
  'brown': 'a52a2a', 'gold': 'ffd700', 'indigo': '4b0082', 'violet': 'ee82ee', 'darkgray': 'a9a9a9',
  'darkgrey': 'a9a9a9', 'lightgray': 'd3d3d3', 'lightgrey': 'd3d3d3', 'darkred': '8b0000',
  'darkgreen': '006400', 'darkblue': '00008b', 'skyblue': '87ceeb', 'tomato': 'ff6347', 'coral': 'ff7f50',
  'salmon': 'fa8072', 'beige': 'f5f5dc', 'khaki': 'f0e68c', 'crimson': 'dc143c', 'turquoise': '40e0d0',
};

/// A colour value as ("#rrggbb", alpha), or null (none / unreadable).
(String, double)? _parseColor(String? raw, [String? current]) {
  if (raw == null) return null;
  var v = raw.trim().toLowerCase();
  if (v == 'none' || v == 'transparent' || v.isEmpty) return null;
  if (v == 'currentcolor') return current == null ? ('#000000', 1.0) : _parseColor(current);
  if (_named.containsKey(v)) return ('#${_named[v]}', 1.0);
  if (v.startsWith('#')) {
    v = v.substring(1);
    if (v.length == 3 || v.length == 4) v = [for (final c in v.split('')) '$c$c'].join();
    if (v.length == 8) {
      final a = int.tryParse(v.substring(6), radix: 16);
      return ('#${v.substring(0, 6)}', (a ?? 255) / 255);
    }
    if (v.length == 6 && int.tryParse(v, radix: 16) != null) return ('#$v', 1.0);
    return null;
  }
  final m = RegExp(r'rgba?\(([^)]*)\)').firstMatch(v);
  if (m != null) {
    final parts = m.group(1)!.split(RegExp(r'[\s,/]+')).where((s) => s.isNotEmpty).toList();
    if (parts.length < 3) return null;
    int ch(String s) => s.endsWith('%')
        ? ((double.tryParse(s.substring(0, s.length - 1)) ?? 0) * 2.55).round().clamp(0, 255)
        : (double.tryParse(s) ?? 0).round().clamp(0, 255);
    final hex = [for (final s in parts.take(3)) ch(s).toRadixString(16).padLeft(2, '0')].join();
    var a = 1.0;
    if (parts.length > 3) {
      final s = parts[3];
      a = s.endsWith('%') ? (double.tryParse(s.substring(0, s.length - 1)) ?? 100) / 100 : double.tryParse(s) ?? 1;
    }
    return ('#$hex', a.clamp(0.0, 1.0));
  }
  return null;
}

double _parseOpacity(String? raw) {
  if (raw == null) return 1;
  final t = raw.trim();
  final v = t.endsWith('%') ? (double.tryParse(t.substring(0, t.length - 1)) ?? 100) / 100 : double.tryParse(t) ?? 1;
  return v.clamp(0.0, 1.0);
}

/// A length / fraction: "50%" -> 0.5 (of `of`), "12" / "12px" -> 12.
double _len(String? raw, double fallback, {double of = 1}) {
  if (raw == null) return fallback;
  final t = raw.trim();
  if (t.endsWith('%')) return (double.tryParse(t.substring(0, t.length - 1)) ?? 0) / 100 * of;
  return double.tryParse(t.replaceAll(RegExp(r'(px|pt)$'), '')) ?? fallback;
}

Map<String, String> _parseDecls(String body) => {
      for (final d in body.split(';'))
        if (d.contains(':')) d.substring(0, d.indexOf(':')).trim(): d.substring(d.indexOf(':') + 1).trim()
    };

class _SvgImporter {
  final layers = <Layer>[];
  final errors = <String>[];
  final report = <String>[];
  final Map<String, XmlElement> byId = {};

  /// `<style>` rules: selector -> declarations, in order.
  final List<(String, Map<String, String>)> css = [];
  double vw = 0, vh = 0;

  _SvgImporter(XmlElement root) {
    for (final e in [root, ...root.descendantElements]) {
      final id = e.getAttribute('id');
      if (id != null) byId[id] = e;
      if (e.name.local == 'style') {
        final text = e.innerText.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
        for (final m in RegExp(r'([^{}]+)\{([^}]*)\}').allMatches(text)) {
          final decls = _parseDecls(m.group(2)!);
          for (final sel in m.group(1)!.split(',')) {
            css.add((sel.trim(), decls));
          }
        }
      }
    }
    final vb = root.getAttribute('viewBox')?.split(RegExp(r'[\s,]+')).map(double.tryParse).toList();
    if (vb != null && vb.length == 4 && vb.every((v) => v != null)) {
      vw = vb[2]!;
      vh = vb[3]!;
    } else {
      vw = _len(root.getAttribute('width'), stageSize.width);
      vh = _len(root.getAttribute('height'), stageSize.height);
    }
  }

  /// This element's own styling: presentation attributes, then `<style>`
  /// rules (tag < class < id), then its `style` attribute.
  Map<String, String> ownStyle(XmlElement el) {
    final out = <String, String>{};
    for (final a in el.attributes) {
      if (_styleProps.contains(a.name.local)) out[a.name.local] = a.value;
    }
    if (css.isNotEmpty) {
      final classes = (el.getAttribute('class') ?? '').split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toSet();
      final id = el.getAttribute('id');
      for (final rank in [0, 1, 2]) {
        for (final (sel, decls) in css) {
          final hit = switch (rank) {
            0 => sel == el.name.local || sel == '*',
            1 => sel.startsWith('.') && sel.substring(1).split('.').every(classes.contains),
            _ => id != null && sel == '#$id',
          };
          if (hit) out.addAll(decls);
        }
      }
    }
    final st = el.getAttribute('style');
    if (st != null) out.addAll(_parseDecls(st));
    return out;
  }

  void walk(XmlElement el, Map<String, String> inherited, List<double> ctm, double groupOpacity) {
    for (final child in el.childElements) {
      final tag = child.name.local;
      // definitions and descriptions: nothing to draw (a big metadata
      // block is never even looked into).
      if (const {
            'defs', 'metadata', 'title', 'desc', 'style', 'linearGradient', 'radialGradient', 'clipPath', 'mask',
            'pattern', 'symbol', 'filter', 'marker', 'script', 'namedview', 'foreignObject'
          }.contains(tag) ||
          child.name.prefix != null) {
        continue;
      }
      final own = ownStyle(child);
      if (own['display']?.trim() == 'none') continue;
      final style = {
        for (final e in inherited.entries)
          if (_inherited.contains(e.key)) e.key: e.value,
        ...own,
      };
      final m = _mul(ctm, _parseTransform(child.getAttribute('transform')) ?? _identity);
      final opacity = groupOpacity * _parseOpacity(own['opacity']);
      if (tag == 'g' || tag == 'svg' || tag == 'a' || tag == 'switch') {
        walk(child, style, m, opacity);
        continue;
      }
      if (style['visibility']?.trim() == 'hidden') continue;
      try {
        final layer = shape(child, style, m, opacity);
        if (layer != null) layers.add(layer);
      } catch (e) {
        errors.add('<$tag>: ${e is ArgumentError ? e.message : e}');
      }
    }
  }

  /// One drawing element as a layer (null: nothing to draw).
  Layer? shape(XmlElement el, Map<String, String> style, List<double> m, double opacity) {
    final tag = el.name.local;
    double n(String a, double d, {double of = 1}) => _len(el.getAttribute(a), d, of: of);
    List<List<List<double>>> rings;
    String? native; // rect / circle kept as such when only moved
    var closed = true;
    switch (tag) {
      case 'rect':
        final x = n('x', 0, of: vw), y = n('y', 0, of: vh), w = n('width', 0, of: vw), h = n('height', 0, of: vh);
        if (w <= 0 || h <= 0) throw ArgumentError('rect has non-positive width/height');
        var rx = el.getAttribute('rx') == null ? null : n('rx', 0, of: vw);
        var ry = el.getAttribute('ry') == null ? null : n('ry', 0, of: vh);
        rx ??= ry ?? 0;
        ry ??= rx;
        rx = math.min(rx, w / 2);
        ry = math.min(ry, h / 2);
        if (rx > 0 && ry > 0) {
          rings = [_roundRect(x, y, w, h, rx, ry)];
        } else {
          rings = [
            [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]
          ];
          native = 'rect';
        }
      case 'circle':
        final r = n('r', 0, of: math.sqrt((vw * vw + vh * vh) / 2));
        if (r <= 0) throw ArgumentError('circle has non-positive radius');
        rings = [_sampleEllipse(n('cx', 0, of: vw), n('cy', 0, of: vh), r, r)];
        native = 'circle';
      case 'ellipse':
        final rx = n('rx', 0, of: vw), ry = n('ry', 0, of: vh);
        if (rx <= 0 || ry <= 0) throw ArgumentError('ellipse has non-positive rx/ry');
        rings = [_sampleEllipse(n('cx', 0, of: vw), n('cy', 0, of: vh), rx, ry)];
      case 'polygon':
      case 'polyline':
        final raw = el.getAttribute('points');
        if (raw == null || raw.trim().isEmpty) throw ArgumentError('$tag has no points');
        rings = [_parsePointsAttr(raw)];
        closed = tag == 'polygon';
      case 'line':
        rings = [
          [[n('x1', 0), n('y1', 0)], [n('x2', 0), n('y2', 0)]]
        ];
        closed = false;
      case 'path':
        final d = el.getAttribute('d');
        if (d == null || d.trim().isEmpty) throw ArgumentError('path has no d attribute');
        final (subs, allClosed) = _parsePathData(d);
        rings = [for (final r in subs) if (r.length >= 2) r];
        if (rings.isEmpty) throw ArgumentError('path draws nothing');
        closed = allClosed;
      case 'text':
      case 'image':
      case 'use':
        throw ArgumentError('unsupported element type (not imported)');
      default:
        return null; // unknown: quietly skipped
    }

    // the paint: fill, else the stroke (drawn as the outline).
    final current = style['color'];
    String? paintRaw = style.containsKey('fill') ? style['fill'] : '#000000';
    var paintOpacity = _parseOpacity(style['fill-opacity']);
    var outline = false;
    final noFill = paintRaw == null || paintRaw.trim() == 'none' || !closed && tag == 'line';
    if (noFill) {
      final st = style['stroke'];
      if (st == null || st.trim() == 'none') return null; // nothing visible
      paintRaw = st;
      paintOpacity = _parseOpacity(style['stroke-opacity']);
      outline = true;
      report.add('<$tag${_idOf(el)}>: its stroke is drawn as a thin outline');
    }

    // the element's own bounding box (gradient objectBoundingBox).
    final all = [for (final r in rings) ...r];
    final bx0 = all.map((p) => p[0]).reduce(math.min), bx1 = all.map((p) => p[0]).reduce(math.max);
    final by0 = all.map((p) => p[1]).reduce(math.min), by1 = all.map((p) => p[1]).reduce(math.max);

    final world = [
      for (final r in rings) [for (final p in r) _applyMatrix(m, p[0], p[1])]
    ];
    final wall = [for (final r in world) ...r];
    final minX = wall.map((p) => p[0]).reduce(math.min), maxX = wall.map((p) => p[0]).reduce(math.max);
    final minY = wall.map((p) => p[1]).reduce(math.min), maxY = wall.map((p) => p[1]).reduce(math.max);
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;

    Content content;
    if (native != null && _isPureTranslation(m)) {
      content = Content(
          shape: native,
          offset: const [0, 0],
          size: [bx1 - bx0, by1 - by0],
          sides: native == 'circle' ? 48 : null);
    } else if (world.length == 1) {
      content = Content(
          shape: 'polygon',
          offset: const [0, 0],
          size: [math.max(1e-6, maxX - minX), math.max(1e-6, maxY - minY)],
          points: [for (final p in world.single) [p[0] - cx, p[1] - cy]]);
    } else {
      final evenOdd = style['fill-rule']?.trim() == 'evenodd';
      final local = [
        for (final r in world) [for (final p in r) [p[0] - cx, p[1] - cy]]
      ];
      content = Content(
          shape: 'compound',
          offset: const [0, 0],
          size: [math.max(1e-6, maxX - minX), math.max(1e-6, maxY - minY)],
          contours: evenOdd ? _evenOddAsNonZero(local) : local);
    }

    layerCounter++;
    final layer = Layer(
      id: 'L_svg_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter',
      name: el.getAttribute('id') ?? '${content.shape}_import_$layerCounter',
      parentId: null,
      transform: Transform(
        anchor: track([cx / stageSize.width, cy / stageSize.height], true),
        scale: track([1.0, 1.0]),
        rotation: track(0.0),
        opacity: track(1.0),
      ),
      content: content,
      color: '#000000',
    );
    if (outline) layer.renderMode = 'outline';

    final url = RegExp(r'url\(\s*#([^)\s]+)\s*\)').firstMatch(paintRaw);
    if (url != null) {
      final g = gradient(url.group(1)!, [bx1 - bx0, 0, 0, by1 - by0, bx0, by0],
          _mul([1, 0, 0, 1, -cx, -cy], m), '<$tag${_idOf(el)}>');
      if (g == null) {
        // a missing paint server: SVG's fallback colour, else none.
        final fb = _parseColor(paintRaw.substring(url.end).trim(), current);
        if (fb == null) {
          report.add('<$tag${_idOf(el)}>: gradient #${url.group(1)} not found - drawn black');
        } else {
          layer.color = fb.$1;
          paintOpacity *= fb.$2;
        }
      } else if (g.$1 != null) {
        layer.fill.paint = g.$1;
        layer.color = g.$1!.stops.isEmpty ? '#000000' : g.$1!.stops.first.color;
      } else {
        layer.color = g.$2!.$1;
        paintOpacity *= g.$2!.$2;
      }
    } else {
      final c = _parseColor(paintRaw, current);
      if (c == null) return null;
      layer.color = c.$1;
      paintOpacity *= c.$2;
    }
    final total = (opacity * paintOpacity).clamp(0.0, 1.0);
    layer.transform.opacity = track(total.toDouble());
    return layer;
  }

  /// The gradient `id` as a paint gradient mapped into the layer's
  /// content px (`toLocal`: element space -> content), or - when it can't
  /// be drawn exactly - its average colour (reported). Null: not found.
  (FillGradient?, (String, double)?)? gradient(String id, List<double> bbox, List<double> toLocal, String who) {
    var el = byId[id];
    if (el == null || !(el.name.local == 'linearGradient' || el.name.local == 'radialGradient')) return null;
    final type = el.name.local == 'radialGradient' ? 'radial' : 'linear';
    // attributes and stops, inherited through href.
    final attrs = <String, String>{};
    List<XmlElement>? stops;
    final seen = <String>{};
    for (XmlElement? e = el; e != null && seen.add(e.getAttribute('id') ?? '${e.hashCode}');) {
      for (final a in e.attributes) {
        attrs.putIfAbsent(a.name.local, () => a.value);
      }
      final own = e.childElements.where((c) => c.name.local == 'stop').toList();
      if (stops == null && own.isNotEmpty) stops = own;
      final href = e.getAttribute('href') ?? e.getAttribute('href', namespace: 'http://www.w3.org/1999/xlink');
      var h = href ?? e.attributes.where((a) => a.name.local == 'href').map((a) => a.value).firstOrNull;
      if (h == null || !h.startsWith('#')) break;
      e = byId[h.substring(1)];
    }
    final parsed = <GradientStop>[];
    var last = 0.0;
    for (final st in stops ?? const <XmlElement>[]) {
      final s = ownStyle(st);
      final off = math.max(last, _len(st.getAttribute('offset'), 0).clamp(0.0, 1.0).toDouble());
      last = off;
      final c = _parseColor(s['stop-color'] ?? '#000000') ?? ('#000000', 0.0);
      parsed.add(GradientStop(off, c.$1, (c.$2 * _parseOpacity(s['stop-opacity'])).clamp(0.0, 1.0)));
    }
    if (parsed.isEmpty) {
      report.add('$who: gradient #$id has no stops - not drawn');
      return (null, ('#000000', 0.0));
    }
    final user = attrs['gradientUnits'] == 'userSpaceOnUse';
    final gt = _parseTransform(attrs['gradientTransform']) ?? _identity;
    final space = _mul(toLocal, user ? gt : _mul(bbox, gt));
    double a(String k, double d, double of) => _len(attrs[k], d, of: user ? of : 1);
    final g = FillGradient(type: type, stops: parsed, matrix: space, spread: attrs['spreadMethod'] ?? 'pad');
    if (type == 'linear') {
      g
        ..x1 = a('x1', 0, vw)
        ..y1 = a('y1', 0, vh)
        ..x2 = a('x2', user ? vw : 1, vw)
        ..y2 = a('y2', 0, vh);
    } else {
      g
        ..cx = a('cx', user ? vw / 2 : 0.5, vw)
        ..cy = a('cy', user ? vh / 2 : 0.5, vh)
        ..r = a('r', user ? math.sqrt((vw * vw + vh * vh) / 2) / 2 : 0.5, math.sqrt((vw * vw + vh * vh) / 2));
      final fx = attrs['fx'] == null ? g.cx : a('fx', g.cx, vw), fy = attrs['fy'] == null ? g.cy : a('fy', g.cy, vh);
      final fr = attrs['fr'] == null ? 0.0 : a('fr', 0, vw);
      if ((fx - g.cx).abs() > 1e-9 || (fy - g.cy).abs() > 1e-9 || fr > 0) {
        // a focal point isn't drawn: its stops' average colour instead.
        var r = 0.0, gg = 0.0, b = 0.0, o = 0.0;
        for (final s in parsed) {
          final v = int.parse(s.color.substring(1), radix: 16);
          r += (v >> 16) & 255;
          gg += (v >> 8) & 255;
          b += v & 255;
          o += s.opacity;
        }
        final k = parsed.length;
        String h(double v) => (v / k).round().toRadixString(16).padLeft(2, '0');
        report.add('$who: radial gradient #$id has a focal point - filled with its average colour');
        return (null, ('#${h(r)}${h(gg)}${h(b)}', o / k));
      }
    }
    return (g, null);
  }
}

String _idOf(XmlElement el) {
  final id = el.getAttribute('id');
  return id == null ? '' : ' id="$id"';
}

/// A rounded rectangle's outline (corners sampled).
List<List<double>> _roundRect(double x, double y, double w, double h, double rx, double ry) {
  const n = 8;
  final out = <List<double>>[];
  void corner(double cx, double cy, double a0) {
    for (var i = 0; i <= n; i++) {
      final a = a0 + i / n * math.pi / 2;
      out.add([cx + rx * math.cos(a), cy + ry * math.sin(a)]);
    }
  }

  corner(x + w - rx, y + ry, -math.pi / 2);
  corner(x + w - rx, y + h - ry, 0);
  corner(x + rx, y + h - ry, math.pi / 2);
  corner(x + rx, y + ry, math.pi);
  return out;
}

/// Even-odd rings as non-zero ones: each wound by how deep it sits
/// inside the others (even: one way, odd: the other).
List<List<List<double>>> _evenOddAsNonZero(List<List<List<double>>> rings) {
  double area(List<List<double>> r) {
    var a = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      a += p[0] * q[1] - q[0] * p[1];
    }
    return a / 2;
  }

  bool inside(List<double> p, List<List<double>> r) {
    var c = false;
    for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
      if ((r[i][1] > p[1]) != (r[j][1] > p[1]) &&
          p[0] < (r[j][0] - r[i][0]) * (p[1] - r[i][1]) / (r[j][1] - r[i][1]) + r[i][0]) {
        c = !c;
      }
    }
    return c;
  }

  return [
    for (var i = 0; i < rings.length; i++)
      () {
        var depth = 0;
        for (var j = 0; j < rings.length; j++) {
          if (j != i && rings[i].isNotEmpty && inside(rings[i].first, rings[j])) depth++;
        }
        final ccw = area(rings[i]) > 0;
        return ccw == depth.isEven ? rings[i] : rings[i].reversed.toList();
      }(),
  ];
}

List<List<double>> _sampleEllipse(double cx, double cy, double rx, double ry, {int segments = 48}) => [
      for (var i = 0; i < segments; i++)
        [cx + rx * math.cos(i / segments * math.pi * 2), cy + ry * math.sin(i / segments * math.pi * 2)]
    ];

List<List<double>> _parsePointsAttr(String raw) {
  // SVG's own points syntax accepts either "x,y x,y" or "x y x y" (comma
  // and/or whitespace as the separator, in any mix) - normalize both to
  // a flat number stream first.
  final nums = raw
      .trim()
      .split(RegExp(r'[\s,]+'))
      .where((s) => s.isNotEmpty)
      .map((s) {
        final v = double.tryParse(s);
        if (v == null) throw ArgumentError('invalid number "$s" in points list');
        return v;
      })
      .toList();
  if (nums.length < 4 || nums.length.isOdd) {
    throw ArgumentError('needs at least 2 coordinate pairs');
  }
  return [for (var i = 0; i < nums.length; i += 2) [nums[i], nums[i + 1]]];
}

/// Path data as its subpaths' points: every command (M L H V C S Q T A Z,
/// absolute and relative), curves and arcs flattened. Also whether every
/// subpath closes (open ones then draw as an outline).
(List<List<List<double>>>, bool) _parsePathData(String d) {
  final tokens = RegExp(r'[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')
      .allMatches(d)
      .map((m) => m.group(0)!)
      .toList();
  final subs = <List<List<double>>>[];
  var cur = <List<double>>[];
  var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
  double? lcx, lcy; // last control point (S / T)
  String? prevCmd;
  var allClosed = true;
  var i = 0;
  String? cmd;
  bool isCmd(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  double next() {
    if (i >= tokens.length || isCmd(tokens[i])) throw ArgumentError('incomplete path data');
    return double.parse(tokens[i++]);
  }

  void cubic(double x1, double y1, double x2, double y2, double ex, double ey) {
    const n = 16;
    for (var k = 1; k <= n; k++) {
      final t = k / n, u = 1 - t;
      cur.add([
        u * u * u * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * ex,
        u * u * u * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * ey,
      ]);
    }
  }

  void quad(double qx, double qy, double ex, double ey) {
    const n = 12;
    for (var k = 1; k <= n; k++) {
      final t = k / n, u = 1 - t;
      cur.add([u * u * x + 2 * u * t * qx + t * t * ex, u * u * y + 2 * u * t * qy + t * t * ey]);
    }
  }

  void arc(double rx, double ry, double phiDeg, bool large, bool sweep, double ex, double ey) {
    if (rx == 0 || ry == 0) {
      cur.add([ex, ey]);
      return;
    }
    rx = rx.abs();
    ry = ry.abs();
    final phi = phiDeg * math.pi / 180, cp = math.cos(phi), sp = math.sin(phi);
    final dx = (x - ex) / 2, dy = (y - ey) / 2;
    final x1p = cp * dx + sp * dy, y1p = -sp * dx + cp * dy;
    final lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
    if (lam > 1) {
      rx *= math.sqrt(lam);
      ry *= math.sqrt(lam);
    }
    final num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    final den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co = den == 0 ? 0.0 : math.sqrt(math.max(0, num / den));
    if (large == sweep) co = -co;
    final cxp = co * rx * y1p / ry, cyp = -co * ry * x1p / rx;
    final ccx = cp * cxp - sp * cyp + (x + ex) / 2, ccy = sp * cxp + cp * cyp + (y + ey) / 2;
    double ang(double ux, double uy, double vx, double vy) {
      final a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
      return a;
    }

    final t1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep && dt > 0) dt -= 2 * math.pi;
    if (sweep && dt < 0) dt += 2 * math.pi;
    final n = math.max(4, (dt.abs() / (math.pi / 16)).ceil());
    for (var k = 1; k <= n; k++) {
      final t = t1 + dt * k / n;
      cur.add([ccx + rx * math.cos(t) * cp - ry * math.sin(t) * sp, ccy + rx * math.cos(t) * sp + ry * math.sin(t) * cp]);
    }
  }

  void endSub(bool closed) {
    if (cur.length > 1) {
      // a closing point on top of the first one is dropped.
      if (cur.length > 2 && (cur.first[0] - cur.last[0]).abs() < 1e-9 && (cur.first[1] - cur.last[1]).abs() < 1e-9) {
        cur.removeLast();
      }
      subs.add(cur);
      if (!closed) allClosed = false;
    }
    cur = [];
  }

  while (i < tokens.length) {
    if (isCmd(tokens[i])) {
      cmd = tokens[i++];
    } else if (cmd == null) {
      throw ArgumentError('path data must start with a command letter');
    }
    final c = cmd;
    final rel = c == c.toLowerCase();
    final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
    switch (c.toUpperCase()) {
      case 'M':
        endSub(false);
        x = ox + next();
        y = oy + next();
        sx = x;
        sy = y;
        cur = [[x, y]];
        // further pairs are line-tos.
        cmd = rel ? 'l' : 'L';
      case 'L':
        x = ox + next();
        y = oy + next();
        cur.add([x, y]);
      case 'H':
        x = ox + next();
        cur.add([x, y]);
      case 'V':
        y = oy + next();
        cur.add([x, y]);
      case 'C':
        final x1 = ox + next(), y1 = oy + next(), x2 = ox + next(), y2 = oy + next(), ex = ox + next(), ey = oy + next();
        cubic(x1, y1, x2, y2, ex, ey);
        lcx = x2;
        lcy = y2;
        x = ex;
        y = ey;
      case 'S':
        final r = prevCmd != null && 'CS'.contains(prevCmd.toUpperCase());
        final x1 = r ? 2 * x - lcx! : x, y1 = r ? 2 * y - lcy! : y;
        final x2 = ox + next(), y2 = oy + next(), ex = ox + next(), ey = oy + next();
        cubic(x1, y1, x2, y2, ex, ey);
        lcx = x2;
        lcy = y2;
        x = ex;
        y = ey;
      case 'Q':
        final qx = ox + next(), qy = oy + next(), ex = ox + next(), ey = oy + next();
        quad(qx, qy, ex, ey);
        lcx = qx;
        lcy = qy;
        x = ex;
        y = ey;
      case 'T':
        final r = prevCmd != null && 'QT'.contains(prevCmd.toUpperCase());
        final qx = r ? 2 * x - lcx! : x, qy = r ? 2 * y - lcy! : y;
        final ex = ox + next(), ey = oy + next();
        quad(qx, qy, ex, ey);
        lcx = qx;
        lcy = qy;
        x = ex;
        y = ey;
      case 'A':
        final rx = next(), ry = next(), phi = next();
        final large = next() != 0, sweep = next() != 0;
        final ex = ox + next(), ey = oy + next();
        arc(rx, ry, phi, large, sweep, ex, ey);
        x = ex;
        y = ey;
      case 'Z':
        endSub(true);
        x = sx;
        y = sy;
        cur = [[x, y]];
    }
    prevCmd = c;
    if (cur.isEmpty) cur = [[x, y]];
  }
  endSub(false);
  return (subs, allClosed && subs.isNotEmpty);
}


/// A shape whose outline isn't its plain primitive - rounded corners (they
/// change the shape), masks, cuts, mask regions, deforming effects - as
/// one path of its real outline (local space), or null for a plain one.
String? _shapedPath(Project project, Layer layer, int frame) {
  final c = layer.content;
  if (c.shape == 'text' || isNodeLine(c)) return null;
  final shaped = layer.fill.cornerRadius > 0 || shapeSmoothedOrGrown(layer) ||
      layer.fill.outerRadius > 0 ||
      layer.links.any((k) => k.enabled && k.to.startsWith('round')) ||
      layer.masks.any((m) => m.enabled && m.sourceLayerId != null) ||
      layer.cuts.any((k) => k.enabled && k.cutterId != null) ||
      (layer.maskRegions?.enabled ?? false) ||
      layer.effectStack.any(isDeformingEffect);
  if (!shaped) return null;
  final rings = layerVectorRings(project, layer, frame);
  if (rings == null) return null;
  final d = [
    for (final r in rings)
      if (r.length >= 3) 'M${r.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}Z'
  ].join();
  return d;
}

/// `a` moved `k` (0..1) of the way to `b` (#rrggbb); `a` when no `b`.
String _mixHex(String a, String? b, double k) {
  if (b == null || k <= 0) return a;
  int? ch(String h, int i) => h.length >= 7 ? int.tryParse(h.substring(1 + i * 2, 3 + i * 2), radix: 16) : null;
  final out = StringBuffer('#');
  for (var i = 0; i < 3; i++) {
    final x = ch(a, i), y = ch(b, i);
    if (x == null || y == null) return a;
    out.write((x + (y - x) * k.clamp(0.0, 1.0)).round().toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// A layer flipped (Crop tab, Mirror) about its own middle: the flip goes
/// into its matrix, so the SVG shows it flipped too.
List<double> _withLayerMirror(Layer layer, List<double> m) {
  if (!layer.mirrorX && !layer.mirrorY) return m;
  final b = shapeBoundingBox(layer.content);
  final cx = (b.minX + b.maxX) / 2, cy = (b.minY + b.maxY) / 2;
  final sx = layer.mirrorX ? -1.0 : 1.0, sy = layer.mirrorY ? -1.0 : 1.0;
  return matMul(m, [sx, 0, 0, sy, (1 - sx) * cx, (1 - sy) * cy]);
}


/// A shape's own body (local space): its real outline when it isn't a
/// plain primitive, else the primitive.
String? _shapeBody(Layer layer, Project project, int frame, String fillAttr) {
  final content = layer.content;
  final shaped = _shapedPath(project, layer, frame);
  if (shaped != null) return '<path d="$shaped" fill-rule="${_rule(layer)}" $fillAttr/>';
  if (content.shape == 'compound' && content.contours != null) {
    final d = [
      for (final c in layerContours(layer))
        if (c.isNotEmpty) 'M${c.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}Z'
    ].join();
    return '<path d="$d" $fillAttr/>';
  }
  if (isRectLikeShape(content.shape)) {
    final w = content.size[0], h = content.size[1];
    return '<rect x="${_fmt(content.offset[0] - w / 2)}" y="${_fmt(content.offset[1] - h / 2)}" '
        'width="${_fmt(w)}" height="${_fmt(h)}" $fillAttr/>';
  }
  if (content.shape == 'circle' && content.size[0] == content.size[1]) {
    return '<circle cx="${_fmt(content.offset[0])}" cy="${_fmt(content.offset[1])}" r="${_fmt(content.size[0] / 2)}" $fillAttr/>';
  }
  final pts = layerShapePoints(layer);
  if (pts.isEmpty) return null;
  return '<polygon points="${pts.map((p) => '${_fmt(p[0])},${_fmt(p[1])}').join(' ')}" $fillAttr/>';
}

/// Pieces of folded paper lie over each other: non-zero, so they add up.
String _rule(Layer layer) => deformsPointwise(layer) ? 'nonzero' : 'evenodd';

/// The shape's outline as path data (local space), for its shadow and
/// glows.
String? _outlineD(Project project, Layer layer, int frame) {
  final rings = layerVectorRings(project, layer, frame);
  if (rings == null) return null;
  final d = [
    for (final r in rings)
      if (r.length >= 3) 'M${r.map((p) => '${_fmt(p[0])} ${_fmt(p[1])}').join('L')}Z'
  ].join();
  return d.isEmpty ? null : d;
}
