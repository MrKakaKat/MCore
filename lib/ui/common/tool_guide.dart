import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A tour of a tool field: the screen darkens, a round hole shows one
/// icon at a time with what it does above it; a tap goes to the next.

final Map<String, GlobalKey> _keys = {};

/// The key a guided icon wears (one per id).
GlobalKey guideKey(String id) => _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'guide-$id'));

bool _running = false;

/// Shows `steps` (icon id, description) in order; steps whose icon isn't
/// on screen are skipped. `onDone` runs at the end (or when nothing
/// could be shown).
void showToolGuide(BuildContext context, List<(String, String)> steps, VoidCallback onDone) {
  if (_running) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _running = true;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Guide(
      steps: steps,
      onDone: () {
        entry.remove();
        _running = false;
        onDone();
      },
    ),
  );
  overlay.insert(entry);
}

class _Guide extends StatefulWidget {
  final List<(String, String)> steps;
  final VoidCallback onDone;
  const _Guide({required this.steps, required this.onDone});

  @override
  State<_Guide> createState() => _GuideState();
}

class _GuideState extends State<_Guide> with SingleTickerProviderStateMixin {
  int _i = -1;
  Rect? _hole;

  /// After the last icon: the note that the guide can be shown again.
  bool _closing = false;
  late final Ticker _ticker = createTicker((_) => _track());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _next());
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  BuildContext? _ctx(int i) => _keys[widget.steps[i].$1]?.currentContext;

  /// Where step `i`'s icon is now (null: not on screen).
  Rect? _rectOf(int i) {
    final me = context.findRenderObject() as RenderBox?;
    final box = _ctx(i)?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize || me == null || !me.hasSize) return null;
    return box.localToGlobal(Offset.zero, ancestor: me) & box.size;
  }

  /// The hole follows its icon every frame (a panel still sliding in, a
  /// row scrolling to it).
  void _track() {
    if (!mounted || _i < 0 || _closing) return;
    final r = _rectOf(_i);
    if (r != null && r != _hole) setState(() => _hole = r);
  }

  /// The next step whose icon is on screen; a row that scrolls brings it
  /// into view, smoothly.
  void _next() {
    if (!mounted) return;
    if (_closing) {
      widget.onDone();
      return;
    }
    for (var i = _i + 1; i < widget.steps.length; i++) {
      final ctx = _ctx(i);
      if (ctx == null || _rectOf(i) == null) continue;
      Scrollable.ensureVisible(ctx,
          alignment: 0.5, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
      setState(() {
        _i = i;
        _hole = _rectOf(i);
      });
      return;
    }
    setState(() {
      _closing = true;
      _hole = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hole = _hole;
    final size = MediaQuery.sizeOf(context);
    final r = hole == null ? 0.0 : math.max(hole.width, hole.height) / 2 + 8;
    final text = _i < 0 ? '' : widget.steps[_i].$2;
    if (_closing) {
      return GestureDetector(
        key: const ValueKey('tool-guide'),
        behavior: HitTestBehavior.opaque,
        onTap: _next,
        child: Container(
          color: const Color(0xC0000000),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(32),
          child: const Material(
            color: Colors.transparent,
            child: Text(
              'That\'s all. You can see this guide again in Settings -> Show the tool guides again.',
              key: ValueKey('tool-guide-end'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15, height: 1.3),
            ),
          ),
        ),
      );
    }
    // the note above the hole, or under it when there's no room.
    final above = hole != null && hole.center.dy - r > 120;
    return GestureDetector(
      key: const ValueKey('tool-guide'),
      behavior: HitTestBehavior.opaque,
      onTap: _next,
      child: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: _Dim(hole?.center, r))),
        if (hole != null)
          Positioned(
            left: 16,
            right: 16,
            top: above ? null : hole.center.dy + r + 12,
            bottom: above ? size.height - (hole.center.dy - r) + 12 : null,
            child: Material(
              color: Colors.transparent,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.3)),
                const SizedBox(height: 6),
                Text(
                    '${_i + 1} / ${widget.steps.length}  ·  tap to go on',
                    style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _Dim extends CustomPainter {
  final Offset? c;
  final double r;
  _Dim(this.c, this.r);

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Path()..addRect(Offset.zero & size);
    final p = c == null ? dim : Path.combine(PathOperation.difference, dim, Path()..addOval(Rect.fromCircle(center: c!, radius: r)));
    canvas.drawPath(p, Paint()..color = const Color(0xC0000000));
    if (c != null) {
      canvas.drawCircle(c!, r, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white70);
    }
  }

  @override
  bool shouldRepaint(_Dim old) => old.c != c || old.r != r;
}
