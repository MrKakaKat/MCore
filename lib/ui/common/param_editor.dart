import 'xy_pad.dart';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import 'reset_button.dart';

import 'num_field.dart';

/// How a parameter value is dragged: an ordinary slider over a fixed
/// range, or an endless ruler for values with no natural limit (angles
/// that go past 360, anchor, scale, pixel offsets...).
class ParamScale {
  final bool isRuler;
  final double min;
  final double max;
  final bool integer;
  final int decimals;

  /// Decimals of the value printed above the control (angles show whole
  /// degrees; the value itself is never rounded).
  final int labelDecimals;
  // ruler only
  final double unitsPerPixel;
  final double minorTick;
  final double majorTick;
  final String suffix;

  const ParamScale.slider(this.min, this.max,
      {this.decimals = 2, this.integer = false, int? labelDecimals, this.suffix = ''})
      : labelDecimals = labelDecimals ?? (integer ? 0 : decimals),
        isRuler = false,
        unitsPerPixel = 0,
        minorTick = 0,
        majorTick = 0;

  const ParamScale.ruler({
    required this.unitsPerPixel,
    required this.minorTick,
    required this.majorTick,
    this.min = double.negativeInfinity,
    this.max = double.infinity,
    this.decimals = 2,
    int? labelDecimals,
    this.suffix = '',
  })  : labelDecimals = labelDecimals ?? decimals,
        isRuler = true,
        integer = false;

  /// Degrees: 0.5 deg per pixel, a tick every 15 deg, labels every 90.
  static const degrees = ParamScale.ruler(
      unitsPerPixel: 0.5, minorTick: 15, majorTick: 90, decimals: 1, labelDecimals: 0, suffix: '°');
}

/// A parameter row a header line with the name (its current value), the
/// caller's icons (ease / reset / key), the switch between sliders and number
/// fields, and an expand arrow. The control itself only shows when the row is
/// expanded, and then takes the row's full width - a slider per component, an
/// endless ruler for unbounded values, or the plain number fields.
///
/// Both choices (expanded, fields vs sliders) are remembered per
/// `prefKey` for the app session.
///
/// Drags call `onEditStart` once (push undo there), then `onChanged` live;
/// the number fields call `onCommit` per entered value.
/// A ParamEditor header icon shown only while its control is open.
class OpenOnly extends StatelessWidget {
  final Widget child;
  const OpenOnly({super.key, required this.child});

  @override
  Widget build(BuildContext context) => child;
}

class ParamEditor extends StatefulWidget {
  final String prefKey;

  /// The parameter's name, shown capitalised.
  final String? label;
  final List<double> values;
  final ParamScale scale;
  final List<String>? componentLabels;
  final VoidCallback onEditStart;
  final ValueChanged<List<double>> onChanged;
  final ValueChanged<List<double>> onCommit;

  /// Icons shown in the header before the mode switch (ease, reset, key).
  final List<Widget> trailing;

  /// A point parameter's value at the XY pad's centre (null: where it is).
  final List<double>? padCenter;

  /// How much of the value the XY pad spans (see XyPadTarget.span).
  final double padSpan;

  const ParamEditor({
    super.key,
    required this.prefKey,
    this.label,
    required this.values,
    required this.scale,
    this.componentLabels,
    required this.onEditStart,
    required this.onChanged,
    required this.onCommit,
    this.trailing = const [],
    this.padCenter,
    this.padSpan = 1,
  });

  /// prefKey -> true when that parameter shows number fields.
  static final Map<String, bool> _fieldsMode = {};

  /// prefKey -> the user's own snap stations (kept with the app's
  /// settings - see onStationsChanged).
  static final Map<String, List<double>> stations = {};

  /// Called when the stations change (the app saves them).
  static VoidCallback? onStationsChanged;

  /// Every degrees ruler snaps to these too.
  static const angleStations = [0.0, 45.0, 90.0];

  /// A ruler's stations: the user's list, or (never edited) the built-in
  /// ones for angles - those can be removed too.
  static List<double> stationsFor(String prefKey, ParamScale s) =>
      stations[prefKey] ?? (identical(s, ParamScale.degrees) ? angleStations : const <double>[]);

  /// The copied values (Copy under the number fields); Paste is there
  /// while it holds some.
  static List<double>? clipboard;

  /// prefKey -> how many of the smallest units a ruler's - / + step is.
  static final Map<String, double> steps = {};

  /// prefKey -> true when that parameter's row is expanded.
  static final Map<String, bool> _expanded = {};

  /// Rows start collapsed; tests of the controls themselves open them.
  @visibleForTesting
  static bool expandedByDefault = false;

  @visibleForTesting
  static void resetModes({bool expanded = false}) {
    _fieldsMode.clear();
    _expanded.clear();
    expandedByDefault = expanded;
  }

  @override
  State<ParamEditor> createState() => _ParamEditorState();
}

/// "shutter" -> "Shutter".
String capitalizeLabel(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class _ParamEditorState extends State<ParamEditor> {
  bool get _fields => ParamEditor._fieldsMode[widget.prefKey] ?? false;
  bool get _open => ParamEditor._expanded[widget.prefKey] ?? ParamEditor.expandedByDefault;

  List<double> _with(int i, double v) =>
      [for (var j = 0; j < widget.values.length; j++) j == i ? v : widget.values[j]];

  static const double controlHeight = 34;

  static const _iconConstraints = BoxConstraints(minWidth: 28, minHeight: 28);

  String _readout() {
    final s = widget.scale;
    final d = s.isRuler ? s.labelDecimals : (s.integer ? 0 : s.labelDecimals);
    return widget.values.map((v) => '${v.toStringAsFixed(d)}${s.suffix}').join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final header = Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: () => setState(() => ParamEditor._expanded[widget.prefKey] = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  if (widget.label != null)
                    Flexible(
                      child: Text(capitalizeLabel(widget.label!),
                          style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
                    ),
                  const SizedBox(width: 8),
                  // the value, so a collapsed row still says where it is.
                  Flexible(
                    child: Text(_readout(),
                        style: const TextStyle(fontSize: 11, color: Colors.grey), overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          ),
        ),
        // a point on the plane: the XY pad.
        if (_open && widget.values.length == 2)
          IconButton(
            key: ValueKey('xy-pad-open-${widget.prefKey}'),
            icon: const Icon(Icons.open_with, size: 16, color: Colors.grey),
            tooltip: 'move the point in a pad',
            onPressed: () => openXyPad(
                context,
                XyPadTarget(
                  label: capitalizeLabel(widget.label ?? widget.prefKey),
                  start: [...widget.values],
                  center: widget.padCenter,
                  span: widget.padSpan,
                  onEditStart: widget.onEditStart,
                  onChanged: widget.onChanged,
                  onCommit: widget.onCommit,
                )),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: _iconConstraints,
          ),
        // the ruler / number switch first, then reset and the key.
        if (_open)
        IconButton(
          icon: Icon(_fields ? Icons.tune : Icons.numbers, size: 16, color: Colors.grey),
          tooltip: _fields ? 'show sliders' : 'show number fields',
          onPressed: () => setState(() {
            ParamEditor._fieldsMode[widget.prefKey] = !_fields;
            ParamEditor._expanded[widget.prefKey] = true;
          }),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: _iconConstraints,
        ),
        // folded: only the key (and ease) buttons - reset and the
        // ruler / number switch show once the row is opened.
        for (final w in widget.trailing)
          if (_open || (w is! ResetIconButton && w is! OpenOnly)) w,
        IconButton(
          icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
          tooltip: _open ? 'hide control' : 'show control',
          onPressed: () => setState(() => ParamEditor._expanded[widget.prefKey] = !_open),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: _iconConstraints,
        ),
      ],
    );
    if (!_open) return header;

    Widget body;
    if (_fields) {
      body = Row(children: [
        for (var i = 0; i < widget.values.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          if (widget.componentLabels != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(widget.componentLabels![i], style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          Expanded(
              child: NumField(
                  value: widget.values[i], onCommit: (v) => widget.onCommit(_with(i, v)))),
        ],
        // x and y the same: the second takes the first.
        if (widget.values.length == 2)
          IconButton(
            key: ValueKey('fields-same-${widget.prefKey}'),
            icon: const Icon(Icons.chevron_left, size: 18),
            tooltip: 'the same as the first',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: _iconConstraints,
            onPressed: () {
              widget.onEditStart();
              widget.onCommit([widget.values[0], widget.values[0]]);
            },
          ),
      ]);
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        body,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton.icon(
            key: ValueKey('fields-copy-${widget.prefKey}'),
            icon: const Icon(Icons.copy, size: 14),
            label: const Text('Copy', style: TextStyle(fontSize: 12)),
            onPressed: () => setState(() => ParamEditor.clipboard = [...widget.values]),
          ),
          TextButton.icon(
            key: ValueKey('fields-paste-${widget.prefKey}'),
            icon: const Icon(Icons.paste, size: 14),
            label: const Text('Paste', style: TextStyle(fontSize: 12)),
            onPressed: ParamEditor.clipboard == null
                ? null
                : () {
                    final c = ParamEditor.clipboard!;
                    widget.onEditStart();
                    widget.onCommit([for (var i = 0; i < widget.values.length; i++) c[i < c.length ? i : c.length - 1]]);
                  },
          ),
        ]),
      ]);
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < widget.values.length; i++)
            Row(children: [
              // x / y in their own column, level with the ruler's numbers.
              if (widget.componentLabels != null)
                SizedBox(
                  width: 14,
                  height: controlHeight,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(widget.componentLabels![i],
                        style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ),
                ),
              if (widget.scale.isRuler) _stepButton(i, -1),
              Expanded(child: _dragControl(context, i)),
              if (widget.scale.isRuler) _stepButton(i, 1),
            ]),
          // how big a - / + step is: that many of the smallest units.
          if (widget.scale.isRuler)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Text('Step  ${_unitLabel()} ×', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(width: 4),
              SizedBox(
                width: 48,
                child: NumField(
                  key: ValueKey('ruler-step-${widget.prefKey}'),
                  value: ParamEditor.steps[widget.prefKey] ?? 1,
                  onCommit: (v) => setState(() => ParamEditor.steps[widget.prefKey] = v <= 0 ? 1 : v),
                ),
              ),
            ]),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 6), child: body),
        // the user's own stations, right under the ruler.
        if (!_fields && widget.scale.isRuler && widget.values.length == 1) _stationRow(context),
      ],
    );
  }

  final _stationField = TextEditingController();

  @override
  void dispose() {
    _stationField.dispose();
    super.dispose();
  }

  /// A number field, + to keep it as a station block, then the blocks
  /// (tap: go there; ×: remove), scrolling sideways.
  Widget _stationRow(BuildContext context) {
    final own = ParamEditor.stationsFor(widget.prefKey, widget.scale);
    final s = widget.scale;
    String fmt(double v) {
      final t = v.toStringAsFixed(math.max(0, s.labelDecimals));
      return t.contains('.') ? t.replaceFirst(RegExp(r'\.?0+$'), '') : t;
    }

    void add() {
      final v = double.tryParse(_stationField.text.replaceAll(',', '.'));
      if (v == null) return;
      setState(() {
        ParamEditor.stations[widget.prefKey] = ({...own, v}.toList()..sort());
        _stationField.clear();
      });
      ParamEditor.onStationsChanged?.call();
    }

    // styled like the key chips in Keyframes: oval, × on the right.
    Widget block(double v, {bool fixed = false}) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Material(
            key: ValueKey('station-${widget.prefKey}-$v'),
            color: fixed
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                widget.onEditStart();
                widget.onCommit([v]);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${fmt(v)}${s.suffix}', style: const TextStyle(fontSize: 12)),
                  if (!fixed) ...[
                    const SizedBox(width: 6),
                    InkWell(
                      key: ValueKey('station-del-${widget.prefKey}-$v'),
                      onTap: () {
                        setState(() => ParamEditor.stations[widget.prefKey] = [...own]..remove(v));
                        ParamEditor.onStationsChanged?.call();
                      },
                      child: const Icon(Icons.close, size: 14),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Row(children: [
        SizedBox(
          width: 56,
          height: 28,
          child: TextField(
            key: ValueKey('station-field-${widget.prefKey}'),
            controller: _stationField,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(isDense: true, hintText: 'Stop', contentPadding: EdgeInsets.all(6)),
            onSubmitted: (_) => add(),
          ),
        ),
        IconButton(
          key: ValueKey('station-add-${widget.prefKey}'),
          icon: const Icon(Icons.add, size: 16),
          tooltip: 'keep it as a snap station',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: _iconConstraints,
          onPressed: add,
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final v in own) block(v),
            ]),
          ),
        ),
      ]),
    );
  }

  /// The smallest unit of this value (its last shown decimal).
  double get _unit => math.pow(10, -widget.scale.decimals).toDouble();

  String _unitLabel() => _unit.toStringAsFixed(widget.scale.decimals);

  /// - / + beside a ruler: moves the value by the step.
  Widget _stepButton(int i, int dir) => SizedBox(
        width: 26,
        height: controlHeight,
        child: InkWell(
          key: ValueKey('ruler-${dir < 0 ? 'minus' : 'plus'}-${widget.prefKey}-$i'),
          borderRadius: BorderRadius.circular(13),
          onTap: () {
            final s = widget.scale;
            final step = _unit * (ParamEditor.steps[widget.prefKey] ?? 1);
            widget.onEditStart();
            widget.onCommit(_with(i, (widget.values[i] + dir * step).clamp(s.min, s.max).toDouble()));
          },
          child: Icon(dir < 0 ? Icons.remove : Icons.add, size: 16, color: Colors.grey),
        ),
      );

  Widget _dragControl(BuildContext context, int i) {
    final s = widget.scale;
    final v = widget.values[i];
    if (s.isRuler) {
      return EndlessRuler(
        value: v,
        scale: s,
        onChangeStart: widget.onEditStart,
        onChanged: (nv) => widget.onChanged(_with(i, nv)),
        stations: [
          if (widget.values.length == 1)
            ...ParamEditor.stationsFor(widget.prefKey, s)
          else if (identical(s, ParamScale.degrees))
            ...ParamEditor.angleStations,
        ],
      );
    }
    // same size as a ruler: the value on top, the track across the whole
    // width below it.
    final accent = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: controlHeight,
      child: Column(children: [
        SizedBox(
          height: 12,
          child: Text('${v.toStringAsFixed(s.labelDecimals)}${s.suffix}',
              style: TextStyle(fontSize: 10, color: accent, fontWeight: FontWeight.bold)),
        ),
        SizedBox(
          height: controlHeight - 12,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackShape: const _FullWidthTrackShape(),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: v.clamp(s.min, s.max).toDouble(),
              min: s.min,
              max: s.max,
              divisions: s.integer ? (s.max - s.min).round() : null,
              onChangeStart: (_) => widget.onEditStart(),
              onChanged: (nv) => widget.onChanged(_with(i, s.integer ? nv.roundToDouble() : nv)),
            ),
          ),
        ),
      ]),
    );
  }
}

/// A slider track that spans the whole control (minus the thumb radius at
/// each end) instead of leaving the default overlay margins.
class _FullWidthTrackShape extends RoundedRectSliderTrackShape {
  const _FullWidthTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const inset = 8.0;
    final trackHeight = sliderTheme.trackHeight ?? 4;
    final top = offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(offset.dx + inset, top, math.max(0, parentBox.size.width - 2 * inset), trackHeight);
  }
}

/// Settings: how long the rulers are - the value range one ruler width
/// covers, as a multiple of each parameter's own (0.25..4).
double rulerLengthScale = 1;

/// The stage's zoom (set by the stage as it draws): zoomed in, the rulers
/// go finer by as much (angles excepted), so moving things stays easy.
double stageRulerZoom = 1;

/// Value units per ruler pixel now.
double rulerUnitsPerPixel(ParamScale s) =>
    s.unitsPerPixel * rulerLengthScale / (identical(s, ParamScale.degrees) ? 1 : math.max(1.0, stageRulerZoom));

/// A tape ruler under a fixed centre marker: drag it sideways to change
/// the value, as far as you like in either direction (angles past 360,
/// anchors off the frame...). The tape follows the finger.
class EndlessRuler extends StatefulWidget {
  final double value;
  final ParamScale scale;
  final VoidCallback onChangeStart;
  final ValueChanged<double> onChanged;

  /// Snap stations: the value sticks to them while dragged (a degrees
  /// ruler compares round the circle).
  final List<double> stations;
  const EndlessRuler({
    super.key,
    required this.value,
    required this.scale,
    required this.onChangeStart,
    required this.onChanged,
    this.stations = const [],
  });

  @override
  State<EndlessRuler> createState() => _EndlessRulerState();
}

class _EndlessRulerState extends State<EndlessRuler> {
  double? _startValue;
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // count from where the finger went down, not from where the drag
      // was recognised - the tape moves exactly as far as the finger.
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: (_) {
        _startValue = widget.value;
        _dx = 0;
        widget.onChangeStart();
      },
      onHorizontalDragUpdate: (d) {
        final start = _startValue;
        if (start == null) return;
        _dx += d.delta.dx;
        final s = widget.scale;
        var v = (start - _dx * rulerUnitsPerPixel(s)).clamp(s.min, s.max).toDouble();
        // a station within 6 px pulls the value onto it.
        final reach = 6 * rulerUnitsPerPixel(s);
        final round = identical(s, ParamScale.degrees);
        for (final st in widget.stations) {
          final diff = round ? ((v - st) % 360 + 540) % 360 - 180 : v - st;
          if (diff.abs() <= reach) {
            v -= diff;
            break;
          }
        }
        widget.onChanged(v);
      },
      onHorizontalDragEnd: (_) => _startValue = null,
      onHorizontalDragCancel: () => _startValue = null,
      child: SizedBox(
        height: 34,
        child: CustomPaint(
          painter: _RulerPainter(
              value: widget.value, scale: widget.scale, color: color, accent: accent, stations: widget.stations),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  final double value;
  final ParamScale scale;
  final Color color;
  final Color accent;
  final List<double> stations;
  _RulerPainter(
      {required this.value, required this.scale, required this.color, required this.accent, this.stations = const []});

  // the current value in full: 1 shows as 1.000.
  String _fmtLabel(double v) => v.toStringAsFixed(math.max(3, scale.labelDecimals));

  String _fmt(double v, [int? decimals]) {
    final s = v.toStringAsFixed(decimals ?? scale.decimals);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final cx = size.width / 2;
    final base = size.height - 2;
    final upp = rulerUnitsPerPixel(scale);
    final halfUnits = cx * upp;
    // ticks thin out on a long ruler so they never crowd.
    var minor = scale.minorTick, major = scale.majorTick;
    while (minor / upp < 4) {
      minor *= 2;
      major *= 2;
    }
    final tickPaint = Paint()
      ..color = color.withOpacity(0.45)
      ..strokeWidth = 1;
    final majorPaint = Paint()
      ..color = color.withOpacity(0.8)
      ..strokeWidth = 1.2;
    final first = ((value - halfUnits) / minor).floor();
    final last = ((value + halfUnits) / minor).ceil();
    for (var i = first; i <= last; i++) {
      final t = i * minor;
      if (t < scale.min || t > scale.max) continue;
      final x = cx + (t - value) / upp;
      final isMajor = ((t / major) - (t / major).roundToDouble()).abs() < 1e-6;
      canvas.drawLine(Offset(x, base), Offset(x, base - (isMajor ? 10 : 5)), isMajor ? majorPaint : tickPaint);
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(text: _fmt(t), style: TextStyle(fontSize: 8, color: color.withOpacity(0.6))),
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = x - tp.width / 2;
        if (lx >= 0 && lx + tp.width <= size.width) tp.paint(canvas, Offset(lx, base - 20));
      }
    }
    // the snap stations: small marks (round the circle for degrees).
    final stationPaint = Paint()..color = accent.withOpacity(0.7);
    final round = identical(scale, ParamScale.degrees);
    for (final st in stations) {
      for (var k = round ? ((value - halfUnits - st) / 360).floor() : 0;
          k <= (round ? ((value + halfUnits - st) / 360).ceil() : 0);
          k++) {
        final t = st + k * 360;
        final x = cx + (t - value) / upp;
        if (x < 0 || x > size.width) continue;
        canvas.drawPath(
            Path()
              ..moveTo(x - 3, base - 12)
              ..lineTo(x + 3, base - 12)
              ..lineTo(x, base - 7)
              ..close(),
            stationPaint);
      }
    }
    // centre marker + current value
    canvas.drawLine(Offset(cx, base), Offset(cx, 12), Paint()
      ..color = accent
      ..strokeWidth = 2);
    final label = TextPainter(
      text: TextSpan(
          text: '${_fmtLabel(value)}${scale.suffix}',
          style: TextStyle(fontSize: 10, color: accent, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    final lx = math.max(0.0, math.min(size.width - label.width, cx - label.width / 2));
    label.paint(canvas, Offset(lx, 0));
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.value != value ||
      old.color != color ||
      old.accent != accent ||
      old.scale != scale ||
      old.stations.length != stations.length;
}
