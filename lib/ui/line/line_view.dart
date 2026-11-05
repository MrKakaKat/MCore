import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';

/// Line tab: the selected vector line's points (model/line_path.dart).
/// While it is open every point is a handle on the stage; the segment
/// arriving at the selected point is straight, a bezier (its handles show
/// on the stage) or a sine wave. Close & fill turns the line into a filled
/// shape. Reveal draws it along its length over time, from either end.
class LineView extends StatefulWidget {
  final AppState app;
  const LineView({super.key, required this.app});

  @override
  State<LineView> createState() => _LineViewState();
}

class _LineViewState extends State<LineView> {
  AppState get app => widget.app;


  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null || !isNodeLine(layer.content)) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Select a line, or add one'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('line-add'),
                onPressed: () => app.addLayer('line'),
                icon: const Icon(Icons.horizontal_rule),
                label: const Text('Add line'),
              ),
            ]),
          );
        }
        return _editor(context, layer);
      },
    );
  }

  Widget _editor(BuildContext context, Layer layer) {
    final c = layer.content;
    final nodes = c.lineNodes!;
    final sel = lineSelectedPoint.clamp(0, nodes.length - 1);
    final n = nodes.length;
    final id = layer.id;
    final local = layerLocalFrame(layer, app.currentFrame);
    // the segments either side of the selected point: before it (arriving)
    // and after it (leaving); an open line's ends have one each.
    final before = c.lineClosed || sel > 0 ? sel : null;
    final after = c.lineClosed || sel < n - 1 ? (sel + 1) % n : null;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        _number('width', c.lineWidth, 4, const ParamScale.slider(0.5, 60, decimals: 1),
            (v) => app.editLineLive(id, (c) => c.lineWidth = v)),
        const Divider(height: 20),
        Row(children: [
          const Expanded(child: Text('Points', style: TextStyle(fontWeight: FontWeight.bold))),
          // tap the stage to add points (past the selected end; from a
          // point in the middle a new line starts there).
          IconButton(
            key: const ValueKey('line-tap-add'),
            icon: Icon(app.lineTapAdd ? Icons.touch_app : Icons.touch_app_outlined, size: 20),
            tooltip: app.lineTapAdd ? 'adding points by tapping the stage (tap to stop)' : 'add points by tapping the stage',
            color: app.lineTapAdd ? Theme.of(context).colorScheme.primary : null,
            onPressed: () => app.setLineTapAdd(!app.lineTapAdd),
          ),
          IconButton(
            key: const ValueKey('line-point-add'),
            icon: const Icon(Icons.add_circle_outline, size: 20),
            tooltip: 'add a point after the selected one',
            onPressed: () => app.editLine(id, (c) => lineSelectedPoint = addPointAfter(c, sel)),
          ),
          IconButton(
            key: const ValueKey('line-point-remove'),
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            tooltip: 'remove the selected point',
            onPressed: n <= 2
                ? null
                : () => app.editLine(id, (c) {
                      removeLinePoint(c, sel);
                      lineSelectedPoint = (sel - 1).clamp(0, c.lineNodes!.length - 1);
                    }),
          ),
        ]),
        // the selected point's position as keys (it moves over time).
        Row(children: [
          Expanded(
            child: Text(
              nodes[sel].posT != null && nodes[sel].posT!.keyframes.isNotEmpty
                  ? 'Point ${sel + 1} moves: ${nodes[sel].posT!.keyframes.length} keys'
                  : 'Point ${sel + 1} stays put',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IconButton(
            key: const ValueKey('line-point-key'),
            icon: Icon(
                nodes[sel].posT?.keyframes.any((k) => k.frame == local.round()) ?? false
                    ? Icons.diamond
                    : Icons.diamond_outlined,
                size: 16),
            tooltip: 'key the point\'s position at this frame',
            onPressed: () => app.editLine(id, (c) => toggleLinePointKey(c, sel, local.round())),
          ),
        ]),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < n; i++)
            ChoiceChip(
              key: ValueKey('line-point-$i'),
              label: Text('${i + 1}'),
              selected: i == sel,
              onSelected: (_) => app.selectLinePoint(i),
            ),
        ]),
        if (app.lineTapAdd)
          hint(sel == 0 || sel == n - 1
                  ? 'Tap the stage: each tap adds a point past point ${sel + 1}.'
                  : 'Tap the stage: a new line starts from point ${sel + 1}.') ??
              const SizedBox.shrink(),
        const SizedBox(height: 8),
        ..._curveType(c, id, sel, nodes, before, after, local),
        ..._pointExtras(c, id, sel, nodes[sel], before != null && after != null),
        const Divider(height: 20),
        ..._endsAndJoins(c, id),
        if (_selectedLines().length > 1) ...[
          const SizedBox(height: 6),
          OutlinedButton.icon(
            key: const ValueKey('line-join'),
            onPressed: () => app.joinSelectedLines(),
            icon: const Icon(Icons.merge_type, size: 18),
            label: Text('Join the ${_selectedLines().length} selected lines'),
          ),
        ],
        const Divider(height: 20),
        Wrap(spacing: 8, runSpacing: 4, children: [
          FilterChip(
            key: const ValueKey('line-loop'),
            label: const Text('Loop'),
            selected: c.lineClosed,
            onSelected: n < 3 ? null : (v) => app.editLine(id, (c) => loopLine(c, v)),
          ),
          if (!c.lineFilled)
            ActionChip(
              key: const ValueKey('line-close'),
              avatar: const Icon(Icons.format_color_fill, size: 16),
              label: const Text('Fill'),
              onPressed: n < 3 ? null : () => app.closeLineOf(id),
            )
          else ...[
            // what the fill reaches.
            for (final (k, label) in const [('outer', 'Fill: outer edge'), ('points', 'Fill: through points'), ('inner', 'Fill: inner edge')])
              ChoiceChip(
                key: ValueKey('line-fill-$k'),
                label: Text(label),
                selected: c.lineFillMode == k,
                onSelected: (_) => app.editLine(id, (c) => c.lineFillMode = k),
              ),
            ActionChip(
              key: const ValueKey('line-unfill'),
              label: const Text('Remove fill'),
              onPressed: () => app.editLine(id, (c) => c.lineFilled = false),
            ),
          ],
          FilterChip(
            key: const ValueKey('line-hidden'),
            label: const Text('Invisible'),
            selected: c.lineHidden,
            onSelected: (v) => app.editLine(id, (c) => c.lineHidden = v),
          ),
          FilterChip(
            key: const ValueKey('line-locked'),
            label: const Text('Lock position'),
            selected: c.lineLocked,
            onSelected: (v) => app.editLine(id, (c) => c.lineLocked = v),
          ),
        ]),
        hint('Invisible: not drawn, only a thin guide shows on the stage. Lock: the line can\'t be dragged.') ??
            const SizedBox.shrink(),
        const SizedBox(height: 8),
        // the stage's handles: the line's points or its shape's box.
        SegmentedButton<bool>(
          key: const ValueKey('line-handles'),
          segments: const [
            ButtonSegment(value: false, label: Text('Point handles')),
            ButtonSegment(value: true, label: Text('Box handles')),
          ],
          selected: {c.lineShowBox},
          onSelectionChanged: (v) => app.editLine(id, (c) => c.lineShowBox = v.first),
        ),
        const Divider(height: 20),
        const Text('Reveal', style: TextStyle(fontWeight: FontWeight.bold)),
        hint('Draws the line along its length: animate where it starts and ends (0-1).') ?? const SizedBox.shrink(),
        _trackRow('line.start', 'start', c.lineTrimStart ??= track(0.0), local, 0.0),
        _trackRow('line.end', 'end', c.lineTrimEnd ??= track(1.0), local, 1.0),
      ],
    );
  }

  List<Layer> _selectedLines() => [
        for (final lid in app.selectedGroup)
          if (findLayer(app.project, lid) case final l? when isNodeLine(l.content) && !l.content.lineClosed) l
      ];

  /// "Curve type": one choice for both sides of the selected point (a
  /// bezier gets a mirrored pair of handles), the mirror switches, and -
  /// folded - each side apart.
  List<Widget> _curveType(Content c, String id, int sel, List<LineNode> nodes, int? before, int? after, double local) {
    final kind = linePointKind(c, sel);
    final shown = after ?? before;
    return [
      Text('Curve type at point ${sel + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Wrap(spacing: 6, children: [
        for (final (k, label) in const [('line', 'Straight'), ('bezier', 'Bezier'), ('sine', 'Sine'), ('arc', 'Circle')])
          ChoiceChip(
            key: ValueKey('line-kind-$k'),
            label: Text(label),
            selected: kind == k,
            onSelected: (_) => app.editLine(id, (c) => setLinePointKind(c, sel, k)),
          ),
      ]),
      if (kind == 'bezier') ...[
        SwitchListTile(
          key: const ValueKey('line-mirror-handles'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Handles mirrored'),
          subtitle: const Text('dragging one turns the other the opposite way'),
          value: lineHandlesMirrored,
          onChanged: (v) => app.setAppPreference('lineHandlesMirrored', v),
        ),
        if (lineHandlesMirrored)
          SwitchListTile(
            key: const ValueKey('line-mirror-length'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Same length both sides'),
            subtitle: const Text('off: each keeps its own distance from the point'),
            value: c.lineMirrorLength,
            onChanged: (v) => app.editLine(id, (c) => c.lineMirrorLength = v),
          ),
      ],
      if ((kind == 'sine' || kind == 'arc') && shown != null) ...[
        _trackRow('line.both.amp', kind == 'arc' ? 'bulge' : 'amplitude', nodes[shown].ampT, local, 12,
            scale: const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25)),
        if (kind == 'sine')
          _trackRow('line.both.waves', 'waves', nodes[shown].wavesT, local, 2, scale: const ParamScale.slider(0.5, 20, decimals: 1)),
      ],
      ExpansionTile(
        key: const ValueKey('line-sides'),
        tilePadding: EdgeInsets.zero,
        dense: true,
        title: const Text('Each side apart', style: TextStyle(fontSize: 13)),
        children: [
          if (before != null) ..._segment(c, id, sel, 'before', 'Before point ${sel + 1}', nodes[before], local),
          if (after != null) ..._segment(c, id, sel, 'after', 'After point ${sel + 1}', nodes[after], local),
        ],
      ),
    ];
  }

  /// The selected point's own width and its corner's rounding - each
  /// with keys.
  List<Widget> _pointExtras(Content c, String id, int sel, LineNode node, bool corner) {
    final f = layerLocalFrame(findLayer(app.project, id)!, app.currentFrame).round();
    Widget row(String name, String label, double value, ParamScale scale, double? reset) {
      final t = node.keys[name];
      final keyed = t?.keyframes.any((k) => k.frame == f) ?? false;
      double fit(double v) => v.clamp(scale.min, scale.max).toDouble();
      return ParamEditor(
        key: ValueKey('line-point-$name'),
        prefKey: 'line.point.$name',
        label: label,
        values: [value],
        scale: scale,
        onEditStart: app.pushUndo,
        onChanged: (v) => app.editLineLive(id, (c) => setLinePointValue(c, sel, name, fit(v.first), f)),
        onCommit: (v) => app.editLineLive(id, (c) => setLinePointValue(c, sel, name, fit(v.first), f)),
        trailing: [
          ResetIconButton(onPressed: () => app.editLine(id, (c) => setLinePointValue(c, sel, name, reset, f))),
          IconButton(
            key: ValueKey('line-point-$name-key'),
            icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
            tooltip: 'toggle keyframe at current frame',
            visualDensity: VisualDensity.compact,
            onPressed: () => app.editLine(id, (c) => toggleLinePointValueKey(c, sel, name, f)),
          ),
        ],
      );
    }

    return [
      const SizedBox(height: 4),
      row('w', node.w == null ? 'width here (the line\'s)' : 'width here', node.w ?? c.lineWidth,
          const ParamScale.slider(0, 120, decimals: 1), null),
      if (corner || c.lineClosed) ...[
        row('round', 'round the corner', node.round, const ParamScale.slider(0, 200, decimals: 1), 0),
        if (node.round > 0)
          row('roundK', 'rounding shape (0 cut, 0.55 circle, 1 sharp)', node.roundK, const ParamScale.slider(0, 1, decimals: 3),
              circleRoundK),
      ],
    ];
  }

  /// The ends of an open line and how it turns at its points.
  List<Widget> _endsAndJoins(Content c, String id) => [
        const Text('Ends and corners', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        if (!c.lineClosed)
          Wrap(spacing: 6, children: [
            for (final (k, label) in const [('round', 'Round ends'), ('square', 'Square ends'), ('triangle', 'Pointed ends')])
              ChoiceChip(
                key: ValueKey('line-cap-$k'),
                label: Text(label),
                selected: c.lineCap == k,
                onSelected: (_) => app.editLine(id, (c) => c.lineCap = k),
              ),
          ]),
        if (!c.lineClosed && c.lineCap == 'square')
          _number('end corners round', c.lineCapRound, 0, const ParamScale.slider(0, 1, decimals: 2),
              (v) => app.editLineLive(id, (c) => c.lineCapRound = v)),
        if (!c.lineClosed && c.lineCap == 'square' && c.lineCapRound > 0)
          _number('end rounding shape', c.lineCapShape, circleRoundK, const ParamScale.slider(0, 1, decimals: 3),
              (v) => app.editLineLive(id, (c) => c.lineCapShape = v)),
        if (!c.lineClosed && c.lineCap == 'triangle')
          _number('tip length', c.lineCapLength, 1, const ParamScale.slider(0.2, 10, decimals: 2),
              (v) => app.editLineLive(id, (c) => c.lineCapLength = v)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (final (k, label) in const [('round', 'Round turns'), ('miter', 'Sharp turns'), ('bevel', 'Cut turns')])
            ChoiceChip(
              key: ValueKey('line-join-$k'),
              label: Text(label),
              selected: c.lineJoin == k,
              onSelected: (_) => app.editLine(id, (c) => c.lineJoin = k),
            ),
        ]),
        if (c.lineJoin == 'miter')
          _number('sharpest reach', c.lineMiterLimit, 4, const ParamScale.slider(1, 20, decimals: 1),
              (v) => app.editLineLive(id, (c) => c.lineMiterLimit = v)),
        hint('Sharp turns carry the edges on until they meet; a very tight turn reaching past "sharpest reach" '
                '(in half widths) is cut straight instead.') ??
            const SizedBox.shrink(),
      ];

  /// One segment's shape: straight, bezier or sine (its waves).
  /// One side of the selected point: straight, bezier (this point's own
  /// handle only), sine or circle - with their keyable values.
  List<Widget> _segment(Content c, String id, int point, String side, String title, LineNode node, double local) {
    final kind = lineSideKind(c, point, side);
    return [
      Text(title, style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 4),
      Wrap(spacing: 6, children: [
        for (final (k, label) in const [('line', 'Straight'), ('bezier', 'Bezier'), ('sine', 'Sine'), ('arc', 'Circle')])
          ChoiceChip(
            key: ValueKey('line-$side-$k'),
            label: Text(label),
            selected: kind == k,
            onSelected: (_) => app.editLine(id, (c) => setLineSideKind(c, point, side, k)),
          ),
      ]),
      if (kind == 'sine' || kind == 'arc')
        _trackRow('line.$side.amp', kind == 'arc' ? 'bulge' : 'amplitude', node.ampT, local, 12,
            scale: const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25)),
      if (kind == 'sine')
        _trackRow('line.$side.waves', 'waves', node.wavesT, local, 2, scale: const ParamScale.slider(0.5, 20, decimals: 1)),
      const SizedBox(height: 6),
    ];
  }

  Widget _number(String label, double value, double def, ParamScale scale, void Function(double v) set) =>
      ParamEditor(
        prefKey: 'line.$label',
        label: label,
        values: [value],
        scale: scale,
        onEditStart: app.pushUndo,
        onChanged: (v) {
          set(v.first.clamp(scale.min, scale.max).toDouble());
        },
        onCommit: (v) => set(v.first.clamp(scale.min, scale.max).toDouble()),
        trailing: [
          ResetIconButton(onPressed: () {
            app.pushUndo();
            set(def);
          })
        ],
      );

  // the box follows a curve's new size.
  void _syncBox() {
    final l = findLayer(app.project, app.selection.selectedLayer);
    if (l != null && isNodeLine(l.content)) syncLineBox(l.content);
  }

  /// An animatable value (0..1 by default) with its keyframe toggle.
  Widget _trackRow(String prefKey, String label, Track trk, double localFrame, double def,
      {ParamScale scale = const ParamScale.slider(0, 1, decimals: 3)}) {
    double fit(double v) => v.clamp(scale.min, scale.max).toDouble();
    final value = (evaluateTrack(app.project, trk, localFrame) as num).toDouble();
    final frame = localFrame.round();
    final keyed = trk.keyframes.any((k) => k.frame == frame);
    return ParamEditor(
      prefKey: prefKey,
      label: label,
      values: [value],
      scale: scale,
      onEditStart: app.pushUndo,
      onChanged: (v) {
        setTrackValueAt(trk, frame, fit(v.first));
        _syncBox();
        app.commitEdit();
      },
      onCommit: (v) {
        app.pushUndo();
        setTrackValueAt(trk, frame, fit(v.first));
        _syncBox();
        app.commitEdit();
      },
      trailing: [
        ResetIconButton(onPressed: () {
          app.pushUndo();
          setTrackValueAt(trk, frame, def);
          app.commitEdit();
        }),
        IconButton(
          key: ValueKey('$prefKey-key'),
          icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
          tooltip: 'toggle keyframe at current frame',
          visualDensity: VisualDensity.compact,
          onPressed: () {
            app.pushUndo();
            if (keyed) {
              trk.keyframes.removeWhere((k) => k.frame == frame);
            } else {
              trk.keyframes
                ..add(Keyframe(frame: frame, value: value, temporal: newKeyEasing()))
                ..sort((a, b) => a.frame.compareTo(b.frame));
            }
            app.commitEdit();
          },
        ),
      ],
    );
  }
}

/// A point after `i`: in the middle of the next segment, or past the end
/// of an open line. Returns its index.
int addPointAfter(Content c, int i) {
  final nodes = c.lineNodes!;
  if (!c.lineClosed && i >= nodes.length - 1) {
    final a = nodes[nodes.length - 2], b = nodes.last;
    nodes.add(LineNode(b.x + (b.x - a.x) / 2, b.y + (b.y - a.y) / 2));
    syncLineBox(c);
    return nodes.length - 1;
  }
  return insertLinePoint(c, (i + 1) % nodes.length == 0 ? nodes.length : i + 1);
}
