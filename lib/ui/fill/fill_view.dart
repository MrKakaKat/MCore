import 'dart:math' as math;

import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/color_row.dart';
import '../common/keyed_param_row.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../graph_editor/graph_editor_view.dart';

/// Fill tab: a shape's colour - plain, or a gradient made of glows (points
/// and lines that light the shape in their own colour over the base
/// colour, fading out at their radius). Glow position, radius and
/// strength animate like every other parameter; while this tab is open
/// the glows' handles show on the stage.
class FillView extends StatefulWidget {
  final AppState app;
  const FillView({super.key, required this.app});

  @override
  State<FillView> createState() => _FillViewState();
}

class _FillViewState extends State<FillView> {
  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    glowHandlesVisible = true;
    cornerHandlesVisible = true;
  }

  @override
  void dispose() {
    glowHandlesVisible = false;
    cornerHandlesVisible = false;
    super.dispose();
  }

  void _edit(void Function() change) {
    app.pushUndo();
    change();
    app.commitEdit();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return const Center(child: Text('No layer selected'));
        if (!supportsShapeFill(layer)) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Fill is for vector shapes - images and video keep their own pixels, '
                  'text has its colours in the Text tab.'),
            ),
          );
        }
        final fill = layer.fill;
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            ColorRow(
              key: const ValueKey('fill-base-colour'),
              label: fill.gradient ? 'Base colour' : 'Colour',
              hex: layer.color ?? '#8ab4d8',
              onPick: (c) => _edit(() {
                layer.color = c;
                // a merged shape: every shape takes it (each keeps its alpha).
                final cc = layer.content.contourColors;
                if (cc != null) {
                  for (var i = 0; i < cc.length; i++) {
                    cc[i] = _keepAlpha(c, cc[i]);
                  }
                }
              }),
            ),
            ..._mergedColours(layer),
            ..._shapeStyle(layer),
            SwitchListTile(
              key: const ValueKey('fill-gradient'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Gradient (glows)', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: hint('points and lines that light the shape in their own colour'),
              value: fill.gradient,
              onChanged: (v) => _edit(() => fill.gradient = v),
            ),
            if (fill.gradient) ...[
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('fill-add-point'),
                    icon: const Icon(Icons.blur_on, size: 16),
                    label: const Text('Add point'),
                    onPressed: () => _edit(() => addGlow(layer, 'point')),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('fill-add-line'),
                    icon: const Icon(Icons.horizontal_rule, size: 16),
                    label: const Text('Add line'),
                    onPressed: () => _edit(() => addGlow(layer, 'line')),
                  ),
                ],
              ),
              if (fill.glows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No glows yet - add a point or a line, then drag it on the stage.',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              for (var i = 0; i < fill.glows.length; i++) _glowCard(context, layer, fill.glows[i], i),
            ],
          ],
        );
      },
    );
  }

  Widget _glowCard(BuildContext context, Layer layer, GlowEmitter g, int index) {
    final glows = layer.fill.glows;
    final localFrame = layerLocalFrame(layer, app.currentFrame);
    return Card(
      key: ValueKey('glow-${g.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Checkbox(value: g.enabled, onChanged: (v) => _edit(() => g.enabled = v ?? true)),
                Icon(g.kind == 'line' ? Icons.horizontal_rule : Icons.blur_on, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text('${g.kind == 'line' ? 'Line' : 'Point'} ${index + 1}')),
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  tooltip: 'draw under the previous glow',
                  onPressed: index == 0
                      ? null
                      : () => _edit(() {
                            glows.removeAt(index);
                            glows.insert(index - 1, g);
                          }),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 16),
                  tooltip: 'draw over the next glow',
                  onPressed: index == glows.length - 1
                      ? null
                      : () => _edit(() {
                            glows.removeAt(index);
                            glows.insert(index + 1, g);
                          }),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'delete this glow',
                  onPressed: () => _edit(() => glows.remove(g)),
                ),
              ],
            ),
            // see-through: the glow fades the shape out instead.
            if (g.color != 'transparent')
              ColorRow(label: 'Colour', hex: g.color, onPick: (c) => _edit(() => g.color = c)),
            FilterChip(
              key: ValueKey('glow-transparent-${g.id}'),
              label: const Text('See-through (fades the shape out)'),
              selected: g.color == 'transparent',
              onSelected: (v) => _edit(() => g.color = v ? 'transparent' : '#ffffff'),
            ),
            _trackRow(context, 'glow.position', g.kind == 'line' ? 'start' : 'position', g.position, localFrame,
                [0.5, 0.5], const ParamScale.ruler(unitsPerPixel: 0.005, minorTick: 0.05, majorTick: 0.25, decimals: 2)),
            if (g.kind == 'line')
              _trackRow(context, 'glow.end', 'end', g.end, localFrame, [0.8, 0.5],
                  const ParamScale.ruler(unitsPerPixel: 0.005, minorTick: 0.05, majorTick: 0.25, decimals: 2)),
            _trackRow(context, 'glow.radius', 'radius', g.radius, localFrame, g.kind == 'line' ? 0.25 : 0.5,
                const ParamScale.slider(0, 2, decimals: 2)),
            _trackRow(context, 'glow.strength', 'strength', g.strength, localFrame, 1.0,
                const ParamScale.slider(0, 1, decimals: 2)),
          ],
        ),
      ),
    );
  }

  static double _maxCorner(Layer layer) => math.min(layer.content.size[0], layer.content.size[1]).abs() / 2;

  /// Rounded corners (rects) and the shape's shadow.
  List<Widget> _shapeStyle(Layer layer) {
    final fill = layer.fill, sh = fill.shadow;
    Widget value(String key, String label, double v, double def, ParamScale scale, void Function(double) set) => ParamEditor(
          prefKey: 'fill.$key',
          label: label,
          values: [v],
          scale: scale,
          onEditStart: app.pushUndo,
          onChanged: (x) {
            set(x.first.clamp(scale.min, scale.max).toDouble());
            app.commitEdit();
          },
          onCommit: (x) => _edit(() => set(x.first.clamp(scale.min, scale.max).toDouble())),
          trailing: [ResetIconButton(onPressed: () => _edit(() => set(def)))],
        );
    final shape = layer.content.shape;
    final polyLike = const {'triangle', 'ngon', 'polygon', 'compound'}.contains(shape);
    return [
      // triangles, polygons, merged shapes: corners by bezier.
      if (polyLike)
        value('corners', 'rounded corners', fill.cornerRadius, 0,
            const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25, min: 0, max: 2000),
            (v) => fill.cornerRadius = v),
      if (polyLike)
        value('outer', 'inward corners filled round', fill.outerRadius, 0,
            const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25, min: 0, max: 2000),
            (v) => fill.outerRadius = v),
      if ((shape == 'rect' || polyLike) && (fill.cornerRadius > 0 || fill.outerRadius > 0))
        value('cornerShape', 'rounding shape (0 cut, 0.55 circle, 1 sharp)', fill.cornerShape, circleRoundK,
            const ParamScale.slider(0, 1, decimals: 3), (v) => fill.cornerShape = v),
      if (shape == 'rect')
        // at most half the shorter side: there the rect is a pill / circle.
        value(
            'corners',
            'rounded corners',
            fill.cornerRadius.clamp(0.0, _maxCorner(layer)).toDouble(),
            0,
            ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25, min: 0, max: _maxCorner(layer)),
            (v) => fill.cornerRadius = v),
      if (layer.content.shape == 'rect' && fill.cornerRadius > 0)
        SwitchListTile(
          key: const ValueKey('fill-corners-round'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Corners stay round when scaled', style: TextStyle(fontSize: 13)),
          subtitle: hint('Off: the corners stretch with the scale into ovals'),
          value: fill.cornersKeepRound,
          onChanged: (v) => _edit(() => fill.cornersKeepRound = v),
        ),
      SwitchListTile(
        key: const ValueKey('fill-shadow'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Shadow', style: TextStyle(fontWeight: FontWeight.bold)),
        value: sh.enabled,
        onChanged: (v) => _edit(() => sh.enabled = v),
      ),
      if (sh.enabled) ...[
        ParamEditor(
          prefKey: 'fill.shadow offset',
          label: 'offset',
          values: [sh.dx, sh.dy],
          componentLabels: const ['x', 'y'],
          scale: const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25),
          padCenter: const [0, 0],
          padSpan: 400,
          onEditStart: app.pushUndo,
          onChanged: (v) {
            sh
              ..dx = v[0]
              ..dy = v[1];
            app.commitEdit();
          },
          onCommit: (v) => _edit(() => sh
            ..dx = v[0]
            ..dy = v[1]),
        ),
        value('shadow opacity', 'opacity', sh.opacity, 0.6, const ParamScale.slider(0, 1), (v) => sh.opacity = v),
        value('shadow scale', 'scale', sh.scale, 1, const ParamScale.slider(0.1, 3), (v) => sh.scale = v),
        ColorRow(label: 'Colour', hex: sh.color, onPick: (c) => _edit(() => sh.color = c)),
        SwitchListTile(
          key: const ValueKey('fill-shadow-lag'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Lag', style: TextStyle(fontSize: 13)),
          subtitle: hint('The shadow trails the shape when it moves and settles back when it stops. '
              'A long shadow stretches: only its far end lags.'),
          value: sh.lag,
          onChanged: (v) => _edit(() => sh.lag = v),
        ),
        if (sh.lag) ...[
          value('lag speed', 'lag speed', sh.lagSpeed, 60, const ParamScale.slider(1, 500, decimals: 0),
              (v) => sh.lagSpeed = v),
          value('lag bounciness', 'lag bounciness %', sh.lagBounciness, 30,
              const ParamScale.slider(0, 100, decimals: 0), (v) => sh.lagBounciness = v),
        ],
        SwitchListTile(
          key: const ValueKey('fill-long-shadow'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Long shadow (3D depth)', style: TextStyle(fontSize: 13)),
          value: sh.long,
          onChanged: (v) => _edit(() => sh.long = v),
        ),
        if (!sh.long) ...[
          SwitchListTile(
            key: const ValueKey('fill-shadow-echo'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Echo', style: TextStyle(fontSize: 13)),
            subtitle: hint('Copies of the shape along the offset, each farther one fainter.'),
            value: sh.echo,
            onChanged: (v) => _edit(() => sh.echo = v),
          ),
          if (sh.echo) ...[
            value('echo count', 'copies', sh.echoCount.toDouble(), 5, const ParamScale.slider(1, 30, integer: true),
                (v) => sh.echoCount = v.round()),
            keyedParamRow(
                app: app,
                prefKey: 'fill.echo fade',
                label: 'fade',
                trk: sh.echoFade,
                localFrame: layerLocalFrame(layer, app.currentFrame),
                defaultValue: 0.8,
                scale: const ParamScale.slider(0, 1),
                layer: layer),
          ],
        ],
      ],
      const Divider(height: 16),
    ];
  }

  /// One animatable glow parameter: editor, easing curve, reset, key.
  Widget _trackRow(BuildContext context, String prefKey, String label, Track trk, double localFrame,
      dynamic defaultValue, ParamScale scale) {
    final raw = evaluateTrack(app.project, trk, localFrame);
    final values = raw is List ? [for (final v in raw) (v as num).toDouble()] : [(raw as num).toDouble()];
    final frame = localFrame.round();
    final keyed = trk.keyframes.any((k) => k.frame == frame);
    dynamic out(List<double> v) => values.length == 1 ? v.first : [...v];
    return ParamEditor(
      prefKey: prefKey,
      label: label,
      values: values,
      scale: scale,
      componentLabels: values.length == 2 ? const ['x', 'y'] : null,
      onEditStart: app.pushUndo,
      onChanged: (v) {
        setTrackValueAt(trk, frame, out(v));
        app.commitEdit();
      },
      onCommit: (v) {
        app.pushUndo();
        setTrackValueAt(trk, frame, out(v));
        app.commitEdit();
      },
      trailing: [
        if (trk.keyframes.length >= 2)
          IconButton(
            icon: const Icon(Icons.show_chart, size: 16),
            tooltip: 'edit easing curve',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => GraphEditorView(app: app, track: trk, componentCount: values.length),
            ),
          ),
        ResetIconButton(onPressed: () {
          app.pushUndo();
          setTrackValueAt(trk, frame, defaultValue is List ? [...defaultValue] : defaultValue);
          app.commitEdit();
        }),
        IconButton(
          icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
          tooltip: 'toggle keyframe at current frame',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: () {
            app.pushUndo();
            if (keyed) {
              trk.keyframes.removeWhere((k) => k.frame == frame);
            } else {
              trk.keyframes.add(Keyframe(frame: frame, value: raw, temporal: newKeyEasing()));
              trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
            }
            if (trk.spatial) autoComputeTangents(trk);
            app.commitEdit();
          },
        ),
      ],
    );
  }

  /// A merged shape: a colour row for each of its shapes (a shape's holes
  /// go with it).
  List<Widget> _mergedColours(Layer layer) {
    final c = layer.content;
    final cc = c.contourColors;
    if (cc == null || cc.length != (c.contours?.length ?? 0)) return const [];
    final join = c.contourJoin != null && c.contourJoin!.length == cc.length ? c.contourJoin! : null;
    final out = <Widget>[];
    var n = 0;
    for (var i = 0; i < cc.length; i++) {
      if (join != null && join[i]) continue;
      n++;
      final idx = i;
      out.add(Padding(
        padding: const EdgeInsets.only(left: 12),
        child: ColorRow(
          key: ValueKey('merged-colour-$idx'),
          label: 'Shape $n',
          hex: cc[idx] ?? layer.color ?? '#8ab4d8',
          onPick: (v) => _edit(() {
            cc[idx] = _keepAlpha(v, cc[idx]);
            for (var j = idx + 1; j < cc.length && join != null && join[j]; j++) {
              cc[j] = cc[idx];
            }
          }),
        ),
      ));
    }
    return out;
  }
}

/// `picked` with `old`'s alpha, unless `picked` brings its own.
String _keepAlpha(String picked, String? old) {
  final p = picked.replaceFirst('#', '');
  if (p.length == 8 || old == null) return picked;
  final o = old.replaceFirst('#', '');
  return o.length == 8 ? '#$p${o.substring(6)}' : '#$p';
}
