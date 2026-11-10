import 'dart:math' as math;

// Flutter's own material.dart exports an unrelated `Easing` (animation
// curve helpers) that collides with movement_core's `Easing` (the
// {x1,y1,x2,y2} cubic-bezier value this whole file edits) - hidden here
// since every use of the name in this file means the movement_core one.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Easing;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';

/// Ported from movement-core/src/ui/graphEditor.js - a dialog editing the
/// temporal easing {x1,y1,x2,y2} on either one keyframe transition
/// (per-segment mode) or a spatial track's whole-path `globalEasing`
/// (whole-path mode). The actual state transitions and curve sampling
/// live in packages/movement_core/lib/ui_geometry/graph_editor.dart
/// (real `dart test` coverage); this file only owns the two canvases
/// (the classic 0..1 easing square with draggable P1/P2 handles, and the
/// real value-vs-time curve preview) plus the segment/component tabs and
/// coordinate number fields.
///
/// Disclosed deviation from JS, beyond the pure UI redesign for touch
/// (JS's 14px mouse hit-radius becomes a wider touch target below, same
/// reasoning as every other handle in this port - see handles.js's own
/// port in ui_geometry/handles.dart): JS's graph editor never calls
/// render(playback.currentFrame) while dragging - only its own two
/// canvases repaint, so the main stage doesn't visibly react to a
/// mid-drag easing edit at all. This port calls app.commitEdit() on every
/// change instead, so the stage preview updates live - matching this
/// whole app's reactive ChangeNotifier architecture (every other
/// params-panel edit already does this) rather than replicating a static
/// JS panel that happens not to.
///
/// UNVERIFIED like the rest of ui/ against a real device - covered here
/// by real widget tests (drag simulation, coordinate field edits).
class GraphEditorView extends StatefulWidget {
  final AppState app;
  final Track track;
  final int componentCount;
  final bool wholePath;
  const GraphEditorView({
    super.key,
    required this.app,
    required this.track,
    required this.componentCount,
    this.wholePath = false,
  });

  @override
  State<GraphEditorView> createState() => _GraphEditorViewState();
}

class _GraphEditorViewState extends State<GraphEditorView> {
  late final GraphEditorState _state;

  /// Switch: edit the bezier as its speed graph instead of the square.
  static bool speedView = false;

  @override
  void initState() {
    super.initState();
    _state = GraphEditorState(track: widget.track, componentCount: widget.componentCount, wholePath: widget.wholePath);
  }

  void _updateEasing(Easing next) {
    setState(() => _state.setEditingTemporal(next));
    // a master key (every parameter keyed at that frame) keeps one ease.
    if (!_state.wholePath && masterKeysShareEase) {
      final layer = findLayer(widget.app.project, widget.app.selection.selectedLayer);
      final (_, k1) = _state.currentSegmentKeyframes();
      if (layer != null && allTracksKeyedAt(layer, k1.frame)) shareEaseAtFrame(layer, k1.frame, next);
    }
    widget.app.commitEdit();
  }

  /// no way to undo a bad drag/coordinate edit short of re-deriving the
  /// original numbers by hand - resets the currently EDITED easing (this
  /// segment's temporal, or the track's whole-path globalEasing) back to the
  /// same easeInOut default new keyframes are created with. Not a port of
  /// anything in graphEditor.js (it has no reset button at all) - a disclosed,
  /// deliberate addition.
  void _reset() => _updateEasing(newKeyEasing());

  @override
  Widget build(BuildContext context) {
    final t = _state.getEditingTemporal();
    // Compact: the curve beside its result and its numbers, one row of
    // types; no scrolling around the curve - its drags never fight a
    // scroll (the curve takes the finger at once, see _claimFinger).
    Widget toolIcon(String key, IconData icon, String tip, VoidCallback? onPressed) => IconButton(
          key: ValueKey(key),
          icon: Icon(icon, size: 18),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: onPressed,
        );
    const small = TextStyle(fontSize: 11, color: Colors.grey);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      child: SizedBox(
        width: 340,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // what is eased, and the curve tools (copy, paste, reset, close).
              Row(children: [
                Expanded(
                  child: Text(_state.wholePath ? 'Ease - whole path' : 'Ease',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                toolIcon('ease-copy', Icons.copy, 'copy this curve',
                    () => setState(() => widget.app.copiedEasing = _state.getEditingTemporal())),
                toolIcon('ease-paste', Icons.paste, 'paste the copied curve',
                    widget.app.copiedEasing == null ? null : () => _updateEasing(widget.app.copiedEasing!)),
                toolIcon('ease-reset', Icons.restart_alt, 'back to the default curve', _reset),
                toolIcon('ease-close', Icons.close, 'close', () => Navigator.pop(context)),
              ]),
              // which transition (one line, sideways) and X / Y.
              if (!_state.wholePath || _state.componentCount > 1)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    if (_state.componentCount > 1) ...[_componentTabs(), const SizedBox(width: 8)],
                    if (!_state.wholePath) _segmentTabs(),
                  ]),
                ),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: _kindChips(t)),
                if (!t.isOvershoot)
                  toolIcon('ease-speed-view', speedView ? Icons.show_chart : Icons.speed,
                      speedView ? 'edit as a curve' : 'edit as a speed graph', () => setState(() => speedView = !speedView)),
              ]),
              const SizedBox(height: 6),
              if (t.isOvershoot)
                _overshootControls(t)
              else if (speedView)
                _SpeedGraph(easing: t, onChanged: _updateEasing)
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 170,
                      height: 170,
                      child: _claimFinger(_EasingSquare(easing: t, onChanged: _updateEasing)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Result', style: small),
                          SizedBox(
                            height: 56,
                            child: CustomPaint(painter: _CurvePainter(_state.sampleCurve()), size: Size.infinite),
                          ),
                          const SizedBox(height: 6),
                          for (final row in const [
                            [(0, 'x1'), (1, 'y1')],
                            [(2, 'x2'), (3, 'y2')],
                          ])
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(children: [
                                for (final (i, name) in row) ...[
                                  if (i.isOdd) const SizedBox(width: 6),
                                  Expanded(
                                    child: _CoordField(
                                      label: name,
                                      value: [t.x1, t.y1, t.x2, t.y2][i],
                                      onCommit: (v) => _updateEasing(switch (i) {
                                        0 => t.withBezier(GraphEditorState.clampX(v), t.y1, t.x2, t.y2),
                                        1 => t.withBezier(t.x1, GraphEditorState.clampY(v), t.x2, t.y2),
                                        2 => t.withBezier(t.x1, t.y1, GraphEditorState.clampX(v), t.y2),
                                        _ => t.withBezier(t.x1, t.y1, t.x2, GraphEditorState.clampY(v)),
                                      }),
                                    ),
                                  ),
                                ],
                              ]),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              if (t.isOvershoot || speedView) ...[
                const SizedBox(height: 4),
                const Text('Result', style: small),
                SizedBox(
                  height: 48,
                  child: CustomPaint(painter: _CurvePainter(_state.sampleCurve()), size: Size.infinite),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The ease type: the bezier square, or an overshoot (passes the end
  /// and settles back) / anticipation (swings back before leaving).
  Widget _kindChips(Easing t) {
    const kinds = [('bezier', 'Bezier'), ('overshoot', 'Overshoot'), ('anticipate', 'Anticipate')];
    return Wrap(
      spacing: 4,
      children: [
        for (final (kind, label) in kinds)
          ChoiceChip(
            key: ValueKey('ease-kind-$kind'),
            visualDensity: VisualDensity.compact,
            labelStyle: const TextStyle(fontSize: 12),
            label: Text(label),
            selected: t.kind == kind,
            onSelected: (_) => _updateEasing(t.withOvershoot(kind: kind)),
          ),
      ],
    );
  }

  Widget _overshootControls(Easing t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.kind == 'overshoot' ? 'How far past the end' : 'How far back before leaving',
            style: const TextStyle(fontSize: 12)),
        Row(children: [
          Expanded(
            child: Slider(
              key: const ValueKey('ease-overshoot-amount'),
              value: t.amount.clamp(0.02, 0.6),
              min: 0.02,
              max: 0.6,
              onChanged: (v) => _updateEasing(t.withOvershoot(amount: v)),
            ),
          ),
          SizedBox(width: 40, child: Text('${(t.amount * 100).round()}%', style: const TextStyle(fontSize: 12))),
        ]),
        Row(children: [
          const Text('Extra swings', style: TextStyle(fontSize: 12)),
          IconButton(
            key: const ValueKey('ease-bounces-minus'),
            icon: const Icon(Icons.remove, size: 18),
            onPressed: t.bounces <= 0 ? null : () => _updateEasing(t.withOvershoot(bounces: t.bounces - 1)),
          ),
          Text('${t.bounces}'),
          IconButton(
            key: const ValueKey('ease-bounces-plus'),
            icon: const Icon(Icons.add, size: 18),
            onPressed: t.bounces >= 5 ? null : () => _updateEasing(t.withOvershoot(bounces: t.bounces + 1)),
          ),
        ]),
      ],
    );
  }

  Widget _segmentTabs() {
    final labels = _state.segmentLabels();
    return Wrap(
      spacing: 4,
      children: [
        for (var i = 0; i < labels.length; i++)
          ChoiceChip(
            label: Text(labels[i]),
            selected: _state.segmentIndex == i,
            onSelected: (_) => setState(() => _state.segmentIndex = i),
          ),
      ],
    );
  }

  Widget _componentTabs() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 2; i++)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: ChoiceChip(
              label: Text(i == 0 ? 'X' : 'Y'),
              selected: _state.component == i,
              onSelected: (_) => setState(() => _state.component = i),
            ),
          ),
      ],
    );
  }


}

/// The curve takes the finger the moment it lands: nothing behind it (a
/// scrolling list, the sheet) can start moving instead while it is dragged.
Widget _claimFinger(Widget child) => RawGestureDetector(
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(() => EagerGestureRecognizer(), (_) {}),
      },
      behavior: HitTestBehavior.opaque,
      child: child,
    );

/// Same persistent-controller pattern as params_panel_view.dart's
/// `_NumField`, for the same reason: a fresh TextEditingController built
/// inline on every rebuild (which happens on every drag update here,
/// since drag updates rebuild this whole dialog via setState) would
/// clobber an in-progress edit in one of the OTHER three coordinate
/// fields the instant a drag moves the easing square.
class _CoordField extends StatefulWidget {
  final String label;
  final double value;
  final ValueChanged<double> onCommit;
  const _CoordField({required this.label, required this.value, required this.onCommit});

  @override
  State<_CoordField> createState() => _CoordFieldState();
}

class _CoordFieldState extends State<_CoordField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  static String _format(double value) => (value * 100).round() / 100 == value ? value.toString() : value.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focusNode = FocusNode()..addListener(_handleFocusChange);
  }

  // an edited value could sit typed-but-uncommitted indefinitely - some
  // on-device numeric keypads have no visible "done"/submit key at all, so
  // onSubmitted alone (IME action only) never fires; tapping away to dismiss
  // the keyboard is the only way those keyboards let you finish. Committing on
  // focus loss as well closes that gap without touching onSubmitted's own
  // behavior.
  void _handleFocusChange() {
    if (_focusNode.hasFocus) return;
    final v = double.tryParse(_controller.text);
    if (v != null) widget.onCommit(v);
  }

  @override
  void didUpdateWidget(covariant _CoordField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && oldWidget.value != widget.value) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // the name as the field's own label: four fit side by side.
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
                labelText: widget.label,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6)),
            onSubmitted: (text) {
              final v = double.tryParse(text);
              if (v != null) widget.onCommit(v);
            },
          ),
        ),
      ],
    );
  }
}

/// Draggable P1/P2 handle square - JS's `easingCanvas` pointer handlers.
///
/// the handles "didn't feel grabbed" - drags wouldn't reliably register. Root
/// cause: this used `GestureDetector`'s `onPan*` callbacks, which only fire
/// once Flutter's gesture ARENA resolves a pan gesture as the winner for that
/// pointer - and this widget sits inside a dialog `Column`, where an ancestor
/// scrollable competing for the same vertical motion can win that arena
/// instead (touch-slop crossing alone doesn't guarantee `onPanStart` fires
/// here). Fixed by switching to `Listener`, which receives every raw
/// `PointerDownEvent`/`PointerMoveEvent`/`PointerUpEvent` for any pointer that
/// hits it, unconditionally - the same direct-pointer- capture technique
/// `stage_gesture_controller.dart` already relies on for exactly this reason,
/// arena resolution never enters into it.
class _EasingSquare extends StatefulWidget {
  final Easing easing;
  final ValueChanged<Easing> onChanged;
  const _EasingSquare({required this.easing, required this.onChanged});

  @override
  State<_EasingSquare> createState() => _EasingSquareState();
}

class _EasingSquareState extends State<_EasingSquare> {
  // 'p1' | 'p2' | null - which handle (if any) the current drag grabbed.
  String? _dragTarget;

  void _handleDown(Offset local, Size size) {
    final t = widget.easing;
    final p1 = Offset(t.x1 * size.width, size.height - t.y1 * size.height);
    final p2 = Offset(t.x2 * size.width, size.height - t.y2 * size.height);
    final d1 = (local - p1).distance;
    final d2 = (local - p2).distance;
    // JS's mouse hit-radius is 14px; widened for a touch target, same
    // reasoning as every other draggable handle ported this session.
    _dragTarget = math.min(d1, d2) < 24 ? (d1 < d2 ? 'p1' : 'p2') : null;
  }

  void _handleUpdate(Offset local, Size size) {
    if (_dragTarget == null) return;
    final mx = local.dx.clamp(0.0, size.width);
    final my = local.dy.clamp(0.0, size.height);
    final nx = GraphEditorState.clampX(mx / size.width);
    final ny = GraphEditorState.clampY(1 - my / size.height);
    final t = widget.easing;
    widget.onChanged(_dragTarget == 'p1' ? t.withBezier(nx, ny, t.x2, t.y2) : t.withBezier(t.x1, t.y1, nx, ny));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _handleDown(e.localPosition, size),
          onPointerMove: (e) => _handleUpdate(e.localPosition, size),
          onPointerUp: (_) => _dragTarget = null,
          onPointerCancel: (_) => _dragTarget = null,
          child: CustomPaint(painter: _EasingSquarePainter(widget.easing), size: size),
        );
      },
    );
  }
}

/// JS's drawEasingSquare(): quarter grid, dashed diagonal reference,
/// control-point guide lines, the bezier curve itself, start/end dots,
/// and the two draggable handles.
class _EasingSquarePainter extends CustomPainter {
  final Easing easing;
  _EasingSquarePainter(this.easing);

  Offset _toCanvas(double x, double y, Size size) => Offset(x * size.width, size.height - y * size.height);

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0xFF2B2B2B)
      ..strokeWidth = 1;
    for (var g = 0; g <= 4; g++) {
      final p = g / 4;
      canvas.drawLine(Offset(p * size.width, 0), Offset(p * size.width, size.height), gridPaint);
      canvas.drawLine(Offset(0, p * size.height), Offset(size.width, p * size.height), gridPaint);
    }

    final dashPaint = Paint()
      ..color = const Color(0xFF3A3A3A)
      ..strokeWidth = 1;
    _drawDashedLine(canvas, Offset(0, size.height), Offset(size.width, 0), dashPaint);

    final start = _toCanvas(0, 0, size);
    final end = _toCanvas(1, 1, size);
    final p1 = _toCanvas(easing.x1, easing.y1, size);
    final p2 = _toCanvas(easing.x2, easing.y2, size);

    final guidePaint = Paint()
      ..color = const Color(0xFF555555)
      ..strokeWidth = 1;
    canvas.drawLine(start, p1, guidePaint);
    canvas.drawLine(end, p2, guidePaint);

    final curvePaint = Paint()
      ..color = const Color(0xFFD8D8D8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..moveTo(start.dx, start.dy);
    path.cubicTo(p1.dx, p1.dy, p2.dx, p2.dy, end.dx, end.dy);
    canvas.drawPath(path, curvePaint);

    final dotPaint = Paint()..color = const Color(0xFF666666);
    canvas.drawCircle(start, 3, dotPaint);
    canvas.drawCircle(end, 3, dotPaint);

    final handlePaint = Paint()..color = const Color(0xFFE0E0E0);
    canvas.drawCircle(p1, 5, handlePaint);
    canvas.drawCircle(p2, 5, handlePaint);
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dashLength = 3.0, gapLength = 3.0;
    final total = (b - a).distance;
    final direction = (b - a) / total;
    var covered = 0.0;
    while (covered < total) {
      final segEnd = math.min(covered + dashLength, total);
      canvas.drawLine(a + direction * covered, a + direction * segEnd, paint);
      covered += dashLength + gapLength;
    }
  }

  @override
  bool shouldRepaint(covariant _EasingSquarePainter oldDelegate) =>
      oldDelegate.easing.x1 != easing.x1 || oldDelegate.easing.y1 != easing.y1 || oldDelegate.easing.x2 != easing.x2 || oldDelegate.easing.y2 != easing.y2;
}

/// JS's drawCurvePreview(): the real value-vs-time curve, samples
/// already computed by GraphEditorState.sampleCurve (auto-scaled to the
/// observed min/max, same as JS).
/// The ease as speed over time: drag left / right to move where it is
/// fastest, up / down for a sharper or smoother peak; presets below.
class _SpeedGraph extends StatefulWidget {
  final Easing easing;
  final ValueChanged<Easing> onChanged;
  const _SpeedGraph({required this.easing, required this.onChanged});

  @override
  State<_SpeedGraph> createState() => _SpeedGraphState();
}

class _SpeedGraphState extends State<_SpeedGraph> {
  double _peak = 0.5, _smooth = 0.6;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1.6,
          child: LayoutBuilder(
            builder: (context, c) => _claimFinger(Listener(
              key: const ValueKey('speed-graph'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (d) => _drag(d.localPosition, c.biggest),
              onPointerMove: (d) => _drag(d.localPosition, c.biggest),
              child: CustomPaint(
                size: c.biggest,
                painter: _SpeedPainter(easeSpeedSamples(widget.easing), Theme.of(context).colorScheme.primary),
              ),
            )),
          ),
        ),
        Wrap(spacing: 4, children: [
          for (final e in speedPresets.entries)
            ActionChip(
              key: ValueKey('speed-${e.key}'),
              label: Text(e.key, style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              onPressed: () => widget.onChanged(e.value.withBezier(e.value.x1, e.value.y1, e.value.x2, e.value.y2)),
            ),
        ]),
      ],
    );
  }

  void _drag(Offset p, Size size) {
    _peak = (p.dx / size.width).clamp(0.0, 1.0);
    // higher on the graph: a taller, sharper peak.
    _smooth = (p.dy / size.height).clamp(0.0, 1.0);
    final e = speedPeakEasing(_peak, _smooth);
    widget.onChanged(widget.easing.withBezier(e.x1, e.y1, e.x2, e.y2));
  }
}

class _SpeedPainter extends CustomPainter {
  final List<double> speeds;
  final Color color;
  _SpeedPainter(this.speeds, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()
      ..color = color.withOpacity(0.08));
    final top = math.max(1.0, speeds.reduce(math.max)) * 1.1;
    final path = Path();
    for (var i = 0; i < speeds.length; i++) {
      final x = i / (speeds.length - 1) * size.width, y = size.height - speeds[i] / top * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    // the even speed (linear) for reference.
    final evenY = size.height - 1 / top * size.height;
    canvas.drawLine(Offset(0, evenY), Offset(size.width, evenY), Paint()
      ..color = Colors.grey.withOpacity(0.5)
      ..strokeWidth = 1);
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _SpeedPainter old) => true;
}

class _CurvePainter extends CustomPainter {
  final List<double> samples;
  _CurvePainter(this.samples);

  static const _pad = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = const Color(0xFF2B2B2B)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(_pad, size.height - _pad), Offset(size.width - _pad, size.height - _pad), axisPaint);

    if (samples.isEmpty) return;
    final minV = samples.reduce(math.min);
    final maxV = samples.reduce(math.max);
    final range = (maxV - minV) == 0 ? 1.0 : (maxV - minV);
    final steps = samples.length - 1;

    final curvePaint = Paint()
      ..color = const Color(0xFFD8D8D8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = _pad + (size.width - 2 * _pad) * i / (steps == 0 ? 1 : steps);
      final y = (size.height - _pad) - ((samples[i] - minV) / range) * (size.height - 2 * _pad);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, curvePaint);
  }

  @override
  bool shouldRepaint(covariant _CurvePainter oldDelegate) => !_listEquals(oldDelegate.samples, samples);

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
