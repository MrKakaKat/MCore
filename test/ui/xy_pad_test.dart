import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/common/xy_pad.dart';

void main() {
  testWidgets('a point parameter opens in the XY pad; dragging moves it by the sensitivity', (tester) async {
    ParamEditor.resetModes(expanded: true);
    addTearDown(() => ParamEditor.resetModes());
    var value = [10.0, 20.0];
    var starts = 0, commits = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ParamEditor(
            prefKey: 'pos',
            label: 'position',
            values: value,
            scale: const ParamScale.ruler(unitsPerPixel: 1, minorTick: 5, majorTick: 25),
            componentLabels: const ['x', 'y'],
            onEditStart: () => starts++,
            onChanged: (v) => setState(() => value = v),
            onCommit: (v) {
              commits++;
              setState(() => value = v);
            },
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('xy-pad-open-pos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('xy-pad')), findsOneWidget);
    xyPadSensitivity.value = 0.5; // tests: any units
    await tester.pump();
    await tester.drag(find.byKey(const ValueKey('xy-pad')), const Offset(40, -20));
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(commits, 1);
    // the drag's first pixels go to the gesture slop; the rest moves it.
    expect(value[0], greaterThan(10 + 10));
    expect(value[0], lessThanOrEqualTo(10 + 20.0001));
    expect(value[1], lessThan(20 - 5));
    await tester.tap(find.byKey(const ValueKey('xy-pad-close')));
    await tester.pumpAndSettle();
    expect(xyPad.value, isNull);
    expect(find.byKey(const ValueKey('xy-pad')), findsNothing);
    xyPadSensitivity.value = 0.002;
  });
}
