import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What the app was doing, kept in a small file every couple of seconds,
/// and the last errors: when the app closes unexpectedly, the next start
/// tells where it was (the project, the frame, playing or not) and what
/// went wrong - to be sent on.
class CrashLog with WidgetsBindingObserver {
  CrashLog._(this._file);

  static CrashLog? instance;

  final File _file;
  Timer? _beat;

  /// What the open project is doing now (set by the editor; null: the
  /// project list).
  Map<String, Object?> Function()? status;

  final List<String> _errors = [];
  String _state = 'running';

  /// The last session, as read at start, when it ended while working
  /// (null: it closed normally, or there is none).
  Map<String, dynamic>? lastCrash;

  static Future<CrashLog> start(Directory dir) async {
    final log = CrashLog._(File('${dir.path}/mcore_session.json'));
    instance = log;
    try {
      if (await log._file.exists()) {
        final last = jsonDecode(await log._file.readAsString());
        if (last is Map<String, dynamic> && last['state'] == 'running' && last['project'] != null) log.lastCrash = last;
        // errors from a session that went on afterwards still count.
        if (last is Map<String, dynamic> && last['state'] != 'running' && (last['errors'] as List?)?.isNotEmpty == true) {
          log.lastCrash = last;
        }
      }
    } catch (_) {}
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (d) {
      log.error('${d.exceptionAsString()}\n${d.stack ?? ''}');
      prevFlutter?.call(d);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      log.error('$e\n$st');
      return true;
    };
    WidgetsBinding.instance.addObserver(log);
    log._beat = Timer.periodic(const Duration(seconds: 2), (_) => log._write());
    log._write();
    return log;
  }

  void error(String text) {
    _errors.add('${DateTime.now().toIso8601String()} ${text.length > 4000 ? text.substring(0, 4000) : text}');
    while (_errors.length > 5) {
      _errors.removeAt(0);
    }
    _write();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // put away by the user (or the system): not a crash if it ends there.
    _state = state == AppLifecycleState.resumed ? 'running' : 'background';
    _write();
  }

  void _write() {
    Map<String, Object?> s = const {};
    try {
      s = status?.call() ?? const {};
    } catch (_) {}
    final data = {
      'state': _state,
      'time': DateTime.now().toIso8601String(),
      ...s,
      if (_errors.isNotEmpty) 'errors': _errors,
    };
    try {
      _file.writeAsStringSync(jsonEncode(data), flush: false);
    } catch (_) {}
  }

  /// The last session's report, readable.
  String describe(Map<String, dynamic> c) {
    final b = StringBuffer();
    b.writeln('MCore closed ${c['state'] == 'running' ? 'unexpectedly' : 'after errors'} at ${c['time']}');
    if (c['project'] != null) b.writeln('project: ${c['project']}');
    for (final k in ['frame', 'playing', 'layers', 'refs', 'version']) {
      if (c[k] != null) b.writeln('$k: ${c[k]}');
    }
    for (final e in (c['errors'] as List? ?? const [])) {
      b.writeln('---');
      b.writeln(e);
    }
    return b.toString();
  }

  void dispose() {
    _beat?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
