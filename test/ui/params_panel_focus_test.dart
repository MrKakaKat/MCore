import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/main.dart';

/// the opacity field (every other numeric field in params_panel_view.dart)
/// lost focus the instant the real, non-floating keyboard opened - a second
/// tap, once the keyboard was already up, was needed to actually start
/// editing. A floating keyboard never triggered it.
///
/// Diagnosed root cause: opening a real keyboard shrinks the Scaffold
/// body (Flutter's default resizeToAvoidBottomInset), which cascades a
/// rebuild down through every plain StatelessWidget between main.dart's
/// own LayoutBuilder and the numeric field - and the field used to
/// build a BRAND NEW TextEditingController inline on every rebuild,
/// which is exactly the kind of thing that can knock an actively-
/// focused field out of its edit state. A floating keyboard doesn't
/// resize the body, so no cascade, no bug - matching the report's own
/// observation about floating-keyboard mode being unaffected.
///
/// This test drives the REAL app shell (MovementMobileApp, from main.dart)
/// through exactly that mechanism - MediaQuery.viewInsets changing the way it
/// does when a real keyboard opens (per testing approach) - not an isolated
/// harness, so it actually exercises the same widget-rebuild path the bug
/// lived in.
void main() {
  testWidgets('a numeric field keeps its focus AND its in-progress typed text through the same viewInsets change a real keyboard opening causes', (tester) async {
    // MovementMobileApp() constructs its own AppState (and default
    // project) internally - the default test surface (800x600) is wide
    // enough to land in the >=700px "wide" branch of main.dart's
    // responsive layout, showing ParamsPanelView directly in its fixed
    // side column rather than behind the mobile DraggableScrollableSheet.
    await tester.pumpWidget(MovementMobileApp());
    await tester.pumpAndSettle();

    // opacity is the LAST numeric field params_panel_view.dart builds
    // (parent selector, anchor x2, scale x2, rotation, then opacity) -
    // find.byType(TextField).last reaches it without depending on
    // params_panel_view.dart's private widget classes, which a
    // different-library test file can't reference directly anyway.
    final opacityField = find.byType(TextField).last;

    // showKeyboard is flutter_test's own standard way to focus an
    // editable field AND mark the fake software keyboard "visible" -
    // the same signal a real, non-floating keyboard opening produces.
    await tester.showKeyboard(opacityField);
    expect(tester.testTextInput.isVisible, isTrue, reason: 'sanity check: the field must actually be focused/attached before simulating the keyboard-open resize');

    // simulate mid-edit: the user has started typing a new value but
    // hasn't submitted it yet - exactly the window during which a real
    // keyboard's OPEN animation would trigger the Scaffold resize this
    // bug was caused by.
    await tester.enterText(opacityField, '0.');
    await tester.pump();
    expect(find.text('0.'), findsOneWidget);

    // this is the actual mechanism identified: a real (non-floating) keyboard
    // opening changes MediaQuery. viewInsets.bottom, which Scaffold's default
    // resizeToAvoidBottomInset turns into a smaller body height, cascading a
    // rebuild through every plain widget in between - including the numeric
    // field.
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(() => tester.view.resetViewInsets());
    await tester.pump();

    // the field must still be genuinely focused/attached (not silently
    // detached and needing a second tap, per AND must still show exactly what
    // was mid-typed, not a reverted/ reformatted value from a
    // freshly-constructed controller.
    expect(tester.testTextInput.isVisible, isTrue, reason: 'the field must stay focused across the keyboard-open resize, not require a second tap');
    expect(find.text('0.'), findsOneWidget, reason: 'in-progress typed text must survive the same rebuild, not get clobbered by a fresh TextEditingController');
  });
}
