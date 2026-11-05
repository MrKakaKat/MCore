import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../common/tool_guide.dart';
import '../player/player_screen.dart';
import '../common/num_field.dart';

/// The transport/action controls that used to live directly under the old
/// scrub-bar widget (timeline_view.dart, since removed as redundant with
/// layers_timeline_view.dart's own zoomed timeline + center-pin scrolling -) -
/// split out into their own widget when the triangle markers underneath that
/// old scrub bar were removed layers_timeline_view.dart's per-layer diamonds
/// made them redundant). This strip now sits directly above the multi-layer
/// timeline panel, functioning as the (a strip with copy/delete functions)
/// asked for. Delete/duplicate later moved OFF this strip entirely, into each
/// layer's own row in layer_panel_view.dart instead - this strip keeps only
/// play/undo/redo/the drawer caret now. (trim) has no button here by design -
/// trimming a layer is a direct drag on its own edge dots in
/// layers_timeline_view.dart, the same way JS's timelinePanel.js has no trim
/// button either (see that file's own doc comment for the full reasoning).
///
/// the keyframe copy/paste/ multiselect buttons that used to live here moved
/// to the TOP of keyframes_editor_view.dart instead - they're keyframe-tab
/// concerns, not something that belongs on the always-visible main strip.
///
/// quick-switch/edge-auto- scroll/center-pin - all 3 toggles that used to sit
/// here, right of the Spacer - moved into TimelineDrawerRow entirely, so this
/// strip is back down to just play/counter/undo/redo/caret.
///
/// UNVERIFIED like the rest of ui/ - needs the Flutter engine, not
/// available in this sandbox.
/// A short note of what an undo / redo did.
void _toast(BuildContext context, AppState app) {
  final text = app.lastUndoMessage;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (text == null || messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      key: const ValueKey('undo-toast'),
      content: Text(text),
      duration: const Duration(milliseconds: 1400),
      behavior: SnackBarBehavior.floating,
    ));
}

/// The bottom tool field's guide.
const bottomGuideSteps = [
  ('play', 'Play / pause the animation.'),
  ('frame', 'The frame the playhead is on - type a number to jump there.'),
  ('player', 'Watch it full screen.'),
  ('undo', 'Undo the last change.'),
  ('redo', 'Redo what was undone.'),
  ('more', 'More timeline options: a field of toggles opens above.'),
];

class TimelineToolbar extends StatelessWidget {
  final AppState app;
  const TimelineToolbar({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        if (!app.guideBottomSeen) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted || app.guideBottomSeen) return;
            showToolGuide(context, bottomGuideSteps, () => app.setAppPreference('guideBottomSeen', true));
          });
        }
        return Row(
          children: [
            IconButton(
              key: guideKey('play'),
              icon: Icon(app.playing ? Icons.pause : Icons.play_arrow),
              // an empty project has nothing to play.
              onPressed: app.canPlay || app.playing ? app.togglePlay : null,
              tooltip: app.canPlay ? null : 'nothing to play yet',
              visualDensity: VisualDensity.compact,
            ),
            // the "70 / 180" here only showed the playhead and the length -
            // both are editable fields now (go to frame / timeline length),
            // replacing the two rows that used to sit at the top of the Layers
            // tab.
            Tooltip(
              key: guideKey('frame'),
              message: 'go to frame',
              // follows the frame live during playback and scrubbing (the
              // rest of the toolbar waits for the frame to rest).
              child: ValueListenableBuilder<int>(
                valueListenable: app.frameNotifier,
                builder: (context, frame, _) => NumField(
                  key: const ValueKey('toolbar-frame'),
                  value: frame.toDouble(),
                  onCommit: (v) => app.setFrame(v.round().clamp(0, app.maxFrame)),
                  width: 44,
                  integer: true,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            // unpinned, the playhead off screen: back to it.
            BackToPlayheadButton(app: app),
            const Spacer(),
            KeyedSubtree(
              key: guideKey('player'),
              child: IconButton(
                key: const ValueKey('open-player'),
                icon: const Icon(Icons.fullscreen),
                tooltip: 'full-screen player',
                onPressed: app.canPlay ? () => PlayerScreen.open(context, app) : null,
                visualDensity: VisualDensity.compact),
            ),
            IconButton(
                key: guideKey('undo'),
                icon: const Icon(Icons.undo),
                tooltip: 'undo',
                onPressed: () => _toast(context, app..performUndo()),
                visualDensity: VisualDensity.compact),
            IconButton(
                key: guideKey('redo'),
                icon: const Icon(Icons.redo),
                tooltip: 'redo',
                onPressed: () => _toast(context, app..performRedo()),
                visualDensity: VisualDensity.compact),
            // (make a caret button that opens a separate field of icons - it
            // sits at the edge, right of undo/redo, and its icon flips to
            // point down when active) - opens/closes TimelineDrawerRow, a
            // secondary row of layer-timeline toggles tucked above this
            // toolbar. A new visual pattern for this codebase (no existing
            // rotate/flip icon precedent anywhere) - AnimatedRotation is the
            // standard Flutter tool for exactly this.
            AnimatedRotation(
              key: guideKey('more'),
              turns: app.timelineDrawerExpanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: IconButton(
                icon: const Icon(Icons.keyboard_arrow_up),
                tooltip: app.timelineDrawerExpanded
                    ? 'hide more timeline options'
                    : 'show more timeline options',
                onPressed: app.toggleTimelineDrawerExpanded,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        );
      },
    );
  }
}


/// Fades in while the (unpinned) playhead is off screen; a tap brings it
/// back into view. Keeps its arrow while fading out.
class BackToPlayheadButton extends StatefulWidget {
  final AppState app;
  const BackToPlayheadButton({super.key, required this.app});

  @override
  State<BackToPlayheadButton> createState() => _BackToPlayheadButtonState();
}

class _BackToPlayheadButtonState extends State<BackToPlayheadButton> {
  int _lastSide = 1;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.app.playheadSide,
      builder: (context, side, _) {
        if (side != 0) _lastSide = side;
        return AnimatedOpacity(
          opacity: side == 0 ? 0 : 1,
          duration: const Duration(milliseconds: 250),
          child: IgnorePointer(
            ignoring: side == 0,
            child: IconButton(
              key: const ValueKey('back-to-playhead'),
              icon: Icon(_lastSide < 0 ? Icons.chevron_left : Icons.chevron_right),
              tooltip: 'back to the playhead',
              onPressed: widget.app.scrollToPlayhead,
              visualDensity: VisualDensity.compact,
            ),
          ),
        );
      },
    );
  }
}
