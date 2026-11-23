import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/freeze_watch.dart';

void main() {
  test('a frozen app: the watch writes down what it was doing', () async {
    final dir = Directory.systemTemp.createTempSync('freeze_');
    final f = File('${dir.path}/freezes.jsonl');
    await FreezeWatch.start(f);
    FreezeWatch.context('project: P');
    FreezeWatch.at('layer "A"');
    FreezeWatch.at('placed project "B", its frame 7');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // the app's own thread stuck.
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 5)) {}
    await Future<void>.delayed(const Duration(seconds: 1));
    final got = FreezeWatch.takeRecorded(f);
    expect(got, hasLength(1));
    expect(got.first, contains('placed project "B", its frame 7'));
    expect(got.first, contains('layer "A"'));
    expect(got.first, contains('project: P'));
    expect(got.first, contains(' for '));
    dir.deleteSync(recursive: true);
  });
}
