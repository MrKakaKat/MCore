import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Transform;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/color_row.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../common/no_layer.dart';

/// Filters: what they act on (the layer, the whole scene, or what is under
/// the layer as glass), negative, blur, fractal warp, colour wheels with
/// Match Color, light wrap.
class FiltersView extends StatelessWidget {
  final AppState app;
  const FiltersView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return NoLayer(app: app, text: 'Select a layer');
        final f = layer.filters;
        void edit(VoidCallback change) {
          app.pushUndo();
          change();
          app.commitEdit();
        }

        Widget section(String title) => Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 2),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            );
        Widget number(String key, String label, double value, double min, double max, ValueChanged<double> set,
                {String suffix = '', int decimals = 0}) =>
            ParamEditor(
              key: ValueKey(key),
              prefKey: key,
              label: label,
              values: [value],
              scale: ParamScale.slider(min, max, decimals: decimals, suffix: suffix),
              onEditStart: app.pushUndo,
              onChanged: (x) {
                set(x.first);
                app.commitEdit();
              },
              onCommit: (x) => edit(() => set(x.first)),
            );
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            const Text('Acts on', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              key: const ValueKey('filter-scope'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'self', label: Text('Object')),
                ButtonSegment(value: 'scene', label: Text('Scene')),
                ButtonSegment(value: 'glass', label: Text('Glass')),
              ],
              selected: {f.scope},
              onSelectionChanged: (v) => edit(() => f.scope = v.first),
            ),
            Hint(switch (f.scope) {
              'scene' => 'The whole frame with every layer goes through the filters.',
              'glass' => 'Everything under this layer\'s shape goes through them - the layer itself is only the '
                  'glass (a negative glass over another one cancels out).',
              _ => 'Only this layer goes through the filters.',
            }),
            section('Negative'),
            _TrackRow(app: app, layer: layer, track: f.negative, keyName: 'filter-negative', label: 'Negative',
                min: 0, max: 100, factor: 100, suffix: '%'),
            section('Blur'),
            _TrackRow(app: app, layer: layer, track: f.blur, keyName: 'filter-blur', label: 'Amount',
                min: 0, max: 100, suffix: ' px'),
            Wrap(spacing: 6, children: [
              for (final (k, name) in const [
                ('gaussian', 'Gaussian'),
                ('directional', 'Directional'),
                ('zoom', 'Zoom'),
                ('spin', 'Spin'),
              ])
                ChoiceChip(
                  key: ValueKey('filter-blur-$k'),
                  label: Text(name),
                  selected: f.blurKind == k,
                  onSelected: (_) => edit(() => f.blurKind = k),
                ),
            ]),
            if (f.blurKind == 'directional')
              number('filter-blur-angle', 'Angle', f.blurAngle, -180, 180, (v) => f.blurAngle = v, suffix: '°'),
            section('Vignette'),
            _TrackRow(app: app, layer: layer, track: f.vignette, keyName: 'filter-vignette', label: 'Amount',
                min: 0, max: 100, factor: 100, suffix: '%'),
            number('filter-vignette-size', 'Starts at', f.vignetteSize * 100, 0, 100, (v) => f.vignetteSize = v / 100,
                suffix: '%'),
            number('filter-vignette-soft', 'Softness', f.vignetteSoft * 100, 0, 100, (v) => f.vignetteSoft = v / 100,
                suffix: '%'),
            ColorRow(label: 'Colour', hex: f.vignetteColor, onPick: (c) => edit(() => f.vignetteColor = c)),
            section('Fractal warp'),
            _TrackRow(app: app, layer: layer, track: f.warp, keyName: 'filter-warp', label: 'Amount',
                min: 0, max: 100, suffix: ' px'),
            number('filter-warp-scale', 'Size', f.warpScale, 4, 400, (v) => f.warpScale = v, suffix: ' px'),
            number('filter-warp-speed', 'Evolution', f.warpSpeed, 0, 5, (v) => f.warpSpeed = v, suffix: '/s', decimals: 2),
            section('Colour'),
            Row(children: [
              FilledButton.tonalIcon(
                key: const ValueKey('filter-match-color'),
                onPressed: () async {
                  final ok = await app.matchColor(layer.id);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Nothing under the layer to match')));
                  }
                },
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: const Text('Match Color'),
              ),
              const Spacer(),
              ResetIconButton(onPressed: () => edit(() {
                    f.lift = [0, 0, 0];
                    f.gamma = [0, 0, 0];
                    f.gain = [0, 0, 0];
                  })),
            ]),
            const Hint('Match Color: the layer takes on the colours of what is under it (its average and '
                'contrast per channel) - set into the wheels below.'),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Wheel(app: app, label: 'Lift', values: f.lift, span: 0.3, onSet: (v) => f.lift = v),
                _Wheel(app: app, label: 'Gamma', values: f.gamma, span: 1, onSet: (v) => f.gamma = v),
                _Wheel(app: app, label: 'Gain', values: f.gain, span: 1, onSet: (v) => f.gain = v),
              ],
            ),
            const Hint('Lift: the shadows, gamma: the midtones, gain: the highlights. Drag a wheel toward a '
                'colour, the line under it for brighter / darker.'),
            section('Light wrap'),
            number('filter-wrap', 'Strength', f.lightWrap * 100, 0, 100, (v) => f.lightWrap = v / 100, suffix: '%'),
            number('filter-wrap-width', 'Width', f.lightWrapWidth, 1, 100, (v) => f.lightWrapWidth = v, suffix: ' px'),
            const Hint('The light of what is under the layer bleeding over its edges (for the Object scope).'),
          ],
        );
      },
    );
  }
}

/// A keyable filter value: slider, reset, key at the playhead.
class _TrackRow extends StatelessWidget {
  final AppState app;
  final Layer layer;
  final Track track;
  final String keyName;
  final String label;
  final double min, max, factor;
  final String suffix;
  const _TrackRow(
      {required this.app,
      required this.layer,
      required this.track,
      required this.keyName,
      required this.label,
      required this.min,
      required this.max,
      this.factor = 1,
      this.suffix = ''});

  @override
  Widget build(BuildContext context) {
    final lf = layerLocalFrame(layer, app.currentFrame);
    final frame = lf.round();
    final v = (evaluateTrack(app.project, track, lf, layer) as num).toDouble();
    final keyed = track.keyframes.any((k) => k.frame == frame);
    double clampV(double x) => (x / factor).clamp(min / factor, max / factor);
    return ParamEditor(
      key: ValueKey(keyName),
      prefKey: 'filters.$keyName',
      label: label,
      values: [v * factor],
      scale: ParamScale.slider(min, max, decimals: 0, suffix: suffix),
      onEditStart: app.pushUndo,
      onChanged: (x) {
        setTrackValueAt(track, frame, clampV(x.first));
        app.commitEdit();
      },
      onCommit: (x) {
        app.pushUndo();
        setTrackValueAt(track, frame, clampV(x.first));
        app.commitEdit();
      },
      trailing: [
        ResetIconButton(onPressed: () {
          app.pushUndo();
          setTrackValueAt(track, frame, 0.0);
          app.commitEdit();
        }),
        IconButton(
          icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
          tooltip: 'toggle keyframe at current frame',
          visualDensity: VisualDensity.compact,
          onPressed: () {
            app.pushUndo();
            if (keyed) {
              track.keyframes.removeWhere((k) => k.frame == frame);
            } else {
              track.keyframes.add(Keyframe(frame: frame, value: v, temporal: newKeyEasing()));
              track.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
            }
            app.commitEdit();
          },
        ),
      ],
    );
  }
}

/// A colour wheel: the dot's direction is the colour pushed in, its
/// distance from the middle how much; the bar under it the master
/// (brighter / darker). `span`: the per-channel offset at the rim.
class _Wheel extends StatelessWidget {
  final AppState app;
  final String label;
  final List<double> values;
  final double span;
  final ValueChanged<List<double>> onSet;
  const _Wheel({required this.app, required this.label, required this.values, required this.span, required this.onSet});

  static const double _size = 78;

  @override
  Widget build(BuildContext context) {
    final w = rgbToWheel(values);
    final dot = Offset(w[0] / span, -w[1] / span);
    void setFrom(double x, double y, double m) {
      onSet(wheelToRgb(x * span, y * span, m));
      app.commitEdit();
    }

    void wheelAt(Offset local) {
      var d = (local - const Offset(_size / 2, _size / 2)) / (_size / 2);
      if (d.distance > 1) d = d / d.distance;
      setFrom(d.dx, -d.dy, w[2]);
    }

    // claims the finger at once: the list behind never scrolls instead.
    Widget eager(Widget child) => RawGestureDetector(
          gestures: {
            EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                () => EagerGestureRecognizer(), (_) {}),
          },
          child: child,
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 4),
      eager(Listener(
        key: ValueKey('wheel-${label.toLowerCase()}'),
        onPointerDown: (e) {
          app.pushUndo();
          wheelAt(e.localPosition);
        },
        onPointerMove: (e) => wheelAt(e.localPosition),
        child: GestureDetector(
          onDoubleTap: () {
            app.pushUndo();
            setFrom(0, 0, w[2]);
          },
          child: CustomPaint(size: const Size(_size, _size), painter: _WheelPainter(dot)),
        ),
      )),
      const SizedBox(height: 6),
      eager(Listener(
        key: ValueKey('wheel-${label.toLowerCase()}-master'),
        onPointerDown: (e) {
          app.pushUndo();
          setFrom(dot.dx, -dot.dy, ((e.localPosition.dx / _size) * 2 - 1).clamp(-1.0, 1.0) * span);
        },
        onPointerMove: (e) =>
            setFrom(dot.dx, -dot.dy, ((e.localPosition.dx / _size) * 2 - 1).clamp(-1.0, 1.0) * span),
        child: CustomPaint(size: const Size(_size, 14), painter: _MasterPainter((w[2] / span).clamp(-1.0, 1.0))),
      )),
    ]);
  }
}

class _WheelPainter extends CustomPainter {
  final Offset dot;
  _WheelPainter(this.dot);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    // red on the right, then (counter-clockwise on screen) green, blue -
    // as wheelToRgb lays them out.
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = SweepGradient(
            colors: [
              for (var i = 0; i <= 12; i++)
                HSVColor.fromAHSV(1, (360 - i * 30) % 360, 0.8, 0.9).toColor(),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r)));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = const RadialGradient(colors: [Color(0xFF808080), Color(0x00808080)])
              .createShader(Rect.fromCircle(center: c, radius: r)));
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white24);
    final p = c + dot * r;
    canvas.drawCircle(p, 5, Paint()..color = Colors.white);
    canvas.drawCircle(p, 5, Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black);
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.dot != dot;
}

class _MasterPainter extends CustomPainter {
  final double v;
  _MasterPainter(this.v);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, size.height / 2 - 3, size.width, 6);
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..shader = const LinearGradient(colors: [Colors.black, Colors.white]).createShader(rect));
    final x = (v + 1) / 2 * size.width;
    canvas.drawCircle(Offset(x, size.height / 2), math.min(6, size.height / 2), Paint()..color = Colors.orange);
  }

  @override
  bool shouldRepaint(_MasterPainter old) => old.v != v;
}
