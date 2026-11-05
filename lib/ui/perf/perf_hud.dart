import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart' show physicsWorldOf;

import '../../app_state.dart';
import '../../io/app_settings.dart';
import '../../perf/perf_monitor.dart';

/// Shows / hides the performance HUD (Settings tab) - an app setting,
/// kept across projects and restarts, never saved in a project.
void togglePerfHud() {
  final on = !PerfMonitor.instance.visible.value;
  PerfMonitor.instance.setVisible(on);
  AppSettings.instance?.setPerfHud(on);
}

/// The performance HUD: a plain widget over the stage - never drawn by the
/// renderer, so it can't reach an export. It doesn't listen to AppState
/// (that would make it rebuild on every playback frame - the cost it is
/// meant to measure); it reads PerfMonitor's aggregates on its own slow
/// timer, 3 times a second, behind a RepaintBoundary.
class PerfHud extends StatelessWidget {
  final AppState app;
  const PerfHud({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PerfMonitor.instance.visible,
      builder: (context, visible, _) => visible ? RepaintBoundary(child: _PerfPanel(app: app)) : const SizedBox.shrink(),
    );
  }
}

class _PerfPanel extends StatefulWidget {
  final AppState app;
  const _PerfPanel({required this.app});

  @override
  State<_PerfPanel> createState() => _PerfPanelState();
}

class _PerfPanelState extends State<_PerfPanel> {
  static const refresh = Duration(milliseconds: 333);
  Timer? _timer;
  PerfSnapshot? _snap;
  ({int count, int bytes, int failures})? _images;
  ({double decodeMs, int holds, int stale, int bytes, int budget})? _video;
  bool _collapsed = true;

  @override
  void initState() {
    super.initState();
    _take();
    _timer = Timer.periodic(refresh, (_) => _take());
  }

  void _take() {
    if (!mounted) return;
    setState(() {
      _snap = PerfMonitor.instance.snapshot();
      _images = widget.app.renderer.imageStats();
      final v = widget.app.renderer.videoFrames;
      _video = (decodeMs: v.avgDecodeMs, holds: v.holds, stale: v.staleDropped, bytes: v.bytes, budget: v.budgetBytes);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  static String _ms(double v) => v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final s = _snap;
    if (s == null) return const SizedBox.shrink();
    // no backing panel: a thin shadow keeps the text readable over the stage.
    const style = TextStyle(fontSize: 9, color: Colors.white, fontFamily: 'monospace', height: 1.2,
        shadows: [Shadow(blurRadius: 2), Shadow(blurRadius: 4)]);
    // the headline is frame time against the display's budget, not FPS:
    // FPS is capped by the display and says nothing while idle.
    final hz = '${s.targetFps.toStringAsFixed(0)} Hz, budget ${_ms(s.budgetMs)} ms';
    final p95Color = s.frameP95Ms <= s.budgetMs
        ? Colors.greenAccent
        : s.frameP95Ms <= s.budgetMs * 1.5
            ? Colors.amberAccent
            : Colors.redAccent;
    final headline = Text.rich(
      TextSpan(children: s.active
          ? [
              TextSpan(text: 'frame ${_ms(s.frameAvgMs)} avg / '),
              TextSpan(
                  text: '${_ms(s.frameP95Ms)} p95',
                  style: style.copyWith(color: p95Color, fontWeight: FontWeight.bold)),
              TextSpan(text: ' ms · ${s.fps.toStringAsFixed(0)} fps · dropped ${s.droppedFrames}'),
            ]
          : [
              TextSpan(text: 'idle', style: style.copyWith(color: Colors.white70, fontWeight: FontWeight.bold)),
              TextSpan(text: ' · $hz'),
            ]),
      style: style,
      key: const ValueKey('perf-headline'),
    );
    final images = _images;
    final video = _video;
    final hits = s.stateHits + s.stateMisses;
    return Container(
      key: const ValueKey('perf-hud'),
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.fromLTRB(4, 2, 0, 2),
      child: DefaultTextStyle(
        style: style,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: headline),
                _iconButton(_collapsed ? Icons.unfold_more : Icons.unfold_less, _collapsed ? 'expand' : 'collapse',
                    () => setState(() => _collapsed = !_collapsed), key: const ValueKey('perf-collapse')),
                _iconButton(Icons.restart_alt, 'reset counters', () {
                  PerfMonitor.instance.reset();
                  widget.app.renderer.videoFrames.resetStats();
                  _take();
                }, key: const ValueKey('perf-reset')),
              ],
            ),
            if (kDebugMode && !_collapsed)
              const Text('DEBUG build: numbers are several times worse than release - don\'t decide on them',
                  key: ValueKey('perf-debug-warning'), style: TextStyle(fontSize: 10, color: Colors.orangeAccent)),
            if (!_collapsed) ...[
              if (s.active) Text(hz),
              if (s.playbackFrames > 0)
                Text('${s.playing ? 'this' : 'last'} playback: '
                    '${s.playbackOverBudgetPercent.toStringAsFixed(0)}% of ${s.playbackFrames} frames over budget',
                    key: const ValueKey('perf-playback')),
              Text('UI ${_ms(s.uiAvgMs)} avg / ${_ms(s.uiWorstMs)} worst · '
                  'raster ${_ms(s.rasterAvgMs)} / ${_ms(s.rasterWorstMs)} ms'),
              const SizedBox(height: 2),
              SizedBox(
                width: 200,
                height: 20,
                child: CustomPaint(painter: _Sparkline(s.recentTotalsMs, s.budgetMs)),
              ),
              const SizedBox(height: 2),
              Text('render: state ${_ms(s.stateMs)} · record ${_ms(s.recordMs)} ms · '
                  '${s.rendersPerSecond.toStringAsFixed(0)}/s'),
              Text('other UI ${_ms(s.otherUiMs)} ms/frame (UI time - render time)', key: const ValueKey('perf-other-ui')),
              Text('app notifies ${s.notifiesPerSecond.toStringAsFixed(0)}/s'),
              Text(s.topLayers.isEmpty
                  ? 'top layers: -'
                  : 'top: ${s.topLayers.map((l) => '${l.name} ${l.ms.toStringAsFixed(2)}').join(', ')}'),
              Text('grid cells ${s.gridCells} · blur samples ${s.blurSamples} · pendulum ${s.pendulumEvals}'),
              Text(hits == 0
                  ? 'state cache: -'
                  : 'state cache ${(s.stateHitRatio * 100).toStringAsFixed(0)}% hits ($hits) - per render, '
                      'only parent/pendulum chains reuse it; 0% on simple scenes is normal'),
              () {
                final c = widget.app.renderer.contours.stats();
                return Text(
                    'contours ${c.extractions}/s · hits ${c.hits}/s · ${_ms(c.ms)} ms each'
                    '${c.isolateAvgMs == null ? '' : ' · isolate ${_ms(c.isolateAvgMs!)} ms avg, last ${_ms(c.isolateLastMs!)}'}',
                    key: const ValueKey('perf-contours'));
              }(),
              if (widget.app.project.layers.any((l) => l.physics.collide))
                () {
                  final w = physicsWorldOf(widget.app.project);
                  return Text(
                      'physics baked 0-${w.bakedUntil} · ${w.framesPerSecond} fr/s · '
                      'contacts ${w.contactsAt(widget.app.currentFrame).length}',
                      key: const ValueKey('perf-physics'));
                }(),
              if (widget.app.project.layers.any((l) => l.content.shape == 'projectRef'))
                () {
                  final r = widget.app.renderer.refStats();
                  return Text(
                      'references ${r.loaded} loaded · nested ${r.renders}/s, ${_ms(r.ms)} ms each · hits ${r.hits}/s',
                      key: const ValueKey('perf-refs'));
                }(),
              if (widget.app.project.layers.any((l) => l.content.text?.animators.isNotEmpty ?? false))
                Text('text units ${widget.app.renderer.textUnitsDrawn} · ${_ms(widget.app.renderer.textUnitsMs)} ms',
                    key: const ValueKey('perf-text-units')),
              if (images != null)
                Text('images ${images.count} (${_mb(images.bytes)}) · failed ${images.failures}'),
              if (video != null) ...[
                Text('video: decode ${_ms(video.decodeMs)} ms/frame · holds ${video.holds} · '
                    'stale dropped ${video.stale}', key: const ValueKey('perf-video')),
                Text('decoded frames ${_mb(video.bytes)} / budget ${_mb(video.budget)}',
                    key: const ValueKey('perf-video-memory')),
              ],
              if (s.rssBytes > 0) Text('memory (RSS) ${_mb(s.rssBytes)}'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, String tooltip, VoidCallback onPressed, {Key? key}) => IconButton(
        key: key,
        icon: Icon(icon, size: 14, color: Colors.white70),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: const EdgeInsets.all(2),
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        visualDensity: VisualDensity.compact,
      );
}

/// The last ~120 frame totals as bars, with the frame budget as a line.
class _Sparkline extends CustomPainter {
  final List<double> totals;
  final double budgetMs;
  _Sparkline(this.totals, this.budgetMs);

  @override
  void paint(Canvas canvas, Size size) {
    if (totals.isEmpty) return;
    final top = (budgetMs * 3).clamp(1.0, double.infinity);
    final barW = size.width / 120;
    final ok = Paint()..color = Colors.greenAccent.withOpacity(0.8);
    final late = Paint()..color = Colors.redAccent;
    for (var i = 0; i < totals.length; i++) {
      final v = totals[i];
      final h = (v / top).clamp(0.0, 1.0) * size.height;
      final x = size.width - (totals.length - i) * barW;
      canvas.drawRect(Rect.fromLTWH(x, size.height - h, barW * 0.8, h), v > budgetMs + 0.5 ? late : ok);
    }
    final y = size.height - budgetMs / top * size.height;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), Paint()
      ..color = Colors.white54
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_Sparkline old) => true;
}
