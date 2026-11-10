import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/ui/export/export_dialog.dart';

void main() {
  test('export names: project, frame, timestamp; never the same twice', () {
    final t = DateTime(2026, 10, 19, 14, 3, 7);
    expect(exportFileName('My clip', 'png', frame: 42, now: t), 'My clip 2026.10.19 14:03:07 f42.png');
    expect(exportFileName('My clip', 'png', frame: 42, now: t), 'My clip 2026.10.19 14:03:07 f42 (2).png');
    expect(exportFileName('a/b:c', 'gif', now: t), 'a_b_c 2026.10.19 14:03:07.gif');
    expect(exportFileName('  ', 'webm', now: t), 'export 2026.10.19 14:03:07.webm');
  });
}
