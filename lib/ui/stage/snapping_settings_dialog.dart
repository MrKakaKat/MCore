import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/reset_button.dart';
import 'grid_settings_dialog.dart' show gridKindChips;

/// movement-mobile-snapping-spec.md's own settings panel: a master
/// toggle + a separate guide-visibility toggle at the top, then one
/// block per category (its own enabled toggle + a sensitivity slider
/// shown only while that category is on) - the exact
/// `stage_settings_dialog.dart` dialog+shared-view split, and the exact
/// `effects_view.dart` "toggle reveals its own controls" pattern, both
/// reused rather than reinvented.
///
/// The master/category-enabled toggles and per-category frame-space
/// radii are plain movement_core globals (drag_ops.dart, pure Dart,
/// reads them directly during a drag) - this view flips them via the
/// same `app.toggleSnapXxx()`/`app.setSnapXxx()` wrapper methods every
/// other toggle in this app uses, and reads the sliders' own screen-px
/// values off AppState (the only place that unit exists - see
/// app_state.dart's own doc comment on `snapSensitivityEdgeToEdgePx`
/// and friends). No `pushUndo()`/`commitEdit()` anywhere here: these
/// are app preferences, not part of the animatable project model, same
/// category as `layerQuickSwitchEnabled`.
///
/// UNVERIFIED like the rest of ui/ for the underlying drag/paint
/// behavior these settings drive - this file's own widget wiring
/// (toggle -> field state) gets real coverage in
/// snapping_settings_view_test.dart.
///
/// the small icon-triggered dialog that used to wrap this view
/// (`showSnappingSettingsDialog`) was removed - it was pure duplication of the
/// Snapping tab/drawer entry (main.dart's own `_ParamsTabs`), which is now the
/// single source of truth for reaching this view on every layout.
class SnappingSettingsView extends StatefulWidget {
  final AppState app;
  const SnappingSettingsView({super.key, required this.app});

  @override
  State<SnappingSettingsView> createState() => _SnappingSettingsViewState();
}

class _SnappingSettingsViewState extends State<SnappingSettingsView> {
  late final TextEditingController _fixedGapController =
      TextEditingController(text: snapFixedGapFrame.round().toString());

  @override
  void dispose() {
    _fixedGapController.dispose();
    super.dispose();
  }

  void _applyFixedGap() {
    final v = double.tryParse(_fixedGapController.text);
    if (v == null || v < 0) return;
    widget.app.setSnapFixedGapFrame(v);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.app,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                      child: Text('Snapping enabled',
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  TextButton(
                    key: const ValueKey('snap-enable-all'),
                    onPressed: widget.app.enableAllSnapping,
                    child: const Text('Enable all'),
                  ),
                  Switch(
                      value: snapEnabled,
                      onChanged: (_) => widget.app.toggleSnapEnabled()),
                ],
              ),
              Row(
                children: [
                  const Expanded(child: Text('Show snap guides')),
                  Switch(
                      value: snapGuidesVisible,
                      onChanged: (_) => widget.app.toggleSnapGuidesVisible()),
                ],
              ),
              const Hint('Guide lines only actually show when this AND the general visual toggle (the stage overlay icon) are both on.'),
              if (snapEnabled) ...[
                const Divider(height: 24),
                _categoryToggle(
                  label: 'Edge to edge',
                  enabled: snapEdgeToEdgeEnabled,
                  onToggle: widget.app.toggleSnapEdgeToEdge,
                  sensitivityPx: widget.app.snapSensitivityEdgeToEdgePx,
                  onSensitivity: widget.app.setSnapSensitivityEdgeToEdgePx,
                ),
                const SizedBox(height: 8),
                _categoryToggle(
                  label: 'Center to center',
                  enabled: snapCenterToCenterEnabled,
                  onToggle: widget.app.toggleSnapCenterToCenter,
                  sensitivityPx: widget.app.snapSensitivityCenterToCenterPx,
                  onSensitivity: widget.app.setSnapSensitivityCenterToCenterPx,
                  extra: !snapCenterToCenterEnabled
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(left: 16, top: 4),
                          child: Wrap(
                            spacing: 4,
                            children: [
                              FilterChip(
                                label: const Text('Horizontal'),
                                selected: snapCenterHorizontalEnabled,
                                onSelected: (_) =>
                                    widget.app.toggleSnapCenterHorizontal(),
                              ),
                              FilterChip(
                                label: const Text('Vertical'),
                                selected: snapCenterVerticalEnabled,
                                onSelected: (_) =>
                                    widget.app.toggleSnapCenterVertical(),
                              ),
                              FilterChip(
                                label: const Text('Diagonal'),
                                selected: snapCenterDiagonalEnabled,
                                onSelected: (_) =>
                                    widget.app.toggleSnapCenterDiagonal(),
                              ),
                              FilterChip(
                                label: const Text('Any-angle line'),
                                selected: snapCenterLineEnabled,
                                onSelected: (_) =>
                                    widget.app.toggleSnapCenterLine(),
                              ),
                            ],
                          ),
                        ),
                ),
                if (snapCenterToCenterEnabled) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Equal spacing',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        Switch(
                          value: snapEqualSpacingEnabled,
                          onChanged: (_) => widget.app.toggleSnapEqualSpacing(),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                _categoryToggle(
                  label: 'Corner to corner',
                  enabled: snapCornerToCornerEnabled,
                  onToggle: widget.app.toggleSnapCornerToCorner,
                  sensitivityPx: widget.app.snapSensitivityCornerToCornerPx,
                  onSensitivity: widget.app.setSnapSensitivityCornerToCornerPx,
                ),
                const SizedBox(height: 8),
                _categoryToggle(
                  label: 'Equal size',
                  enabled: snapEqualSizeEnabled,
                  onToggle: widget.app.toggleSnapEqualSize,
                  sensitivityPx: widget.app.snapSensitivityEqualSizePx,
                  onSensitivity: widget.app.setSnapSensitivityEqualSizePx,
                  extra: !snapEqualSizeEnabled
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(left: 16, top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 6,
                                children: [
                                  ChoiceChip(
                                    label: const Text('Edge gap'),
                                    selected: snapSizeMeasurement ==
                                        SnapSizeMeasurement.edgeGap,
                                    onSelected: (_) => widget.app
                                        .setSnapSizeMeasurement(
                                            SnapSizeMeasurement.edgeGap),
                                  ),
                                  ChoiceChip(
                                    label: const Text('Center distance'),
                                    selected: snapSizeMeasurement ==
                                        SnapSizeMeasurement.centerDistance,
                                    onSelected: (_) => widget.app
                                        .setSnapSizeMeasurement(
                                            SnapSizeMeasurement.centerDistance),
                                  ),
                                ],
                              ),
                              Row(
                                children: [
                                  const Text('Fixed gap (px):',
                                      style: TextStyle(fontSize: 12)),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 60,
                                    child: TextField(
                                        controller: _fixedGapController,
                                        keyboardType: TextInputType.number),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton(
                                      onPressed: _applyFixedGap,
                                      child: const Text('Apply')),
                                  ResetIconButton(onPressed: () {
                                    widget.app.setSnapFixedGapFrame(40);
                                    _fixedGapController.text = '40';
                                  }),
                                ],
                              ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 8),
                // Grid's cols/rows + overlay visibility moved to the
                // dedicated grid_settings_dialog.dart - this toggle keeps
                // only its own meaning: "can a drag snap to the grid's
                // line positions," independent of whether the grid is
                // even visually drawn (gridOverlayEnabled, elsewhere).
                _categoryToggle(
                  label: 'Snap to grid lines',
                  enabled: snapGridEnabled,
                  onToggle: widget.app.toggleSnapGrid,
                  sensitivityPx: widget.app.snapSensitivityGridPx,
                  onSensitivity: widget.app.setSnapSensitivityGridPx,
                ),
                // which of the grid's lines there are (and snap): the same
                // field as in the Grid window.
                if (snapGridEnabled)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: gridKindChips('snap-grid-kind', gridLineKinds,
                        (v) => setState(() => widget.app.setAppPreference('gridKinds', v))),
                  ),
                const SizedBox(height: 8),
                _categoryToggle(
                  label: 'Frame boundaries', // also while resizing
                  enabled: snapFrameBoundaryEnabled,
                  onToggle: widget.app.toggleSnapFrameBoundary,
                  sensitivityPx: widget.app.snapSensitivityFrameBoundaryPx,
                  onSensitivity: widget.app.setSnapSensitivityFrameBoundaryPx,
                  sensitivityDefault: 10,
                ),
                const SizedBox(height: 8),
                // + - RotateDragOp only, no effect on position/size drags.
                _categoryToggle(
                  label: 'Rotation',
                  enabled: snapRotationEnabled,
                  onToggle: widget.app.toggleSnapRotation,
                  sensitivityPx:
                      snapRotationToleranceDeg, // core global directly - no AppState px-mirror, see its own doc comment
                  onSensitivity: widget.app.setSnapRotationToleranceDeg,
                  sensitivityLabel: 'tolerance (°)',
                  sensitivityMin: 1,
                  sensitivityMax: 15,
                  sensitivityDefault: 5,
                  extra: !snapRotationEnabled
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(left: 16, top: 4),
                          child: Wrap(
                            spacing: 4,
                            children: [
                              FilterChip(
                                label: const Text('Horizontal'),
                                selected: snapRotationHorizontalEnabled,
                                onSelected: (_) =>
                                    widget.app.toggleSnapRotationHorizontal(),
                              ),
                              FilterChip(
                                label: const Text('Vertical'),
                                selected: snapRotationVerticalEnabled,
                                onSelected: (_) =>
                                    widget.app.toggleSnapRotationVertical(),
                              ),
                              FilterChip(
                                label: const Text('Diagonal'),
                                selected: snapRotationDiagonalEnabled,
                                onSelected: (_) =>
                                    widget.app.toggleSnapRotationDiagonal(),
                              ),
                            ],
                          ),
                        ),
                ),
                if (snapRotationEnabled) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        const Expanded(
                            child: Text('Match nearby rotation',
                                style: TextStyle(fontSize: 12))),
                        Switch(
                            value: snapRotationMatchNearbyEnabled,
                            onChanged: (_) =>
                                widget.app.toggleSnapRotationMatchNearby()),
                      ],
                    ),
                  ),
                  // the mirror of a nearby shape's angle too.
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        const Expanded(child: Text('Also its mirror angle', style: TextStyle(fontSize: 12))),
                        Switch(
                            key: const ValueKey('snap-rotation-mirror'),
                            value: snapRotationMirrorEnabled,
                            onChanged: (v) => widget.app.setAppPreference('snapRotationMirror', v)),
                      ],
                    ),
                  ),
                ],
              ],
              const Divider(),
              const Text('Reach and more', style: TextStyle(fontWeight: FontWeight.w600)),
              // how far snapping reaches: by the dragged object's size.
              Row(children: [
                const SizedBox(width: 120, child: Text('Reach (its sizes, 0 = everywhere)', style: TextStyle(fontSize: 12))),
                Expanded(
                  child: Slider(
                    key: const ValueKey('snap-reach'),
                    value: snapReachBySize.clamp(0.0, 5.0),
                    min: 0,
                    max: 5,
                    divisions: 20,
                    onChanged: (v) => widget.app.setAppPreference('snapReach', v),
                  ),
                ),
                SizedBox(width: 32, child: Text(snapReachBySize == 0 ? 'all' : snapReachBySize.toStringAsFixed(2))),
              ]),
              Row(children: [
                const Expanded(child: Text('Edge to edge: also edges\' middles', style: TextStyle(fontSize: 12))),
                Switch(
                    key: const ValueKey('snap-edge-mid'),
                    value: snapEdgeMidpointsEnabled,
                    onChanged: (v) => widget.app.setAppPreference('snapEdgeMid', v)),
              ]),
              // texts: letter onto letter, by their real outlines.
              Row(children: [
                const Expanded(
                    child: Text('Text: a letter\'s middle onto another text\'s letter', style: TextStyle(fontSize: 12))),
                Switch(
                    key: const ValueKey('snap-text-centers'),
                    value: snapTextCentersEnabled,
                    onChanged: (v) => widget.app.setAppPreference('snapTextCenters', v)),
              ]),
              Row(children: [
                const Expanded(
                    child: Text('Text: a letter\'s edge touching another text\'s letter (top, bottom, sides)',
                        style: TextStyle(fontSize: 12))),
                Switch(
                    key: const ValueKey('snap-text-edges'),
                    value: snapTextEdgesEnabled,
                    onChanged: (v) => widget.app.setAppPreference('snapTextEdges', v)),
              ]),
              Row(children: [
                const Expanded(child: Text('Roundings take each other\'s size', style: TextStyle(fontSize: 12))),
                Switch(
                    key: const ValueKey('snap-equal-rounding'),
                    value: snapEqualRoundingEnabled,
                    onChanged: (v) => widget.app.setAppPreference('snapEqualRounding', v)),
              ]),
              Row(children: [
                const Expanded(child: Text('Centres onto the crossings of a rect\'s own grid', style: TextStyle(fontSize: 12))),
                Switch(
                    key: const ValueKey('snap-rect-grid'),
                    value: snapRectGridEnabled,
                    onChanged: (v) => widget.app.setAppPreference('snapRectGrid', v)),
              ]),
              const Divider(),
              // a line's points while they are dragged.
              const Text('Line points', style: TextStyle(fontWeight: FontWeight.w600)),
              for (final (key, pref, label, on) in [
                ('snap-line-angle', 'snapLineAngle', 'Along horizontals, verticals, diagonals from the next point', snapLineAngleEnabled),
                ('snap-line-length', 'snapLineLength', 'The length of another stretch', snapLineLengthEnabled),
                ('snap-line-points', 'snapLinePoints', 'Onto points: other lines, shapes\' corners and middles, the frame', snapLinePointsEnabled),
              ])
                Row(children: [
                  Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
                  Switch(key: ValueKey(key), value: on, onChanged: (v) => widget.app.setAppPreference(pref, v)),
                ]),
            ],
          ),
        );
      },
    );
  }

  Widget _categoryToggle({
    required String label,
    required bool enabled,
    required VoidCallback onToggle,
    required double sensitivityPx,
    required ValueChanged<double> onSensitivity,
    String sensitivityLabel = 'sensitivity (px)',
    double sensitivityMin = 1,
    double sensitivityMax = 40,
    double sensitivityDefault = 8,
    Widget? extra,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Switch(value: enabled, onChanged: (_) => onToggle()),
          ],
        ),
        if (enabled)
          _sensitivityRow(sensitivityPx, onSensitivity,
              label: sensitivityLabel,
              min: sensitivityMin,
              max: sensitivityMax,
              defaultValue: sensitivityDefault),
        if (extra != null) extra,
      ],
    );
  }

  Widget _sensitivityRow(double value, ValueChanged<double> onChanged,
      {String label = 'sensitivity (px)',
      double min = 1,
      double max = 40,
      double defaultValue = 8}) {
    return Row(
      children: [
        const SizedBox(width: 16),
        SizedBox(
            width: 74,
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey))),
        Expanded(
            child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged)),
        SizedBox(width: 28, child: Text(value.toStringAsFixed(0))),
        ResetIconButton(onPressed: () => onChanged(defaultValue)),
      ],
    );
  }
}
