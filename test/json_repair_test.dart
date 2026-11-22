import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/io/json_repair.dart';

void main() {
  test('a project file cut off part way: what was written whole comes back', () {
    final full = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'name': 'Mine',
      'project': {
        'layers': [
          for (var i = 0; i < 5; i++) {'id': 'L$i', 'name': 'layer "$i" {x}', 'keys': [1, 2, 3]}
        ]
      },
      'maxFrame': 120,
    });
    final cut = full.substring(0, full.indexOf('L3') + 10);
    final r = repairTruncatedJson(cut) as Map;
    expect(r['name'], 'Mine');
    final layers = (r['project'] as Map)['layers'] as List;
    expect(layers.length, 3, reason: 'the three written whole');
    expect(repairTruncatedJson(''), isNull);
    expect(repairTruncatedJson(full), isA<Map>());
  });

  test('a safe write leaves the file whole and the one before it beside', () async {
    final dir = await Directory.systemTemp.createTemp('safe_write_');
    try {
      final f = File('${dir.path}/p.json');
      await writeFileSafely(f, '{"a":1}');
      await writeFileSafely(f, '{"a":2}');
      expect(await f.readAsString(), '{"a":2}');
      expect(await File('${f.path}.bak').readAsString(), '{"a":1}');
      expect(await File('${f.path}.tmp').exists(), isFalse);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
