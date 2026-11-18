import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('a folder\'s pieces one after another pack into one row (no staircase); overlapping ones keep theirs', () {
    Layer l(String id, int start, int dur, String? folder) => createLayer('rect')
      ..id = id
      ..startFrame = start
      ..durationFrames = dur
      ..folder = folder;
    final p = Project(layers: [
      l('out', 0, 100, null),
      l('a', 0, 20, 'F'),
      l('b', 20, 20, 'F'),
      l('c', 40, 20, 'F'),
      l('d', 10, 30, 'F'), // overlaps a and b
    ]);
    expect(timelineRows(p).length, 5);
    expect(packFolderRows(p, 'F'), isTrue);
    final rows = timelineRows(p);
    String ids(List<Layer> r) => r.map((x) => x.id).join();
    expect(rows.map(ids).toList(), ['out', 'abc', 'd']);
    expect(packFolderRows(p, 'F'), isFalse, reason: 'already packed');
  });
}
