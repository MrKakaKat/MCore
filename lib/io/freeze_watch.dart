import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// A watch on the app from its own thread: the app tells it what it is
/// doing as it goes (a layer drawn, a placed project, an export frame);
/// when the app stops answering for a while (frozen), the watch writes
/// down what it was doing at that moment - into a file the next start
/// reads (see CrashLog), even if the app is closed while frozen.
class FreezeWatch {
  FreezeWatch._();

  static SendPort? _port;
  static String _last = '';

  /// How long the app may not answer before it counts as frozen.
  static const limit = Duration(seconds: 4);

  static Future<void> start(File file) async {
    if (_port != null) return;
    final ready = ReceivePort();
    await Isolate.spawn(_watch, [ready.sendPort, file.path, limit.inMilliseconds]);
    _port = await ready.first as SendPort;
    // answering while nothing in particular is done.
    // (with the memory the app takes: running out of it slows it to a
    // stop, then it is closed.)
    Timer.periodic(const Duration(milliseconds: 500), (_) {
      _port?.send(['ping', memoryMb()]);
    });
  }

  /// The memory the app takes, MB: what is in the phone's memory plus what
  /// the system put aside (swap - it no longer counts as "in memory", and
  /// the app slows to a crawl over it).
  static int memoryMb() {
    try {
      final status = File('/proc/self/status').readAsLinesSync();
      int kb(String name) {
        final l = status.firstWhere((l) => l.startsWith(name), orElse: () => '');
        return int.tryParse(RegExp(r'\d+').firstMatch(l)?.group(0) ?? '') ?? 0;
      }

      final rss = kb('VmRSS:'), swap = kb('VmSwap:');
      if (rss > 0) return (rss + swap) >> 10;
    } catch (_) {}
    try {
      return ProcessInfo.currentRss >> 20;
    } catch (_) {
      return 0;
    }
  }

  /// What the app is doing now (cheap: sent only when it changes).
  static void at(String what) {
    final p = _port;
    if (p == null || identical(what, _last) || what == _last) return;
    _last = what;
    p.send(['at', what]);
  }

  /// What the open project is (written with a freeze).
  static void context(String text) => _port?.send(['ctx', text]);

  /// Reads (and clears) the freezes written down since the last start.
  static List<String> takeRecorded(File file) {
    try {
      if (!file.existsSync()) return const [];
      final raw = file.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      file.deleteSync();
      // a freeze it came back from is written twice (at once, and when
      // back): the later one says how long.
      final byAt = <String, String>{};
      for (final l in raw) {
        try {
          byAt[(jsonDecode(l) as Map)['at'] as String] = l;
        } catch (_) {
          byAt[l] = l;
        }
      }
      final lines = byAt.values.toList();
      return [
        for (final l in lines.reversed.take(5).toList().reversed)
          () {
            try {
              final j = jsonDecode(l) as Map<String, dynamic>;
              final dur = j['ms'] == null ? 'and did not come back' : 'for ${((j['ms'] as num) / 1000).toStringAsFixed(1)} s';
              return 'FROZE ${j['at']} $dur\n  doing: ${j['doing']}\n  before: ${(j['before'] as List?)?.join(' | ')}\n  ${j['ctx'] ?? ''}\n  memory: ${j['mb'] ?? '?'} MB';
            } catch (_) {
              return l;
            }
          }()
      ];
    } catch (_) {
      return const [];
    }
  }
}

void _watch(List<Object?> args) {
  final reply = args[0] as SendPort;
  final file = File(args[1] as String);
  final limitMs = args[2] as int;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  var lastHeard = DateTime.now();
  var doing = '';
  final before = <String>[];
  var ctx = '';
  var memory = 0;
  DateTime? frozeAt;
  inbox.listen((m) {
    final msg = m as List;
    final now = DateTime.now();
    if (frozeAt != null) {
      // back: how long it was gone.
      final ms = now.difference(frozeAt!).inMilliseconds + limitMs;
      _append(file, {'at': frozeAt!.toIso8601String(), 'ms': ms, 'doing': doing, 'before': before, 'ctx': ctx, 'mb': memory});
      frozeAt = null;
    }
    lastHeard = now;
    switch (msg[0]) {
      case 'at':
        if (doing.isNotEmpty) {
          before.add(doing);
          if (before.length > 6) before.removeAt(0);
        }
        doing = msg[1] as String;
      case 'ctx':
        ctx = msg[1] as String;
      case 'ping':
        memory = msg[1] as int;
    }
  });
  Timer.periodic(const Duration(milliseconds: 500), (_) {
    if (frozeAt != null) return;
    if (DateTime.now().difference(lastHeard).inMilliseconds > limitMs) {
      frozeAt = DateTime.now();
      // written at once: the app may never come back.
      _append(file, {'at': frozeAt!.toIso8601String(), 'doing': doing, 'before': before, 'ctx': ctx, 'mb': memory});
    }
  });
}

void _append(File f, Map<String, Object?> j) {
  try {
    f.writeAsStringSync('${jsonEncode(j)}\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}
