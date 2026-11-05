import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../common/tool_guide.dart';

/// Secondary row of timeline toggles, tucked behind TimelineToolbar's own new
/// caret button (see TimelineToolbar's own doc comment) - "a duplicate of the
/// existing horizontal toolbar row" per kept as its own file/class so more
/// layer-timeline-feature toggles can be appended to this Row later without
/// restructuring TimelineToolbar itself. Same toggle-icon convention as
/// TimelineToolbar's own buttons: Icon(condition ? filled: outlined, color:
/// condition ? primary: null) + an on/off tooltip + onPressed: app.toggleX +
/// compact density.
///
/// quick-switch/edge-auto-scroll/ center-pin - the 3 toggles that used to sit
/// in TimelineToolbar, right of its Spacer - moved here entirely, joining the
/// original snap-layer-edges toggle.
///
/// UNVERIFIED like the rest of ui/ - needs the Flutter engine, not
/// available in this sandbox.
/// The top tool field's guide.
const topGuideSteps = [
  ('lock', 'Lock the timeline: keys, edges and layers can\'t be dragged by accident.'),
  ('snap', 'Snap layer edges to other layers\' edges while dragging.'),
  ('quick', 'Quick switching: tap any layer to focus it at once.'),
  ('autoscroll', 'Dragging near the edge scrolls the timeline.'),
  ('pin', 'Pin the timeline to the playhead: it stays in the middle and the timeline scrolls under it.'),
  ('keep', 'Selecting a key leaves the playhead where it is.'),
  ('multi', 'Select several keys by tapping them.'),
  ('all', 'Turn every option here on (or all off).'),
];

class TimelineDrawerRow extends StatelessWidget {
  final AppState app;
  const TimelineDrawerRow({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        if (!app.guideTopSeen) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted || app.guideTopSeen) return;
            showToolGuide(context, topGuideSteps, () => app.setAppPreference('guideTopSeen', true));
          });
        }
        return Row(
          children: [
            KeyedSubtree(
              key: guideKey('lock'),
              child: IconButton(
              key: const ValueKey('timeline-lock'),
              icon: Icon(app.timelineHandlesLocked ? Icons.lock : Icons.lock_open,
                  color: app.timelineHandlesLocked ? Theme.of(context).colorScheme.primary : null),
              tooltip: app.timelineHandlesLocked
                  ? 'timeline handles off: keys and layers can\'t be dragged (tap to turn them back on)'
                  : 'turn off every timeline handle (keys, edges, moving layers)',
              onPressed: app.toggleTimelineHandlesLocked,
              visualDensity: VisualDensity.compact,
            ),
            ),
            IconButton(
              key: guideKey('snap'),
              icon: Icon(
                app.snapTimelineLayersEnabled ? Icons.push_pin : Icons.push_pin_outlined,
                color: app.snapTimelineLayersEnabled ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip: app.snapTimelineLayersEnabled
                  ? 'snap layer edges: on (dragging a layer snaps its start/end to other layers\' edges)'
                  : 'snap layer edges: off',
              onPressed: app.toggleSnapTimelineLayers,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              key: guideKey('quick'),
              icon: Icon(app.layerQuickSwitchEnabled ? Icons.swap_horiz : Icons.swap_horiz_outlined,
                  color: app.layerQuickSwitchEnabled ? Theme.of(context).colorScheme.primary : null),
              tooltip: app.layerQuickSwitchEnabled
                  ? 'quick layer switching: on (tap any layer to focus it directly)'
                  : 'quick layer switching: off (tap the focused layer again to unfocus first)',
              onPressed: app.toggleLayerQuickSwitch,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              key: guideKey('autoscroll'),
              icon: Icon(app.timelineEdgeAutoScrollEnabled ? Icons.arrow_circle_right : Icons.arrow_circle_right_outlined,
                  color: app.timelineEdgeAutoScrollEnabled ? Theme.of(context).colorScheme.primary : null),
              tooltip: app.timelineEdgeAutoScrollEnabled
                  ? 'drag-to-edge auto-scroll: on (dragging a layer near the timeline\'s edge scrolls it)'
                  : 'drag-to-edge auto-scroll: off',
              onPressed: app.toggleTimelineEdgeAutoScroll,
              visualDensity: VisualDensity.compact,
            ),
            KeyedSubtree(
              key: guideKey('pin'),
              child: IconButton(
              key: const ValueKey('timeline-center-pin'),
              icon: Icon(Icons.vertical_align_center,
                  color: app.timelineCenterPlayheadEnabled ? Theme.of(context).colorScheme.primary : null),
              tooltip: app.timelineCenterPlayheadEnabled
                  ? 'pinned to the playhead: on (the timeline scrolls under it)'
                  : 'pin the timeline to the playhead',
              onPressed: app.toggleTimelineCenterPlayhead,
              visualDensity: VisualDensity.compact,
            ),
            ),
            IconButton(
              key: guideKey('keep'),
              icon: Icon(app.keyframeSelectKeepsPlayhead ? Icons.location_disabled : Icons.location_disabled_outlined,
                  color: app.keyframeSelectKeepsPlayhead ? Theme.of(context).colorScheme.primary : null),
              tooltip: app.keyframeSelectKeepsPlayhead
                  ? 'keep playhead: on (selecting a keyframe does not move the playhead)'
                  : 'keep playhead: off (selecting a keyframe moves the playhead onto it)',
              onPressed: app.toggleKeyframeSelectKeepsPlayhead,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              key: guideKey('multi'),
              icon: Icon(app.kfMultiselectEnabled ? Icons.check_box : Icons.check_box_outline_blank,
                  color: app.kfMultiselectEnabled ? Theme.of(context).colorScheme.primary : null),
              tooltip: app.kfMultiselectEnabled
                  ? 'keyframe multiselect: on (tap adds/removes keys)'
                  : 'keyframe multiselect: off (tap selects one key)',
              onPressed: app.toggleKfMultiselect,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              key: guideKey('all'),
              icon: Icon(Icons.done_all,
                  color: app.allTimelineToggles ? Theme.of(context).colorScheme.primary : null),
              tooltip: app.allTimelineToggles ? 'all timeline options: on (tap turns all off)' : 'turn all timeline options on',
              onPressed: app.toggleAllTimelineToggles,
              visualDensity: VisualDensity.compact,
            ),
            // off the screen's edge.
            const SizedBox(width: 12),
          ],
        );
      },
    );
  }
}
