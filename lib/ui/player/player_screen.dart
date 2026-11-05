import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';

/// Full-screen player: the project alone on black, playing in a loop -
/// no handles, panels or timeline. Tap pauses / plays, a horizontal drag
/// scrubs, back closes it (playback stops, the playhead stays where it
/// is).
class PlayerScreen extends StatefulWidget {
  final AppState app;
  const PlayerScreen({super.key, required this.app});

  static Future<void> open(BuildContext context, AppState app) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerScreen(app: app)));

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final bool _loopBefore;
  late final bool _cameraBefore;
  double _scrubDx = 0;
  int _scrubFrom = 0;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loopBefore = app.loopPlayback;
    _cameraBefore = app.renderer.useStageCamera;
    app.renderer.useStageCamera = true; // the picture through the stage camera
    app.loopPlayback = true;
    if (!app.playing && app.canPlay) app.togglePlay();
  }

  @override
  void dispose() {
    if (app.playing) app.togglePlay();
    app.loopPlayback = _loopBefore;
    app.renderer.useStageCamera = _cameraBefore;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        key: const ValueKey('player-surface'),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(app.togglePlay),
        onHorizontalDragStart: (_) {
          if (app.playing) app.togglePlay();
          _scrubDx = 0;
          _scrubFrom = app.currentFrame;
        },
        onHorizontalDragUpdate: (d) {
          _scrubDx += d.delta.dx;
          // the screen's width is the whole timeline.
          final w = MediaQuery.sizeOf(context).width;
          app.setFrame((_scrubFrom + _scrubDx / w * app.maxFrame).round().clamp(0, app.maxFrame));
        },
        child: ValueListenableBuilder<int>(
          valueListenable: app.frameNotifier,
          builder: (context, _, __) {
            app.renderer.renderFrame(app.project, app.currentFrame, clipToFrame: true);
            return Stack(children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _PlayerPainter(app.renderer.currentPicture, stageSize.width, stageSize.height),
                ),
              ),
              if (!app.playing)
                const Center(child: Icon(Icons.play_arrow, size: 72, color: Colors.white54)),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 3,
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: app.maxFrame == 0 ? 0 : app.currentFrame / app.maxFrame,
                  child: const ColoredBox(color: Colors.white38),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _PlayerPainter extends CustomPainter {
  final ui.Picture? picture;
  final double frameW, frameH;
  _PlayerPainter(this.picture, this.frameW, this.frameH);

  @override
  void paint(Canvas canvas, Size size) {
    final p = picture;
    if (p == null || frameW <= 0 || frameH <= 0) return;
    final s = math.min(size.width / frameW, size.height / frameH);
    canvas.save();
    canvas.translate((size.width - frameW * s) / 2, (size.height - frameH * s) / 2);
    canvas.scale(s);
    canvas.clipRect(Rect.fromLTWH(0, 0, frameW, frameH));
    canvas.drawPicture(p);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlayerPainter old) => true;
}
