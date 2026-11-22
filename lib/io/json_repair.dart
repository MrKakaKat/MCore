import 'dart:convert';
import 'dart:io';

/// Writes `text` to `file` so that a crash part way never leaves it cut
/// short: written whole to a side file first, then put in its place in
/// one step. The version it replaces is kept beside it (`.bak`).
Future<void> writeFileSafely(File file, String text, {bool keepBackup = true}) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(text, flush: true);
  if (keepBackup) {
    try {
      if (await file.exists() && await file.length() > 0) await file.copy('${file.path}.bak');
    } catch (_) {}
  }
  await tmp.rename(file.path);
}

/// What is left of a JSON text cut off part way (the app closed while it
/// was written): everything up to the last complete value, the open
/// lists and objects closed. Null when nothing can be made of it.
Object? repairTruncatedJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {}
  // where each list / object closes, and what is still open after it.
  final cuts = <(int, String)>[];
  final stack = <String>[];
  var inString = false, escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    switch (c) {
      case '"':
        inString = true;
      case '{':
        stack.add('}');
      case '[':
        stack.add(']');
      case '}' || ']':
        if (stack.isNotEmpty) stack.removeLast();
        cuts.add((i, stack.reversed.join()));
    }
  }
  // the latest cut that reads, at most a few hundred tries back.
  for (var k = cuts.length - 1; k >= 0 && k >= cuts.length - 400; k--) {
    final (i, closers) = cuts[k];
    try {
      return jsonDecode(text.substring(0, i + 1) + closers);
    } catch (_) {}
  }
  return null;
}
