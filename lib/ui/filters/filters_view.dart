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
import '../../io/freeze_watch.dart';

/// Filters: what they act on (the layer, the whole scene, or what is under
/// the layer as glass), negative, blur, fractal warp, colour wheels with
/// Match Color, light wrap.
/// The ordered pattern picked last (error diffusion tapped off goes back
/// to it).
String _lastOrdered = 'bayer4';

/// What each filter value starts at (as shown: percentages as 0..100).
const _filterDefaults = <String, double>{
  'filter-blur-angle': 0,
  'filter-focus-x': 50,
  'filter-focus-y': 50,
  'filter-focus-angle': 0,
  'filter-focus-size': 12,
  'filter-focus-soft': 20,
  'filter-dither-colorize': 100,
  'filter-dither-levels': 4,
  'filter-dither-opacity': 100,
  'filter-dither-softness': 0,
  'filter-dither-invert': 0,
  'filter-dither-scanlines': 0,
  'filter-dither-spread': 100,
  'filter-dither-angle': 0,
  'filter-dither-bleed': 100,
  'filter-dither-dot': 1,
  'filter-vignette-size': 50,
  'filter-vignette-soft': 50,
  'filter-warp-scale': 60,
  'filter-warp-speed': 0.5,
  'filter-wrap': 0,
  'filter-wrap-width': 12,
};

/// Ready-made palettes for the dither (up to 8 colours).
const _ditherPalettes = <(String, List<String>)>[
  ('1-bit', ['#000000', '#ffffff']),
  ('Handheld', ['#0f380f', '#306230', '#8bac0f', '#9bbc0f']),
  ('CGA', ['#000000', '#55ffff', '#ff55ff', '#ffffff']),
  ('Sepia', ['#2b1d0e', '#6b4a2b', '#b08a5a', '#f1e1c2']),
  ('Neon', ['#0d0221', '#261447', '#ff3864', '#2de2e6', '#f6019d', '#fdfdfd']),
  ('Pastel', ['#2e2e3a', '#f4a6a6', '#f8e1a1', '#a8e6cf', '#a0c4ff', '#fdfdfd']),
];

/// Each glitch tap: other bursts.
int _glitchSeed = 0;

class FiltersView extends StatelessWidget {
  final AppState app;
  const FiltersView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    FreezeWatch.at('building $runtimeType');
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
                {String suffix = '', int decimals = 0, double? reset}) {
          // every value can go back to how it starts.
          final def = reset ?? _filterDefaults[key];
          return ParamEditor(
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
            trailing: [
              if (def != null && (value - def).abs() > 1e-9)
                ResetIconButton(key: ValueKey('$key-reset'), onPressed: () => edit(() => set(def))),
            ],
          );
        }
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
            section('Glitch'),
            Wrap(spacing: 6, runSpacing: 4, children: [
              for (final (k, name, _) in glitchPresets)
                ActionChip(
                  key: ValueKey('glitch-$k'),
                  label: Text(name),
                  onPressed: () => edit(() => applyGlitchPreset(layer, k, seed: ++_glitchSeed)),
                ),
              if (layer.glitch == null)
                ActionChip(
                  key: const ValueKey('glitch-custom'),
                  avatar: const Icon(Icons.tune, size: 16),
                  label: const Text('Own'),
                  onPressed: () => edit(() => applyGlitch(layer, GlitchSettings(seed: ++_glitchSeed))),
                ),
            ]),
            if (layer.glitch == null)
              const Hint('A starting point - then every part of it is yours to set: when the bursts come, how '
                  'strong, colours pulled apart, jolts, time steps, tears, flashes of negative.'),
            if (layer.glitch case final g?) ...() {
              // every change puts the glitch on again with the new settings.
              void put(void Function() change) {
                change();
                applyGlitch(layer, g);
              }

              // (back to the preset's own start: a fresh glitch's value)
              final fresh = GlitchSettings().toJson();
              const shown = {'intensity': 'intensity', 'variance': 'variance', 'flicker-chance': 'flickerChance'};
              const field = {
                'gap-min': 'gapMin', 'gap-max': 'gapMax', 'burst': 'burstMax', 'rgb-calm': 'rgbCalm', //
                'rgb-burst': 'rgbBurst', 'rgb-angle': 'rgbAngle', 'shake-amount': 'shakeAmount',
                'shake-speed': 'shakeSpeed', 'shake-smooth': 'shakeSmooth', 'steps': 'stepFps', 'tear-calm': 'tearCalm',
                'tear-burst': 'tearBurst', 'tear-size': 'tearSize', 'tear-speed': 'tearSpeed',
              };
              Widget gNum(String key, String label, double v, double min, double max, void Function(double) set,
                  {String suffix = '', int decimals = 0}) {
                final name = shown[key] ?? field[key];
                final raw = name == null ? null : (fresh[name] as num).toDouble();
                final def = raw == null ? null : (shown.containsKey(key) ? raw * 100 : raw);
                return number('glitch-$key', label, v, min, max, (x) => put(() => set(x)),
                    suffix: suffix, decimals: decimals, reset: def);
              }
              Widget toggle(String key, String label, bool v, void Function(bool) set) => SwitchListTile(
                    key: ValueKey('glitch-$key'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                    value: v,
                    onChanged: (x) => edit(() => put(() => set(x))),
                  );
              return <Widget>[
                Row(children: [
                  const Text('Acts on'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SegmentedButton<String>(
                      key: const ValueKey('glitch-scope'),
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'self', label: Text('Object')),
                        ButtonSegment(value: 'scene', label: Text('Frame')),
                        ButtonSegment(value: 'glass', label: Text('Under it')),
                      ],
                      selected: {g.scope},
                      onSelectionChanged: (v) => edit(() => put(() => g.scope = v.first)),
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                const Text('Bursts', style: TextStyle(fontWeight: FontWeight.w600)),
                gNum('gap-min', 'Calm at least', g.gapMin.toDouble(), 1, 300, (v) => g.gapMin = v.round(), suffix: ' fr'),
                gNum('gap-max', 'Calm at most', g.gapMax.toDouble(), 1, 600, (v) => g.gapMax = v.round(), suffix: ' fr'),
                gNum('burst', 'Burst up to', g.burstMax.toDouble(), 1, 60, (v) => g.burstMax = v.round(), suffix: ' fr'),
                gNum('intensity', 'Strength', g.intensity * 100, 0, 300, (v) => g.intensity = v / 100, suffix: '%'),
                gNum('variance', 'Bursts differ', g.variance * 100, 0, 100, (v) => g.variance = v / 100, suffix: '%'),
                Row(children: [
                  Text('Pattern ${g.seed}', style: const TextStyle(fontSize: 12)),
                  const Spacer(),
                  TextButton.icon(
                    key: const ValueKey('glitch-reroll'),
                    onPressed: () => edit(() => put(() => g.seed = ++_glitchSeed)),
                    icon: const Icon(Icons.casino_outlined, size: 18),
                    label: const Text('Other bursts'),
                  ),
                ]),
                toggle('rgb', 'Colours pulled apart', g.rgb, (v) => g.rgb = v),
                if (g.rgb) ...[
                  gNum('rgb-calm', 'Between bursts', g.rgbCalm, 0, 60, (v) => g.rgbCalm = v, suffix: ' px'),
                  gNum('rgb-burst', 'In a burst', g.rgbBurst, 0, 200, (v) => g.rgbBurst = v, suffix: ' px'),
                  gNum('rgb-angle', 'Direction', g.rgbAngle, -180, 180, (v) => g.rgbAngle = v, suffix: '°'),
                  toggle('rgb-flip', 'Either way at random', g.rgbFlip, (v) => g.rgbFlip = v),
                ],
                toggle('shake', 'Jolts', g.shake, (v) => g.shake = v),
                if (g.shake) ...[
                  gNum('shake-amount', 'How far', g.shakeAmount, 0, 100, (v) => g.shakeAmount = v, suffix: ' px'),
                  gNum('shake-speed', 'How fast', g.shakeSpeed, 1, 120, (v) => g.shakeSpeed = v),
                  gNum('shake-smooth', 'Smoothness', g.shakeSmooth, 0, 100, (v) => g.shakeSmooth = v, suffix: '%'),
                ],
                gNum('steps', 'Time in steps (0: smooth)', g.stepFps, 0, 30, (v) => g.stepFps = v.roundToDouble(),
                    suffix: ' fps'),
                toggle('tear', 'Tears (noise)', g.tear, (v) => g.tear = v),
                if (g.tear) ...[
                  gNum('tear-calm', 'Between bursts', g.tearCalm, 0, 60, (v) => g.tearCalm = v, suffix: ' px'),
                  gNum('tear-burst', 'In a burst', g.tearBurst, 0, 200, (v) => g.tearBurst = v, suffix: ' px'),
                  gNum('tear-size', 'Grain', g.tearSize, 2, 200, (v) => g.tearSize = v, suffix: ' px'),
                  gNum('tear-speed', 'Changes', g.tearSpeed, 0, 20, (v) => g.tearSpeed = v, suffix: '/s', decimals: 1),
                ],
                toggle('flicker', 'Flashes of negative', g.flicker, (v) => g.flicker = v),
                if (g.flicker)
                  gNum('flicker-chance', 'Bursts that flash', g.flickerChance * 100, 0, 100, (v) => g.flickerChance = v / 100,
                      suffix: '%'),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const ValueKey('glitch-clear'),
                    onPressed: () => edit(() => clearGlitch(layer)),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Take the glitch off'),
                  ),
                ),
                const Hint('It sets the filters below (blur, fractal warp, negative), the wiggle and the time steps - '
                    'changing them by hand there works too, until the glitch is set again here.'),
              ];
            }(),
            section('Negative'),
            _TrackRow(app: app, layer: layer, track: f.negative, keyName: 'filter-negative', label: 'Negative',
                min: 0, max: 100, factor: 100, suffix: '%'),
            section('Blur'),
            _TrackRow(app: app, layer: layer, track: f.blur, keyName: 'filter-blur', label: 'Amount',
                min: 0, max: 100, suffix: ' px'),
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: Wrap(spacing: 6, children: [
              for (final (k, name) in const [
                ('gaussian', 'Gaussian'),
                ('directional', 'Directional'),
                ('zoom', 'Zoom'),
                ('spin', 'Spin'),
                ('chromatic', 'Chromatic'),
              ])
                ChoiceChip(
                  key: ValueKey('filter-blur-$k'),
                  label: Text(name),
                  selected: f.blurKind == k,
                  onSelected: (_) => edit(() => f.blurKind = k),
                ),
            ])),
            if (f.blurKind == 'chromatic')
              SwitchListTile(
                key: const ValueKey('filter-blur-centered'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('From the middle'),
                subtitle: hint(f.blurCentered
                    ? 'The colours split more toward the edges; the middle stays together.'
                    : 'The colours shift apart along the angle, everywhere alike.'),
                value: f.blurCentered,
                onChanged: (v) => edit(() => f.blurCentered = v),
              ),
            if (f.blurKind == 'directional' || (f.blurKind == 'chromatic' && !f.blurCentered))
              number('filter-blur-angle', 'Angle', f.blurAngle, -180, 180, (v) => f.blurAngle = v, suffix: '°'),
            // where it stays sharp: around a point, or along a line.
            const SizedBox(height: 6),
            Row(children: [
              const Text('Focus'),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<String>(
                  key: const ValueKey('filter-blur-focus'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'none', label: Text('None')),
                    ButtonSegment(value: 'point', label: Text('Point')),
                    ButtonSegment(value: 'line', label: Text('Line')),
                  ],
                  selected: {f.blurFocus},
                  onSelectionChanged: (v) => edit(() => f.blurFocus = v.first),
                ),
              ),
            ]),
            if (f.blurFocus != 'none') ...[
              number('filter-focus-x', 'Focus X', f.blurFocusX * 100, 0, 100, (v) => f.blurFocusX = v / 100, suffix: '%'),
              number('filter-focus-y', 'Focus Y', f.blurFocusY * 100, 0, 100, (v) => f.blurFocusY = v / 100, suffix: '%'),
              if (f.blurFocus == 'line')
                number('filter-focus-angle', 'Line angle', f.blurFocusAngle, -180, 180, (v) => f.blurFocusAngle = v,
                    suffix: '°'),
              number('filter-focus-size', f.blurFocus == 'line' ? 'Sharp width' : 'Sharp radius', f.blurFocusSize * 100,
                  0, 100, (v) => f.blurFocusSize = v / 100,
                  suffix: '%'),
              number('filter-focus-soft', 'Fade', f.blurFocusSoft * 100, 0, 100, (v) => f.blurFocusSoft = v / 100,
                  suffix: '%'),
            ],
            section('Pixels'),
            _TrackRow(app: app, layer: layer, track: f.mosaic, keyName: 'filter-mosaic', label: 'Mosaic',
                min: 0, max: 200, suffix: ' px'),
            const Hint('Mosaic: the picture in square cells this wide (0: off) - keyable.'),
            SwitchListTile(
              key: const ValueKey('filter-dither'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Dither', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: hint('Few colours, the steps between them broken up by a pattern - pixel-art style.'),
              value: f.dither,
              onChanged: (v) => edit(() => f.dither = v),
            ),
            if (f.dither) ...[
              SegmentedButton<String>(
                key: const ValueKey('filter-dither-mode'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'levels', label: Text('Levels')),
                  ButtonSegment(value: 'mono', label: Text('Greys')),
                  ButtonSegment(value: 'duo', label: Text('Two')),
                  ButtonSegment(value: 'palette', label: Text('Palette')),
                ],
                selected: {f.ditherMode},
                onSelectionChanged: (v) => edit(() => f.ditherMode = v.first),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('filter-dither-retro'),
                  icon: const Icon(Icons.tv, size: 18),
                  label: const Text('Retro look'),
                  // a starting point: two colours keeping a touch of the
                  // picture's own, 2 px dots, a quarter of the dots left out.
                  onPressed: () => edit(() => f
                    ..ditherMode = 'duo'
                    ..ditherLevels = 5
                    ..ditherPattern = 'bayer4'
                    ..ditherDot = 2
                    ..ditherColorize = 0.1
                    ..ditherDark = '#000000'
                    ..ditherLight = '#ffffff'
                    ..ditherOpacity = 0.75
                    ..ditherStipple = true
                    ..ditherInvert = 0
                    ..ditherScanlines = 0),
                ),
              ),
              if (f.ditherMode == 'duo') ...[
                ColorRow(
                    key: const ValueKey('filter-dither-dark'),
                    label: 'Dark',
                    hex: f.ditherDark,
                    onPick: (c) => edit(() => f.ditherDark = c)),
                ColorRow(
                    key: const ValueKey('filter-dither-light'),
                    label: 'Light',
                    hex: f.ditherLight,
                    onPick: (c) => edit(() => f.ditherLight = c)),
                number('filter-dither-colorize', 'Its own colours ↔ these two', f.ditherColorize * 100, 0, 100,
                    (v) => f.ditherColorize = v / 100,
                    suffix: '%'),
              ],
              if (f.ditherMode != 'palette')
                number('filter-dither-levels', f.ditherMode == 'mono' ? 'Greys' : f.ditherMode == 'duo' ? 'Steps' : 'Steps per colour', f.ditherLevels.toDouble(),
                    2, 32, (v) => f.ditherLevels = v.round()),
              number('filter-dither-opacity', 'Opacity', f.ditherOpacity * 100, 0, 100, (v) => f.ditherOpacity = v / 100,
                  suffix: '%'),
              SwitchListTile(
                key: const ValueKey('filter-dither-stipple'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Opacity as dots'),
                subtitle: hint('Below 100%: a share of the dots left out (by the grid) instead of a blend.'),
                value: f.ditherStipple,
                onChanged: (v) => edit(() => f.ditherStipple = v),
              ),
              number('filter-dither-softness', 'Softness', f.ditherSoftness * 100, 0, 100,
                  (v) => f.ditherSoftness = v / 100,
                  suffix: '%'),
              const Hint('Softness: between two levels a pixel blends them smoothly instead of jumping.'),
              SwitchListTile(
                key: const ValueKey('filter-dither-lighten'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Only lighter dots'),
                subtitle: hint('Where the dither would darken, it lightens by as much instead - dark colours '
                    'get light dots, nothing gets darker.'),
                value: f.ditherLightenOnly,
                onChanged: (v) => edit(() => f.ditherLightenOnly = v),
              ),
              number('filter-dither-invert', 'Invert', f.ditherInvert * 100, 0, 100, (v) => f.ditherInvert = v / 100,
                  suffix: '%'),
              number('filter-dither-scanlines', 'Scanlines', f.ditherScanlines * 100, 0, 100,
                  (v) => f.ditherScanlines = v / 100,
                  suffix: '%'),
              const SizedBox(height: 6),
              const Text('Ordered (a pattern over the picture)', style: TextStyle(fontSize: 12, color: Colors.grey)),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: Wrap(spacing: 6, children: [
                for (final (k, name) in const [
                  ('bayer2', 'Grid 2'),
                  ('bayer4', 'Grid 4'),
                  ('bayer8', 'Grid 8'),
                  ('halftone', 'Halftone'),
                  ('lines', 'Lines'),
                  ('diagonal', 'Hatch'),
                  ('dash', 'Dash'),
                  ('bluenoise', 'Blue noise'),
                  ('noise', 'Noise'),
                  ('none', 'None'),
                ])
                  ChoiceChip(
                    key: ValueKey('filter-dither-$k'),
                    label: Text(name),
                    selected: f.ditherPattern == k,
                    onSelected: (_) => edit(() => f.ditherPattern = _lastOrdered = k),
                  ),
              ])),
              const Text('Error diffusion (retro)', style: TextStyle(fontSize: 12, color: Colors.grey)),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: Wrap(spacing: 6, children: [
                for (final (k, name) in const [
                  ('floyd', 'Floyd-Steinberg'),
                  ('atkinson', 'Atkinson'),
                  ('jarvis', 'Jarvis'),
                  ('stucki', 'Stucki'),
                  ('burkes', 'Burkes'),
                  ('sierra', 'Sierra'),
                  ('sierralite', 'Sierra Lite'),
                ])
                  ChoiceChip(
                    key: ValueKey('filter-dither-$k'),
                    label: Text(name),
                    selected: f.ditherPattern == k,
                    // tapped again: off - back to the ordered pattern before.
                    onSelected: (_) => edit(() => f.ditherPattern = f.ditherPattern == k ? _lastOrdered : k),
                  ),
              ])),
              if (!f.ditherDiffuses) ...[
                number('filter-dither-spread', 'Pattern strength', f.ditherSpread * 100, 0, 200,
                    (v) => f.ditherSpread = v / 100,
                    suffix: '%'),
                number('filter-dither-angle', 'Pattern angle', f.ditherAngle, -90, 90, (v) => f.ditherAngle = v, suffix: '°'),
              ] else ...[
                number('filter-dither-bleed', 'Error passed on', f.ditherBleed * 100, 0, 150, (v) => f.ditherBleed = v / 100,
                    suffix: '%'),
                SwitchListTile(
                  key: const ValueKey('filter-dither-serpentine'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Back and forth'),
                  subtitle: hint('Every other row right to left: no drift to one side.'),
                  value: f.ditherSerpentine,
                  onChanged: (v) => edit(() => f.ditherSerpentine = v),
                ),
                const Hint('Worked out on the side: the stage shows it a moment after a change, and a grid stands in '
                    'while playing. Export waits for it on every frame. Tap it again to go back to a pattern.'),
              ],
              number('filter-dither-dot', 'Pattern dot', f.ditherDot, 1, 64, (v) => f.ditherDot = v.roundToDouble(),
                  suffix: ' px'),
              const Hint('The dot is the mosaic\'s cell when a mosaic is on.'),
              if (f.ditherMode == 'palette') ...[
                const SizedBox(height: 4),
                SingleChildScrollView(scrollDirection: Axis.horizontal, child: Wrap(spacing: 6, children: [
                  for (final (name, colours) in _ditherPalettes)
                    ActionChip(
                      key: ValueKey('filter-dither-pal-$name'),
                      label: Text(name),
                      avatar: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final c in colours.take(4))
                          Container(width: 4, height: 14, color: Color(0xFF000000 | int.parse(c.substring(1), radix: 16))),
                      ]),
                      onPressed: () => edit(() => f.ditherPalette = [...colours]),
                    ),
                ])),
                SwitchListTile(
                  key: const ValueKey('filter-dither-perceptual'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Nearest as the eye sees'),
                  subtitle: hint('Green counts most, blue least - skin and greens land on truer colours.'),
                  value: f.ditherPerceptual,
                  onChanged: (v) => edit(() => f.ditherPerceptual = v),
                ),
                for (var i = 0; i < f.ditherPalette.length; i++)
                  Row(children: [
                    Expanded(
                      child: ColorRow(
                        key: ValueKey('filter-dither-colour-$i'),
                        label: 'Colour ${i + 1}',
                        hex: f.ditherPalette[i],
                        onPick: (c) => edit(() => f.ditherPalette = [...f.ditherPalette]..[i] = c),
                      ),
                    ),
                    IconButton(
                      key: ValueKey('filter-dither-remove-$i'),
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                      tooltip: 'Remove',
                      onPressed: f.ditherPalette.length > 2
                          ? () => edit(() => f.ditherPalette = [...f.ditherPalette]..removeAt(i))
                          : null,
                    ),
                  ]),
                if (f.ditherPalette.length < 8)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('filter-dither-add'),
                      onPressed: () => edit(() => f.ditherPalette = [...f.ditherPalette, '#ffffff']),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add a colour'),
                    ),
                  ),
              ],
            ],
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
    FreezeWatch.at('building $runtimeType');
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
    FreezeWatch.at('building $runtimeType');
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
