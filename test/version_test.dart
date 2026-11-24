import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/version.dart';

void main() {
  test('the version shown is the one built', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':')[1].trim().split('+').first, appVersion);
  });
}
