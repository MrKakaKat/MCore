import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'i18n.dart';
import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'io/project_store.dart';
import 'ui/reverse/reverse_view.dart';
import 'ui/home/home_screen.dart';
import 'ui/timeline/timeline_rows_view.dart';
import 'ui/audio/audio_view.dart';
import 'io/app_settings.dart';
import 'perf/perf_monitor.dart';
import 'ui/crop/crop_view.dart';
import 'ui/perf/perf_hud.dart';
import 'ui/fill/fill_view.dart';
import 'ui/ai/ai_dialogs.dart';
import 'ui/filters/filters_view.dart';
import 'ui/graph_editor/graph_editor_view.dart';
import 'ui/objects/objects_view.dart';
import 'ui/drawing/drawing_view.dart';
import 'ui/links/links_view.dart';
import 'ui/palettes/palettes_view.dart';
import 'ui/effects/effects_view.dart';
import 'ui/export/export_dialog.dart';
import 'ui/layer_panel/layer_panel_view.dart';
import 'ui/layer_panel/project_ref_ui.dart';
import 'ui/masks/masks_view.dart';
import 'ui/params_panel/params_panel_view.dart';
import 'io/font_store.dart';
import 'ui/chroma/chroma_view.dart';
import 'ui/presets/presets_view.dart';
import 'ui/settings/settings_view.dart';
import 'ui/text/text_view.dart';
import 'ui/line/line_view.dart';
import 'ui/common/xy_pad.dart';
import 'ui/common/color_row.dart' show startColorEyedropper, cancelColorEyedropper;
import 'ui/stage/grid_settings_dialog.dart';
import 'ui/stage/snapping_settings_dialog.dart';
import 'ui/stage/stage_settings_dialog.dart';
import 'ui/stage/stage_view.dart';
import 'ui/timeline/keyframes_editor_view.dart';
import 'ui/timeline/layers_timeline_view.dart';
import 'ui/timeline/timeline_drawer_row.dart';
import 'ui/timeline/timeline_toolbar.dart';

/// Mirrors movement-core/src/main.js's role: register built-in effects
/// (done inside AppState's constructor, since that's where the rest of
/// the project state lives) and wire up the app shell.
///
/// Opens on the home screen (project list + "New project"); each opened
/// project gets its own AppState/EditorScreen, autosaved to its own file.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadDefaultFont();
  final dir = await getApplicationDocumentsDirectory();
  await FontStore(dir).registerAll();
  Directory? cache;
  try {
    cache = await getApplicationCacheDirectory();
  } catch (_) {}
  final settings = AppSettings(File('${dir.path}/app_settings.json'));
  await settings.load();
  AppSettings.instance = settings;
  appLanguage = settings.language;
  if (settings.perfHud) PerfMonitor.instance.setVisible(true);
  runApp(MovementMobileApp(store: ProjectStore(dir, cacheRoot: cache)));
}

/// The bundled default text font (Roboto, SIL Open Font License - see
/// assets/fonts/Roboto-OFL.txt).
Future<void> loadDefaultFont() async {
  try {
    final data = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
    registerFont(defaultFontId, data.buffer.asUint8List(), name: 'Roboto');
  } catch (_) {
    // no font: text layers draw nothing rather than crash.
  }
}

class MovementMobileApp extends StatelessWidget {
  /// With a `store`, the app opens on the home screen. Without one (every
  /// existing test construction), it opens straight into an editor on
  /// `appState` (or a fresh default AppState), exactly as before.
  MovementMobileApp({super.key, AppState? appState, this.store})
      : appState = appState ?? AppState();

  final AppState appState;
  final ProjectStore? store;

  @override
  Widget build(BuildContext context) {
    final store = this.store;
    return MaterialApp(
      title: 'MCore',
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: store != null
          ? HomeScreen(store: store)
          : EditorScreen(appState: appState),
    );
  }
}

/// The editor for one open project. Owns (and disposes) its AppState.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with WidgetsBindingObserver {
  /// The narrow layout's tab sheet: the height it takes under the timeline
  /// (closed or half open; full open lays over the head instead).
  final ValueNotifier<double> _sheetDock = ValueNotifier(_MobileParamsSheetState.collapsedPx);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // colour fields pick off this editor's stage.
    startColorEyedropper = widget.appState.startStageColorPick;
    cancelColorEyedropper = () => widget.appState.finishStageColorPick(null);
  }

  // autosave should also fire immediately (app backgrounding/closing), not
  // just the debounced after-every-change path - `paused`/`detached` cover
  // both.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      widget.appState.saveNow();
    }
    // the system may have emptied the cache while the app was away.
    if (state == AppLifecycleState.resumed) {
      widget.appState.restoreVideoFrames();
      widget.appState.restoreAudio();
      // a referenced project may have been edited meanwhile.
      widget.appState.loadReferences();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    startColorEyedropper = null;
    cancelColorEyedropper = null;
    widget.appState.saveNow();
    widget.appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        // (move the stage screen to the very top so the tabs have enough room)
        // - no AppBar at all any more; its own two toggle icons (plus a new
        // settings icon, see stage_settings_dialog.dart) now overlay directly
        // on the stage itself instead, via _stageWithOverlayIcons below.
        //
        // (in wide mode, make the tabs reachable via a simple slide from the
        // right, and remove the redundant icons) - the Stage/Snapping settings
        // icons that used to overlay the stage in BOTH layouts were pure
        // duplication of their own tabs; this endDrawer is their new
        // wide-layout home (Keyframes/Masks/ Effects had no wide-layout home
        // at all before this either - fixed incidentally by reusing the same
        // _ParamsTabs widget the narrow layout's own bottom sheet uses).
        // Scaffold's own edge- swipe-from-the-right gesture opens it for free;
        // the new Icons.tune button below is for discoverability. Layers/
        // Movement are deliberately excluded here - those already have
        // dedicated fixed side columns in the wide Row below.
        endDrawer: Drawer(
          // 420, not the Material default 304 or something narrower -
          // several tab bodies (KeyframesEditorView's own per-track row
          // of label + hide/loop checkboxes, in particular) already
          // assume roughly a real phone's own portrait width (the
          // narrow layout's bottom sheet gets the FULL screen width,
          // comfortably more than this) and overflow below that.
          width: 420,
          child: SafeArea(
            child: _ParamsTabs(tabs: _wideDrawerTabs, app: widget.appState),
          ),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            // on a portrait phone, the old fixed 3-column Row below (220px
            // layer panel + 260px params panel, both non-flexible) already
            // adds up to 480px before StageView's own Expanded gets anything -
            // on a narrow phone that's more than the whole screen width, so
            // Expanded(child: StageView) was left with ~0px and never painted
            // anything visible. 700 is a plain phone-vs-tablet/ landscape
            // width heuristic, not tied to any specific device; the 3-column
            // layout below is kept as-is above it since it already works
            // there.
            final narrow = constraints.maxWidth < 700;
            final body = narrow
                ? Stack(
                    children: [
                      Positioned.fill(child: StageView(app: widget.appState)),
                      _stageOverlayIcons(widget.appState, narrow: true),
                      _contextNote(widget.appState),
                      _perfHud(widget.appState),
                    ],
                  )
                : Row(
                    children: [
                      SizedBox(
                          width: 220,
                          child: LayerPanelView(app: widget.appState)),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: Stack(
                          children: [
                            Positioned.fill(
                                child: StageView(app: widget.appState)),
                            _stageOverlayIcons(widget.appState, narrow: false),
                            _contextNote(widget.appState),
                            _perfHud(widget.appState),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      SizedBox(
                          width: 260,
                          child: ParamsPanelView(app: widget.appState)),
                    ],
                  );
            // the new multi-layer timeline (layers_timeline_view.dart - one
            // row per layer, drag to move/trim, its own zoom/playhead) needs
            // real vertical room of its own - (move the stage screen up). A
            // FIXED height budget for it (tried first) turned out unsafe:
            // combined with a real keyboard's viewInsets shrinking the whole
            // Scaffold body (resizeToAvoidBottomInset, the same mechanism
            // params_ panel_focus_test.dart covers), a fixed-size sibling
            // never yields, so the stage's own Expanded could be squeezed to
            // literally zero height, taking the params fields with it. Both
            // areas are `Expanded` with a flex ratio instead, so a shrinking
            // Scaffold body shrinks BOTH proportionally rather than one
            // hoarding fixed space while the other collapses - each side
            // already tolerates being squeezed gracefully (ParamsPanelView's
            // own ListView, and LayersTimelineView's new vertical
            // SingleChildScrollView) rather than erroring.
            //
            // - TimelineToolbar (the "start"/play, quick-switch, undo/ redo
            //   row) moves back ABOVE LayersTimelineView (undoing a previous
            //   round's opposite swap), which stays last. (The old scrub-bar
            //   TimelineView that used to sit above TimelineToolbar was later
            //   removed outright - as redundant with LayersTimelineView's own
            //   zoomed timeline + center-pin scrolling; TimelineToolbar is now
            //   this section's first child.)
            //
            // (a big empty area appeared at the bottom) - LayersTimelineView's
            // own content got 3x shorter (rowHeight shrunk from 36 to 12), so
            // the fixed 3:2 flex split below was reserving far more height
            // than that shorter content actually needs, showing as dead space
            // under it. The bottom section's own share shrinks to 1 (from 2) -
            // still flex-based, so keyboard-safety above still holds - freeing
            // the difference back to `body` (flex 3, unchanged), which is also
            // (proportionally enlarge) the stage/tabs area this same report
            // asked for. the drawer used to be inserted as a plain conditional
            // child ABOVE TimelineToolbar, inside this same fixed-height
            // flex:1 section - that visibly pushed the toolbar/timeline down
            // WITHIN their own fixed section every time the drawer opened. Now
            // the toolbar+ timeline Column below is completely untouched by
            // the drawer's state - its own outer flex:3/flex:1 split can never
            // move - and the drawer is a separate Positioned overlay, anchored
            // to the exact pixel height of the flex:1 section (so its BOTTOM
            // edge never moves) and grown upward via AnimatedSize into the
            // flex:3 (stage/tabs) area above when expanded.
            // TimelineToolbar/LayersTimelineView each already wrap themselves
            // in their own AnimatedBuilder for their own content, so the
            // toolbar+timeline Column itself no longer needs one at this level
            // either. narrow: stage, then the timeline (the head), then the
            // tab sheet docked under it - closed (just the tab chips), half
            // open, or full (over the head and most of the stage).
            final timelineHeight = (constraints.maxHeight - 1) / 4;
            return ValueListenableBuilder<double>(
              valueListenable: _sheetDock,
              builder: (context, dock, _) {
              // narrow: the head starts at the screen's middle and never
              // moves; the sheet lies over it (half / full), only its
              // closed strip has its own place.
              final reserved = narrow ? _MobileParamsSheetState.collapsedPx : 0.0;
              final sectionHeight =
                  narrow ? constraints.maxHeight / 2 - reserved : timelineHeight;
              final flexOneSectionHeight = sectionHeight + reserved;
              return Stack(
              children: [
                Column(
                  children: [
                    Expanded(child: body),
                    const Divider(height: 1),
                    SizedBox(
                      height: sectionHeight,
                      // opaque: nothing behind the timeline shows through.
                      child: ColoredBox(
                       key: const ValueKey('timeline-section'),
                       color: Theme.of(context).scaffoldBackgroundColor,
                       child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: TimelineToolbar(app: widget.appState),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              child: LayersTimelineView(app: widget.appState),
                            ),
                          ),
                        ],
                       ),
                      ),
                    ),
                    // the docked sheet's place.
                    SizedBox(height: reserved),
                  ],
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: flexOneSectionHeight,
                  child: AnimatedBuilder(
                    animation: widget.appState,
                    builder: (context, _) => AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      alignment: Alignment.bottomCenter,
                      child: widget.appState.timelineDrawerExpanded
                          ? Material(
                              elevation: 8,
                              color: Theme.of(context).scaffoldBackgroundColor,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                child:
                                    TimelineDrawerRow(app: widget.appState),
                              ),
                            )
                          : const SizedBox(width: double.infinity, height: 0),
                    ),
                  ),
                ),
                if (narrow)
                  _MobileParamsSheet(app: widget.appState, dock: _sheetDock, fullHeight: constraints.maxHeight),
              ],
            );
              },
            );
          },
        ),
      );
  }
}

/// the icons that used to live in the removed AppBar (hideHandles,
/// hideVisualLayer) - now a small overlay row directly on the stage itself,
/// top-right, since there's no AppBar left to host them. AnimatedBuilder so
/// the two toggle icons actually reflect hideHandles/hideVisualLayer's current
/// state - both are plain movement_core globals, not part of AppState's own
/// fields, but toggleHideHandles/toggleHideVisualLayer call notifyListeners on
/// appState after flipping them, same as every other mutation in this app. A
/// semi-transparent circular background per icon keeps them legible against
/// arbitrary stage content/colors.
///
/// without an AppBar, the Scaffold body paints all the way to the true top of
/// the screen (an AppBar used to reserve that space implicitly) - this row's
/// own small top offset wasn't enough on a device with a status bar/notch, so
/// it visibly ran off/ under the edge. Wrapped in its own SafeArea (top only -
/// this is a top-right corner overlay, not a full-width bar) so it respects
/// whatever inset the actual device has, same as MediaQuery.padding.
///
/// (same goes for Stage settings - remove from the top icons, it's pure
/// duplication of the existing tab) - the Snapping and Stage-settings icons
/// that used to live here are GONE; their tabs (in _MobileParamsSheet for
/// narrow, the new endDrawer for wide - see MovementMobileApp's own doc
/// comment) are now the single source of truth. Grid and Export keep their
/// icons here - neither has a tab home. `narrow` adds one extra icon
/// (Icons.tune, opening the new endDrawer) ONLY for the wide layout, which has
/// no tab rail of its own and would otherwise have no discoverable way to
/// reach it (beyond the Scaffold's own edge-swipe gesture, which still works
/// either way).
Widget _stageOverlayIcons(AppState app, {required bool narrow}) {
  return Positioned(
    top: 0,
    left: 0,
    right: 0,
    child: SafeArea(
      bottom: false,
      left: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // back to the home screen (project list) - only when this editor
          // was opened from it.
          // the back arrow, then (down the side) the move axis lock and
          // undo / redo.
          Padding(
            padding: const EdgeInsets.all(4),
            child: AnimatedBuilder(
              animation: app,
              builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
                if (Navigator.of(context).canPop())
                  _stageOverlayIconButton(
                    icon: Icons.arrow_back,
                    tooltip: 'projects',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                // the move axis lock: only while something is selected.
                if (!app.hideStageIcons && findLayer(app.project, app.selection.selectedLayer) != null) ...[
                  const SizedBox(height: 4),
                  KeyedSubtree(
                    key: const ValueKey('stage-axis-lock'),
                    child: _stageOverlayIconButton(
                      icon: switch (dragAxisLock) {
                        'x' => Icons.swap_horiz,
                        'y' => Icons.swap_vert,
                        _ => Icons.open_with,
                      },
                      tooltip: switch (dragAxisLock) {
                        'x' => 'moving along x only (tap: y only)',
                        'y' => 'moving along y only (tap: free)',
                        _ => 'moving freely (tap: x only)',
                      },
                      onPressed: () {
                        dragAxisLock = switch (dragAxisLock) { null => 'x', 'x' => 'y', _ => null };
                        app.notifyListeners();
                      },
                    ),
                  ),
                ],
              ]),
            ),
          ),
          // the right side takes all the room left and shrinks only when
          // it really doesn't fit (a narrow phone).
          Expanded(child: Align(alignment: Alignment.topRight, child: Padding(
          padding: const EdgeInsets.all(4),
          child: AnimatedBuilder(
            animation: app,
            // Settings tab: "Hide top icons" (the back arrow stays).
            builder: (context, _) => app.hideStageIcons ? const SizedBox.shrink() : FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.topRight, child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _stageOverlayIconButton(
                  icon: hideHandles ? Icons.touch_app_outlined : Icons.touch_app,
                  tooltip: hideHandles ? 'show handles' : 'hide handles',
                  onPressed: app.toggleHideHandles,
                ),
                _stageOverlayIconButton(
                  icon: hideVisualLayer ? Icons.visibility_off_outlined : Icons.visibility,
                  tooltip: hideVisualLayer ? 'show visual aids' : 'hide visual aids',
                  onPressed: app.toggleHideVisualLayer,
                ),
                // grid overlay - no tab-rail home (unlike Stage/Snapping,
                // now removed from here), shown in both layouts.
                Builder(
                  builder: (context) => _stageOverlayIconButton(
                    icon: gridOverlayEnabled ? Icons.window : Icons.window_outlined,
                    tooltip: 'grid',
                    onPressed: () => showGridSettingsDialog(context, app),
                  ),
                ),
                if (!narrow)
                  Builder(
                    builder: (context) => _stageOverlayIconButton(
                      icon: Icons.tune,
                      tooltip: 'layers, movement, keyframes, masks, effects, stage, snapping',
                      onPressed: () => Scaffold.of(context).openEndDrawer(),
                    ),
                  ),
                // Show in context: while shown, a tap hides / shows it and
                // a long press opens its settings.
                // only for a project placed in another one.
                if (app.projectStore != null && (app.usedInCount > 0 || app.contextHost != null))
                  Builder(
                    builder: (context) => GestureDetector(
                      key: const ValueKey('context-toggle'),
                      onLongPress: () => showContextDialog(context, app),
                      child: _stageOverlayIconButton(
                        icon: app.contextHost == null
                            ? Icons.picture_in_picture_alt_outlined
                            : app.contextVisible
                                ? Icons.picture_in_picture_alt
                                : Icons.picture_in_picture_alt_outlined,
                        tooltip: 'show in context',
                        onPressed: () => app.contextHost == null
                            ? showContextDialog(context, app)
                            : app.setContextVisible(!app.contextVisible),
                      ),
                    ),
                  ),
                // edit with AI: copy the project as a prompt, paste a reply back
                // (the same round button as the others, its menu under it).
                Builder(
                  builder: (context) => KeyedSubtree(
                    key: const ValueKey('ai-menu'),
                    child: _stageOverlayIconButton(
                      icon: Icons.auto_awesome,
                      tooltip: 'edit with AI',
                      onPressed: () async {
                        final box = context.findRenderObject() as RenderBox;
                        final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
                        final at = box.localToGlobal(Offset.zero, ancestor: overlay);
                        final v = await showMenu<String>(
                          context: context,
                          position: RelativeRect.fromLTRB(
                              at.dx, at.dy + box.size.height, overlay.size.width - at.dx - box.size.width, 0),
                          items: const [
                            PopupMenuItem(value: 'prompt', child: Text('Copy prompt: edit this project with AI')),
                            PopupMenuItem(value: 'paste', child: Text('Paste the AI\'s reply (replaces the layers)')),
                          ],
                        );
                        if (!context.mounted) return;
                        if (v == 'prompt') await showAiPromptDialog(context, app: app);
                        if (v == 'paste' && context.mounted) {
                          final r = await showAiImportDialog(context, title: 'Paste the AI\'s reply');
                          if (r != null) app.replaceWithMcj(r);
                        }
                      },
                    ),
                  ),
                ),
                Builder(
                  builder: (context) => _stageOverlayIconButton(
                    icon: Icons.ios_share,
                    tooltip: 'export',
                    onPressed: () => showExportDialog(context, app),
                  ),
                ),
              ],
            )),
          ),
        ))),
        ],
      ),
    ),
  );
}

/// Show in context: the stage's frame is outside that reference's time in
/// the host (shown at the nearest end).
Widget _contextNote(AppState app) => Positioned(
      left: 8,
      bottom: 8,
      child: AnimatedBuilder(
        animation: app,
        builder: (context, _) => app.contextVisible && app.contextOutside
            ? Container(
                key: const ValueKey('context-outside'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: Colors.black54,
                child: const Text('outside range', style: TextStyle(fontSize: 11, color: Colors.white70)),
              )
            : const SizedBox.shrink(),
      ),
    );

/// The performance HUD, top-left under the back arrow - a widget over the
/// stage, never part of what the renderer draws (see PerfHud).
Widget _perfHud(AppState app) => Positioned(
      top: 0,
      left: 0,
      child: SafeArea(
        bottom: false,
        right: false,
        child: Padding(padding: const EdgeInsets.only(left: 4, top: 44), child: PerfHud(app: app)),
      ),
    );

Widget _stageOverlayIconButton(
    {required IconData icon,
    required String tooltip,
    required VoidCallback onPressed}) {
  return Padding(
    padding: const EdgeInsets.all(2),
    child: Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, size: 18),
        color: Colors.white,
        tooltip: tooltip,
        onPressed: onPressed,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
        visualDensity: VisualDensity.compact,
      ),
    ),
  );
}

/// Portrait/narrow-width navigation shell around the params sections none
/// existed at all - StageView filled the whole body, and the layer/params
/// panels the wide layout puts in fixed side columns had nowhere to go). A
/// DraggableScrollableSheet (plain Flutter SDK widget, no new dependency)
/// floating over the stage, drag-resizable from a handle at its top, wrapping
/// the shared `_ParamsTabs` tab rail below (all the tabs, unlike the
/// wide-layout endDrawer's 5 - see MovementMobileApp's own doc comment on why
/// Layers/Movement are excluded there but not here).
///
/// The grabber drags the sheet between 4 heights (bottom to top): just
/// the tab chips (for 9:16 projects), the default (1:1), a bit higher
/// (16:9), and near the top (comfortable parameter editing). Tapping the
/// selected tab chip again deselects it and drops the sheet to the
/// bottom; picking a tab while collapsed raises it back.
class _MobileParamsSheet extends StatefulWidget {
  final AppState app;
  final ValueNotifier<double> dock;
  final double fullHeight;
  const _MobileParamsSheet({required this.app, required this.dock, required this.fullHeight});

  static const tabs = ['Layers', 'Movement', 'Keyframes', 'Timeline', 'Masks', 'Effects', 'Collide', 'Figures', 'Filters', 'Objects', 'Drawing', 'Links', 'Palettes', 'Text', 'Line', 'Crop', 'Chroma', 'Audio', 'Reverse', 'Presets', 'Stage', 'Snapping', 'Settings'];

  @override
  State<_MobileParamsSheet> createState() => _MobileParamsSheetState();
}

/// Three ways open: closed (the grabber and the tab chips), half (under
/// the timeline, the stage gives way) and full (over the timeline and
/// most of the stage). Drag the grabber, or tap the open tab's chip to
/// close it / any chip to open.
class _MobileParamsSheetState extends State<_MobileParamsSheet> {
  static const double _grabberHeight = 20;
  static const double collapsedPx = _grabberHeight + 40 + 4;

  int _mode = 1; // 0 closed, 1 half, 2 full
  int? _tab = 0;
  int _lastTab = 0;
  double? _dragHeight; // while the grabber is dragged

  // the head takes the screen's lower half (above the closed strip):
  // half open covers half of the head, full covers exactly all of it.
  double get _halfPx => widget.fullHeight / 4 + collapsedPx / 2;
  double get _fullPx => widget.fullHeight / 2;
  double _heightOf(int mode) => [collapsedPx, _halfPx, _fullPx][mode];

  @override
  void initState() {
    super.initState();
    widget.app.tabRequests.addListener(_onTabRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishDock());
    xyPadHosts++;
    xyPad.addListener(_onXyPad);
    easePanelHosts++;
    easePanel.addListener(_onEasePanel);
  }

  // the ease editor takes the tab's place, over the whole head; closing it
  // puts the sheet back.
  int? _modeBeforeEase;
  void _onEasePanel() {
    if (!mounted) return;
    if (easePanel.value != null) {
      _modeBeforeEase ??= _mode;
      if (_mode != 2) _setMode(2);
      if (_tab == null) _onTabChanged(_lastTab);
    } else if (_modeBeforeEase != null) {
      final m = _modeBeforeEase!;
      _modeBeforeEase = null;
      _setMode(m);
    } else {
      setState(() {});
    }
  }

  // the XY pad opens the sheet over the whole head; closing it puts the
  // sheet back.
  int? _modeBeforePad;
  void _onXyPad() {
    if (!mounted) return;
    if (xyPad.value != null) {
      _modeBeforePad ??= _mode;
      _setMode(2);
    } else if (_modeBeforePad != null) {
      final m = _modeBeforePad!;
      _modeBeforePad = null;
      _setMode(m);
    } else {
      setState(() {});
    }
  }

  /// AppState.showTab (e.g. a new text layer opens the Text tab), raising
  /// the sheet if it was closed.
  void _onTabRequest() {
    final i = _MobileParamsSheet.tabs.indexOf(widget.app.requestedTab ?? '');
    if (i < 0 || !mounted) return;
    // only picked: the sheet stays as it is, the tab is there next time.
    if (!widget.app.tabRequestOpens && _tab == null) {
      _lastTab = i;
      return;
    }
    _onTabChanged(i);
  }

  @override
  void dispose() {
    widget.app.tabRequests.removeListener(_onTabRequest);
    xyPad.removeListener(_onXyPad);
    xyPadHosts--;
    easePanel.removeListener(_onEasePanel);
    easePanelHosts--;
    super.dispose();
  }

  // closed and half take room under the timeline; full lies over it and
  // keeps the half's room so nothing under it jumps.
  void _publishDock() => widget.dock.value = _mode == 0 ? collapsedPx : _halfPx;

  void _setMode(int mode) {
    setState(() {
      _mode = mode;
      _dragHeight = null;
      if (mode == 0) {
        if (_tab != null) _lastTab = _tab!;
        _tab = null;
      } else {
        _tab ??= _lastTab;
      }
    });
    _publishDock();
  }

  void _onGrabberDrag(DragUpdateDetails d) {
    setState(() => _dragHeight = ((_dragHeight ?? _heightOf(_mode)) - d.delta.dy).clamp(collapsedPx, _fullPx));
  }

  void _onGrabberDragEnd(DragEndDetails d) {
    final h = _dragHeight ?? _heightOf(_mode);
    final v = d.primaryVelocity ?? 0; // > 0 = downward
    int target;
    if (v.abs() > 400) {
      target = v < 0 ? (_mode + 1).clamp(0, 2) : (_mode - 1).clamp(0, 2);
    } else {
      target = [0, 1, 2].reduce((a, b) => (_heightOf(a) - h).abs() <= (_heightOf(b) - h).abs() ? a : b);
    }
    // the XY pad shows over the whole head or not at all.
    if (xyPad.value != null && target == 1) target = v > 0 || h < _halfPx ? 0 : 2;
    _setMode(target);
  }

  void _onTabChanged(int? i) {
    if (i == null) {
      _setMode(0);
    } else if (_tab == null) {
      setState(() => _tab = i);
      _setMode(1);
    } else {
      setState(() => _tab = i);
    }
  }

  double? _lastFullHeight;
  bool _spaceChanged = false;

  @override
  Widget build(BuildContext context) {
    _spaceChanged = _lastFullHeight != null && _lastFullHeight != widget.fullHeight;
    _lastFullHeight = widget.fullHeight;
    final h = _dragHeight ?? _heightOf(_mode);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedContainer(
        key: const ValueKey('params-sheet'),
        // the space itself changed (the keyboard came up / went down): the
        // sheet follows at once, no springing.
        duration: _dragHeight == null && !_spaceChanged ? const Duration(milliseconds: 200) : Duration.zero,
        curve: Curves.easeOut,
        height: h,
        child: Material(
          elevation: 8,
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Column(
            children: [
              GestureDetector(
                key: const ValueKey('sheet-grabber'),
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: _onGrabberDrag,
                onVerticalDragEnd: _onGrabberDragEnd,
                child: const SizedBox(
                  height: _grabberHeight,
                  width: double.infinity,
                  child: Center(
                    child: SizedBox(
                      width: 36,
                      height: 4,
                      child: DecoratedBox(decoration: BoxDecoration(color: Colors.grey)),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _ParamsTabs(
                  tabs: _MobileParamsSheet.tabs,
                  app: widget.app,
                  selected: _tab,
                  onChanged: _onTabChanged,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// the tabs with NO existing fixed-column home in the wide layout's own
// Row (main.dart's own build() above) - Layers/Movement are excluded
// since they already have dedicated 220px/260px columns there; including
// them again here would reintroduce the exact top-icon duplication this
// round removed, just relocated into the drawer instead.
const _wideDrawerTabs = ['Keyframes', 'Timeline', 'Masks', 'Effects', 'Collide', 'Figures', 'Filters', 'Objects', 'Drawing', 'Links', 'Palettes', 'Text', 'Line', 'Crop', 'Chroma', 'Audio', 'Reverse', 'Presets', 'Stage', 'Snapping', 'Settings'];

/// the tab-rail + tab-body switch shared by both the narrow layout's
/// `_MobileParamsSheet` (all tabs) and the wide layout's new endDrawer (see
/// `_wideDrawerTabs`) - extracted so both share identical tab-rail code
/// instead of duplicating it). Switches on the tab's own NAME rather than a
/// positional index, since the two callers pass different tab lists at
/// different indices - the Effects tab shows the real port of
/// effectsSection.js (ui/effects/effects_view.dart); Masks shows the real port
/// of masksSection.js (ui/masks/masks_view.dart).
class _ParamsTabs extends StatefulWidget {
  final List<String> tabs;
  final AppState app;
  // controlled mode (the narrow sheet): the parent owns the selection,
  // and tapping the selected chip reports null (deselect). Without
  // onChanged (the wide endDrawer) the tabs keep their own, always-set
  // selection.
  final int? selected;
  final ValueChanged<int?>? onChanged;
  const _ParamsTabs(
      {required this.tabs, required this.app, this.selected, this.onChanged});

  @override
  State<_ParamsTabs> createState() => _ParamsTabsState();
}

class _ParamsTabsState extends State<_ParamsTabs> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // the wide drawer keeps its own selection - follow AppState.showTab.
    if (widget.onChanged == null) widget.app.tabRequests.addListener(_onTabRequest);
  }

  void _onTabRequest() {
    final i = widget.tabs.indexOf(widget.app.requestedTab ?? '');
    if (i >= 0 && mounted) setState(() => _tab = i);
  }

  @override
  void dispose() {
    widget.app.tabRequests.removeListener(_onTabRequest);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onChanged = widget.onChanged;
    final int? tab = onChanged == null ? _tab : widget.selected;
    // the ease editor: in place of the tabs and their page (its own exit
    // in the corner).
    return ValueListenableBuilder<EaseTarget?>(
      valueListenable: easePanel,
      builder: (context, ease, tabs) => ease != null && onChanged != null
          ? GraphEditorView(
              key: ObjectKey(ease.track),
              app: ease.app,
              track: ease.track,
              componentCount: ease.componentCount,
              wholePath: ease.wholePath,
              onClose: () => easePanel.value = null,
            )
          : tabs!,
      child: _tabsAndPage(tab, onChanged),
    );
  }

  Widget _tabsAndPage(int? tab, ValueChanged<int?>? onChanged) {
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: widget.tabs.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(tr(widget.tabs[i])),
                selected: tab == i,
                onSelected: (_) {
                  if (onChanged == null) {
                    setState(() => _tab = i);
                  } else {
                    onChanged(tab == i ? null : i);
                  }
                },
              ),
            ),
          ),
        ),
        Expanded(
          // the XY pad takes the page of whichever tab is picked.
          child: ValueListenableBuilder<XyPadTarget?>(
            valueListenable: xyPad,
            // the page stays built under the pad (hidden), so it comes back
            // scrolled where it was.
            builder: (context, pad, _) {
              final showPad = pad != null && widget.onChanged != null;
              return Stack(children: [
                if (tab != null)
                  Positioned.fill(
                    child: Offstage(
                      offstage: showPad,
                      child: TickerMode(enabled: !showPad, child: _tabBody(widget.tabs[tab])),
                    ),
                  ),
                if (showPad)
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Center(child: XyPadPanel(target: pad)),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ],
    );
  }

  Widget _tabBody(String tabName) {
    switch (tabName) {
      case 'Layers':
        return LayerPanelView(app: widget.app);
      case 'Movement':
        return ParamsPanelView(app: widget.app);
      case 'Keyframes':
        return KeyframesEditorView(app: widget.app);
      case 'Masks':
        return MasksView(app: widget.app);
      case 'Effects':
        return EffectsView(app: widget.app);
      case 'Collide':
        // the contour: Outline and physics (the base for what comes next).
        return EffectsView(app: widget.app, contour: true);
      case 'Stage':
        return StageSettingsView(app: widget.app);
      case 'Audio':
        return AudioView(app: widget.app);
      case 'Figures':
        return FillView(app: widget.app);
      case 'Filters':
        return FiltersView(app: widget.app);
      case 'Objects':
        return ObjectsView(app: widget.app);
      case 'Drawing':
        return DrawingView(app: widget.app);
      case 'Links':
        return LinksView(app: widget.app);
      case 'Palettes':
        return PalettesView(app: widget.app);
      case 'Crop':
        return CropView(app: widget.app);
      case 'Presets':
        return PresetsView(app: widget.app);
      case 'Reverse':
        return ReverseView(app: widget.app);
      case 'Line':
        return LineView(app: widget.app);
      case 'Text':
        return TextView(app: widget.app);
      case 'Chroma':
        return ChromaView(app: widget.app);
      case 'Timeline':
        return TimelineRowsView(app: widget.app);
      case 'Settings':
        return SettingsView(app: widget.app);
      case 'Snapping':
        return SnappingSettingsView(app: widget.app);
      default:
        return const SizedBox.shrink();
    }
  }
}
