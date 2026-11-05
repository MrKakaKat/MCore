import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/backup.dart';

void main() {
  test('a backup restores projects and media into an empty folder; caches left out', () {
    final a = Directory.systemTemp.createTempSync('bk_a'), b = Directory.systemTemp.createTempSync('bk_b');
    addTearDown(() {
      a.deleteSync(recursive: true);
      b.deleteSync(recursive: true);
    });
    File('${a.path}/projects/p1.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"x":1}');
    File('${a.path}/images/abc.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    File('${a.path}/cache/big.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9]);
    expect(restoreBackup(makeBackup(a), b), 2);
    expect(File('${b.path}/projects/p1.json').readAsStringSync(), '{"x":1}');
    expect(File('${b.path}/images/abc.png').readAsBytesSync(), [1, 2, 3]);
    expect(File('${b.path}/cache/big.bin').existsSync(), isFalse);
  });
}
