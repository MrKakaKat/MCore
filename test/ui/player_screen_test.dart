import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/player/player_screen.dart';

void main() {
  testWidgets('the player plays in a loop, tap pauses, closing stops and restores the loop setting', (tester) async {
    final app = AppState();
    app.addLayer('rect');
    app.loopPlayback = false;
    await tester.pumpWidget(MaterialApp(home: PlayerScreen(app: app)));
    expect(app.playing, isTrue);
    expect(app.loopPlayback, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('player-surface')));
    await tester.pump();
    expect(app.playing, isFalse);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey('player-surface')), const Offset(200, 0));
    await tester.pump();
    expect(app.currentFrame, greaterThan(0), reason: 'a drag scrubs');

    await tester.pumpWidget(const SizedBox());
    expect(app.playing, isFalse);
    expect(app.loopPlayback, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });
}
