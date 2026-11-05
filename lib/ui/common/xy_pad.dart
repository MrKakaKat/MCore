import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A parameter with a point on the plane (two values, x and y), opened in
/// the XY pad: a square where dragging moves the point - the third way to
/// change it, beside the rulers and the number fields.
class XyPadTarget {
  final String label;
  final List<double> start;

  /// The value at the pad's centre (the middle of the stage for a
  /// position).
  final List<double> center;

  /// How much of the value the pad's side spans (1: the whole stage for a
  /// position) - fixed, so the sensitivity only slows the point down.
  final double span;
  final VoidCallback onEditStart;
  final ValueChanged<List<double>> onChanged;
  final ValueChanged<List<double>> onCommit;
  XyPadTarget(
      {required this.label,
      required this.start,
      List<double>? center,
      this.span = 1,
      required this.onEditStart,
      required this.onChanged,
      required this.onCommit})
      : center = center ?? start;
}

/// The parameter open in the pad (null: closed). The params sheet shows the
/// pad in place of the open tab's page (whichever tab is picked) over the
/// whole head, and goes back where it was when the pad closes.
final ValueNotifier<XyPadTarget?> xyPad = ValueNotifier(null);

/// Value units per pad pixel.
final ValueNotifier<double> xyPadSensitivity = ValueNotifier(0.002);

/// The sensitivity's range (value units per pad pixel).
const xyPadMinSensitivity = 0.000001, xyPadMaxSensitivity = 1.0;

/// Whether a sheet shows the pad (else it opens in a dialog).
int xyPadHosts = 0;

/// Opens `target` in the pad.
void openXyPad(BuildContext context, XyPadTarget target) {
  xyPad.value = target;
  if (xyPadHosts > 0) return;
  showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      contentPadding: const EdgeInsets.all(12),
      content: SizedBox(width: 300, child: XyPadPanel(target: target, onClose: () => Navigator.pop(d))),
    ),
  ).then((_) => xyPad.value = null);
}

class XyPadPanel extends StatefulWidget {
  final XyPadTarget target;
  final VoidCallback? onClose;
  const XyPadPanel({super.key, required this.target, this.onClose});

  @override
  State<XyPadPanel> createState() => _XyPadPanelState();
}

class _XyPadPanelState extends State<XyPadPanel> {
  late List<double> _value = [...widget.target.start];

  @override
  void didUpdateWidget(XyPadPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.target, widget.target)) _value = [...widget.target.start];
  }

  void _close() {
    widget.onClose?.call();
    xyPad.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.target;
    return ValueListenableBuilder<double>(
      valueListenable: xyPadSensitivity,
      builder: (context, sens, _) => LayoutBuilder(builder: (context, box) {
        // the pad as big as the page allows, the sensitivity under it
        // across its whole width.
        const header = 36.0, footer = 56.0;
        final side = math.max(80.0,
            math.min(box.maxWidth, box.hasBoundedHeight ? box.maxHeight - header - footer : box.maxWidth));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: header,
              width: side,
              child: Row(children: [
                Expanded(
                  child: Text('${t.label}: ${_value.map((v) => v.toStringAsFixed(3)).join(', ')}',
                      style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  key: const ValueKey('xy-pad-close'),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'close the pad',
                  visualDensity: VisualDensity.compact,
                  onPressed: _close,
                ),
              ]),
            ),
            GestureDetector(
              key: const ValueKey('xy-pad'),
              onPanStart: (_) => t.onEditStart(),
              onPanUpdate: (d) {
                setState(() => _value = [_value[0] + d.delta.dx * sens, _value[1] + d.delta.dy * sens]);
                t.onChanged([..._value]);
              },
              onPanEnd: (_) => t.onCommit([..._value]),
              child: CustomPaint(
                size: Size(side, side),
                painter: _PadPainter([
                  (_value[0] - t.center[0]) / t.span * side,
                  (_value[1] - t.center[1]) / t.span * side,
                ]),
              ),
            ),
            SizedBox(
              width: side,
              height: footer,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Sensitivity ${(sens * 10000).toStringAsPrecision(2)}', style: const TextStyle(fontSize: 11)),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(overlayShape: SliderComponentShape.noOverlay),
                  child: Slider(
                    key: const ValueKey('xy-pad-sensitivity'),
                    value: _log(sens),
                    min: _log(xyPadMinSensitivity),
                    max: _log(xyPadMaxSensitivity),
                    onChanged: (v) => xyPadSensitivity.value = _pow(v),
                  ),
                ),
              ]),
            ),
          ],
        );
      }),
    );
  }
}

double _log(double v) => (v <= 0 ? -4.0 : math.log(v) / math.ln10)
    .clamp(math.log(xyPadMinSensitivity) / math.ln10, math.log(xyPadMaxSensitivity) / math.ln10)
    .toDouble();
double _pow(double e) => math.pow(10, e).toDouble();

/// The pad: a grid, its centre (the parameter's centre value) and
/// the point's offset from there (pad px), held at the edge.
class _PadPainter extends CustomPainter {
  final List<double> offset;
  _PadPainter(this.offset);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = const Color(0xFF16161A));
    final grid = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8, y = size.height * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final c = r.center;
    final axis = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(c.dx, 0), Offset(c.dx, size.height), axis);
    canvas.drawLine(Offset(0, c.dy), Offset(size.width, c.dy), axis);
    final p = Offset((c.dx + offset[0]).clamp(0, size.width), (c.dy + offset[1]).clamp(0, size.height));
    canvas.drawCircle(p, 5, Paint()..color = const Color(0xFF2F7DD1));
    canvas.drawCircle(
        p,
        5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PadPainter old) => old.offset[0] != offset[0] || old.offset[1] != offset[1];
}
