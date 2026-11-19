import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/main.dart';

void main() {
  testWidgets('a start that fails shows why, with a safe start and saving the projects - never an endless splash',
      (tester) async {
    // no folders plugin in tests: the start fails at finding the folders.
    await tester.pumpWidget(const AppBoot());
    expect(find.byKey(const ValueKey('boot-step')), findsOneWidget, reason: 'something on the screen at once');
    for (var i = 0; i < 20 && find.byKey(const ValueKey('boot-error')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('boot-error')), findsOneWidget);
    expect(find.text('Safe start'), findsOneWidget);
    expect(find.text('Save my projects...'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
