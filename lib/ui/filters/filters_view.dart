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
  'filter-dither-squeeze': 0,
  'filter-dither-hold': 0,
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
            // an effect layer: over the layers under it, as long as it runs.
            if (layer.adjustment)
              const Hint('An effect layer: its filters act on every layer under it while it runs '
                  '(it is not drawn itself; pick it from the layers list).')
            else if (f.changed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('filters-detach'),
                  icon: const Icon(Icons.layers_outlined, size: 18),
                  label: const Text('Make into its own layer'),
                  onPressed: () => app.detachToEffectLayer(layer.id, 'filters'),
                ),
              ),
            section('Effect matte'),
            DropdownButton<String?>(
              key: const ValueKey('filter-matte-layer'),
              isExpanded: true,
              value: f.matteLayerId != null && app.project.layers.any((l) => l.id == f.matteLayerId) ? f.matteLayerId : null,
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None - everywhere')),
                for (final l in app.project.layers.reversed)
                  if (l.id != layer.id)
                    DropdownMenuItem<String?>(
                        value: l.id, child: Text('${l.name}${l.hidden ? '  (hidden)' : ''}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => edit(() => f.matteLayerId = v),
            ),
            if (f.matteLayerId != null) ...[
              SwitchListTile(
                key: const ValueKey('filter-matte-invert'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Invert'),
                value: f.matteInvert,
                onChanged: (v) => edit(() => f.matteInvert = v),
              ),
              Wrap(spacing: 6, children: [
                FilterChip(
                  key: const ValueKey('filter-matte-filters'),
                  label: const Text('Filters'),
                  selected: f.matteFilters,
                  onSelected: (v) => edit(() => f.matteFilters = v),
                ),
                FilterChip(
                  key: const ValueKey('filter-matte-blur'),
                  label: const Text('Motion blur'),
                  selected: f.matteBlur,
                  onSelected: (v) => edit(() => f.matteBlur = v),
                ),
              ]),
            ],
            const Hint('Another layer\'s brightness says where the effects work: white fully, black not at all '
                '(grey: partly). Any layer can be one - hide it and it still works; a black-and-white filter on it '
                'shapes it further.'),
            section('Edge and dissolve'),
            FilterTrackRow(app: app, layer: layer, track: f.choke, keyName: 'filter-choke', label: 'Simple Choker',
                min: -50, max: 50, suffix: ' px'),
            const Hint('Simple Choker: the layer\'s edge pulled in (or, below 0, spread out) - keyable.'),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              key: const ValueKey('filter-dissolve'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'none', label: Text('Blend')),
                ButtonSegment(value: 'dissolve', label: Text('Dissolve')),
                ButtonSegment(value: 'dancing', label: Text('Dancing')),
              ],
              selected: {f.dissolve},
              onSelectionChanged: (v) => edit(() => f.dissolve = v.first),
            ),
            const Hint('Dissolve: the layer\'s opacity shows as a share of whole pixels, at random, instead of a '
                'see-through blend. Dancing: other pixels every frame.'),
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
            FilterTrackRow(app: app, layer: layer, track: f.negative, keyName: 'filter-negative', label: 'Negative',
                min: 0, max: 100, factor: 100, suffix: '%'),
            section('Blur'),
            FilterTrackRow(app: app, layer: layer, track: f.blur, keyName: 'filter-blur', label: 'Amount',
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
            FilterTrackRow(app: app, layer: layer, track: f.mosaic, keyName: 'filter-mosaic', label: 'Mosaic',
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
                    ..ditherSqueeze = 0
                    ..ditherScanlines = 0),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('filter-dither-retrodither'),
                  icon: const Icon(Icons.blur_on, size: 18),
                  label: const Text('RetroDither'),
                  // its own defaults (canvas-ui's RetroDither): two colours,
                  // 2 px cells (the picture sampled per cell too), its 4x4
                  // table, contrast 0.6, three quarters of the cells.
                  onPressed: () => edit(() => f
                    ..mosaic = Track(2.0, false)
                    ..ditherMode = 'duo'
                    ..ditherLevels = 5
                    ..ditherPattern = _lastOrdered = 'bayer4c'
                    ..ditherDot = 2
                    ..ditherColorize = 0.1
                    ..ditherDark = '#000000'
                    ..ditherLight = '#ffffff'
                    ..ditherOpacity = 0.75
                    ..ditherStipple = true
                    ..ditherSqueeze = 0.4
                    ..ditherSpread = 1
                    ..ditherSoftness = 0
                    ..ditherLightenOnly = false
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

              number('filter-dither-hold', 'Pattern hold', f.ditherHold * 100, 0, 100, (v) => f.ditherHold = v / 100,
                  suffix: '%'),
              const Hint('Pattern hold: the light parts keep the pattern instead of going flat - the top step is '
                  'pressed down (at 100% white lies halfway between the two top levels).'),
              number('filter-dither-squeeze', 'Squeeze toward middle', f.ditherSqueeze * 100, 0, 100,
                  (v) => f.ditherSqueeze = v / 100,
                  suffix: '%'),
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
                  ('bayer4c', 'Grid 4 classic'),
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
            FilterTrackRow(app: app, layer: layer, track: f.vignette, keyName: 'filter-vignette', label: 'Amount',
                min: 0, max: 100, factor: 100, suffix: '%'),
            number('filter-vignette-size', 'Starts at', f.vignetteSize * 100, 0, 100, (v) => f.vignetteSize = v / 100,
                suffix: '%'),
            number('filter-vignette-soft', 'Softness', f.vignetteSoft * 100, 0, 100, (v) => f.vignetteSoft = v / 100,
                suffix: '%'),
            ColorRow(label: 'Colour', hex: f.vignetteColor, onPick: (c) => edit(() => f.vignetteColor = c)),
            section('Fractal warp'),
            FilterTrackRow(app: app, layer: layer, track: f.warp, keyName: 'filter-warp', label: 'Amount',
                min: 0, max: 100, suffix: ' px'),
            number('filter-warp-scale', 'Size', f.warpScale, 4, 400, (v) => f.warpScale = v, suffix: ' px'),
            number('filter-warp-speed', 'Evolution', f.warpSpeed, 0, 5, (v) => f.warpSpeed = v, suffix: '/s', decimals: 2),
            section('Colour'),
            ..._matchRows(context, layer),
            Row(children: [
              const Expanded(child: Text('Colour wheels', style: TextStyle(fontSize: 13))),
              ResetIconButton(onPressed: () => edit(() {
                    f.lift = [0, 0, 0];
                    f.gamma = [0, 0, 0];
                    f.gain = [0, 0, 0];
                  })),
            ]),
            const SizedBox(height: 6),
            _WheelsPanel(app: app, f: f),
            const Hint('Lift: the shadows, gamma: the midtones, gain: the highlights. Tick the ones to change in the '
                'list - the wheel moves them all at once. Drag toward a colour, the line under it for brighter / darker.'),
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
/// Match Color's target picked for the next match (null: what is under
/// the layer) and whether it acts only while that layer runs.
String? _matchTarget;
bool _matchWhileTarget = true;

extension _MatchRows on FiltersView {
  /// Match Color: a list of matches, each onto its own layer (or what is
  /// under it), with its strength (keyable), measured again at a frame (a
  /// key there), acting only while its layer runs if set.
  List<Widget> _matchRows(BuildContext context, Layer layer) {
    final others = [for (final l in app.project.layers) if (l.id != layer.id && !isAudioShape(l.content.shape)) l];
    if (_matchTarget != null && !others.any((l) => l.id == _matchTarget)) _matchTarget = null;
    String nameOf(String? id) => id == null ? 'what is under it' : (findLayer(app.project, id)?.name ?? '(gone)');
    void nothing() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to match there')));
    return [
      Row(children: [
        const Text('Match onto ', style: TextStyle(fontSize: 13)),
        Expanded(
          child: DropdownButton<String?>(
            key: const ValueKey('match-target'),
            isExpanded: true,
            value: _matchTarget,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('What is under it')),
              for (final l in others) DropdownMenuItem<String?>(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) {
              _matchTarget = v;
              app.notifyListeners();
            },
          ),
        ),
      ]),
      if (_matchTarget != null)
        SwitchListTile(
          key: const ValueKey('match-while-target'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Only while that layer is there'),
          subtitle: hint('Where it ends, the match is gone (the colours as they were)'),
          value: _matchWhileTarget,
          onChanged: (v) {
            _matchWhileTarget = v;
            app.notifyListeners();
          },
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: const ValueKey('filter-match-color'),
          onPressed: () async {
            final m = await app.addColorMatch(layer.id, targetId: _matchTarget, whileTarget: _matchWhileTarget);
            if (m == null && context.mounted) nothing();
          },
          icon: const Icon(Icons.auto_fix_high, size: 18),
          label: const Text('Add a match'),
        ),
      ),
      const Hint('Match Color: the layer takes on the colours (average and contrast per channel) of the layer '
          'picked, measured here. Several matches add up, each with its own time on the timeline.'),
      for (var i = 0; i < layer.filters.matches.length; i++)
        () {
          final m = layer.filters.matches[i];
          final bound = layer.effectBinds[m.entryId];
          final frame = layerLocalFrame(layer, app.currentFrame).round();
          final keyed = m.coeffs.keyframes.any((k) => k.frame == frame);
          return Card(
            key: ValueKey('match-${m.id}'),
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 0, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text('Match ${i + 1}: onto ${nameOf(m.targetLayerId)}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(
                    key: ValueKey('match-again-${m.id}'),
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: 'match again here',
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      if (!await app.rematchColor(layer.id, m.id) && context.mounted) nothing();
                    },
                  ),
                  IconButton(
                    key: ValueKey('match-key-${m.id}'),
                    icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
                    tooltip: 'match here as a key (its colours change over time)',
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      if (!await app.rematchColor(layer.id, m.id, key: true) && context.mounted) nothing();
                    },
                  ),
                  IconButton(
                    key: ValueKey('match-delete-${m.id}'),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'remove this match',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => app.removeColorMatch(layer.id, m.id),
                  ),
                ]),
                FilterTrackRow(
                    app: app,
                    layer: layer,
                    track: m.strength,
                    keyName: 'match-strength-${m.id}',
                    label: 'Strength',
                    min: 0,
                    max: 100,
                    factor: 100,
                    suffix: ' %',
                    resetTo: 1),
                if (m.targetLayerId != null)
                  SwitchListTile(
                    key: ValueKey('match-bind-${m.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Only while ${nameOf(m.targetLayerId)} is there'),
                    value: bound == m.targetLayerId,
                    onChanged: (v) => app.bindEffect(layer.id, m.entryId, v ? m.targetLayerId : null),
                  )
                else if (bound != null)
                  Text('Only while ${nameOf(bound)} is there (Timeline tab)', style: const TextStyle(fontSize: 11)),
              ]),
            ),
          );
        }(),
    ];
  }
}

class FilterTrackRow extends StatelessWidget {
  final AppState app;
  final Layer layer;
  final Track track;
  final String keyName;
  final String label;
  final double min, max, factor;
  final String suffix;
  final double resetTo;
  const FilterTrackRow(
      {super.key,
      required this.app,
      required this.layer,
      required this.track,
      required this.keyName,
      required this.label,
      required this.min,
      required this.max,
      this.factor = 1,
      this.suffix = '',
      this.resetTo = 0});

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
          setTrackValueAt(track, frame, resetTo);
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
/// The colour wheels picked for the wheel (several at once).
Set<String> _pickedWheels = {'Gamma'};

/// The colour wheels: one wheel (and brightness line) for every wheel
/// ticked in the list under it - they move together, each by its own
/// span; the list shows each one's colour and value, with its reset.
class _WheelsPanel extends StatelessWidget {
  final AppState app;
  final LayerFilters f;
  const _WheelsPanel({required this.app, required this.f});

  @override
  Widget build(BuildContext context) {
    final wheels = <(String, double, List<double> Function(), void Function(List<double>))>[
      ('Lift', 0.3, () => f.lift, (v) => f.lift = v),
      ('Gamma', 1.0, () => f.gamma, (v) => f.gamma = v),
      ('Gain', 1.0, () => f.gain, (v) => f.gain = v),
    ];
    final picked = [for (final w in wheels) if (_pickedWheels.contains(w.$1)) w];
    // the wheel shows the first ticked one; a move goes to every ticked
    // one by as much (in its own span).
    final lead = picked.isEmpty ? null : picked.first;
    Widget wheel() {
      if (lead == null) {
        return const SizedBox(
            height: 60, child: Center(child: Text('Tick a wheel below', style: TextStyle(color: Colors.grey))));
      }
      return _Wheel(
        app: app,
        label: picked.map((w) => w.$1).join(' + '),
        keyName: 'wheel',
        values: lead.$3(),
        span: lead.$2,
        onSet: (v) {
          final before = rgbToWheel(lead.$3()), after = rgbToWheel(v);
          for (final w in picked) {
            final k = w.$2 / lead.$2;
            final cur = rgbToWheel(w.$3());
            w.$4(wheelToRgb(cur[0] + (after[0] - before[0]) * k, cur[1] + (after[1] - before[1]) * k,
                cur[2] + (after[2] - before[2]) * k));
          }
        },
      );
    }

    Color swatch(List<double> v, double span) => Color.fromARGB(
        255,
        ((0.5 + v[0] / span / 2).clamp(0.0, 1.0) * 255).round(),
        ((0.5 + v[1] / span / 2).clamp(0.0, 1.0) * 255).round(),
        ((0.5 + v[2] / span / 2).clamp(0.0, 1.0) * 255).round());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: wheel()),
      const SizedBox(height: 6),
      for (final w in wheels)
        Row(key: ValueKey('wheel-row-${w.$1.toLowerCase()}'), children: [
          Checkbox(
            key: ValueKey('wheel-pick-${w.$1.toLowerCase()}'),
            visualDensity: VisualDensity.compact,
            value: _pickedWheels.contains(w.$1),
            onChanged: (v) {
              v == true ? _pickedWheels.add(w.$1) : _pickedWheels.remove(w.$1);
              app.notifyListeners();
            },
          ),
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(color: swatch(w.$3(), w.$2), shape: BoxShape.circle, border: Border.all(color: Colors.white24)),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 52, child: Text(w.$1, style: const TextStyle(fontSize: 13))),
          Expanded(
            child: Text(
                () {
                  final c = rgbToWheel(w.$3());
                  return 'colour ${(math.sqrt(c[0] * c[0] + c[1] * c[1]) / w.$2 * 100).round()}%  ·  '
                      'bright ${(c[2] / w.$2 * 100).round()}%';
                }(),
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          ResetIconButton(
              key: ValueKey('wheel-reset-${w.$1.toLowerCase()}'),
              onPressed: () {
                app.pushUndo();
                w.$4([0, 0, 0]);
                app.commitEdit();
              }),
        ]),
    ]);
  }
}

class _Wheel extends StatelessWidget {
  final AppState app;
  final String label;
  final List<double> values;
  final double span;
  final ValueChanged<List<double>> onSet;
  final String? keyName;
  const _Wheel(
      {required this.app, required this.label, required this.values, required this.span, required this.onSet, this.keyName});

  static const double _size = 150;

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
        key: ValueKey(keyName ?? 'wheel-${label.toLowerCase()}'),
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
      const SizedBox(height: 8),
      // the brightness bar: wide and tall enough for a finger; a double
      // tap puts it back to the middle.
      LayoutBuilder(builder: (context, box) {
        final bw = box.maxWidth.isFinite ? box.maxWidth.clamp(_size, 320.0) : 240.0;
        double at(Offset p) => (((p.dx - 13) / (bw - 26)) * 2 - 1).clamp(-1.0, 1.0) * span;
        return eager(Listener(
          key: ValueKey('${keyName ?? 'wheel-${label.toLowerCase()}'}-master'),
          onPointerDown: (e) {
            app.pushUndo();
            setFrom(dot.dx, -dot.dy, at(e.localPosition));
          },
          onPointerMove: (e) => setFrom(dot.dx, -dot.dy, at(e.localPosition)),
          child: GestureDetector(
            onDoubleTap: () {
              app.pushUndo();
              setFrom(dot.dx, -dot.dy, 0);
            },
            child: CustomPaint(size: Size(bw, 36), painter: _MasterPainter((w[2] / span).clamp(-1.0, 1.0))),
          ),
        ));
      }),
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
    const knob = 13.0;
    final rect = Rect.fromLTWH(knob, size.height / 2 - 6, size.width - 2 * knob, 12);
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()..shader = const LinearGradient(colors: [Colors.black, Colors.white]).createShader(rect));
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white24);
    // the middle mark.
    canvas.drawLine(Offset(size.width / 2, rect.top - 3), Offset(size.width / 2, rect.bottom + 3),
        Paint()..color = Colors.white54..strokeWidth = 1.5);
    final x = knob + (v + 1) / 2 * (size.width - 2 * knob);
    final c = Offset(x, size.height / 2);
    canvas.drawCircle(c, math.min(knob, size.height / 2), Paint()..color = Colors.orange);
    canvas.drawCircle(c, math.min(knob, size.height / 2), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black54);
  }

  @override
  bool shouldRepaint(_MasterPainter old) => old.v != v;
}
